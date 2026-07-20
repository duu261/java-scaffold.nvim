local M = {}

local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function executable_upward(names, start)
  for _, path in ipairs(vim.fs.find(names, { path = start, upward = true, type = "file" })) do
    if vim.fn.executable(path) == 1 then
      return absolute(path)
    end
  end
end

---@class DukeMavenBuild
---@field kind "maven"
---@field root string
---@field build_file string
---@field command string
---@field cwd string
---@field wrapper boolean

---@param pom_path string
---@param fallback string
---@return DukeMavenBuild
function M.maven(pom_path, fallback)
  local build_file = absolute(pom_path)
  local cwd = vim.fs.dirname(build_file)
  local wrapper_names = vim.fn.has("win32") == 1 and { "mvnw.cmd", "mvnw" } or { "mvnw" }
  local wrapper = executable_upward(wrapper_names, cwd)

  return {
    kind = "maven",
    root = wrapper and vim.fs.dirname(wrapper) or cwd,
    build_file = build_file,
    command = wrapper or fallback,
    cwd = cwd,
    wrapper = wrapper ~= nil,
  }
end

return M
