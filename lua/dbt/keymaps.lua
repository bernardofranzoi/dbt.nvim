local project = require("dbt.project")
local terminal = require("dbt.terminal")
local query = require("dbt.query")
local render = require("dbt.render")

local M = {}

function M.setup(opts)
  local keys = opts.keys or {}

  if keys.compile then
    vim.keymap.set("n", keys.compile, function()
      local m = project.model_name()
      terminal.exec("compile", "-s " .. m, " dbt compile: " .. m .. " ")
    end, { desc = "dbt compile" })
  end

  if keys.show then
    vim.keymap.set("n", keys.show, function()
      local m = project.model_name()
      terminal.exec("show", "-s " .. m .. " --limit " .. (opts.show_limit or 100), " dbt show: " .. m .. " ")
    end, { desc = "dbt show (preview)" })
  end

  if keys.run then
    vim.keymap.set("n", keys.run, function()
      local m = project.model_name()
      terminal.exec("run", "-s " .. m, " dbt run: " .. m .. " ")
    end, { desc = "dbt run" })
  end

  if keys.test then
    vim.keymap.set("n", keys.test, function()
      local m = project.model_name()
      terminal.exec("test", "-s " .. m, " dbt test: " .. m .. " ")
    end, { desc = "dbt test" })
  end

  if keys.build then
    vim.keymap.set("n", keys.build, function()
      local m = project.model_name()
      terminal.exec("build", "-s " .. m, " dbt build: " .. m .. " ")
    end, { desc = "dbt build" })
  end

  if keys.query then
    -- Normal mode: run entire buffer
    vim.keymap.set("n", keys.query, function()
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local content = table.concat(lines, "\n")
      if project.has_jinja(content) and project.is_dbt_model() and not project.is_compiled_artifact() then
        query.compile_and_run()
      else
        query.run_sql(lines)
      end
    end, { desc = "Run buffer SQL on warehouse" })

    -- Visual mode: run selection
    vim.keymap.set("x", keys.query, function()
      local start_line = vim.fn.line("v")
      local end_line = vim.fn.line(".")
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      local content = table.concat(lines, "\n")
      if project.has_jinja(content) and project.is_dbt_model() and not project.is_compiled_artifact() then
        query.compile_and_run()
      else
        query.run_sql(lines)
      end
    end, { desc = "Run selection SQL on warehouse" })
  end

  if keys.query_csv then
    -- Normal mode: run entire buffer and save to CSV
    vim.keymap.set("n", keys.query_csv, function()
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local content = table.concat(lines, "\n")
      local csv_path = vim.fn.input("Save CSV to: ", vim.fn.getcwd() .. "/query_results.csv")
      if csv_path == "" then return end
      if project.has_jinja(content) and project.is_dbt_model() and not project.is_compiled_artifact() then
        query.compile_and_run({ csv = csv_path })
      else
        query.run_sql(lines, { csv = csv_path })
      end
    end, { desc = "Run buffer SQL and save to CSV" })

    -- Visual mode: run selection and save to CSV
    vim.keymap.set("x", keys.query_csv, function()
      local start_line = vim.fn.line("v")
      local end_line = vim.fn.line(".")
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      local csv_path = vim.fn.input("Save CSV to: ", vim.fn.getcwd() .. "/query_results.csv")
      if csv_path == "" then return end
      local content = table.concat(lines, "\n")
      if project.has_jinja(content) and project.is_dbt_model() and not project.is_compiled_artifact() then
        query.compile_and_run({ csv = csv_path })
      else
        query.run_sql(lines, { csv = csv_path })
      end
    end, { desc = "Run selection SQL and save to CSV" })
  end

  if keys.render then
    vim.keymap.set("n", keys.render, function()
      render.open_rendered()
    end, { desc = "Open rendered SQL (fast)" })
  end

  if keys.format then
    vim.keymap.set("n", keys.format, function()
      if vim.bo.modified then
        vim.cmd("write")
      end
      local file = vim.fn.expand("%:p")
      local root = project.find_root()
      if not root then
        vim.notify("No dbt_project.yml found", vim.log.levels.ERROR)
        return
      end
      local sqlfluff = project.get_sqlfluff(root)
      local env = project.env_prefix(root)
      local cmd = string.format("cd %s && %s%s fix %s", vim.fn.shellescape(root), env, sqlfluff, vim.fn.shellescape(file))
      vim.fn.jobstart(cmd, {
        on_exit = function(_, exit_code)
          vim.schedule(function()
            if exit_code <= 1 then
              vim.cmd("edit")
              vim.notify("sqlfluff fix done", vim.log.levels.INFO)
            else
              vim.notify("sqlfluff fix failed (exit " .. exit_code .. ")", vim.log.levels.ERROR)
            end
          end)
        end,
      })
    end, { desc = "Format with sqlfluff fix" })
  end

  if keys.defer then
    vim.keymap.set("n", keys.defer, function()
      project._defer_enabled = not project._defer_enabled
      local status = project._defer_enabled and "ON" or "OFF"
      vim.notify("dbt defer to prod: " .. status, vim.log.levels.INFO)
    end, { desc = "Toggle defer to prod" })
  end

  -- Register which-key group if available
  if opts.which_key_group then
    local ok, wk = pcall(require, "which-key")
    if ok then
      wk.add({ { opts.which_key_group, group = "dbt" } })
    end
  end
end

return M
