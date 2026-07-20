local central = require("duke.maven_central")
local pom = require("duke.pom")
local pom_file = require("duke.pom_file")

local M = {}

local registry = {}
local lifetime_ms = 30 * 60 * 1000

local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end
  for index, line in ipairs(left) do
    if right[index] ~= line then
      return false
    end
  end
  return true
end

local function complete_once(callback)
  local completed = false
  return function(err, result)
    if completed then
      return
    end
    completed = true
    vim.schedule(function()
      pcall(callback, err, result)
    end)
  end
end

local function random_id()
  for _ = 1, 4 do
    local value, err = vim.uv.random(24)
    if not value then
      return nil, "cannot create upgrade plan ID: " .. tostring(err)
    end
    local id = value:gsub(".", function(char)
      return string.format("%02x", string.byte(char))
    end)
    if not registry[id] then
      return id
    end
  end
  return nil, "cannot create unique upgrade plan ID"
end

local function coordinate_parts(coordinate)
  if type(coordinate) ~= "string" then
    return nil
  end
  local group_id, artifact_id = coordinate:match("^([^:]+):([^:]+)$")
  if not group_id or group_id == "" or artifact_id == "" then
    return nil
  end
  return group_id, artifact_id
end

local function selected_dependency(model, coordinate)
  local matches = {}
  for _, dependency in ipairs(model.dependencies) do
    if dependency.coordinate == coordinate then
      matches[#matches + 1] = dependency
    end
  end
  if #matches == 0 then
    return nil, "dependency is not declared in root dependencies: " .. coordinate
  end
  if #matches > 1 then
    return nil, "dependency has duplicate root declarations: " .. coordinate
  end
  return matches[1]
end

local function resolve_versions(changes, opts, callback)
  local index = 1
  local function next_change()
    local change = changes[index]
    if not change then
      callback()
      return
    end
    index = index + 1
    if type(change.new_version) == "string" and change.new_version ~= "" then
      next_change()
      return
    end
    local group_id, artifact_id = coordinate_parts(change.coordinate)
    if not group_id then
      callback("invalid dependency coordinate: " .. tostring(change.coordinate))
      return
    end
    local settled = false
    local ok, start_err = pcall(central.versions, group_id, artifact_id, function(err, versions)
      if settled then
        return
      end
      settled = true
      if err then
        callback(err)
        return
      end
      if not versions or not versions[1] then
        callback("no Maven Central versions found for " .. change.coordinate)
        return
      end
      change.new_version = versions[1]
      next_change()
    end, opts.runner)
    if not ok and not settled then
      settled = true
      callback("cannot start Maven Central lookup: " .. tostring(start_err))
    end
  end
  next_change()
end

local function canonical_plan(opts, lines, buffer, was_modified, model, changes)
  local pom_changes = {}
  local display_changes = {}
  local target_changes = {}
  local affected = {}
  local shared = {}

  for _, requested in ipairs(changes) do
    local dependency, dependency_err = selected_dependency(model, requested.coordinate)
    if not dependency then
      return nil, dependency_err
    end
    local target = dependency
    local current_version = dependency.version
    local property_name = current_version and current_version:match("^%${([%w_.-]+)}$")
    local consumers = { requested.coordinate }
    local source_kind = "dependency"
    if property_name then
      local property = model.properties[property_name]
      if not property then
        return nil, "dependency version property is not a direct root property: " .. property_name
      end
      if property.value:match("^%${[^}]+}$") then
        return nil, "interpolated dependency version property is not editable: " .. property_name
      end
      if #property.other_consumers > 0 then
        return nil, "dependency version property has other consumers: " .. property_name
      end
      target = property
      current_version = property.value
      consumers = vim.deepcopy(property.consumers)
      source_kind = "property"
    elseif not dependency.version or not dependency._version_start then
      return nil, "dependency has no editable root version: " .. requested.coordinate
    end
    if requested.new_version == current_version then
      return nil, "dependency already uses selected version: " .. requested.coordinate
    end

    local target_key = tostring(target._value_start or target._version_start)
    local existing = target_changes[target_key]
    if existing and existing.new_version ~= requested.new_version then
      return nil, "shared property received conflicting target versions: " .. property_name
    end
    if not existing then
      local change = { target = target, new_version = requested.new_version }
      target_changes[target_key] = change
      pom_changes[#pom_changes + 1] = change
      display_changes[#display_changes + 1] = {
        coordinate = requested.coordinate,
        source_kind = source_kind,
        property = property_name,
        line = target.line or target.start_line,
        current_version = current_version,
        new_version = requested.new_version,
        consumers = vim.deepcopy(consumers),
      }
      if property_name and #consumers > 1 then
        shared[#shared + 1] = {
          name = property_name,
          consumers = vim.deepcopy(consumers),
        }
      end
      for _, coordinate in ipairs(consumers) do
        affected[coordinate] = true
      end
    end
  end

  local after, update_err = pom.update_versions(lines, pom_changes)
  if update_err then
    return nil, update_err
  end
  local affected_coordinates = vim.tbl_keys(affected)
  table.sort(affected_coordinates)
  table.sort(shared, function(left, right)
    return left.name < right.name
  end)
  local id, id_err = random_id()
  if not id then
    return nil, id_err
  end
  local path = absolute(opts.pom_path)
  local fingerprint = vim.fn.sha256(table.concat(lines, "\n"))
  local descriptor = {
    id = id,
    pom_path = path,
    preview = {
      before = vim.deepcopy(lines),
      after = vim.deepcopy(after),
    },
    changes = vim.deepcopy(display_changes),
    affected_coordinates = vim.deepcopy(affected_coordinates),
    shared_properties = vim.deepcopy(shared),
    fingerprint = fingerprint,
  }
  registry[id] = {
    id = id,
    pom_path = path,
    before = vim.deepcopy(lines),
    after = vim.deepcopy(after),
    buffer = buffer,
    was_modified = was_modified == true,
    changes = display_changes,
    affected_coordinates = affected_coordinates,
    expires_at = vim.uv.now() + lifetime_ms,
  }
  return descriptor
end

function M.build(opts, callback)
  local complete = complete_once(callback)
  if type(opts) ~= "table" then
    complete("options must be a table")
    return
  end
  if type(opts.pom_path) ~= "string" or opts.pom_path == "" then
    complete("pom_path must be a non-empty string")
    return
  end
  if type(opts.changes) ~= "table" or #opts.changes == 0 then
    complete("changes must be a non-empty list")
    return
  end
  local changes = vim.deepcopy(opts.changes)
  local seen = {}
  for _, change in ipairs(changes) do
    if not coordinate_parts(change.coordinate) then
      complete("invalid dependency coordinate: " .. tostring(change.coordinate))
      return
    end
    if seen[change.coordinate] then
      complete("duplicate dependency change: " .. change.coordinate)
      return
    end
    seen[change.coordinate] = true
    if
      change.new_version ~= nil
      and (type(change.new_version) ~= "string" or change.new_version == "")
    then
      complete("new_version must be a non-empty string")
      return
    end
  end

  local path = absolute(opts.pom_path)
  local lines, _, _, read_err = pom_file.read(path)
  if not lines then
    complete(read_err)
    return
  end
  local model, model_err = pom.model(lines)
  if not model then
    complete(model_err)
    return
  end
  for _, change in ipairs(changes) do
    local _, dependency_err = selected_dependency(model, change.coordinate)
    if dependency_err then
      complete(dependency_err)
      return
    end
  end
  resolve_versions(changes, opts, function(resolve_err)
    if resolve_err then
      complete(resolve_err)
      return
    end
    local current, current_buffer, current_modified, current_err = pom_file.read(path)
    if not current then
      complete(current_err)
      return
    end
    if not same_lines(lines, current) then
      complete("pom.xml changed during version lookup; create a new plan")
      return
    end
    local current_model, current_model_err = pom.model(current)
    if not current_model then
      complete(current_model_err)
      return
    end
    local descriptor, plan_err = canonical_plan(
      opts,
      current,
      current_buffer,
      current_modified == true,
      current_model,
      changes
    )
    complete(plan_err, descriptor)
  end)
end

function M.apply(descriptor, callback)
  local complete = complete_once(callback)
  local id = type(descriptor) == "table" and descriptor.id or nil
  local plan = type(id) == "string" and registry[id] or nil
  if not plan or plan.expires_at < vim.uv.now() then
    if id then
      registry[id] = nil
    end
    complete("unknown or expired upgrade plan")
    return
  end
  registry[id] = nil

  local lines, buffer, was_modified, read_err = pom_file.read(plan.pom_path)
  if not lines then
    complete(read_err)
    return
  end
  if not same_lines(lines, plan.before) then
    complete("pom.xml changed after plan creation; create a new plan")
    return
  end
  local saved, save_err = pom_file.save(plan.pom_path, plan.after, buffer, was_modified)
  if saved == nil then
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      local current = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
      if same_lines(current, plan.after) then
        pcall(vim.api.nvim_buf_set_lines, buffer, 0, -1, false, plan.before)
        vim.bo[buffer].modified = was_modified
      end
    end
    complete(save_err)
    return
  end
  require("duke.events").build_changed(plan.pom_path, "plan_upgrades", {
    coordinates = vim.deepcopy(plan.affected_coordinates),
    changes = vim.deepcopy(plan.changes),
    saved = saved,
  })
  complete(nil, {
    pom_path = plan.pom_path,
    saved = saved,
    coordinates = vim.deepcopy(plan.affected_coordinates),
    changes = vim.deepcopy(plan.changes),
  })
end

return M
