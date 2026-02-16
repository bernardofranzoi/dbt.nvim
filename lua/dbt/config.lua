local M = {}

M.defaults = {
  keys = {
    compile = "<leader>dc",
    show = "<leader>ds",
    run = "<leader>dr",
    test = "<leader>dt",
    build = "<leader>db",
    query = "<leader>dq",
    query_csv = "<leader>dQ",
    render = "<leader>do",
    defer = "<leader>dd",
    format = "<leader>df",
    lineage = "<leader>dl",
  },
  which_key_group = "<leader>d",
  show_limit = 100,
  query_limit = 1000, -- default row limit for queries (nil to disable)
  defer_to_prod = true,
  float_win = { height = 0.8, width = 0.9, border = "rounded" },
  python_bin = nil, -- auto-detect from .venv or global
  dbt_bin = nil, -- auto-detect from .venv or global
}

--- Deep-merge user overrides onto defaults.
function M.resolve(opts)
  return vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
