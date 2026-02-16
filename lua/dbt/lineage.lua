local project = require("dbt.project")

local M = {}

-- Manifest cache: { path = { mtime = number, data = table } }
local _cache = {}

--- Load and cache manifest.json, re-reading only when mtime changes.
local function load_manifest(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local cached = _cache[path]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.data
  end
  local content = vim.fn.readfile(path)
  local ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
  if not ok then
    return nil
  end
  _cache[path] = { mtime = stat.mtime.sec, data = data }
  return data
end

--- Resolve the unique_id for the current model from the manifest nodes.
local function resolve_current_node(manifest, model_name)
  local nodes = manifest.nodes or {}
  -- Try model first, then seed, then snapshot
  for _, prefix in ipairs({ "model.", "seed.", "snapshot." }) do
    for uid, _ in pairs(nodes) do
      if uid:find(prefix, 1, true) and uid:match("[^.]+$") == model_name then
        return uid
      end
    end
  end
  return nil
end

--- Get the display tag for a node unique_id.
local function node_tag(uid)
  if uid:find("^source%.") then
    return "source"
  elseif uid:find("^model%.") then
    return "model"
  elseif uid:find("^seed%.") then
    return "seed"
  elseif uid:find("^snapshot%.") then
    return "snapshot"
  end
  return "unknown"
end

--- Get a short display name for a node unique_id.
local function node_name(uid)
  -- source.project.schema.table -> schema.table
  if uid:find("^source%.") then
    local parts = {}
    for part in uid:gmatch("[^.]+") do
      parts[#parts + 1] = part
    end
    if #parts >= 4 then
      return parts[#parts - 1] .. "." .. parts[#parts]
    end
  end
  -- model.project.name -> name
  return uid:match("[^.]+$") or uid
end

--- Recursively collect tree nodes.
--- map_data: parent_map or child_map from manifest
--- Returns a tree: { uid = string, children = tree[] }
local function build_tree(uid, map_data, visited)
  visited = visited or {}
  if visited[uid] then
    return nil
  end
  visited[uid] = true

  local deps = map_data[uid] or {}
  local children = {}
  for _, dep_uid in ipairs(deps) do
    -- Filter out test nodes
    if not dep_uid:find("^test%.") then
      local child = build_tree(dep_uid, map_data, visited)
      if child then
        children[#children + 1] = child
      end
    end
  end

  table.sort(children, function(a, b)
    return a.uid < b.uid
  end)

  return { uid = uid, children = children }
end

--- Render a tree into lines with box-drawing characters.
--- Each line entry: { text = string, uid = string }
local function render_tree(node, prefix, is_last, result)
  result = result or {}
  prefix = prefix or ""

  local connector = is_last and " └── " or " ├── "
  local tag = node_tag(node.uid)
  local name = node_name(node.uid)
  local text = prefix .. connector .. "[" .. tag .. "] " .. name
  result[#result + 1] = { text = text, uid = node.uid, tag = tag }

  local child_prefix = prefix .. (is_last and "     " or " │   ")
  for i, child in ipairs(node.children) do
    render_tree(child, child_prefix, i == #node.children, result)
  end

  return result
end

--- Build the full rendered output.
--- Returns: lines (string[]), line_metadata ({uid, tag}[]), current_line (1-indexed)
local function render_lineage(manifest, current_uid)
  local parent_map = manifest.parent_map or {}
  local child_map = manifest.child_map or {}

  local lines = {}
  local meta = {}
  local current_line = nil

  -- Helper to add a line
  local function add(text, uid, tag)
    lines[#lines + 1] = text
    meta[#meta + 1] = { uid = uid, tag = tag }
  end

  -- Upstream
  local upstream_tree = build_tree(current_uid, parent_map, {})
  local has_upstream = upstream_tree and #upstream_tree.children > 0

  if has_upstream then
    add(" UPSTREAM", nil, "header")
    for i, child in ipairs(upstream_tree.children) do
      local rendered = render_tree(child, "", i == #upstream_tree.children)
      for _, entry in ipairs(rendered) do
        add(entry.text, entry.uid, entry.tag)
      end
    end
    add("", nil, nil) -- blank separator
  end

  -- Current model
  local tag = node_tag(current_uid)
  local name = node_name(current_uid)
  add(" ► " .. name, current_uid, "current")
  current_line = #lines

  -- Downstream
  local downstream_tree = build_tree(current_uid, child_map, {})
  local has_downstream = downstream_tree and #downstream_tree.children > 0

  if has_downstream then
    add("", nil, nil) -- blank separator
    add(" DOWNSTREAM", nil, "header")
    for i, child in ipairs(downstream_tree.children) do
      local rendered = render_tree(child, "", i == #downstream_tree.children)
      for _, entry in ipairs(rendered) do
        add(entry.text, entry.uid, entry.tag)
      end
    end
  end

  return lines, meta, current_line
end

--- Apply highlights to the buffer.
local function apply_highlights(buf, lines, meta)
  local ns = vim.api.nvim_create_namespace("dbt_lineage")
  for i, m in ipairs(meta) do
    if m.tag == "header" then
      vim.api.nvim_buf_add_highlight(buf, ns, "Title", i - 1, 0, -1)
    elseif m.tag == "current" then
      vim.api.nvim_buf_add_highlight(buf, ns, "WarningMsg", i - 1, 0, -1)
    elseif m.tag == "source" then
      -- Highlight the [source] tag
      local s, e = lines[i]:find("%[source%]")
      if s then
        vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticInfo", i - 1, s - 1, e)
      end
    elseif m.tag == "model" then
      local s, e = lines[i]:find("%[model%]")
      if s then
        vim.api.nvim_buf_add_highlight(buf, ns, "Function", i - 1, s - 1, e)
      end
    elseif m.tag == "seed" then
      local s, e = lines[i]:find("%[seed%]")
      if s then
        vim.api.nvim_buf_add_highlight(buf, ns, "Type", i - 1, s - 1, e)
      end
    elseif m.tag == "snapshot" then
      local s, e = lines[i]:find("%[snapshot%]")
      if s then
        vim.api.nvim_buf_add_highlight(buf, ns, "Type", i - 1, s - 1, e)
      end
    end
  end
end

--- Open the file for a node uid, using original_file_path from manifest.
local function open_node_file(manifest, uid)
  if not uid then
    return
  end
  local node
  if uid:find("^source%.") then
    node = (manifest.sources or {})[uid]
  else
    node = (manifest.nodes or {})[uid]
  end
  if not node then
    vim.notify("Node not found in manifest", vim.log.levels.WARN)
    return
  end
  local file = node.original_file_path or node.path
  if not file then
    vim.notify("No file path for this node", vim.log.levels.WARN)
    return
  end
  -- original_file_path is relative to project root
  local root = project.find_root()
  if root then
    file = root .. "/" .. file
  end
  if vim.fn.filereadable(file) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(file))
  else
    vim.notify("File not found: " .. file, vim.log.levels.WARN)
  end
end

function M.show()
  local root = project.find_root()
  if not root then
    vim.notify("No dbt_project.yml found", vim.log.levels.ERROR)
    return
  end

  local manifest_path = project.find_manifest(root)
  if not manifest_path then
    vim.notify("No manifest.json found (run dbt compile first)", vim.log.levels.ERROR)
    return
  end

  local manifest = load_manifest(manifest_path)
  if not manifest then
    vim.notify("Failed to parse manifest.json", vim.log.levels.ERROR)
    return
  end

  local model_name = project.model_name()
  local current_uid = resolve_current_node(manifest, model_name)
  if not current_uid then
    vim.notify("Model '" .. model_name .. "' not found in manifest", vim.log.levels.WARN)
    return
  end

  local lines, meta, current_line = render_lineage(manifest, current_uid)

  Snacks.win({
    position = "float",
    border = "rounded",
    title = " dbt lineage: " .. model_name .. " ",
    title_pos = "center",
    width = 0.6,
    height = 0.6,
    enter = true,
    text = lines,
    bo = { modifiable = false, filetype = "dbt_lineage" },
    wo = { cursorline = true },
    on_buf = function(self)
      apply_highlights(self.buf, lines, meta)
    end,
    on_win = function(self)
      if current_line then
        vim.api.nvim_win_set_cursor(self.win, { current_line, 0 })
      end
    end,
    keys = {
      q = "close",
      ["<CR>"] = {
        function(self)
          local row = vim.api.nvim_win_get_cursor(self.win)[1]
          local m = meta[row]
          if m and m.uid then
            self:close()
            open_node_file(manifest, m.uid)
          end
        end,
        desc = "Open model file",
      },
    },
  })
end

return M
