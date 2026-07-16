describe("Maven Central search", function()
  local search

  before_each(function()
    package.loaded["java_scaffold.maven_central"] = nil
    package.loaded["java_scaffold.config"] = {
      get = function()
        return {
          maven = {
            central_search_url = "https://search.maven.org/solrsearch/select",
            central_search_rows = 20,
            central_search_timeout = 15000,
          },
        }
      end,
    }
    search = require("java_scaffold.maven_central")
  end)

  after_each(function()
    package.loaded["java_scaffold.config"] = nil
    package.loaded["java_scaffold.maven_central"] = nil
  end)

  it("builds encoded HTTPS curl search args", function()
    assert.same({
      "--fail-with-body",
      "--location",
      "--proto",
      "=https",
      "--silent",
      "--show-error",
      "--get",
      "--data-urlencode",
      "q=guava core",
      "--data-urlencode",
      "rows=20",
      "--data-urlencode",
      "wt=json",
      "--user-agent",
      "java-scaffold.nvim",
      "https://search.maven.org/solrsearch/select",
    }, search.build_search_args("https://search.maven.org/solrsearch/select", "guava core", 20))
  end)

  it("validates Maven Central response schemas", function()
    assert.is_true(search.is_search_result({
      response = {
        docs = { { g = "com.google.guava", a = "guava", latestVersion = "33.4.8-jre" } },
      },
    }))
    assert.is_true(search.is_search_result({ response = { docs = {} } }))
    assert.is_false(search.is_search_result({ response = { docs = { { g = "g", a = "a" } } } }))
    assert.is_false(search.is_search_result({ response = { docs = "broken" } }))
  end)

  it("maps search results and filters pom packaging", function()
    local received
    local runner = function(command, args, opts, callback)
      assert.equals("curl", command)
      assert.equals(15000, opts.timeout)
      assert.equals("q=guava", args[9])
      callback({
        code = 0,
        stdout = vim.json.encode({
          response = {
            numFound = 2,
            docs = {
              {
                g = "com.google.guava",
                a = "guava",
                latestVersion = "33.4.8-jre",
                p = "jar",
              },
              { g = "example", a = "bom", latestVersion = "1.0.0", p = "pom" },
            },
          },
        }),
        stderr = "",
      })
    end

    search.search("guava", function(err, results)
      assert.is_nil(err)
      received = results
    end, runner)

    assert.same({
      {
        group_id = "com.google.guava",
        artifact_id = "guava",
        version = "33.4.8-jre",
        packaging = "jar",
      },
    }, received)
  end)

  it("reports process and malformed response errors", function()
    local errors = {}
    search.search("guava", function(err)
      errors[#errors + 1] = err
    end, function(_, _, _, callback)
      callback({ code = 22, stdout = "", stderr = "rate limited" })
    end)
    search.search("guava", function(err)
      errors[#errors + 1] = err
    end, function(_, _, _, callback)
      callback({ code = 0, stdout = "{}", stderr = "" })
    end)

    assert.matches("rate limited", errors[1])
    assert.matches("unexpected structure", errors[2])
  end)
end)
