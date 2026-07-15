if vim.g.loaded_java_scaffold then
  return
end
vim.g.loaded_java_scaffold = true

vim.api.nvim_create_user_command("JavaScaffoldMaven", function()
  require("java_scaffold").new_maven()
end, { desc = "Create a Maven Java project", force = true })

vim.api.nvim_create_user_command("JavaScaffoldGradle", function()
  require("java_scaffold").new_gradle()
end, { desc = "Create a Gradle Java project", force = true })

vim.api.nvim_create_user_command("JavaScaffoldSpring", function()
  require("java_scaffold").new_spring()
end, { desc = "Create a Spring Boot project", force = true })

vim.api.nvim_create_user_command("JavaScaffoldAddDependency", function()
  require("java_scaffold").add_dependency()
end, { desc = "Add Spring dependencies to pom.xml", force = true })

vim.api.nvim_create_user_command("JavaScaffoldLog", function()
  require("java_scaffold.log").show()
end, { desc = "Show java-scaffold.nvim log", force = true })
