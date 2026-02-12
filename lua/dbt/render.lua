local project = require("dbt.project")

local M = {}

-- Resolve script path relative to the plugin install directory
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local render_script = plugin_root .. "/scripts/dbt_render.py"

--- Compile Jinja via dbt_render.py using the prod manifest, open result in vsplit.
function M.open_rendered(opts)
  local root = project.find_root()
  if not root then
    vim.notify("No dbt_project.yml found", vim.log.levels.ERROR)
    return
  end
  local state_dir = project.find_prod_state_dir(root)
  if not state_dir then
    vim.notify("No prod manifest found", vim.log.levels.ERROR)
    return
  end
  local python = project.get_python(root)
  local model_file = vim.fn.expand("%:p")
  local outfile = vim.fn.tempname() .. ".sql"
  local cmd = string.format(
    "%s %s %s %s --output %s",
    python,
    vim.fn.shellescape(render_script),
    vim.fn.shellescape(model_file),
    vim.fn.shellescape(state_dir),
    vim.fn.shellescape(outfile)
  )
  vim.fn.jobstart(cmd, {
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          vim.notify("Render failed", vim.log.levels.ERROR)
          return
        end
        vim.cmd("vsplit " .. vim.fn.fnameescape(outfile))
        vim.bo.filetype = "sql"
        vim.bo.bufhidden = "wipe"
      end)
    end,
  })
end

return M
