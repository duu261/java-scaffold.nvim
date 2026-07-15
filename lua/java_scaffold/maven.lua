local M = {}

local function sanitize_segment(segment)
  local clean = segment:gsub("[^%w_]", "")
  if clean:match("^%d") then
    clean = "_" .. clean
  end
  return clean
end

function M.package_name(group_id, artifact_id)
  local parts = {}
  for part in group_id:gmatch("[^.]+") do
    local clean = sanitize_segment(part)
    if clean ~= "" then
      parts[#parts + 1] = clean
    end
  end
  local artifact = sanitize_segment(artifact_id)
  if artifact ~= "" then
    parts[#parts + 1] = artifact
  end
  return table.concat(parts, ".")
end

function M.validate(group_id, artifact_id)
  if
    type(group_id) ~= "string"
    or group_id == ""
    or not group_id:match("^[%w_.-]+$")
    or group_id:find("..", 1, true)
  then
    return "groupId contains invalid characters"
  end
  if
    type(artifact_id) ~= "string"
    or artifact_id == ""
    or not artifact_id:match("^[%w][%w_.-]*$")
  then
    return "artifactId contains invalid characters"
  end
end

function M.build_args(opts)
  return {
    "-B",
    "archetype:generate",
    "-DarchetypeGroupId=" .. opts.archetype.group_id,
    "-DarchetypeArtifactId=" .. opts.archetype.artifact_id,
    "-DarchetypeVersion=" .. opts.archetype.version,
    "-DgroupId=" .. opts.group_id,
    "-DartifactId=" .. opts.artifact_id,
    "-Dversion=" .. opts.version,
    "-Dpackage=" .. (opts.package_name or M.package_name(opts.group_id, opts.artifact_id)),
    "-DjavaCompilerVersion=" .. opts.java_version,
    "-DoutputDirectory=" .. (opts.output_directory or opts.cwd),
    "-DinteractiveMode=false",
  }
end

function M.create(opts, callback)
  local validation_error = M.validate(opts.group_id, opts.artifact_id)
  if validation_error then
    callback(validation_error)
    return
  end

  local target = vim.fs.joinpath(opts.cwd, opts.artifact_id)
  if vim.uv.fs_stat(target) then
    callback("target already exists: " .. target)
    return
  end

  local fs = require("java_scaffold.fs")
  local staging, staging_error = fs.make_staging(opts.cwd)
  if not staging then
    callback(staging_error)
    return
  end

  local staged_project = vim.fs.joinpath(staging, opts.artifact_id)
  local args = M.build_args(vim.tbl_extend("force", opts, { output_directory = staging }))

  require("java_scaffold.process").run(
    opts.command,
    args,
    { cwd = opts.cwd, timeout = opts.timeout, env = opts.env },
    function(result)
      if result.code ~= 0 then
        fs.cleanup(staging)
        local detail = require("java_scaffold.process").detail(result)
        callback("Maven project creation failed: " .. detail)
        return
      end
      if not vim.uv.fs_stat(vim.fs.joinpath(staged_project, "pom.xml")) then
        fs.cleanup(staging)
        callback("Maven exited successfully but no pom.xml was created")
        return
      end
      local promoted, promote_error = fs.promote(staged_project, target)
      fs.cleanup(staging)
      if not promoted then
        callback(promote_error)
        return
      end
      callback(nil, target)
    end
  )
end

return M
