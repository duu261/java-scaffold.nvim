describe("Opaque Maven change plans", function()
  local change_plan
  local root
  local pom_path
  local events

  local function write(lines)
    vim.fn.writefile(lines, pom_path)
  end

  local function pom_lines(extra)
    local lines = {
      "<project>",
      "  <groupId>com.acme</groupId>",
      "  <artifactId>app</artifactId>",
      "  <version>1.0.0</version>",
      "  <properties>",
      "    <slf4j.version>2.0.16</slf4j.version>",
      "  </properties>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.slf4j</groupId>",
      "      <artifactId>slf4j-api</artifactId>",
      "      <version>${slf4j.version}</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>org.slf4j</groupId>",
      "      <artifactId>slf4j-simple</artifactId>",
      "      <version>${slf4j.version}</version>",
      "    </dependency>",
      "  </dependencies>",
    }
    vim.list_extend(lines, extra or {})
    lines[#lines + 1] = "</project>"
    return lines
  end

  local function wait_build(opts)
    local calls = {}
    change_plan.build(opts, function(err, result)
      calls[#calls + 1] = { err = err, result = result }
    end)
    assert.is_true(vim.wait(1000, function()
      return #calls == 1
    end))
    return calls[1].err, calls[1].result
  end

  local function wait_apply(plan)
    local calls = {}
    change_plan.apply(plan, function(err, result)
      calls[#calls + 1] = { err = err, result = result }
    end)
    assert.is_true(vim.wait(1000, function()
      return #calls == 1
    end))
    return calls[1].err, calls[1].result
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    pom_path = vim.fs.joinpath(root, "pom.xml")
    write(pom_lines())
    events = {}
    package.loaded["duke.change_plan"] = nil
    package.loaded["duke.events"] = {
      build_changed = function(path, operation, details)
        events[#events + 1] = { path = path, operation = operation, details = details }
      end,
    }
    change_plan = require("duke.change_plan")
  end)

  after_each(function()
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buffer) == pom_path then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
      end
    end
    vim.fn.delete(root, "rf")
    package.loaded["duke.change_plan"] = nil
    package.loaded["duke.events"] = nil
  end)

  it("applies a private canonical shared-property plan once", function()
    local err, descriptor = wait_build({
      pom_path = pom_path,
      changes = { { coordinate = "org.slf4j:slf4j-api", new_version = "2.0.17" } },
    })

    assert.is_nil(err)
    assert.is_string(descriptor.id)
    assert.equals(1, #descriptor.shared_properties)
    assert.same(
      { "org.slf4j:slf4j-api", "org.slf4j:slf4j-simple" },
      descriptor.affected_coordinates
    )
    descriptor.preview.after[6] = "    <slf4j.version>caller-controlled</slf4j.version>"
    descriptor.pom_path = "/tmp/attacker.xml"

    local apply_err, result = wait_apply(descriptor)

    assert.is_nil(apply_err)
    assert.is_true(result.saved)
    assert.equals("    <slf4j.version>2.0.17</slf4j.version>", vim.fn.readfile(pom_path)[6])
    assert.equals(1, #events)
    assert.equals("plan_upgrades", events[1].operation)
    assert.same({ "org.slf4j:slf4j-api", "org.slf4j:slf4j-simple" }, events[1].details.coordinates)
    local reused_err = wait_apply(descriptor)
    assert.matches("unknown or expired", reused_err)
  end)

  it("expires a plan when any source line changes", function()
    local _, descriptor = wait_build({
      pom_path = pom_path,
      changes = { { coordinate = "org.slf4j:slf4j-api", new_version = "2.0.17" } },
    })
    local lines = vim.fn.readfile(pom_path)
    table.insert(lines, 2, "  <!-- user edit -->")
    write(lines)

    local err = wait_apply(descriptor)

    assert.matches("changed", err)
    assert.equals(0, #events)
    local reused_err = wait_apply(descriptor)
    assert.matches("unknown or expired", reused_err)
  end)

  it("discards a declined plan before it can be applied", function()
    local _, descriptor = wait_build({
      pom_path = pom_path,
      changes = { { coordinate = "org.slf4j:slf4j-api", new_version = "2.0.17" } },
    })

    assert.is_true(change_plan.discard(descriptor))
    assert.is_false(change_plan.discard(descriptor))
    local err = wait_apply(descriptor)

    assert.matches("unknown or expired", err)
    assert.equals(0, #events)
  end)

  it("updates a loaded modified buffer without claiming a disk save", function()
    local buffer = vim.fn.bufadd(pom_path)
    vim.fn.bufload(buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, pom_lines())
    vim.bo[buffer].modified = true
    local _, descriptor = wait_build({
      pom_path = pom_path,
      changes = { { coordinate = "org.slf4j:slf4j-api", new_version = "2.0.17" } },
    })

    local err, result = wait_apply(descriptor)

    assert.is_nil(err)
    assert.is_false(result.saved)
    assert.is_true(vim.bo[buffer].modified)
    assert.equals(
      "    <slf4j.version>2.0.17</slf4j.version>",
      vim.api.nvim_buf_get_lines(buffer, 5, 6, false)[1]
    )
    assert.equals("    <slf4j.version>2.0.16</slf4j.version>", vim.fn.readfile(pom_path)[6])
    assert.is_false(events[1].details.saved)
  end)

  it("rejects property changes with non-dependency consumers", function()
    write(pom_lines({
      "  <build>",
      "    <finalName>${slf4j.version}</finalName>",
      "  </build>",
    }))

    local err, descriptor = wait_build({
      pom_path = pom_path,
      changes = { { coordinate = "org.slf4j:slf4j-api", new_version = "2.0.17" } },
    })

    assert.is_nil(descriptor)
    assert.matches("other consumers", err)
  end)

  it("re-reads the POM after version lookup", function()
    local central = require("duke.maven_central")
    local original_versions = central.versions
    central.versions = function(_, _, callback)
      local lines = vim.fn.readfile(pom_path)
      table.insert(lines, 2, "  <!-- concurrent edit -->")
      write(lines)
      callback(nil, { "2.0.17" })
    end

    local err, descriptor = wait_build({
      pom_path = pom_path,
      changes = { { coordinate = "org.slf4j:slf4j-api" } },
    })
    central.versions = original_versions

    assert.is_nil(descriptor)
    assert.matches("changed during", err)
  end)
end)
