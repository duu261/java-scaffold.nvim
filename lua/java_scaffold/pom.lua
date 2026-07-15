local M = {}

local function strip_comments(xml)
  return (
    xml:gsub("<!%-%-(.-)%-%->", function(comment)
      local _, newlines = comment:gsub("\n", "\n")
      return string.rep("\n", newlines)
    end)
  )
end

local function escape_pattern(value)
  return value:gsub("([^%w])", "%%%1")
end

local function tag_value(xml, tag)
  local escaped = escape_pattern(tag)
  return xml:match("<" .. escaped .. "%s*[^>]*>%s*([^<]-)%s*</" .. escaped .. "%s*>")
end

local function resolve_property(xml, value)
  local property = value and value:match("^%${([%w_.-]+)}$")
  if not property then
    return value
  end
  return tag_value(xml, property)
end

function M.spring_boot_version(lines)
  local xml = strip_comments(table.concat(lines, "\n"))
  for parent in xml:gmatch("<parent[^>]*>(.-)</parent>") do
    if
      tag_value(parent, "groupId") == "org.springframework.boot"
      and tag_value(parent, "artifactId") == "spring-boot-starter-parent"
    then
      return resolve_property(xml, tag_value(parent, "version"))
    end
  end

  local management = xml:match("<dependencyManagement%s*[^>]*>(.-)</dependencyManagement%s*>")
  if management then
    for dependency in management:gmatch("<dependency%s*[^>]*>(.-)</dependency%s*>") do
      if
        tag_value(dependency, "groupId") == "org.springframework.boot"
        and tag_value(dependency, "artifactId") == "spring-boot-dependencies"
      then
        return resolve_property(xml, tag_value(dependency, "version"))
      end
    end
  end
end

local function structure(lines)
  local stack = {}
  local found = {}
  local xml = strip_comments(table.concat(lines, "\n"))
  local line_number = 1
  local previous_position = 1

  for position, closing, qualified_name, attributes in xml:gmatch("()<(%/?)([%w_:.-]+)([^>]*)>") do
    local _, newlines = xml:sub(previous_position, position - 1):gsub("\n", "\n")
    line_number = line_number + newlines
    previous_position = position

    local name = qualified_name:match("([^:]+)$")
    if closing == "/" then
      local parent = stack[#stack - 1]
      if name == "dependencies" and stack[#stack] == "dependencies" and parent == "project" then
        found.dependencies_close = line_number
      elseif name == "project" and stack[#stack] == "project" then
        found.project_close = line_number
      end
      if stack[#stack] == name then
        table.remove(stack)
      end
    elseif not attributes:match("/%s*$") then
      if name == "project" then
        found.project_open = line_number
      end
      if name == "dependencies" and stack[#stack] == "project" then
        found.dependencies_open = line_number
      end
      stack[#stack + 1] = name
    elseif name == "dependencies" and stack[#stack] == "project" then
      found.dependencies_self_closing = line_number
    end
  end

  return found
end

local function existing_coordinates(lines, first, last)
  local result = {}
  if not first or not last then
    return result
  end
  local full_xml = strip_comments(table.concat(lines, "\n"))
  local xml = strip_comments(table.concat(vim.list_slice(lines, first, last), "\n"))
  for dependency in xml:gmatch("<dependency%s*[^>]*>(.-)</dependency%s*>") do
    local group_id = resolve_property(full_xml, tag_value(dependency, "groupId"))
    local artifact_id = resolve_property(full_xml, tag_value(dependency, "artifactId"))
    local dependency_type = resolve_property(full_xml, tag_value(dependency, "type"))
    local classifier = resolve_property(full_xml, tag_value(dependency, "classifier"))
    if
      group_id
      and artifact_id
      and (not dependency_type or dependency_type == "jar")
      and (not classifier or classifier == "")
    then
      result[group_id .. ":" .. artifact_id] = true
    end
  end
  return result
end

local function dependency_lines(dependency, indent)
  local function escape(value)
    return tostring(value)
      :gsub("&", "&amp;")
      :gsub("<", "&lt;")
      :gsub(">", "&gt;")
      :gsub('"', "&quot;")
      :gsub("'", "&apos;")
  end
  local lines = {
    indent .. "<dependency>",
    indent .. "  <groupId>" .. escape(dependency.group_id) .. "</groupId>",
    indent .. "  <artifactId>" .. escape(dependency.artifact_id) .. "</artifactId>",
  }
  if dependency.version then
    lines[#lines + 1] = indent .. "  <version>" .. escape(dependency.version) .. "</version>"
  end
  if dependency.scope and dependency.scope ~= "compile" then
    lines[#lines + 1] = indent .. "  <scope>" .. escape(dependency.scope) .. "</scope>"
  end
  lines[#lines + 1] = indent .. "</dependency>"
  return lines
end

function M.insert(lines, dependencies)
  local updated = vim.deepcopy(lines)
  local positions = structure(updated)
  if not positions.project_close then
    return updated, 0, "pom.xml has no closing project element"
  end
  if
    positions.project_open == positions.project_close
    or (positions.dependencies_open and positions.dependencies_open == positions.dependencies_close)
  then
    return updated, 0, "compact one-line project/dependencies XML is not supported"
  end
  if positions.dependencies_self_closing then
    return updated, 0, "self-closing root dependencies element is not supported"
  end

  local existing =
    existing_coordinates(updated, positions.dependencies_open, positions.dependencies_close)
  local additions = {}
  local added = 0
  local close_line = positions.dependencies_close or positions.project_close
  local close_indent = updated[close_line]:match("^%s*") or ""
  local block_indent = positions.dependencies_close and close_indent or (close_indent .. "  ")
  local dependency_indent = block_indent .. "  "

  if not positions.dependencies_close then
    additions[#additions + 1] = block_indent .. "<dependencies>"
  end

  for _, dependency in ipairs(dependencies) do
    local coordinate = dependency.group_id .. ":" .. dependency.artifact_id
    if not existing[coordinate] then
      vim.list_extend(additions, dependency_lines(dependency, dependency_indent))
      existing[coordinate] = true
      added = added + 1
    end
  end

  if not positions.dependencies_close then
    additions[#additions + 1] = block_indent .. "</dependencies>"
  end
  if added == 0 then
    return updated, 0
  end

  for offset, line in ipairs(additions) do
    table.insert(updated, close_line + offset - 1, line)
  end
  return updated, added
end

return M
