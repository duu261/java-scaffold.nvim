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

local function parse_java_model(stdout)
  local projects = {}
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local project_id, language_version, source_compatibility, target_compatibility =
      line:match("^DUKE_JAVA_MODEL\t([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
    if project_id then
      projects[#projects + 1] = {
        project_id = project_id,
        language_version = language_version ~= "" and language_version or nil,
        source_compatibility = source_compatibility ~= "" and source_compatibility or nil,
        target_compatibility = target_compatibility ~= "" and target_compatibility or nil,
      }
    end
  end
  return projects
end

local function parse_toolchains(stdout)
  local versions = {}
  local seen = {}
  for version in (stdout or ""):gmatch("Language Version:%s*([%w_.-]+)") do
    if not seen[version] then
      seen[version] = true
      versions[#versions + 1] = version
    end
  end
  return versions
end

local function dependency_content(line)
  local position = line:find("+--- ", 1, true) or line:find("\\--- ", 1, true)
  if not position then
    return nil
  end
  return vim.trim(line:sub(position + 5)), math.floor((position - 1) / 5)
end

local function parse_dependencies(stdout, configuration, project_id)
  local dependencies = {}
  local unknown = {}
  local stack = {}
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local content, depth = dependency_content(line)
    if content then
      while #stack > depth do
        table.remove(stack)
      end
    end
    if content and content:match("^project%s") then
      local path = content:match("^project%s+'?([^'%s]+)'?")
      stack[depth + 1] = path and ("project " .. path) or content
    elseif content and content:match("%s+FAILED%s*$") then
      unknown[#unknown + 1] = line
    elseif content then
      local requested, selected = content:match("^(.-)%s+%-%>%s+([^%s]+)")
      local notation = requested or content
      notation = notation:gsub("%s+%b()", "")
      local group_id, artifact_id, version = notation:match("^([^:%s]+):([^:%s]+):([^%s]+)")
      if not group_id and selected then
        group_id, artifact_id = notation:match("^([^:%s]+):([^:%s]+)$")
      end
      if group_id and artifact_id and (version or selected) then
        local coordinate = group_id .. ":" .. artifact_id
        local path = {}
        for index = 1, depth do
          path[#path + 1] = stack[index]
        end
        path[#path + 1] = coordinate
        dependencies[#dependencies + 1] = {
          coordinate = coordinate,
          requested_version = version,
          version = selected or version,
          configuration = configuration,
          project_id = project_id,
          direct = depth == 0,
          path = path,
        }
        stack[depth + 1] = coordinate
      elseif not content:match("^platform%(") then
        unknown[#unknown + 1] = line
      end
    end
  end
  return dependencies, unknown
end

local function model_script()
  return vim.api.nvim_get_runtime_file("lua/duke/gradle_model.init.gradle", false)[1]
end

local function dependency_reports(java_projects)
  local reports = {}
  for _, project in ipairs(java_projects) do
    for _, configuration in ipairs({ "runtimeClasspath", "testRuntimeClasspath" }) do
      local task = project.project_id == ":" and ":dependencies"
        or project.project_id .. ":dependencies"
      reports[#reports + 1] = {
        kind = "dependencies",
        project_id = project.project_id,
        configuration = configuration,
        args = {
          "--console=plain",
          "--no-daemon",
          task,
          "--configuration",
          configuration,
        },
      }
    end
  end
  return reports
end

function M.enrich(snapshot, opts, callback)
  opts = opts or {}
  local enriched = vim.deepcopy(snapshot)
  enriched.diagnostics = enriched.diagnostics or {}
  enriched.analysis = {
    projects = {},
    java = {},
    toolchains = {},
    dependencies = {},
  }
  local command = enriched.environment.wrapper or opts.gradle_command or "gradle"
  local script = model_script()
  local partial = false
  local reports = {
    { kind = "version", args = { "--version" } },
    { kind = "projects", args = { "--console=plain", "--no-daemon", "projects" } },
  }
  if script then
    reports[#reports + 1] = {
      kind = "java_model",
      args = {
        "--console=plain",
        "--no-daemon",
        "--init-script",
        script,
        "dukeWorkspaceIntelligenceJavaModelV1",
      },
    }
  else
    partial = true
    enriched.diagnostics[#enriched.diagnostics + 1] = {
      code = "missing_gradle_model_script",
      severity = "warning",
      message = "Gradle Java model script is unavailable",
    }
  end
  reports[#reports + 1] = {
    kind = "toolchains",
    args = { "--console=plain", "--no-daemon", "javaToolchains" },
  }
  local index = 1
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
          enriched.environment.gradle_parser_family = "plain-console-v1"
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
      elseif report.kind == "java_model" then
        enriched.analysis.java = parse_java_model(result.stdout)
        if #enriched.analysis.java == 0 then
          partial = true
          enriched.diagnostics[#enriched.diagnostics + 1] = {
            code = "unknown_gradle_java_model",
            severity = "warning",
            message = "Gradle Java model output was not recognized",
          }
        else
          vim.list_extend(reports, dependency_reports(enriched.analysis.java))
        end
      elseif report.kind == "toolchains" then
        enriched.analysis.toolchains = parse_toolchains(result.stdout)
        if #enriched.analysis.toolchains == 0 then
          partial = true
          enriched.diagnostics[#enriched.diagnostics + 1] = {
            code = "unknown_gradle_toolchains",
            severity = "warning",
            message = "Gradle toolchain output was not recognized",
          }
        end
      else
        local dependencies, unknown =
          parse_dependencies(result.stdout, report.configuration, report.project_id)
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
