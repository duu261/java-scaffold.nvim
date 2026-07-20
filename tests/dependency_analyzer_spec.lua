describe("Dependency analyzer", function()
  local analyzer

  before_each(function()
    package.loaded["duke.dependency_analyzer"] = nil
    analyzer = require("duke.dependency_analyzer")
  end)

  after_each(function()
    package.loaded["duke.dependency_analyzer"] = nil
  end)

  local function module(id, declared_version, resolved_version)
    return {
      id = id,
      model = {
        dependencies = {
          { coordinate = "org.slf4j:slf4j-api", version = declared_version, start_line = 10 },
          { coordinate = "org.slf4j:slf4j-api", version = declared_version, start_line = 20 },
        },
        properties = {},
      },
      resolved = {
        effective = { dependencies = {} },
        tree = {
          coordinate = id,
          children = {
            {
              coordinate = "org.slf4j:slf4j-api",
              version = resolved_version,
              scope = "compile",
              children = {
                {
                  coordinate = "org.example:leaf",
                  version = "1.0",
                  scope = "runtime",
                  children = {},
                },
              },
            },
          },
        },
      },
    }
  end

  it("finds duplicates, cross-module drift, unknown ownership, and every path", function()
    local analysis = analyzer.analyze({
      modules = {
        module("com.acme:a", "2.0.16", "2.0.16"),
        module("com.acme:b", "2.0.17", "2.0.17"),
      },
    })

    assert.equals(2, #analysis.findings.duplicates)
    assert.equals(1, #analysis.findings.drift)
    assert.equals("org.slf4j:slf4j-api", analysis.findings.drift[1].coordinate)
    assert.equals(2, #analysis.findings.unknown)
    assert.equals(4, #analysis.dependencies)
    assert.same({
      { "com.acme:a", "org.slf4j:slf4j-api", "org.example:leaf" },
    }, analyzer.paths(analysis, "org.example:leaf", "com.acme:a"))
  end)
end)
