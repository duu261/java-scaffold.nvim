local M = {}

local kind_names = {
  maven = "Maven",
  gradle = "Gradle",
  spring = "Spring Boot",
}

local function add_line(view, text, highlight)
  view.lines[#view.lines + 1] = text
  if highlight then
    view.highlights[#view.highlights + 1] = {
      group = highlight,
      line = #view.lines,
      col = 0,
      end_col = -1,
    }
  end
  return #view.lines
end

local function add_action(view, id, text, pane, enabled)
  local line = add_line(view, text)
  view.actions[#view.actions + 1] = {
    id = id,
    line = line,
    pane = view.layout == "narrow" and "main" or pane,
    enabled = enabled ~= false,
  }
end

local function display(value)
  if type(value) == "table" then
    if value.name then
      return value.name
    end
    if vim.islist(value) then
      return #value == 0 and "none" or table.concat(value, ", ")
    end
    return "selected"
  end
  if value == nil or value == "" then
    return "not set"
  end
  return tostring(value)
end

local function render_generators(view, snapshot)
  add_line(view, "Generator", "DukeHeading")
  for _, kind in ipairs({ "maven", "gradle", "spring" }) do
    local marker = snapshot.kind == kind and "●" or "○"
    add_action(view, "generator:" .. kind, "  " .. marker .. " " .. kind_names[kind], "generators")
  end
end

local function render_fields(view, snapshot)
  add_line(view, "")
  add_line(view, "Project settings", "DukeHeading")
  for _, field in ipairs(snapshot.fields or {}) do
    add_action(
      view,
      "field:" .. field.id,
      string.format("  %-18s %s", field.label, display(snapshot.values[field.id])),
      "fields"
    )
    if snapshot.errors and snapshot.errors[field.id] then
      add_line(view, "    ! " .. snapshot.errors[field.id], "DiagnosticError")
    end
  end
  add_line(view, "")
  add_line(view, "Destination preview: " .. display(snapshot.derived.project_dir))
end

local function render_status(view, snapshot)
  add_line(view, "")
  add_line(view, "Environment", "DukeHeading")
  local runtimes = snapshot.async and snapshot.async.runtimes or {}
  if runtimes.state == "loading" then
    add_line(view, "  Discovering Java runtimes...")
  else
    local version = snapshot.derived.maven_runner_version
      or snapshot.derived.gradle_runner_version
      or snapshot.derived.runner_version
      or "system"
    add_line(view, "  Runner JVM: " .. version)
  end
  if snapshot.banner then
    add_line(view, "  ! " .. snapshot.banner, "DiagnosticWarn")
  end
  if snapshot.busy then
    add_line(view, "  Creating project...")
  end
end

function M.settings(snapshot, opts)
  opts = opts or {}
  local view = {
    layout = opts.layout or "wide",
    lines = {},
    highlights = {},
    actions = {},
  }
  add_line(view, "Duke Creation Center", "DukeHeading")
  add_line(view, "")
  render_generators(view, snapshot)
  render_fields(view, snapshot)
  render_status(view, snapshot)
  add_line(view, "")
  local loading = false
  for _, status in pairs(snapshot.async or {}) do
    if status.state == "loading" then
      loading = true
      break
    end
  end
  local valid = not snapshot.busy and not loading and not next(snapshot.errors or {})
  add_action(view, "create", valid and "Create" or "Create (unavailable)", "fields", valid)
  if snapshot.help then
    add_line(view, "Enter edit  j/k move  Tab pane  c create  q cancel  ? help")
  else
    add_line(view, "Press ? for help")
  end
  view.cursor_action = view.actions[1] and view.actions[1].id or nil
  return view
end

function M.dependencies(_snapshot, dependency_snapshot, opts)
  opts = opts or {}
  local view = {
    layout = opts.layout or "wide",
    lines = {},
    highlights = {},
    actions = {},
  }
  add_line(view, "Duke Creation Center - Spring dependencies", "DukeHeading")
  add_line(
    view,
    dependency_snapshot.query ~= "" and ("Search: " .. dependency_snapshot.query) or "Search: none"
  )
  add_line(view, "")
  add_line(view, "Categories", "DukeHeading")
  for index, category in ipairs(dependency_snapshot.categories or {}) do
    local marker = index == dependency_snapshot.category_index and "●" or "○"
    add_action(
      view,
      "dependency:category:" .. index,
      "  " .. marker .. " " .. category,
      "categories"
    )
  end
  add_line(view, "")
  add_line(view, "Dependencies", "DukeHeading")
  local selected = {}
  for _, id in ipairs(dependency_snapshot.selected_ids or {}) do
    selected[id] = true
  end
  for _, item in ipairs(dependency_snapshot.results or {}) do
    local marker = selected[item.id] and "✓" or " "
    add_action(
      view,
      "dependency:item:" .. item.id,
      string.format("  [%s] %s  %s", marker, item.name, item.description or ""),
      "results"
    )
  end
  add_line(view, "")
  add_line(
    view,
    string.format("Selected (%d)", dependency_snapshot.selected_count or 0),
    "DukeHeading"
  )
  for _, id in ipairs(dependency_snapshot.selected_ids or {}) do
    add_line(view, "  " .. id)
  end
  add_line(view, "")
  add_line(view, "Space toggle  / search  Tab pane  Enter accept  b back  q cancel")
  view.cursor_action = view.actions[1] and view.actions[1].id or nil
  return view
end

return M
