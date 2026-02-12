local project = require("dbt.project")

local M = {}

--- Detect ref('model') or source('schema', 'table') under the cursor.
--- Returns ("ref", model_name) or ("source", schema, table_name) or nil.
function M.ref_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col(".")

  -- Check {{ ref('...') }} patterns (cursor anywhere in the {{ }} block)
  local pos = 1
  while true do
    local s, e, model = line:find("{{%s*ref%('([^']+)'%)%s*}}", pos)
    if not s then break end
    if col >= s and col <= e then
      return "ref", model
    end
    pos = e + 1
  end

  -- Check {{ source('...', '...') }} patterns
  pos = 1
  while true do
    local s, e, schema, tbl = line:find("{{%s*source%('([^']+)',%s*'([^']+)'%)%s*}}", pos)
    if not s then break end
    if col >= s and col <= e then
      return "source", schema, tbl
    end
    pos = e + 1
  end

  return nil
end

--- Set up buffer-local gd keymap for dbt ref/source navigation.
local function setup_gd(buf)
  vim.keymap.set("n", "gd", function()
    local root = project.find_root()
    if not root then
      return vim.lsp.buf.definition()
    end

    local kind, a, b = M.ref_at_cursor()

    if kind == "ref" then
      local matches = vim.fn.glob(root .. "/models/**/" .. a .. ".sql", false, true)
      if #matches == 0 then
        matches = vim.fn.glob(root .. "/**/" .. a .. ".sql", false, true)
      end
      if #matches > 0 then
        vim.cmd("edit " .. vim.fn.fnameescape(matches[1]))
      else
        vim.notify("Model not found: " .. a, vim.log.levels.WARN)
      end
    elseif kind == "source" then
      local yamls = vim.fn.glob(root .. "/models/**/*.yml", false, true)
      vim.list_extend(yamls, vim.fn.glob(root .. "/models/**/*.yaml", false, true))
      for _, yf in ipairs(yamls) do
        local lines = vim.fn.readfile(yf)
        for i, l in ipairs(lines) do
          if l:find("name:%s*" .. b) or l:find("name:%s*'" .. b .. "'") then
            vim.cmd("edit +" .. i .. " " .. vim.fn.fnameescape(yf))
            return
          end
        end
      end
      vim.notify("Source not found: " .. a .. "." .. b, vim.log.levels.WARN)
    else
      vim.lsp.buf.definition()
    end
  end, { buffer = buf, desc = "Go to dbt ref/source" })
end

--- Attach gd navigation to SQL buffers via FileType autocmd + retroactive scan.
function M.attach()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "sql",
    callback = function(ev)
      setup_gd(ev.buf)
    end,
  })

  -- Apply to any SQL buffers already open
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "sql" then
      setup_gd(buf)
    end
  end
end

return M
