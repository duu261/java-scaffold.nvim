# java-scaffold.nvim

Create Maven, Gradle, and Spring Boot projects, add Spring dependencies, then land in the new project or on generated Java source - without leaving Neovim.

## Requirements

- Neovim 0.11+
- `java`
- `mvn` for Maven projects
- `gradle` for Gradle projects
- `curl` and GNU `tar` for Spring Initializr
- Optional: Telescope for searchable pickers
- Optional: any project handoff command

## Installation

Local checkout with lazy.nvim:

```lua
{
  dir = "~/Projects/java-scaffold.nvim",
  name = "java-scaffold.nvim",
  cond = vim.fn.isdirectory(vim.fn.expand("~/Projects/java-scaffold.nvim")) == 1,
  opts = {},
}
```

GitHub installation after publishing:

```lua
{
  "duu261/java-scaffold.nvim",
  opts = {},
}
```

## Configuration

Defaults:

```lua
require("java_scaffold").setup({
  group_id = "com.example",
  artifact_id = "demo",
  java_version = "auto", -- active user JDK when supported
  java_versions = {}, -- extra choices for Maven/Gradle projects
  java_homes = {}, -- optional version-to-JDK-home map
  entry_selector = nil, -- optional function(project_dir, detected_entry)
  maven = {
    command = "mvn",
    runner_java_version = "auto", -- active Java; separate from project target
    project_version = "1.0-SNAPSHOT",
    timeout = 180000,
    archetype = {
      group_id = "org.apache.maven.archetypes",
      artifact_id = "maven-archetype-quickstart",
      version = "1.5",
    },
  },
  gradle = {
    command = "gradle",
    runner_java_version = "auto", -- active Java; toolchain targets selection
    dsl = "kotlin",
    test_framework = "auto", -- JUnit 4 for Java 8/11; Jupiter for 17+
    timeout = 180000,
    default_project_type = "java-application",
    project_types = {
      { id = "java-application", name = "Java application" },
      { id = "java-library", name = "Java library" },
      { id = "java-gradle-plugin", name = "Gradle plugin" },
    },
  },
  spring = {
    metadata_url = "https://start.spring.io",
    dependencies_url = "https://start.spring.io/dependencies",
    starter_url = "https://start.spring.io/starter.tgz",
    project_type = "maven-project",
    language = "java",
    packaging = "jar",
    metadata_timeout = 30000,
    timeout = 60000,
  },
  handoff = {
    enabled = false,
    command = nil, -- project path is appended to this argv list
    required_executables = {},
  },
})
```

`java_version = "auto"` controls project target/toolchain and defaults to active user Java. Maven and Gradle offer active Java, `JDK<version>` environments, configured homes, and JDKs discovered under common Linux, macOS, SDKMAN, asdf, and Maven JDK directories. Build JVM stays separate through each workflow's `runner_java_version`; its default is active Java. This lets Gradle run on a modern JVM while targeting Java 8/11, matching IDE behavior. Known runner homes become scoped `JAVA_HOME` and `PATH`; global shell state stays unchanged. Wrappers that reset `JAVA_HOME` can still override this, so health and creation report actual runner Java. Spring projects use only versions supported by selected Initializr Boot metadata; unsupported active Java falls back to Initializr's default.

## Project coverage

- Maven quickstart: conventional console project and tests
- Gradle: Java application, library, or Gradle plugin; Kotlin DSL; JUnit 4 for Java 8/11 and Jupiter for 17+
- Spring Boot: current Initializr Boot/Java/dependency compatibility
- Existing Spring project: safe direct dependency insertion into nearest root `pom.xml`

## Usage

| Command | Action |
| --- | --- |
| `:JavaScaffoldMaven` | Create Maven quickstart project |
| `:JavaScaffoldGradle` | Create Gradle application, library, or plugin |
| `:JavaScaffoldSpring` | Create Spring Boot project |
| `:JavaScaffoldAddDependency` | Add Spring dependencies to nearest `pom.xml` |
| `:JavaScaffoldLog` | Show internal operation log |

Creation runs in current working directory. Generation uses a private staging directory, validates build files, then promotes the finished project without deleting an existing target. Wizard prompts for coordinates and Java, plus project type for Gradle or dependencies for Spring.

Without handoff, plugin opens generated application source when available. This naturally triggers a normal Java filetype/JDTLS setup. It does not own or duplicate JDTLS configuration. Successful creation emits `User JavaScaffoldProjectCreated` with `data.project_dir` and `data.entry_file`.

Optional handoff can invoke any external project opener:

```lua
handoff = {
  enabled = true,
  command = { "project-opener", "{project}" },
  required_executables = { "project-opener" },
}
```

Replace `project-opener` with an available command. `{project}` and `{file}` placeholders are expanded. Without placeholders, project path is appended for compatibility. Successful creation above calls:

```text
project-opener /absolute/project/path
```

When handoff is disabled or fails, project opens in current Neovim.

## Offline metadata

Successful Initializr responses are cached under `stdpath("cache")/java-scaffold.nvim`. Fetch failures fall back to cached project metadata and Boot-version dependency coordinates. Project creation still needs network access; cached coordinates keep supported POM insertion working offline.

## Dependency insertion limits

V1 inserts dependencies representable by one normal Maven `<dependency>` block. Initializr entries needing a BOM import, custom repository, or annotation-processor/plugin wiring are hidden from this command because plain insertion would create a broken build. They remain available during new Spring project creation, where Initializr generates required Maven configuration.

Run `:checkhealth java_scaffold` when something fails.

## Development

```sh
make test
make lint
```

## License

Copyright (C) 2026 duu261. Licensed under GPL-3.0-or-later. See
[LICENSE](LICENSE).
