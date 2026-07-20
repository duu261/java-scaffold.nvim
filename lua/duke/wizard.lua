local M = {}

-- Require picker lazily inside each function so mock overrides in tests work.
-- Pattern matches init.lua and every other module in the codebase.

local function notify_error(message)
  require("duke.log").add("ERROR", message)
  vim.notify("duke.nvim: " .. message, vim.log.levels.ERROR)
end

-- Engine: runs steps sequentially. Each step is fn(state, callback).
-- callback(nil) aborts the sequence. callback(new_state) advances to next step.
-- on_complete(final_state) called after the last step succeeds.
function M.sequence(steps, on_complete)
  local state = {}
  local current = 1

  local function next_step()
    if current > #steps then
      on_complete(state)
      return
    end
    local step = steps[current]
    current = current + 1
    local ok, err = pcall(step, state, function(result)
      if result == nil then
        return -- cancelled, abort silently
      end
      state = result
      next_step()
    end)
    if not ok then
      notify_error("wizard step failed: " .. tostring(err))
    end
  end

  next_step()
end

-- Built-in steps: thin wrappers around require("duke.picker").

function M.select_one(items, opts, state_key)
  return function(state, callback)
    require("duke.picker").select_one(items, opts, function(choice)
      if not choice then
        callback(nil)
        return
      end
      state[state_key] = choice
      callback(state)
    end)
  end
end

function M.select_many(items, opts, state_key)
  return function(state, callback)
    require("duke.picker").select_many(items, opts, function(selected)
      if not selected then
        callback(nil)
        return
      end
      state[state_key] = selected
      callback(state)
    end)
  end
end

function M.input(prompt, default, state_key, opts)
  opts = opts or {}
  return function(state, callback)
    require("duke.picker").input(prompt, default, function(value)
      if value == nil then
        callback(nil)
        return
      end
      value = vim.trim(value)
      if value == "" and not opts.allow_empty then
        value = default
      end
      state[state_key] = value
      callback(state)
    end)
  end
end

function M.confirm(title, fields_fn)
  return function(state, callback)
    local fields = fields_fn(state)
    local lines = { title }
    for _, field in ipairs(fields) do
      lines[#lines + 1] = field[1] .. ": " .. tostring(field[2])
    end
    local confirmed = require("duke.picker").confirm(table.concat(lines, "\n"))
    if not confirmed then
      callback(nil)
      return
    end
    callback(state)
  end
end

return M
