describe("Maven multi-module core", function()
  local temporary_directories = {}
  local original_promote
  local original_make_staging
  local original_writefile
  local original_readfile
  local original_buffer

  local function temp_dir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    temporary_directories[#temporary_directories + 1] = path
    return path
  end

  local function write_reactor(directory, lines)
    local path = vim.fs.joinpath(directory, "pom.xml")
    vim.fn.writefile(lines, path)
    return path
  end

  local function basic_reactor_lines()
    return {
      '<?xml version="1.0" encoding="UTF-8"?>',
      "<project>",
      "  <modelVersion>4.0.0</modelVersion>",
      "  <groupId>com.example</groupId>",
      "  <artifactId>parent</artifactId>",
      "  <version>1.0.0</version>",
      "  <packaging>pom</packaging>",
      "</project>",
    }
  end

  local function inherited_reactor_lines()
    return {
      "<project>",
      "  <modelVersion>4.0.0</modelVersion>",
      "  <parent>",
      "    <groupId>com.example</groupId>",
      "    <artifactId>company-parent</artifactId>",
      "    <version>2.0.0</version>",
      "  </parent>",
      "  <artifactId>reactor</artifactId>",
      "  <packaging>pom</packaging>",
      "</project>",
    }
  end

  local function invoke(opts)
    local calls = {}
    require("duke.maven_module").create(opts, function(err, result)
      calls[#calls + 1] = { err = err, result = result }
    end)
    assert.equals(1, #calls)
    return calls[1].err, calls[1].result, #calls
  end

  before_each(function()
    original_buffer = vim.api.nvim_get_current_buf()
    original_promote = nil
    original_make_staging = nil
    original_writefile = nil
    original_readfile = nil
    for _, module in ipairs({
      "duke.maven_module",
      "duke.pom",
      "duke.pom_file",
      "duke.fs",
      "duke.maven",
    }) do
      package.loaded[module] = nil
    end
  end)

  after_each(function()
    if original_promote then
      package.loaded["duke.fs"] = nil
      local fs = require("duke.fs")
      fs.promote = original_promote
    end
    if original_make_staging then
      package.loaded["duke.fs"] = nil
      local fs = require("duke.fs")
      fs.make_staging = original_make_staging
    end
    if original_writefile then
      vim.fn.writefile = original_writefile
    end
    if original_readfile then
      vim.fn.readfile = original_readfile
    end
    if vim.api.nvim_buf_is_valid(original_buffer) then
      vim.api.nvim_set_current_buf(original_buffer)
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf):match("pom%.xml$") then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
    temporary_directories = {}
    for _, module in ipairs({
      "duke.maven_module",
      "duke.pom",
      "duke.pom_file",
      "duke.fs",
      "duke.maven",
    }) do
      package.loaded[module] = nil
    end
  end)

  it("builds the child only in private staging before any parent save", function()
    local reactor = temp_dir()
    local parent = write_reactor(reactor, basic_reactor_lines())
    local parent_before = table.concat(vim.fn.readfile(parent), "\n")
    local seen = { staged_pom = false, parent_saved = false, parent_touched = false }

    local fs = require("duke.fs")
    original_promote = fs.promote
    fs.promote = function(staged, target)
      seen.staged_pom = vim.fn.filereadable(vim.fs.joinpath(staged, "pom.xml")) == 1
      seen.parent_touched = table.concat(vim.fn.readfile(parent), "\n") ~= parent_before
      return original_promote(staged, target)
    end

    local pom_file = require("duke.pom_file")
    local original_save = pom_file.save
    pom_file.save = function(path, lines, buffer, was_modified)
      seen.parent_saved = true
      assert.is_true(
        seen.staged_pom or vim.fn.glob(reactor .. "/.duke-*/**/pom.xml", true, true)[1] ~= nil
      )
      return original_save(path, lines, buffer, was_modified)
    end

    local err, result = invoke({ reactor_dir = reactor, artifact_id = "child" })

    pom_file.save = original_save
    assert.is_nil(err)
    assert.is_true(seen.parent_saved)
    assert.is_true(result.module_dir:find("child", 1, true) ~= nil)
    assert.same({}, vim.fn.glob(vim.fs.joinpath(reactor, ".duke-*"), false, true))
  end)

  it(
    "uses direct and inherited parent coordinates with relativePath and no child GAV dupes",
    function()
      local direct = temp_dir()
      write_reactor(direct, basic_reactor_lines())
      local _, direct_result = invoke({ reactor_dir = direct, artifact_id = "child" })
      local direct_child =
        table.concat(vim.fn.readfile(vim.fs.joinpath(direct_result.module_dir, "pom.xml")), "\n")

      assert.matches("<groupId>com%.example</groupId>", direct_child)
      assert.matches("<artifactId>parent</artifactId>", direct_child)
      assert.matches("<version>1%.0%.0</version>", direct_child)
      assert.matches("<relativePath>%.%./pom%.xml</relativePath>", direct_child)
      assert.matches("<artifactId>child</artifactId>", direct_child)
      assert.is_falsy(direct_child:match("<parent>.-<groupId>.-</groupId>.-</parent>.-<groupId>"))
      assert.is_falsy(direct_child:find("<parent>.*</parent>.-<version>", 1))

      local inherited = temp_dir()
      write_reactor(inherited, inherited_reactor_lines())
      local _, inherited_result = invoke({ reactor_dir = inherited, artifact_id = "svc" })
      local inherited_child =
        table.concat(vim.fn.readfile(vim.fs.joinpath(inherited_result.module_dir, "pom.xml")), "\n")
      assert.matches("<groupId>com%.example</groupId>", inherited_child)
      assert.matches("<artifactId>reactor</artifactId>", inherited_child)
      assert.matches("<version>2%.0%.0</version>", inherited_child)
      assert.matches("<relativePath>%.%./pom%.xml</relativePath>", inherited_child)
    end
  )

  it("derives and validates the source package through existing Maven helpers", function()
    local reactor = temp_dir()
    write_reactor(reactor, basic_reactor_lines())
    local err, result = invoke({ reactor_dir = reactor, artifact_id = "my-lib" })
    assert.is_nil(err)
    local java = vim.fn.glob(result.module_dir .. "/src/main/java/**/*.java", true, true)
    assert.equals(1, #java)
    local source = table.concat(vim.fn.readfile(java[1]), "\n")
    assert.matches("package com%.example%.mylib;", source)

    local bad = temp_dir()
    write_reactor(bad, basic_reactor_lines())
    local bad_err = invoke({
      reactor_dir = bad,
      artifact_id = "ok",
      package_name = "com.example.class",
    })
    assert.matches("package", bad_err)
    assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(bad, "ok")))
    assert.same(basic_reactor_lines(), vim.fn.readfile(vim.fs.joinpath(bad, "pom.xml")))
  end)

  it("re-reads a parent changed during staging and applies the edit to latest contents", function()
    local reactor = temp_dir()
    local parent = write_reactor(reactor, basic_reactor_lines())
    local fs = require("duke.fs")
    original_make_staging = fs.make_staging
    fs.make_staging = function(parent_dir)
      local staging = original_make_staging(parent_dir)
      local lines = basic_reactor_lines()
      table.insert(lines, #lines, "  <!-- changed during staging -->")
      vim.fn.writefile(lines, parent)
      return staging
    end

    local err, result = invoke({ reactor_dir = reactor, artifact_id = "child" })
    assert.is_nil(err)
    local final = vim.fn.readfile(parent)
    assert.is_truthy(vim.tbl_contains(final, "  <!-- changed during staging -->"))
    assert.is_truthy(vim.tbl_contains(final, "    <module>child</module>"))
    assert.equals(parent, result.parent_pom)
  end)

  it("rejects initial target collision without staging or parent mutation", function()
    local reactor = temp_dir()
    local parent = write_reactor(reactor, basic_reactor_lines())
    local target = vim.fs.joinpath(reactor, "child")
    vim.fn.mkdir(target, "p")
    vim.fn.writefile({ "keep" }, vim.fs.joinpath(target, "sentinel"))

    local err = invoke({ reactor_dir = reactor, artifact_id = "child" })
    assert.matches("target already exists", err)
    assert.equals("keep", vim.fn.readfile(vim.fs.joinpath(target, "sentinel"))[1])
    assert.same(basic_reactor_lines(), vim.fn.readfile(parent))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(reactor, ".duke-*"), false, true))
  end)

  it(
    "preserves a target that appears after parent save, restores parent, and reports rollback",
    function()
      local reactor = temp_dir()
      local parent = write_reactor(reactor, basic_reactor_lines())
      local parent_before = vim.fn.readfile(parent)
      local fs = require("duke.fs")
      original_promote = fs.promote
      fs.promote = function(staged, target)
        vim.fn.mkdir(target, "p")
        vim.fn.writefile({ "keep" }, vim.fs.joinpath(target, "sentinel"))
        return original_promote(staged, target)
      end

      local err, result = invoke({ reactor_dir = reactor, artifact_id = "child" })
      assert.matches("target already exists", err)
      assert.is_true(result.rolled_back)
      assert.equals("keep", vim.fn.readfile(vim.fs.joinpath(reactor, "child", "sentinel"))[1])
      assert.same(parent_before, vim.fn.readfile(parent))
      assert.same({}, vim.fn.glob(vim.fs.joinpath(reactor, ".duke-*"), false, true))
    end
  )

  it("refuses blind rollback when the parent changes after save", function()
    local reactor = temp_dir()
    local parent = write_reactor(reactor, basic_reactor_lines())
    local fs = require("duke.fs")
    original_promote = fs.promote
    fs.promote = function(_, target)
      local lines = vim.fn.readfile(parent)
      table.insert(lines, #lines, "  <!-- post-save edit -->")
      vim.fn.writefile(lines, parent)
      vim.fn.mkdir(target, "p")
      return nil, "target already exists: " .. target
    end

    local err, result = invoke({ reactor_dir = reactor, artifact_id = "child" })
    assert.matches("rollback conflict", err)
    assert.is_false(result.rolled_back)
    local final = table.concat(vim.fn.readfile(parent), "\n")
    assert.matches("post%-save edit", final)
    assert.matches("<module>child</module>", final)
    assert.same({}, vim.fn.glob(vim.fs.joinpath(reactor, ".duke-*"), false, true))
  end)

  it("restores a pre-modified loaded buffer on promotion failure without writing disk", function()
    local reactor = temp_dir()
    local parent = write_reactor(reactor, basic_reactor_lines())
    vim.cmd.edit(vim.fn.fnameescape(parent))
    vim.api.nvim_buf_set_lines(0, 1, 1, false, { "  <!-- unsaved -->" })
    local disk_before = table.concat(vim.fn.readfile(parent), "\n")
    local buffer_before = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    local fs = require("duke.fs")
    original_promote = fs.promote
    fs.promote = function(_, target)
      vim.fn.mkdir(target, "p")
      return nil, "target already exists: " .. target
    end

    local err, result = invoke({ reactor_dir = reactor, artifact_id = "child" })
    assert.matches("target already exists", err)
    assert.is_true(result.rolled_back)
    assert.is_false(result.saved)
    assert.same(buffer_before, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_true(vim.bo.modified)
    assert.equals(disk_before, table.concat(vim.fn.readfile(parent), "\n"))
    assert.is_truthy(vim.uv.fs_stat(vim.fs.joinpath(reactor, "child")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(reactor, ".duke-*"), false, true))
  end)

  it("contains staged write, parent read, parent save, promotion, and rollback failures", function()
    local cases = {}

    -- staged write failure via unwritable staging parent simulation
    do
      local reactor = temp_dir()
      write_reactor(reactor, basic_reactor_lines())
      local fs = require("duke.fs")
      original_make_staging = fs.make_staging
      fs.make_staging = function()
        return nil, "cannot create staging directory: EACCES"
      end
      local err, result, count = invoke({ reactor_dir = reactor, artifact_id = "child" })
      cases.staging = { err = err, count = count, result = result }
      fs.make_staging = original_make_staging
      original_make_staging = nil
      package.loaded["duke.fs"] = nil
    end

    -- parent read failure
    do
      local reactor = temp_dir()
      write_reactor(reactor, basic_reactor_lines())
      package.loaded["duke.pom_file"] = nil
      local pom_file = require("duke.pom_file")
      local original_read = pom_file.read
      local reads = 0
      pom_file.read = function(path)
        reads = reads + 1
        if reads == 1 then
          return original_read(path)
        end
        return nil, nil, nil, "cannot read " .. path .. ": boom"
      end
      -- first read is eligibility; after staging second read fails
      local err, _, count = invoke({ reactor_dir = reactor, artifact_id = "child" })
      cases.read = { err = err, count = count }
      pom_file.read = original_read
      assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(reactor, "child")))
      assert.same({}, vim.fn.glob(vim.fs.joinpath(reactor, ".duke-*"), false, true))
      assert.same(basic_reactor_lines(), vim.fn.readfile(vim.fs.joinpath(reactor, "pom.xml")))
    end

    -- parent save failure
    do
      local reactor = temp_dir()
      write_reactor(reactor, basic_reactor_lines())
      package.loaded["duke.pom_file"] = nil
      package.loaded["duke.maven_module"] = nil
      local pom_file = require("duke.pom_file")
      local original_save = pom_file.save
      pom_file.save = function()
        return nil, "cannot write pom: denied"
      end
      local err, result, count = invoke({ reactor_dir = reactor, artifact_id = "child" })
      cases.save = { err = err, count = count, result = result }
      pom_file.save = original_save
      assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(reactor, "child")))
      assert.same({}, vim.fn.glob(vim.fs.joinpath(reactor, ".duke-*"), false, true))
    end

    assert.matches("staging", cases.staging.err)
    assert.equals(1, cases.staging.count)
    assert.matches("cannot read", cases.read.err)
    assert.equals(1, cases.read.count)
    assert.matches("denied", cases.save.err)
    assert.equals(1, cases.save.count)
  end)

  it(
    "returns absolute module directory, parent POM path, save state, and rollback state",
    function()
      local reactor = temp_dir()
      local parent = write_reactor(reactor, basic_reactor_lines())
      local err, result = invoke({ reactor_dir = reactor, artifact_id = "child" })
      assert.is_nil(err)
      assert.equals(
        vim.fs.normalize(vim.fs.joinpath(reactor, "child")),
        vim.fs.normalize(result.module_dir)
      )
      assert.equals(vim.fs.normalize(parent), vim.fs.normalize(result.parent_pom))
      assert.is_true(result.saved)
      assert.is_false(result.rolled_back)
    end
  )

  it("edits a pre-modified loaded parent buffer without forced disk write", function()
    local reactor = temp_dir()
    local parent = write_reactor(reactor, basic_reactor_lines())
    vim.cmd.edit(vim.fn.fnameescape(parent))
    vim.api.nvim_buf_set_lines(0, 1, 1, false, { "  <!-- unsaved -->" })
    local disk_before = table.concat(vim.fn.readfile(parent), "\n")

    local err, result = invoke({ reactor_dir = reactor, artifact_id = "child" })
    assert.is_nil(err)
    assert.is_false(result.saved)
    assert.is_true(vim.bo.modified)
    assert.matches(
      "<module>child</module>",
      table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    )
    assert.equals(disk_before, table.concat(vim.fn.readfile(parent), "\n"))
    assert.is_truthy(vim.uv.fs_stat(vim.fs.joinpath(reactor, "child", "pom.xml")))
  end)
end)
