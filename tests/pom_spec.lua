describe("POM editing", function()
  local pom

  before_each(function()
    package.loaded["java_scaffold.pom"] = nil
    pom = require("java_scaffold.pom")
  end)

  it("detects Spring Boot parent version", function()
    local lines = {
      "<project>",
      "  <parent>",
      "    <groupId>org.springframework.boot</groupId>",
      "    <artifactId>spring-boot-starter-parent</artifactId>",
      "    <version>3.5.3</version>",
      "  </parent>",
      "</project>",
    }

    assert.equals("3.5.3", pom.spring_boot_version(lines))
  end)

  it("resolves a Spring Boot version property", function()
    local lines = {
      "<project>",
      "  <properties><spring-boot.version>3.4.7</spring-boot.version></properties>",
      "  <dependencyManagement>",
      "    <dependencies><dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-dependencies</artifactId>",
      "      <version>${spring-boot.version}</version>",
      "    </dependency></dependencies>",
      "  </dependencyManagement>",
      "</project>",
    }

    assert.equals("3.4.7", pom.spring_boot_version(lines))
  end)

  it("inserts dependencies before root dependency close", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "  </dependencies>",
      "</project>",
    }
    local updated, added = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.equals(1, added)
    assert.same({
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }, updated)
  end)

  it("emits only non-compile dependency scopes", function()
    local updated, added = pom.insert({ "<project>", "</project>" }, {
      {
        group_id = "org.junit.jupiter",
        artifact_id = "junit-jupiter",
        version = "5.13.4",
        scope = "test",
      },
      { group_id = "com.example", artifact_id = "compile-lib", version = "1.0", scope = "compile" },
      { group_id = "com.example", artifact_id = "default-lib", version = "1.0" },
    })

    assert.equals(3, added)
    assert.is_truthy(table.concat(updated, "\n"):find("<scope>test</scope>", 1, true))
    assert.is_falsy(table.concat(updated, "\n"):find("<scope>compile</scope>", 1, true))
    assert.equals("      <version>5.13.4</version>", updated[6])
    assert.equals("      <scope>test</scope>", updated[7])
  end)

  it("handles a multiline root project tag", function()
    local lines = {
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<project xmlns="http://maven.apache.org/POM/4.0.0"',
      '  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
      "  <dependencies>",
      "  </dependencies>",
      "</project>",
    }
    local updated, added = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-actuator" },
    })

    assert.equals(1, added)
    assert.equals("    <dependency>", updated[5])
    assert.equals("  </dependencies>", updated[9])
  end)

  it("rejects compact one-line project XML", function()
    local lines = { "<project><dependencies></dependencies></project>" }
    local updated, added, err = pom.insert(lines, {
      { group_id = "com.example", artifact_id = "demo" },
    })

    assert.equals(0, added)
    assert.matches("compact", err)
    assert.same(lines, updated)
  end)

  it("rejects self-closing root dependencies", function()
    local lines = { "<project>", "  <dependencies/>", "</project>" }
    local updated, added, err = pom.insert(lines, {
      { group_id = "com.example", artifact_id = "demo" },
    })

    assert.equals(0, added)
    assert.matches("self%-closing", err)
    assert.same(lines, updated)
  end)

  it("creates a root dependencies block when absent", function()
    local updated, added = pom.insert({ "<project>", "</project>" }, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.equals(1, added)
    assert.same({
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }, updated)
  end)

  it("skips duplicate coordinates", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local updated, added = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.equals(0, added)
    assert.same(lines, updated)
  end)

  it("resolves property-backed duplicate coordinates", function()
    local lines = {
      "<project>",
      "  <properties>",
      "    <starter.group>org.springframework.boot</starter.group>",
      "  </properties>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>${starter.group}</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local updated, added = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.equals(0, added)
    assert.same(lines, updated)
  end)

  it("does not treat a classified dependency as the same default jar", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>demo</artifactId>",
      "      <classifier>tests</classifier>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local _, added = pom.insert(lines, {
      { group_id = "com.example", artifact_id = "demo" },
    })

    assert.equals(1, added)
  end)

  it("escapes dependency coordinates as XML text", function()
    local updated, added = pom.insert({ "<project>", "</project>" }, {
      { group_id = "com.example&tools", artifact_id = "demo<api>" },
    })

    assert.equals(1, added)
    assert.equals("      <groupId>com.example&amp;tools</groupId>", updated[4])
    assert.equals("      <artifactId>demo&lt;api&gt;</artifactId>", updated[5])
  end)

  it("does not insert into dependencyManagement", function()
    local lines = {
      "<project>",
      "  <dependencyManagement>",
      "    <dependencies>",
      "    </dependencies>",
      "  </dependencyManagement>",
      "</project>",
    }
    local updated = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.same({
      "<project>",
      "  <dependencyManagement>",
      "    <dependencies>",
      "    </dependencies>",
      "  </dependencyManagement>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }, updated)
  end)
end)
