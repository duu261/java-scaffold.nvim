describe("Initializr metadata", function()
  local metadata

  before_each(function()
    package.loaded["java_scaffold.metadata"] = nil
    metadata = require("java_scaffold.metadata")
  end)

  it("flattens grouped dependencies", function()
    local entries = metadata.flatten_dependencies({
      dependencies = {
        values = {
          {
            name = "Web",
            values = {
              { id = "web", name = "Spring Web", description = "Build web applications" },
            },
          },
          {
            name = "SQL",
            values = {
              { id = "data-jpa", name = "Spring Data JPA" },
            },
          },
        },
      },
    })

    assert.same({
      { id = "web", name = "Spring Web", description = "Build web applications", group = "Web" },
      { id = "data-jpa", name = "Spring Data JPA", description = "", group = "SQL" },
    }, entries)
  end)

  it("uses remote JSON and refreshes cache", function()
    local cache = vim.fn.tempname()
    local result

    metadata.fetch_cached("https://example.test/metadata", cache, function(_, callback)
      callback(nil, '{"source":"remote"}')
    end, function(err, value, source)
      assert.is_nil(err)
      result = { value = value, source = source }
    end)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.equals("remote", result.value.source)
    assert.equals("remote", result.source)
    assert.equals('{"source":"remote"}', table.concat(vim.fn.readfile(cache), "\n"))
    vim.fn.delete(cache)
  end)

  it("falls back to cached JSON after fetch failure", function()
    local cache = vim.fn.tempname()
    vim.fn.writefile({ '{"source":"cache"}' }, cache)
    local result

    metadata.fetch_cached("https://example.test/metadata", cache, function(_, callback)
      callback("offline")
    end, function(err, value, source)
      assert.is_nil(err)
      result = { value = value, source = source }
    end)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.equals("cache", result.value.source)
    assert.equals("cache", result.source)
    vim.fn.delete(cache)
  end)

  it("rejects invalid remote structure without replacing valid cache", function()
    local cache = vim.fn.tempname()
    local cached_json = '{"dependencies":{"web":{}}}'
    vim.fn.writefile({ cached_json }, cache)
    local result

    metadata.fetch_cached("https://example.test/dependencies", cache, function(_, callback)
      callback(nil, "{}")
    end, function(err, value, source)
      assert.is_nil(err)
      result = { value = value, source = source }
    end, metadata.is_catalog)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.equals("cache", result.source)
    assert.is_table(result.value.dependencies)
    assert.equals(cached_json, table.concat(vim.fn.readfile(cache), "\n"))
    vim.fn.delete(cache)
  end)

  it("resolves selected dependency IDs through the version catalog", function()
    local dependencies, missing = metadata.resolve({
      dependencies = {
        web = {
          groupId = "org.springframework.boot",
          artifactId = "spring-boot-starter-webmvc",
          scope = "compile",
        },
        test = {
          groupId = "org.springframework.boot",
          artifactId = "spring-boot-starter-test",
          scope = "test",
        },
      },
    }, { "web", "missing", "test" })

    assert.same({
      {
        group_id = "org.springframework.boot",
        artifact_id = "spring-boot-starter-webmvc",
        scope = "compile",
      },
      {
        group_id = "org.springframework.boot",
        artifact_id = "spring-boot-starter-test",
        scope = "test",
      },
    }, dependencies)
    assert.same({ "missing" }, missing)
  end)

  it("accepts only dependencies representable by one Maven dependency block", function()
    assert.is_true(metadata.is_direct({ groupId = "g", artifactId = "a", scope = "runtime" }))
    assert.is_false(metadata.is_direct({ groupId = "g", artifactId = "a", bom = "cloud" }))
    assert.is_false(
      metadata.is_direct({ groupId = "g", artifactId = "a", repository = "milestones" })
    )
    assert.is_false(metadata.is_direct({
      groupId = "g",
      artifactId = "a",
      scope = "annotationProcessor",
    }))
  end)
end)
