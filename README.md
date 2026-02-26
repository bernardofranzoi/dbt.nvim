# dbt.nvim

A Neovim plugin for dbt development. Run dbt commands, execute SQL against your warehouse, render Jinja templates, and navigate model references — all without leaving your editor.

## Features

### dbt Commands
Run any dbt command on the current model in a floating terminal:
- **Compile** — compile the current model
- **Show** — preview results (up to 100 rows by default)
- **Run** — run the current model
- **Test** — run tests for the current model
- **Build** — compile, test, and run

### SQL Execution on the Warehouse
Execute SQL directly against BigQuery or Databricks using your dbt `profiles.yml` credentials:
- Run the entire buffer or a visual selection
- Export results to CSV
- Auto-detects Jinja: if the buffer contains Jinja syntax, it compiles first before querying
- Configurable row limit (default 1000)
- Results displayed as an ASCII table in a floating window

### Fast Jinja Rendering
Render Jinja templates instantly using `manifest.json` — no full `dbt compile` needed:
- Resolves `ref()` and `source()` calls against the manifest
- Expands custom macros from `macros/` and `dbt_packages/`
- Handles `is_incremental()`, `var()`, `env_var()`, `target`, and more
- Falls back to regex-based rendering if Jinja2 parsing fails
- Opens the rendered SQL in a vertical split (read-only)

### Go-to-Definition
Press `gd` on any dbt reference to jump to its definition:
- `{{ ref('model') }}` — opens the model SQL file
- `{{ source('schema', 'table') }}` — opens the source YAML and positions the cursor at the `name:` entry
- `{{ macro_name(...) }}` — finds the macro in `macros/` or `dbt_packages/*/macros/`
- Falls back to LSP definition for non-dbt references

### Defer to Prod
Toggle defer-to-prod mode to run models against your production state:
- Uses `--defer --favor-state --state <dir>` flags automatically
- Toggle on/off with a single keymap

### SQL Formatting
Format SQL files or selections using [sqlfluff](https://sqlfluff.com/):
- Normal mode: formats the entire file, reloads buffer on next enter
- Visual mode: formats the selected lines via a temp file

### Snippets
dbt snippets for [LuaSnip](https://github.com/L3MON4D3/LuaSnip) / [friendly-snippets](https://github.com/rafamadriz/friendly-snippets):
- `ref` → `{{ ref('...') }}`
- `source` → `{{ source('...', '...') }}`
- `config` → config block with materialization

### Floating Terminal
Open an interactive terminal with your project's `.venv` automatically activated.

---

## Requirements

**Neovim plugins:**
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) (required, for floating terminals)
- [folke/which-key.nvim](https://github.com/folke/which-key.nvim) (optional, for keymap group labels)

**Python packages** (in your project's `.venv` or globally):
- `Jinja2`
- `PyYAML`
- `google-cloud-bigquery` (BigQuery only)
- `databricks-sql-connector` (Databricks only)

**External tools:**
- `dbt` CLI
- `sqlfluff` (for formatting)
- Python 3

---

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "bernardofranzoi/dbt.nvim",
  dependencies = { "folke/snacks.nvim" },
  ft = "sql",
  opts = {},
}
```

---

## Configuration

All options and their defaults:

```lua
require("dbt").setup({
  -- dbt binary path. Auto-detected from .venv or $PATH if nil.
  dbt_bin = nil,

  -- Python binary path. Auto-detected from .venv or $PATH if nil.
  python_bin = nil,

  -- Row limit for `dbt show`. Set to nil to disable.
  show_limit = 100,

  -- Row limit for warehouse queries. Set to nil to disable.
  query_limit = 1000,

  -- Enable defer-to-prod by default.
  defer_to_prod = true,

  -- How to display command output: "float" (default) or "split" (horizontal split below).
  output = "float",

  -- Height of the split as a proportion of the screen. Only used when output = "split".
  split_height = 0.35,

  -- Floating window appearance. Only used when output = "float".
  float_win = {
    height = 0.8,
    width = 0.9,
    border = "rounded",
  },

  -- which-key group label for <leader>d keymaps.
  which_key_group = "<leader>d",

  -- Keymaps. Set any key to false to disable it.
  keys = {
    compile  = "<leader>dc",
    show     = "<leader>ds",
    run      = "<leader>dr",
    test     = "<leader>dt",
    build    = "<leader>db",
    query    = "<leader>dq",  -- also works in visual mode
    query_csv = "<leader>dQ", -- also works in visual mode
    render   = "<leader>do",
    defer    = "<leader>dd",
    format   = "<leader>df",  -- also works in visual mode
    lineage  = "<leader>dl",
    terminal = "<leader>fT",
    new_file = "<leader>dn",
  },
})
```

### Disabling keymaps

Set any key to `false` to disable it:

```lua
opts = {
  keys = {
    lineage = false,
    new_file = false,
  },
}
```

---

## Keymaps

| Key | Description | Mode |
|-----|-------------|------|
| `<leader>dc` | dbt compile (current model) | n |
| `<leader>ds` | dbt show (preview, limited rows) | n |
| `<leader>dr` | dbt run (current model) | n |
| `<leader>dt` | dbt test (current model) | n |
| `<leader>db` | dbt build (current model) | n |
| `<leader>dq` | Run SQL on warehouse | n, x |
| `<leader>dQ` | Run SQL on warehouse, save to CSV | n, x |
| `<leader>do` | Open rendered SQL in vsplit | n |
| `<leader>dd` | Toggle defer to prod | n |
| `<leader>df` | Format with sqlfluff | n, x |
| `<leader>dl` | Show dbt lineage | n |
| `<leader>fT` | Open interactive terminal (.venv) | n |
| `<leader>dn` | New analysis SQL file | n |
| `gd` | Go to definition (ref/source/macro) | n |

---

## Supported Adapters

| Adapter | Query | Compile/Run/Test/Build |
|---------|-------|----------------------|
| BigQuery | ✓ | ✓ |
| Databricks | ✓ | ✓ |

Credentials are read from `~/.dbt/profiles.yml` using the profile defined in your `dbt_project.yml`.

---

## How It Works

### Project Discovery
The plugin walks up the directory tree from the current buffer to find `dbt_project.yml`. If found, that directory is used as the project root. The `.env` file in the project root is automatically sourced when running commands.

### Virtual Environment
Binaries (`dbt`, `python`, `sqlfluff`) are resolved in this order:
1. Explicit path from config (`dbt_bin` / `python_bin`)
2. `.venv/bin/` in the project root
3. Global `$PATH`

### Defer to Prod
When defer mode is enabled, dbt commands receive `--defer --favor-state --state <dir>`, where `<dir>` is the first manifest directory found outside of `target/`. This lets you run only changed models while joining against production data.

### Jinja Rendering
The renderer loads `manifest.json` to resolve `ref()` and `source()` calls to their fully-qualified relation names, then evaluates the template with Jinja2. Custom macros from `macros/` and installed `dbt_packages/` are loaded into the Jinja environment. A regex-based fallback handles templates that Jinja2 cannot parse directly.
