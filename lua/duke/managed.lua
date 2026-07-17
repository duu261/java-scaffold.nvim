local M = {}

local known_scopes = {
  compile = true,
  test = true,
  runtime = true,
  provided = true,
  system = true,
  import = true,
}

---Parse one mvn dependency:list output line.
---@param line string
---@return { group_id: string, artifact_id: string, version: string } | nil
function M.parse_line(line)
  if type(line) ~= "string" then
    return nil
  end
  -- Strip leading/trailing whitespace.
  line = line:match("^%s*(.-)%s*$")
  -- Strip "[INFO]" prefix and any following whitespace.
  line = line:gsub("^%[INFO%]%s*", "")
  -- Reject empty or obviously malformed lines.
  if line == "" or line:match("^:") or line:match(":$") or line:find("::", 1, true) then
    return nil
  end
  -- Strip trailing "-- module name [auto]" suffix.
  local cleaned = line:gsub("%s*%-%-%s*module%s+.+", "")
  local parts = {}
  for part in cleaned:gmatch("[^:]+") do
    parts[#parts + 1] = part
  end
  if #parts < 4 then
    return nil
  end
  local group_id = parts[1]
  local artifact_id = parts[2]
  if group_id == "" or artifact_id == "" then
    return nil
  end
  local last = parts[#parts]
  -- Strip " (optional)" suffix from scope.
  last = last:gsub("%s*%(optional%)%s*$", "")
  local version
  if #parts == 4 then
    version = parts[4]
  elseif #parts == 5 then
    if known_scopes[last] then
      version = parts[4] -- groupId:artifactId:packaging:version:scope
    else
      version = parts[5] -- groupId:artifactId:packaging:classifier:version
    end
  elseif #parts == 6 then
    version = parts[5] -- groupId:artifactId:packaging:classifier:version:scope
  else
    -- 7+ parts: assume second-to-last is version if last is known scope.
    if known_scopes[last] then
      version = parts[#parts - 1]
    else
      version = last
    end
  end
  if not version or version == "" then
    return nil
  end
  return { group_id = group_id, artifact_id = artifact_id, version = version }
end

---Parse full mvn dependency:list stdout into a coordinate→version map.
---@param stdout string
---@return table<string, string>
function M.parse_output(stdout)
  local resolved = {}
  if type(stdout) ~= "string" then
    return resolved
  end
  for line in stdout:gmatch("[^\r\n]+") do
    local dep = M.parse_line(line)
    if dep then
      local key = dep.group_id .. ":" .. dep.artifact_id
      resolved[key] = dep.version
    end
  end
  return resolved
end

---Run mvn dependency:list and return resolved versions for declared managed deps.
---@param pom_path string
---@param declared_managed table[]
---@param callback fun(err: string|nil, resolved: table<string,string>|nil)
function M.resolve(pom_path, declared_managed, callback)
  local pom_dir = vim.fn.fnamemodify(pom_path, ":h")
  local args = { "dependency:list", "-f", pom_path, "--batch-mode" }

  require("duke.process").run("mvn", args, { cwd = pom_dir }, function(result)
    if result.code ~= 0 then
      local detail = vim.trim(result.stderr or "")
      if detail == "" then
        detail = vim.trim(result.stdout or "")
      end
      if detail == "" then
        detail = "mvn exited with code " .. tostring(result.code)
      end
      callback("mvn dependency:list failed: " .. detail)
      return
    end
    local resolved = M.parse_output(result.stdout)
    local result_map = {}
    for _, dep in ipairs(declared_managed) do
      local key = dep.group_id .. ":" .. dep.artifact_id
      local version = resolved[key]
      if version then
        result_map[key] = version
      end
    end
    callback(nil, result_map)
  end)
end

return M
