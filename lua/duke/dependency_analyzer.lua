local M = {}

local function key(module_id, coordinate)
  return module_id .. "\0" .. coordinate
end

local function index_declarations(module)
  local declarations = {}
  for _, dependency in ipairs(module.model.dependencies or {}) do
    local list = declarations[dependency.coordinate] or {}
    list[#list + 1] = dependency
    declarations[dependency.coordinate] = list
  end
  return declarations
end

local function effective_versions(module)
  local versions = {}
  local effective = module.resolved and module.resolved.effective
  for _, dependency in ipairs((effective and effective.dependencies) or {}) do
    versions[dependency.coordinate] = dependency.version
  end
  return versions
end

function M.analyze(snapshot)
  local analysis = {
    modules = {},
    dependencies = {},
    findings = {
      drift = {},
      duplicates = {},
      conflicts = {},
      unknown = {},
    },
    paths = {},
  }
  local resolved_versions = {}

  for _, module in ipairs(snapshot.modules or {}) do
    analysis.modules[#analysis.modules + 1] = module.id
    local declarations = index_declarations(module)
    local effective = effective_versions(module)
    for coordinate, owners in pairs(declarations) do
      if #owners > 1 then
        analysis.findings.duplicates[#analysis.findings.duplicates + 1] = {
          coordinate = coordinate,
          module_id = module.id,
          lines = vim.tbl_map(function(owner)
            return owner.start_line
          end, owners),
        }
      end
    end

    local root = module.resolved and module.resolved.tree
    local function walk(node, path, depth)
      for _, child in ipairs(node.children or {}) do
        local child_path = vim.deepcopy(path)
        child_path[#child_path + 1] = child.coordinate
        local owners = declarations[child.coordinate]
        local owner = owners and owners[1] or nil
        local property_name = owner and owner.version and owner.version:match("^%${([%w_.-]+)}$")
        local entry = {
          coordinate = child.coordinate,
          module_id = module.id,
          version = child.version,
          scope = child.scope,
          depth = depth,
          direct = depth == 1,
          raw_owner = owner,
          effective_version = effective[child.coordinate],
          property = property_name,
          property_consumers = property_name
              and module.model.properties
              and module.model.properties[property_name]
              and module.model.properties[property_name].consumer_refs
            or nil,
        }
        analysis.dependencies[#analysis.dependencies + 1] = entry
        local paths = analysis.paths[key(module.id, child.coordinate)] or {}
        paths[#paths + 1] = child_path
        analysis.paths[key(module.id, child.coordinate)] = paths

        if not owner then
          analysis.findings.unknown[#analysis.findings.unknown + 1] = entry
        end
        if child.omitted_for_conflict or child.omittedForConflict then
          analysis.findings.conflicts[#analysis.findings.conflicts + 1] = {
            coordinate = child.coordinate,
            module_id = module.id,
            omitted = child.version,
            selected = child.omitted_for_conflict or child.omittedForConflict,
            path = child_path,
          }
        else
          local versions = resolved_versions[child.coordinate] or {}
          versions[child.version or "unknown"] = true
          resolved_versions[child.coordinate] = versions
        end
        walk(child, child_path, depth + 1)
      end
    end
    if root then
      walk(root, { module.id }, 1)
    end
  end

  for coordinate, versions in pairs(resolved_versions) do
    local values = vim.tbl_keys(versions)
    table.sort(values)
    if #values > 1 then
      analysis.findings.drift[#analysis.findings.drift + 1] = {
        coordinate = coordinate,
        versions = values,
      }
    end
  end
  for _, findings in pairs(analysis.findings) do
    table.sort(findings, function(left, right)
      if left.coordinate ~= right.coordinate then
        return left.coordinate < right.coordinate
      end
      return (left.module_id or "") < (right.module_id or "")
    end)
  end
  return analysis
end

function M.paths(analysis, coordinate, module_id)
  return vim.deepcopy(analysis.paths[key(module_id, coordinate)] or {})
end

return M
