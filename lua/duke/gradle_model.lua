local process = require("duke.process")

local M = {}

local function parse_version(stdout)
  return stdout and stdout:match("Gradle%s+([%w_.-]+)")
end

local function parse_projects(stdout)
  local projects = {}
  local root_name = stdout and stdout:match("Root project '([^']+)'")
  if root_name then
    projects[#projects + 1] = { id = ":", name = root_name }
  end
  for path in (stdout or ""):gmatch("Project '(:[^']+)'") do
    projects[#projects + 1] = {
      id = path,
      name = path:match("([^:]+)$"),
    }
  end
  return projects
end

local function dependency_content(line)
  local position = line:find("+--- ", 1, true) or line:find("\\--- ", 1, true)
  if not position then
    return nil
  end
  return vim.trim(line:sub(position + 5)), position == 1
end

local function parse_dependencies(stdout, configuration)
  local dependencies = {}
  local unknown = {}
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local content, direct = dependency_content(line)
    if content and not content:match("^project%s") then
      local requested, selected = content:match("^(.-)%s+%-%>%s+([^%s]+)")
      local notation = requested or content
      notation = notation:gsub("%s+%b()", "")
      local group_id, artifact_id, version = notation:match("^([^:%s]+):([^:%s]+):([^%s]+)")
      if group_id and artifact_id and version then
        dependencies[#dependencies + 1] = {
          coordinate = group_id .. ":" .. artifact_id,
          requested_version = version,
          version = selected or version,
          configuration = configuration,
          direct = direct,
        }
      elseif not content:match("^platform%(") then
        unknown[#unknown + 1] = line
      end
    end
  end
  return dependencies, unknown
end

function M.enrich(snapshot, opts, callback)
  opts = opts or {}
  local enriched = vim.deepcopy(snapshot)
  enriched.diagnostics = enriched.diagnostics or {}
  enriched.analysis = {
    projects = {},
    dependencies = {},
  }
  local command = enriched.environment.wrapper or opts.gradle_command or "gradle"
  local reports = {
    { kind = "version", args = { "--version" } },
    { kind = "projects", args = { "--console=plain", "--no-daemon", "projects" } },
    {
      kind = "dependencies",
      configuration = "runtimeClasspath",
      args = {
        "--console=plain",
        "--no-daemon",
        "dependencies",
        "--configuration",
        "runtimeClasspath",
      },
    },
    {
      kind = "dependencies",
      configuration = "testRuntimeClasspath",
      args = {
        "--console=plain",
        "--no-daemon",
        "dependencies",
        "--configuration",
        "testRuntimeClasspath",
      },
    },
  }
  local index = 1
  local partial = false
  local finished = false

  local function finish()
    if finished then
      return
    end
    finished = true
    enriched.state = partial and "partial" or "resolved"
    pcall(callback, nil, enriched)
  end

  local function next_report()
    local report = reports[index]
    if not report then
      finish()
      return
    end
    index = index + 1
    process.run(command, report.args, {
      cwd = enriched.root,
      env = opts.env,
      timeout = opts.timeout,
    }, function(result)
      if result.code ~= 0 then
        partial = true
        enriched.diagnostics[#enriched.diagnostics + 1] = {
          code = "gradle_report_failed",
          severity = "warning",
          message = report.kind .. ": " .. process.detail(result),
        }
        next_report()
        return
      end
      if report.kind == "version" then
        local version = parse_version(result.stdout)
        if version then
          enriched.environment.gradle_version = version
        else
          partial = true
          enriched.diagnostics[#enriched.diagnostics + 1] = {
            code = "unknown_gradle_version",
            severity = "warning",
            message = "Gradle version output was not recognized",
          }
        end
      elseif report.kind == "projects" then
        enriched.analysis.projects = parse_projects(result.stdout)
        if #enriched.analysis.projects == 0 then
          partial = true
          enriched.diagnostics[#enriched.diagnostics + 1] = {
            code = "unknown_gradle_projects",
            severity = "warning",
            message = "Gradle project report was not recognized",
          }
        end
      else
        local dependencies, unknown = parse_dependencies(result.stdout, report.configuration)
        vim.list_extend(enriched.analysis.dependencies, dependencies)
        if #unknown > 0 then
          partial = true
          enriched.diagnostics[#enriched.diagnostics + 1] = {
            code = "unknown_gradle_dependencies",
            severity = "warning",
            message = "some Gradle dependency lines were not recognized",
            lines = unknown,
          }
        end
      end
      next_report()
    end)
  end

  next_report()
end

return M
