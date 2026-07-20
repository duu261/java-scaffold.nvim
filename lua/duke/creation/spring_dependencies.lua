local M = {}

local View = {}
View.__index = View

local panes = { categories = true, results = true, selected = true }

local function ordered_selected(self)
  local selected = {}
  for _, item in ipairs(self.items) do
    if self.selected[item.id] then
      selected[#selected + 1] = item.id
    end
  end
  return selected
end

local function results(self)
  local found = {}
  local query = self.query:lower()
  for _, item in ipairs(self.items) do
    local searchable = table
      .concat({
        item.id or "",
        item.name or "",
        item.description or "",
        item.group or "",
      }, " ")
      :lower()
    if
      (query ~= "" and searchable:find(query, 1, true))
      or (query == "" and item.group == self.categories[self.category_index])
    then
      found[#found + 1] = item
    end
  end
  return found
end

local function clamp(index, count)
  if count == 0 then
    return 1
  end
  return math.max(1, math.min(index, count))
end

function View:snapshot()
  local current_results = results(self)
  self.result_index = clamp(self.result_index, #current_results)
  local selected_ids = ordered_selected(self)
  return {
    categories = vim.deepcopy(self.categories),
    active_category = self.categories[self.category_index],
    category_index = self.category_index,
    results = vim.deepcopy(current_results),
    result_index = self.result_index,
    selected_ids = selected_ids,
    selected_count = #selected_ids,
    pane = self.pane,
    query = self.query,
  }
end

function View:focus(pane)
  if not panes[pane] then
    return nil, "unknown dependency pane: " .. tostring(pane)
  end
  self.pane = pane
  return true
end

function View:move(delta)
  delta = tonumber(delta) or 0
  if self.pane == "categories" then
    self.category_index = clamp(self.category_index + delta, #self.categories)
    self.result_index = 1
  elseif self.pane == "results" then
    self.result_index = clamp(self.result_index + delta, #results(self))
  end
  return true
end

function View:set_query(query)
  self.query = tostring(query or "")
  self.result_index = 1
  return true
end

function View:toggle()
  local item = results(self)[self.result_index]
  if not item then
    return false
  end
  self.selected[item.id] = not self.selected[item.id] or nil
  return true
end

function View:back()
  return vim.deepcopy(ordered_selected(self))
end

function View:accept()
  return vim.deepcopy(ordered_selected(self))
end

function M.new(items, selected_ids)
  local categories = {}
  local seen_categories = {}
  local selected = {}
  for _, id in ipairs(selected_ids or {}) do
    selected[id] = true
  end
  for _, item in ipairs(items or {}) do
    local group = item.group or "Other"
    if not seen_categories[group] then
      seen_categories[group] = true
      categories[#categories + 1] = group
    end
  end
  return setmetatable({
    items = vim.deepcopy(items or {}),
    categories = categories,
    selected = selected,
    category_index = 1,
    result_index = 1,
    pane = "categories",
    query = "",
  }, View)
end

return M
