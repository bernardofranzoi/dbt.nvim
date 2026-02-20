local project = require("dbt.project")

local M = {}

-- Resolved options, set by init.lua
M._opts = nil

--- Open a Snacks floating terminal that runs `cmd` and stays open for viewing.
function M.float(cmd, title, opts)
  local win_opts = M._opts and M._opts.float_win or { height = 0.8, width = 0.9, border = "rounded" }
  opts = opts or {}
  Snacks.terminal.open(cmd, {
    interactive = false,
    win = vim.tbl_extend("force", {
      position = "float",
      title = title or "",
      title_pos = "center",
    }, win_opts),
  })
end

--- Run a dbt subcommand in a floating terminal.
function M.exec(subcmd, args, title, opts)
  local root = project.find_root()
  if not root then
    vim.notify("No dbt_project.yml found in parent directories", vim.log.levels.ERROR)
    return
  end
  local dbt = project.get_dbt(root)
  local defer = project.defer_flags(root)
  local env = project.env_prefix(root)
  local cmd = string.format(
    "cd %s && %s%s %s %s %s",
    vim.fn.shellescape(root),
    env,
    dbt,
    subcmd,
    args or "",
    defer
  )
  M.float(cmd, title, opts)
end

--- Open an interactive terminal with the project's .venv activated.
function M.open_terminal()
  local root = project.find_root()
  if not root then
    vim.notify("No dbt_project.yml found in parent directories", vim.log.levels.ERROR)
    return
  end
  local activate = root .. "/.venv/bin/activate"
  local shell = os.getenv("SHELL") or "bash"
  local cmd
  if vim.fn.filereadable(activate) == 1 then
    cmd = string.format("cd %s && source %s && exec %s", vim.fn.shellescape(root), vim.fn.shellescape(activate), shell)
    cmd = shell .. " -c " .. vim.fn.shellescape(cmd)
  else
    vim.notify("No .venv found, opening plain terminal", vim.log.levels.WARN)
    cmd = shell
  end
  local win_opts = M._opts and M._opts.float_win or { height = 0.8, width = 0.9, border = "rounded" }
  Snacks.terminal.open(cmd, {
    interactive = true,
    win = vim.tbl_extend("force", {
      position = "float",
      title = " dbt terminal ",
      title_pos = "center",
    }, win_opts),
  })
end

return M
