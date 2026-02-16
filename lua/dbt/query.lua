local project = require("dbt.project")
local terminal = require("dbt.terminal")

local M = {}

-- Resolve script path relative to the plugin install directory
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local query_script = plugin_root .. "/scripts/dbt_query.py"

-- Default query row limit
M._query_limit = 1000

--- Build the base query command string.
local function build_query_cmd(root, tmpfile, extra_args)
  local python = project.get_python(root)
  local profile = project.get_profile(root)
  local limit_flag = M._query_limit and (" --limit " .. M._query_limit) or ""
  return string.format(
    "%s %s %s --profile %s%s%s",
    python,
    vim.fn.shellescape(query_script),
    vim.fn.shellescape(tmpfile),
    vim.fn.shellescape(profile),
    limit_flag,
    extra_args or ""
  ), profile
end

--- Run raw SQL against the warehouse (BigQuery or Databricks) via dbt_query.py.
function M.run_sql(sql_lines, opts)
  local root = project.find_root()
  if not root then
    vim.notify("No dbt_project.yml found in parent directories", vim.log.levels.ERROR)
    return
  end
  if vim.fn.filereadable(query_script) ~= 1 then
    vim.notify("dbt_query.py not found at " .. query_script, vim.log.levels.ERROR)
    return
  end
  local tmpfile = vim.fn.tempname() .. ".sql"
  vim.fn.writefile(sql_lines, tmpfile)
  local csv_flag = ""
  if opts and opts.csv then
    csv_flag = " --csv " .. vim.fn.shellescape(opts.csv)
  end
  local cmd, profile = build_query_cmd(root, tmpfile, csv_flag)
  terminal.float(cmd, " Query Results (" .. profile .. ") ")
end

--- Run raw SQL and save results to CSV.
function M.run_sql_csv(sql_lines)
  local csv_path = vim.fn.input("Save CSV to: ", vim.fn.getcwd() .. "/query_results.csv")
  if csv_path == "" then return end
  M.run_sql(sql_lines, { csv = csv_path })
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
  local csv_flag = ""
  if opts and opts.csv then
    csv_flag = " --csv " .. vim.fn.shellescape(opts.csv)
  end
  local limit_flag = M._query_limit and (" --limit " .. M._query_limit) or ""
  local cmd = string.format(
    [[cd %s && %s%s compile -s %s %s && cp "$(find target/compiled -name '%s.sql' -print -quit)" %s && %s %s %s --profile %s%s%s]],
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
    vim.fn.shellescape(profile),
    limit_flag,
    csv_flag
  )
  terminal.float(cmd, " dbt compile + query: " .. m .. " ")
end

return M
