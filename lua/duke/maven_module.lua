---Maven multi-module creation transaction.
---
---Stages a child module privately, mutates the reactor parent POM first, then
---promotes the child. On promotion failure restores the exact pre-edit parent
---when safe; otherwise reports a rollback conflict.

local M = {}

local function once(callback)
  local completed = false
  return function(err, result)
    if completed then
      return
    end
    completed = true
    if type(callback) == "function" then
      callback(err, result)
    end
  end
end

local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function lines_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
    return false
  end
  for index = 1, #left do
    if left[index] ~= right[index] then
      return false
    end
  end
  return true
end

local function child_pom_lines(reactor, artifact_id)
  return {
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<project xmlns="http://maven.apache.org/POM/4.0.0"',
    '  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
    '  xsi:schemaLocation="http://maven.apache.org/POM/4.0.0'
      .. ' https://maven.apache.org/xsd/maven-4.0.0.xsd">',
    "  <modelVersion>4.0.0</modelVersion>",
    "",
    "  <parent>",
    "    <groupId>" .. reactor.group_id .. "</groupId>",
    "    <artifactId>" .. reactor.artifact_id .. "</artifactId>",
    "    <version>" .. reactor.version .. "</version>",
    "    <relativePath>../pom.xml</relativePath>",
    "  </parent>",
    "",
    "  <artifactId>" .. artifact_id .. "</artifactId>",
    "</project>",
  }
end

local function simple_class_name(artifact_id)
  local cleaned = artifact_id:gsub("[^%w]", "")
  if cleaned == "" then
    return "App"
  end
  return cleaned:sub(1, 1):upper() .. cleaned:sub(2)
end

local function write_child_tree(staging, artifact_id, package_name, reactor)
  local project = vim.fs.joinpath(staging, artifact_id)
  local package_path = package_name:gsub("%.", "/")
  local source_dir = vim.fs.joinpath(project, "src", "main", "java", package_path)
  local mkdir_ok = vim.fn.mkdir(source_dir, "p")
  if mkdir_ok == 0 and not vim.uv.fs_stat(source_dir) then
    return nil, "cannot create staged module directories"
  end

  local pom_path = vim.fs.joinpath(project, "pom.xml")
  if vim.fn.writefile(child_pom_lines(reactor, artifact_id), pom_path) ~= 0 then
    return nil, "cannot write staged child pom.xml"
  end

  local class_name = simple_class_name(artifact_id)
  local source_path = vim.fs.joinpath(source_dir, class_name .. ".java")
  local source_lines = {
    "package " .. package_name .. ";",
    "",
    "public class " .. class_name .. " {",
    "}",
  }
  if vim.fn.writefile(source_lines, source_path) ~= 0 then
    return nil, "cannot write staged Java source"
  end

  if not vim.uv.fs_stat(pom_path) then
    return nil, "staged child pom.xml is missing"
  end
  return project
end

local function restore_parent(path, pre_edit, expected, buffer, wrote_disk)
  local current, current_buffer, _, read_error = require("duke.pom_file").read(path)
  if not current then
    return nil, "rollback failed: " .. tostring(read_error)
  end
  if not lines_equal(current, expected) then
    return nil, "rollback conflict: parent changed after save"
  end

  local restore_buffer = current_buffer or buffer
  local keep_unsaved = not wrote_disk and restore_buffer ~= nil
  local saved, save_error =
    require("duke.pom_file").save(path, pre_edit, restore_buffer, keep_unsaved)
  if saved == nil then
    return nil, "rollback failed: " .. tostring(save_error)
  end
  return true
end

---Create a Maven reactor child module.
---@param opts table { reactor_dir, artifact_id, package_name? }
---@param callback function(err, result)
function M.create(opts, callback)
  local complete = once(callback)
  local result = {
    parent_pom = nil,
    module_dir = nil,
    saved = false,
    rolled_back = false,
  }

  local ok, unexpected = pcall(function()
    if type(opts) ~= "table" then
      complete("options must be a table", result)
      return
    end

    local reactor_dir = opts.reactor_dir
    local artifact_id = opts.artifact_id
    if type(reactor_dir) ~= "string" or reactor_dir == "" then
      complete("reactor_dir must be a non-empty string", result)
      return
    end
    if type(artifact_id) ~= "string" or artifact_id == "" then
      complete("artifact_id must be a non-empty string", result)
      return
    end

    reactor_dir = absolute(reactor_dir)
    local parent_pom = vim.fs.joinpath(reactor_dir, "pom.xml")
    result.parent_pom = parent_pom
    local target = vim.fs.joinpath(reactor_dir, artifact_id)
    result.module_dir = absolute(target)

    local stat = vim.uv.fs_stat(reactor_dir)
    if not stat or stat.type ~= "directory" then
      complete("reactor_dir must be an existing directory", result)
      return
    end
    if not vim.uv.fs_stat(parent_pom) then
      complete("reactor pom.xml is missing", result)
      return
    end

    local maven = require("duke.maven")
    local coordinate_error = maven.validate("placeholder.group", artifact_id)
    if coordinate_error then
      complete(coordinate_error, result)
      return
    end

    local pom = require("duke.pom")
    local pom_file = require("duke.pom_file")
    local fs = require("duke.fs")

    local lines, _, _, read_error = pom_file.read(parent_pom)
    if not lines then
      complete(read_error or ("cannot read " .. parent_pom), result)
      return
    end

    local reactor, reactor_error = pom.reactor(lines)
    if not reactor then
      complete(reactor_error, result)
      return
    end

    local package_name = opts.package_name
    if package_name == nil then
      package_name = maven.package_name(reactor.group_id, artifact_id)
    end
    local package_error = maven.validate_package(package_name)
    if package_error then
      complete(package_error, result)
      return
    end

    if vim.uv.fs_stat(target) then
      complete("target already exists: " .. target, result)
      return
    end

    local staging, staging_error = fs.make_staging(reactor_dir)
    if not staging then
      complete(staging_error, result)
      return
    end

    local staged_project, stage_error =
      write_child_tree(staging, artifact_id, package_name, reactor)
    if not staged_project then
      fs.cleanup(staging)
      complete(stage_error, result)
      return
    end

    if vim.uv.fs_stat(target) then
      fs.cleanup(staging)
      complete("target already exists: " .. target, result)
      return
    end

    local latest, buffer, was_modified, latest_error = pom_file.read(parent_pom)
    if not latest then
      fs.cleanup(staging)
      complete(latest_error or ("cannot read " .. parent_pom), result)
      return
    end

    local latest_reactor, latest_reactor_error = pom.reactor(latest)
    if not latest_reactor then
      fs.cleanup(staging)
      complete(latest_reactor_error, result)
      return
    end
    reactor = latest_reactor
    if opts.package_name == nil then
      package_name = maven.package_name(reactor.group_id, artifact_id)
      package_error = maven.validate_package(package_name)
      if package_error then
        fs.cleanup(staging)
        complete(package_error, result)
        return
      end
    end

    -- Refresh staged child against the latest parent coordinates.
    staged_project, stage_error = write_child_tree(staging, artifact_id, package_name, reactor)
    if not staged_project then
      fs.cleanup(staging)
      complete(stage_error, result)
      return
    end

    local updated, count, insert_error = pom.insert_module(latest, artifact_id)
    if insert_error then
      fs.cleanup(staging)
      complete(insert_error, result)
      return
    end
    if count == 0 then
      fs.cleanup(staging)
      complete("module already declared: " .. artifact_id, result)
      return
    end

    local pre_edit = vim.deepcopy(latest)
    local saved, save_error = pom_file.save(parent_pom, updated, buffer, was_modified)
    if saved == nil then
      local restored, restore_error = restore_parent(parent_pom, pre_edit, updated, buffer, false)
      fs.cleanup(staging)
      if not restored then
        complete(tostring(save_error) .. "; " .. tostring(restore_error), result)
        return
      end
      result.rolled_back = true
      complete(save_error, result)
      return
    end
    result.saved = saved and true or false

    local promoted, promote_error = fs.promote(staged_project, target)
    if not promoted then
      local restored, restore_error =
        restore_parent(parent_pom, pre_edit, updated, buffer, result.saved)
      fs.cleanup(staging)
      if not restored then
        complete(tostring(promote_error) .. "; " .. tostring(restore_error), result)
        return
      end
      result.rolled_back = true
      complete(promote_error, result)
      return
    end

    fs.cleanup(staging)
    complete(nil, result)
  end)

  if not ok then
    complete(tostring(unexpected), result)
  end
end

return M
