describe("build bridge", function()
  local build
  local root

  before_each(function()
    package.loaded["duke.build"] = nil
    build = require("duke.build")
    root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "child"), "p")
  end)

  after_each(function()
    package.loaded["duke.build"] = nil
    package.loaded["duke.config"] = nil
    package.loaded["duke.managed"] = nil
    package.loaded["duke.process"] = nil
    vim.fn.delete(root, "rf")
  end)

  it("uses the reactor Maven wrapper for a child POM", function()
    local wrapper = vim.fs.joinpath(root, "mvnw")
    local child_pom = vim.fs.joinpath(root, "child", "pom.xml")
    vim.fn.writefile({ "#!/bin/sh" }, wrapper)
    assert.equals(true, vim.uv.fs_chmod(wrapper, 493))
    vim.fn.writefile({ "<project></project>" }, child_pom)

    assert.same({
      kind = "maven",
      root = root,
      build_file = child_pom,
      command = wrapper,
      cwd = vim.fs.joinpath(root, "child"),
      wrapper = true,
    }, build.maven(child_pom, "mvn"))
  end)

  it("falls back to configured Maven when no executable wrapper exists", function()
    local child_pom = vim.fs.joinpath(root, "child", "pom.xml")
    vim.fn.writefile({ "#!/bin/sh" }, vim.fs.joinpath(root, "mvnw"))
    vim.fn.writefile({ "<project></project>" }, child_pom)

    local resolved = build.maven(child_pom, "mvnd")
    assert.equals("mvnd", resolved.command)
    assert.is_false(resolved.wrapper)
    assert.equals(vim.fs.joinpath(root, "child"), resolved.root)
  end)

  it("runs managed resolution through the reactor Maven wrapper", function()
    local child_pom = vim.fs.joinpath(root, "child", "pom.xml")
    local wrapper = vim.fs.joinpath(root, "mvnw")
    vim.fn.writefile({ "#!/bin/sh" }, wrapper)
    assert.equals(true, vim.uv.fs_chmod(wrapper, 493))
    vim.fn.writefile({ "<project></project>" }, child_pom)

    package.loaded["duke.config"] = {
      get = function()
        return { maven = { command = "mvnd", timeout = 1234 } }
      end,
    }
    local invocation
    package.loaded["duke.process"] = {
      run = function(command, args, opts, callback)
        invocation = { command = command, args = args, opts = opts }
        callback({
          code = 0,
          stdout = "[INFO] com.example:demo:jar:1.2.3:compile",
          stderr = "",
        })
      end,
    }

    local result
    require("duke.managed").resolve(child_pom, {
      { group_id = "com.example", artifact_id = "demo" },
    }, function(err, resolved)
      result = { err = err, resolved = resolved }
    end)

    assert.same({
      command = wrapper,
      args = { "dependency:list", "-f", child_pom, "--batch-mode" },
      opts = { cwd = vim.fs.joinpath(root, "child"), timeout = 1234 },
    }, invocation)
    assert.is_nil(result.err)
    assert.equals("1.2.3", result.resolved["com.example:demo"])
  end)
end)
