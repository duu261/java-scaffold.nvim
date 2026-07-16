local M = {}

local function non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

function M.build_search_args(url, term, rows)
  return {
    "--fail-with-body",
    "--location",
    "--proto",
    "=https",
    "--silent",
    "--show-error",
    "--get",
    "--data-urlencode",
    "q=" .. term,
    "--data-urlencode",
    "rows=" .. tostring(rows),
    "--data-urlencode",
    "wt=json",
    "--user-agent",
    "java-scaffold.nvim",
    url,
  }
end

function M.is_search_result(value)
  if
    type(value) ~= "table"
    or type(value.response) ~= "table"
    or not vim.islist(value.response.docs)
  then
    return false
  end
  for _, doc in ipairs(value.response.docs) do
    if
      type(doc) ~= "table"
      or not non_empty_string(doc.g)
      or not non_empty_string(doc.a)
      or not non_empty_string(doc.latestVersion)
      or (doc.p ~= nil and type(doc.p) ~= "string")
    then
      return false
    end
  end
  return true
end

function M.search(term, callback, runner)
  local config = require("java_scaffold.config").get().maven
  runner = runner or require("java_scaffold.process").run
  runner(
    "curl",
    M.build_search_args(config.central_search_url, term, config.central_search_rows),
    { timeout = config.central_search_timeout },
    function(result)
      if result.code ~= 0 then
        local detail = vim.trim(result.stderr or "")
        if detail == "" then
          detail = vim.trim(result.stdout or "")
        end
        callback(
          "Maven Central search failed: " .. (detail ~= "" and detail or "HTTP request failed")
        )
        return
      end
      local ok, value = pcall(vim.json.decode, result.stdout or "")
      if not ok or not M.is_search_result(value) then
        callback("Maven Central response has unexpected structure")
        return
      end
      local dependencies = {}
      for _, doc in ipairs(value.response.docs) do
        if doc.p ~= "pom" then
          dependencies[#dependencies + 1] = {
            group_id = doc.g,
            artifact_id = doc.a,
            version = doc.latestVersion,
            packaging = doc.p,
          }
        end
      end
      callback(nil, dependencies)
    end
  )
end

return M
