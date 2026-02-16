local M = {}

-- Module-level state (set by init.lua)
M._defer_enabled = true
M._last_dbt_root = nil
M._dbt_bin = nil
M._python_bin = nil

--- Walk up from a starting path to find dbt_project.yml.
function M.walk_up(start)
  local path = start
  while path ~= "/" and path ~= "" do
    if vim.fn.filereadable(path .. "/dbt_project.yml") == 1 then
      return path
    end
    path = vim.fn.fnamemodify(path, ":h")
  end
  return nil
end

--- Find dbt project root: try buffer path, then cwd, then last known root.
function M.find_root()
  local root = M.walk_up(vim.fn.expand("%:p:h"))
  if root then
    M._last_dbt_root = root
    return root
  end
  root = M.walk_up(vim.fn.getcwd())
  if root then
    M._last_dbt_root = root
    return root
  end
  return M._last_dbt_root
end

--- Return the dbt binary. Uses config override, .venv, or global.
function M.get_dbt(root)
  if M._dbt_bin then
    return M._dbt_bin
  end
  local venv_dbt = root .. "/.venv/bin/dbt"
  if vim.fn.executable(venv_dbt) == 1 then
    return venv_dbt
  end
  return "dbt"
end

--- Return the python binary. Uses config override, .venv, or global.
function M.get_python(root)
  if M._python_bin then
    return M._python_bin
  end
  local venv_py = root .. "/.venv/bin/python3"
  if vim.fn.executable(venv_py) == 1 then
    return venv_py
  end
  return "python3"
end

--- Return the sqlfluff binary. Uses .venv or global.
function M.get_sqlfluff(root)
  local venv_sf = root .. "/.venv/bin/sqlfluff"
  if vim.fn.executable(venv_sf) == 1 then
    return venv_sf
  end
  return "sqlfluff"
end

--- Current file's stem (model name).
function M.model_name()
  return vim.fn.expand("%:t:r")
end

--- Read the profile name from dbt_project.yml.
function M.get_profile(root)
  local yml = root .. "/dbt_project.yml"
  for _, line in ipairs(vim.fn.readfile(yml)) do
    local profile = line:match("^profile:%s*['\"]?([^'\"#%s]+)")
    if profile then
      return profile
    end
  end
  return "default"
end

--- Find the prod state directory by looking for manifest.json in subdirectories
--- of the project root, excluding target/ (which is the local build artifact).
function M.find_prod_state_dir(root)
  local manifests = vim.fn.glob(root .. "/*/manifest.json", false, true)
  for _, path in ipairs(manifests) do
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.fnamemodify(dir, ":t") ~= "target" then
      return dir
    end
  end
  return nil
end

--- Find manifest.json: prefer target/ (latest compile), fall back to prod state dir.
function M.find_manifest(root)
  local target = root .. "/target/manifest.json"
  if vim.fn.filereadable(target) == 1 then
    return target
  end
  local state_dir = M.find_prod_state_dir(root)
  if state_dir then
    local prod = state_dir .. "/manifest.json"
    if vim.fn.filereadable(prod) == 1 then
      return prod
    end
  end
  return nil
end

--- Return --defer --state flags if defer is enabled and a prod manifest exists.
function M.defer_flags(root)
  if not M._defer_enabled then
    return ""
  end
  local state_dir = M.find_prod_state_dir(root)
  if state_dir then
    return "--defer --favor-state --state " .. vim.fn.shellescape(state_dir)
  end
  return ""
end

--- Return a shell prefix to source .env if it exists in the project root.
function M.env_prefix(root)
  if vim.fn.filereadable(root .. "/.env") == 1 then
    return "set -a && . " .. vim.fn.shellescape(root .. "/.env") .. " && set +a && "
  end
  return ""
end

--- Check if the current buffer is a dbt model (file lives inside a dbt project).
function M.is_dbt_model()
  return M.walk_up(vim.fn.expand("%:p:h")) ~= nil
end

--- Check if text contains Jinja syntax (expressions, statements, or comments).
function M.has_jinja(text)
  return text:find("{{") ~= nil or text:find("{%%") ~= nil
end

--- Check if the current file is inside target/compiled or target/run (already compiled).
function M.is_compiled_artifact()
  local filepath = vim.fn.expand("%:p")
  return filepath:find("/target/compiled/") ~= nil
    or filepath:find("/target/run/") ~= nil
end

return M
