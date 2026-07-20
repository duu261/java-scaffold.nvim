describe("Gradle workspace enrichment", function()
  local calls
  local outputs
  local gradle_model

  before_each(function()
    calls = {}
    outputs = {
      "Gradle 9.0.0\n",
      "Root project 'demo'\n+--- Project ':app'\n\\--- Project ':lib'\n",
      "runtimeClasspath - Runtime classpath.\n"
        .. "+--- org.slf4j:slf4j-api:2.0.16 -> 2.0.17\n"
        .. "\\--- project :lib\n",
      "testRuntimeClasspath - Runtime classpath.\n\\--- org.junit.jupiter:junit-jupiter:5.13.4\n",
    }
    package.loaded["duke.gradle_model"] = nil
    package.loaded["duke.process"] = {
      detail = function(result)
        return result.stderr
      end,
      run = function(command, args, opts, callback)
        calls[#calls + 1] = { command = command, args = args, opts = opts }
        callback({ code = 0, stdout = outputs[#calls], stderr = "" })
      end,
    }
    gradle_model = require("duke.gradle_model")
  end)

  after_each(function()
    package.loaded["duke.gradle_model"] = nil
    package.loaded["duke.process"] = nil
  end)

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

  it("runs versioned plain-console reports and normalizes known dependency lines", function()
    local result
    gradle_model.enrich(snapshot(), { timeout = 5000 }, function(err, value)
      assert.is_nil(err)
      result = value
    end)

    assert.equals("resolved", result.state)
    assert.equals("9.0.0", result.environment.gradle_version)
    assert.equals(3, #result.analysis.projects)
    assert.equals(2, #result.analysis.dependencies)
    assert.equals("2.0.16", result.analysis.dependencies[1].requested_version)
    assert.equals("2.0.17", result.analysis.dependencies[1].version)
    assert.same({ "--version" }, calls[1].args)
    assert.same({ "--console=plain", "--no-daemon", "projects" }, calls[2].args)
    assert.same({
      "--console=plain",
      "--no-daemon",
      "dependencies",
      "--configuration",
      "runtimeClasspath",
    }, calls[3].args)
    assert.equals("/workspace/gradlew", calls[1].command)
    assert.equals("/workspace", calls[1].opts.cwd)
  end)

  it("keeps partial results after an unavailable configuration", function()
    package.loaded["duke.process"].run = function(_, _, _, callback)
      callback({ code = 1, stdout = "", stderr = "configuration missing" })
    end
    package.loaded["duke.gradle_model"] = nil
    gradle_model = require("duke.gradle_model")
    local result

    gradle_model.enrich(snapshot(), {}, function(_, value)
      result = value
    end)

    assert.equals("partial", result.state)
    assert.equals("gradle_report_failed", result.diagnostics[1].code)
  end)
end)
