local M = {}

function M.setup(opts)
  opts = require("dbt.config").resolve(opts)
  local project = require("dbt.project")
  project._defer_enabled = opts.defer_to_prod
  project._dbt_bin = opts.dbt_bin
  project._python_bin = opts.python_bin
  require("dbt.terminal")._opts = opts
  require("dbt.keymaps").setup(opts)
  require("dbt.navigation").attach()
end

return M
