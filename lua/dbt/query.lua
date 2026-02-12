local project = require("dbt.project")
local terminal = require("dbt.terminal")

local M = {}

-- Resolve script path relative to the plugin install directory
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local query_script = plugin_root .. "/scripts/dbt_query.py"

--- Run raw SQL against the warehouse (BigQuery or Databricks) via dbt_query.py.
function M.run_sql(sql_lines, opts)
  local root = project.find_root()
  if not root then
    vim.notify("No dbt_project.yml found in parent directories", vim.log.levels.ERROR)
    return
  end
  local python = project.get_python(root)
  if vim.fn.filereadable(query_script) ~= 1 then
    vim.notify("dbt_query.py not found at " .. query_script, vim.log.levels.ERROR)
    return
  end
  local profile = project.get_profile(root)
  local tmpfile = vim.fn.tempname() .. ".sql"
  vim.fn.writefile(sql_lines, tmpfile)
  local cmd = string.format(
    "%s %s %s --profile %s",
    python,
    vim.fn.shellescape(query_script),
    vim.fn.shellescape(tmpfile),
    vim.fn.shellescape(profile)
  )
  terminal.float(cmd, " Query Results (" .. profile .. ") ")
end

--- Compile the current model, then run the compiled SQL against the warehouse.
function M.compile_and_run(opts)
  local root = project.find_root()
  if not root then
    vim.notify("No dbt_project.yml found in parent directories", vim.log.levels.ERROR)
    return
  end
  local dbt = project.get_dbt(root)
  local python = project.get_python(root)
  if vim.fn.filereadable(query_script) ~= 1 then
    vim.notify("dbt_query.py not found at " .. query_script, vim.log.levels.ERROR)
    return
  end
  local profile = project.get_profile(root)
  local defer = project.defer_flags(root)
  local env = project.env_prefix(root)
  local m = project.model_name()
  local tmpfile = vim.fn.tempname() .. ".sql"
  local cmd = string.format(
    [[cd %s && %s%s compile -s %s %s && cp "$(find target/compiled -name '%s.sql' -print -quit)" %s && %s %s %s --profile %s]],
    vim.fn.shellescape(root),
    env,
    dbt,
    m,
    defer,
    m,
    vim.fn.shellescape(tmpfile),
    python,
    vim.fn.shellescape(query_script),
    vim.fn.shellescape(tmpfile),
    vim.fn.shellescape(profile)
  )
  terminal.float(cmd, " dbt compile + query: " .. m .. " ")
end

return M
