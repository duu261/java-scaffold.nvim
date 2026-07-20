describe("Gradle workspace enrichment", function()
  local calls
  local original_get_runtime_file

  local function snapshot()
    return {
      root = "/workspace",
      kind = "gradle",
      state = "local",
      modules = {},
      diagnostics = {},
      environment = { wrapper = "/workspace/gradlew" },
    }
  end

  local function report_key(args)
    if args[1] == "--version" then
      return "version"
    end
    if vim.tbl_contains(args, "dukeWorkspaceIntelligenceJavaModelV1") then
      return "java_model"
    end
    if args[3] == "projects" or args[3] == "javaToolchains" then
      return args[3]
    end
    if args[3] and args[3]:match("dependencies$") then
      return args[3] .. ":" .. args[5]
    end
  end

  local function set_reports(reports, fallback)
    package.loaded["duke.process"] = {
      detail = function(result)
        return result.stderr
      end,
      run = function(command, args, opts, callback)
        calls[#calls + 1] = { command = command, args = args, opts = opts }
        local response = reports[report_key(args)]
          or fallback
          or { stdout = (args[5] or "") .. "\nNo dependencies\n" }
        if type(response) == "string" then
          response = { stdout = response }
        end
        callback({
          code = response.code or 0,
          stdout = response.stdout or "",
          stderr = response.stderr or "",
        })
      end,
    }
  end

  local function resolved_reports()
    return {
      version = "Gradle 9.6.1\n",
      projects = "Root project 'demo'\n"
        .. "+--- Project ':app'\n"
        .. "+--- Project ':list'\n"
        .. "\\--- Project ':utilities'\n",
      java_model = "DUKE_JAVA_MODEL\t:app\t17\t17\t17\n"
        .. "DUKE_JAVA_MODEL\t:list\t17\t17\t17\n"
        .. "DUKE_JAVA_MODEL\t:utilities\t17\t17\t17\n",
      javaToolchains = "| Language Version:   8\n"
        .. "| Language Version:   17\n"
        .. "| Language Version:   23\n",
      [":app:dependencies:runtimeClasspath"] = "runtimeClasspath\n"
        .. "+--- org.apache.commons:commons-text -> 1.14.0\n"
        .. "|    \\--- org.apache.commons:commons-lang3:3.18.0\n"
        .. "\\--- project :utilities\n",
      [":app:dependencies:testRuntimeClasspath"] = "testRuntimeClasspath\n"
        .. "\\--- org.junit.jupiter:junit-jupiter:5.13.4\n",
    }
  end

  local function inspect(opts)
    package.loaded["duke.gradle_model"] = nil
    local result
    local callback_count = 0
    require("duke.gradle_model").enrich(snapshot(), opts or {}, function(err, value)
      assert.is_nil(err)
      callback_count = callback_count + 1
      result = value
    end)
    return result, callback_count
  end

  before_each(function()
    calls = {}
    original_get_runtime_file = vim.api.nvim_get_runtime_file
  end)

  after_each(function()
    vim.api.nvim_get_runtime_file = original_get_runtime_file
    package.loaded["duke.gradle_model"] = nil
    package.loaded["duke.process"] = nil
  end)

  it("normalizes scoped Java, toolchain, and dependency reports", function()
    set_reports(resolved_reports())

    local result, callback_count = inspect({ timeout = 5000 })

    assert.equals(1, callback_count)
    assert.equals("resolved", result.state)
    assert.equals("9.6.1", result.environment.gradle_version)
    assert.equals("plain-console-v1", result.environment.gradle_parser_family)
    assert.equals(4, #result.analysis.projects)
    assert.same({ "8", "17", "23" }, result.analysis.toolchains)
    assert.equals(3, #result.analysis.java)
    assert.equals("17", result.analysis.java[1].language_version)
    assert.equals(3, #result.analysis.dependencies)
    assert.equals("1.14.0", result.analysis.dependencies[1].version)
    assert.is_nil(result.analysis.dependencies[1].requested_version)
    assert.equals(":app", result.analysis.dependencies[1].project_id)
    assert.same({ "org.apache.commons:commons-text" }, result.analysis.dependencies[1].path)
    assert.same({
      "org.apache.commons:commons-text",
      "org.apache.commons:commons-lang3",
    }, result.analysis.dependencies[2].path)
    assert.same({ "--version" }, calls[1].args)
    assert.same({ "--console=plain", "--no-daemon", "projects" }, calls[2].args)
    assert.same({
      "--console=plain",
      "--no-daemon",
      ":app:dependencies",
      "--configuration",
      "runtimeClasspath",
    }, calls[5].args)
    assert.equals("/workspace/gradlew", calls[1].command)
    assert.equals("/workspace", calls[1].opts.cwd)
  end)

  it("returns partial data when Gradle reports fail", function()
    set_reports({}, { code = 1, stderr = "configuration missing" })

    local result = inspect()

    assert.equals("partial", result.state)
    assert.equals("gradle_report_failed", result.diagnostics[1].code)
  end)

  it("keeps useful data and rejects failed dependency nodes", function()
    local reports = resolved_reports()
    reports.projects = "Root project 'demo'\n\\--- Project ':app'\n"
    reports.java_model = "DUKE_JAVA_MODEL\t:\t17\t17\t17\n" .. "DUKE_JAVA_MODEL\t:app\t17\t17\t17\n"
    reports[":dependencies:runtimeClasspath"] =
      "runtimeClasspath\n\\--- com.acme:broken:1.0 FAILED\n"
    reports[":app:dependencies:runtimeClasspath"] = "runtimeClasspath\n"
    reports[":app:dependencies:testRuntimeClasspath"] = {
      code = 1,
      stderr = "configuration failed",
    }
    set_reports(reports)

    local result, callback_count = inspect()

    assert.equals(1, callback_count)
    assert.equals("partial", result.state)
    assert.equals(2, #result.analysis.projects)
    assert.equals(2, #result.analysis.java)
    assert.equals(0, #result.analysis.dependencies)
    assert.equals("unknown_gradle_dependencies", result.diagnostics[1].code)
    assert.equals("gradle_report_failed", result.diagnostics[2].code)
    assert.same({
      "--console=plain",
      "--no-daemon",
      ":dependencies",
      "--configuration",
      "runtimeClasspath",
    }, calls[5].args)
  end)

  it("returns partial data when the bundled Java model script is missing", function()
    vim.api.nvim_get_runtime_file = function(path, all)
      if path == "lua/duke/gradle_model.init.gradle" then
        return {}
      end
      return original_get_runtime_file(path, all)
    end
    set_reports(resolved_reports())

    local result = inspect()

    assert.equals("partial", result.state)
    assert.equals("missing_gradle_model_script", result.diagnostics[1].code)
    assert.equals(3, #calls)
  end)
end)
