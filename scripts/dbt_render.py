#!/usr/bin/env python3
"""Fast dbt model renderer using Jinja2 + manifest.json for full resolution.
Handles ref, source, config, var, env_var, and project/package macros."""
import json
import os
import re
import sys
from datetime import datetime
from glob import glob

import yaml
from jinja2 import Environment, BaseLoader, Undefined


class SilentUndefined(Undefined):
    """Return empty string for undefined variables instead of erroring."""
    def __str__(self):
        return ""

    def __iter__(self):
        return iter([])

    def __bool__(self):
        return False

    def __call__(self, *args, **kwargs):
        return self

    def __getattr__(self, name):
        return self


def load_project_vars(project_root):
    """Load vars from dbt_project.yml."""
    if not project_root:
        return {}
    yml_path = os.path.join(project_root, "dbt_project.yml")
    if not os.path.isfile(yml_path):
        return {}
    with open(yml_path) as f:
        project = yaml.safe_load(f)
    return project.get("vars", {}) or {}


def load_manifest(state_dir):
    with open(os.path.join(state_dir, "manifest.json")) as f:
        return json.load(f)


def build_ref_map(manifest):
    ref_map = {}
    for node in manifest.get("nodes", {}).values():
        name = node.get("name")
        relation = node.get("relation_name")
        if name and relation:
            ref_map[name] = relation
    return ref_map


def build_source_map(manifest):
    source_map = {}
    for source in manifest.get("sources", {}).values():
        source_name = source.get("source_name")
        table_name = source.get("name")
        relation = source.get("relation_name")
        if source_name and table_name and relation:
            source_map[(source_name, table_name)] = relation
    return source_map


def strip_dbt_block_tags(sql):
    """Remove dbt-specific block tags that Jinja2 doesn't understand:
    {% test %}, {% snapshot %}, {% materialization %}, etc."""
    return re.sub(
        r"\{%-?\s*(?:test|snapshot|materialization)\b.*?{%-?\s*end(?:test|snapshot|materialization)\s*-?%}",
        "",
        sql,
        flags=re.DOTALL,
    )


def collect_macro_sources(project_root):
    """Read all .sql files from macros/ and dbt_packages/*/macros/ directories.
    Project macros (macros/) are always included. dbt_packages macros are
    individually validated with Jinja2 and skipped if they fail to parse."""
    sources = []

    # Always load ALL project macros — these are user-defined and must be included
    project_macros_dir = os.path.join(project_root, "macros")
    for path in glob(os.path.join(project_macros_dir, "**", "*.sql"), recursive=True):
        with open(path) as f:
            sources.append(strip_dbt_block_tags(f.read()))

    # For dbt_packages, validate each file and skip unparseable ones
    env = Environment(
        loader=BaseLoader(),
        undefined=SilentUndefined,
        extensions=["jinja2.ext.do", "jinja2.ext.loopcontrols"],
    )
    env.globals.update({
        "adapter": SilentUndefined(name="adapter"),
        "exceptions": SilentUndefined(name="exceptions"),
        "target": {"name": "prod", "schema": "prod"},
        "this": "",
        "config": lambda **kw: "",
        "ref": lambda *a: "",
        "source": lambda *a: "",
        "var": lambda name, default=None: default or "",
        "env_var": lambda name, default=None: os.environ.get(name, default or ""),
        "is_incremental": lambda: False,
        "log": lambda msg, info=False: "",
        "return": lambda x: x,
        "run_started_at": datetime.now(),
    })
    for pkg_macros_dir in glob(os.path.join(project_root, "dbt_packages", "*", "macros")):
        for path in glob(os.path.join(pkg_macros_dir, "**", "*.sql"), recursive=True):
            with open(path) as f:
                content = f.read()
            cleaned = strip_dbt_block_tags(content)
            try:
                env.parse(cleaned)
                sources.append(cleaned)
            except Exception:
                pass

    return "\n".join(sources)


def detect_incremental(model_sql):
    """Check if the model config sets materialized = 'incremental'."""
    return bool(re.search(r"""materialized\s*=\s*['"]incremental['"]""", model_sql))


def render_model(model_sql, ref_map, source_map, macro_sources, project_root, project_vars=None):
    env = Environment(
        loader=BaseLoader(),
        undefined=SilentUndefined,
        extensions=["jinja2.ext.do", "jinja2.ext.loopcontrols"],
    )

    is_incremental = detect_incremental(model_sql)
    _vars = project_vars or {}

    # -- dbt built-in functions --
    def dbt_ref(model_name):
        return ref_map.get(model_name, f"/* UNRESOLVED ref('{model_name}') */")

    def dbt_source(source_name, table_name):
        key = (source_name, table_name)
        return source_map.get(key, f"/* UNRESOLVED source('{source_name}', '{table_name}') */")

    def dbt_config(**kwargs):
        return ""

    def dbt_var(name, default=None):
        if name in _vars:
            return _vars[name]
        if default is not None:
            return default
        return "Not defined."

    def dbt_env_var(name, default=None):
        return os.environ.get(name, default if default is not None else "")

    env.globals["ref"] = dbt_ref
    env.globals["source"] = dbt_source
    env.globals["config"] = dbt_config
    env.globals["var"] = dbt_var
    env.globals["env_var"] = dbt_env_var
    env.globals["is_incremental"] = lambda: is_incremental
    env.globals["target"] = {"name": "prod", "schema": "prod"}
    env.globals["this"] = ""
    env.globals["adapter"] = SilentUndefined(name="adapter")
    env.globals["exceptions"] = SilentUndefined(name="exceptions")
    env.globals["log"] = lambda msg, info=False: ""
    env.globals["return"] = lambda x: x
    env.globals["run_started_at"] = datetime.now()

    # Load macros first, then the model
    full_template = macro_sources + "\n" + model_sql

    try:
        template = env.from_string(full_template)
        rendered = template.render()
    except Exception as e:
        # If Jinja rendering fails, fall back to regex
        rendered = regex_fallback(model_sql, ref_map, source_map, is_incremental, _vars, macro_sources)
        rendered += f"\n-- Jinja render warning: {e}\n"

    # Clean up blank lines
    rendered = re.sub(r"\n{3,}", "\n\n", rendered).strip() + "\n"
    return rendered


# ---------------------------------------------------------------------------
# Regex fallback
# ---------------------------------------------------------------------------

def parse_macro_defs(macro_sources):
    """Extract macro definitions from macro source text.
    Returns dict of {name: (arg_names, body)}."""
    macros = {}
    for m in re.finditer(
        r"\{%-?\s*macro\s+(\w+)\s*\(([^)]*)\)\s*-?%}(.*?)\{%-?\s*endmacro\s*-?%}",
        macro_sources, flags=re.DOTALL,
    ):
        name = m.group(1)
        args = [a.strip().split("=")[0].strip() for a in m.group(2).split(",") if a.strip()]
        body = m.group(3)
        macros[name] = (args, body)
    return macros


def _parse_call_args(call_args_str):
    """Parse a macro call argument string, handling nested parens and quotes."""
    call_args = []
    current = ""
    depth = 0
    in_quote = None
    for ch in call_args_str:
        if ch in ("'", '"') and in_quote is None:
            in_quote = ch
        elif ch == in_quote:
            in_quote = None
        elif ch == "(" and in_quote is None:
            depth += 1
        elif ch == ")" and in_quote is None:
            depth -= 1
        elif ch == "," and depth == 0 and in_quote is None:
            call_args.append(current.strip())
            current = ""
            continue
        current += ch
    if current.strip():
        call_args.append(current.strip())

    # Strip surrounding quotes from arguments
    cleaned = []
    for arg in call_args:
        arg = arg.strip()
        if (arg.startswith("'") and arg.endswith("'")) or \
           (arg.startswith('"') and arg.endswith('"')):
            arg = arg[1:-1]
        cleaned.append(arg)
    return cleaned


def expand_macros(sql, macro_defs, max_depth=10):
    """Expand macro calls in SQL using parsed macro definitions.
    Handles {{ macro_name('arg1', 'arg2') }} patterns."""
    for _ in range(max_depth):
        found = False
        for name, (arg_names, body) in macro_defs.items():
            pattern = r"\{\{-?\s*" + re.escape(name) + r"\s*\((.*?)\)\s*-?\}\}"
            for match in re.finditer(pattern, sql):
                found = True
                cleaned_args = _parse_call_args(match.group(1))

                # Substitute arguments into the macro body
                expanded = body
                for i, arg_name in enumerate(arg_names):
                    if i < len(cleaned_args):
                        # Handle all spacing variants: {{x}}, {{ x }}, {{x }}, {{ x}}
                        expanded = re.sub(
                            r"\{\{-?\s*" + re.escape(arg_name) + r"\s*-?\}\}",
                            cleaned_args[i],
                            expanded,
                        )

                sql = sql[:match.start()] + expanded + sql[match.end():]
                break  # restart after each substitution since positions shifted
        if not found:
            break
    return sql


def _replace_vars(sql, project_vars):
    """Replace {{ var('name') }} and {{ var('name', default) }} expressions."""
    def replace_var(match):
        name = match.group(1)
        default = match.group(3)
        if name in project_vars:
            return str(project_vars[name])
        if default is not None:
            return default
        return "Not defined."

    return re.sub(
        r"\{\{-?\s*var\s*\(\s*['\"]([^'\"]+)['\"]\s*(,\s*['\"]?([^'\")\s]+)['\"]?\s*)?\)\s*-?\}\}",
        replace_var, sql,
    )


def regex_fallback(sql, ref_map, source_map, is_incremental=False, project_vars=None, macro_sources=""):
    """Comprehensive regex fallback when Jinja2 rendering fails."""
    _vars = project_vars or {}

    # 1. Remove Jinja comments {# ... #}
    sql = re.sub(r"\{#.*?#\}", "", sql, flags=re.DOTALL)

    # 2. Handle {% if is_incremental() %} blocks
    def _resolve_incremental(text):
        # {% if is_incremental() %} ... {% else %} ... {% endif %}
        text = re.sub(
            r"\{%-?\s*if\s+is_incremental\s*\(\)\s*-?%}(.*?)(?:\{%-?\s*else\s*-?%}(.*?))?\{%-?\s*endif\s*-?%}",
            lambda m: m.group(1) if is_incremental else (m.group(2) or ""),
            text, flags=re.DOTALL,
        )
        # {% if not is_incremental() %} ... {% else %} ... {% endif %}
        text = re.sub(
            r"\{%-?\s*if\s+not\s+is_incremental\s*\(\)\s*-?%}(.*?)(?:\{%-?\s*else\s*-?%}(.*?))?\{%-?\s*endif\s*-?%}",
            lambda m: m.group(1) if not is_incremental else (m.group(2) or ""),
            text, flags=re.DOTALL,
        )
        return text

    sql = _resolve_incremental(sql)

    # 3. Handle {% if target.name == 'prod' %} and != 'prod' blocks
    sql = re.sub(
        r"\{%-?\s*if\s+target\.name\s*==\s*['\"]prod['\"]\s*-?%}(.*?)(?:\{%-?\s*else\s*-?%}(.*?))?\{%-?\s*endif\s*-?%}",
        lambda m: m.group(1), sql, flags=re.DOTALL,
    )
    sql = re.sub(
        r"\{%-?\s*if\s+target\.name\s*!=\s*['\"]prod['\"]\s*-?%}(.*?)(?:\{%-?\s*else\s*-?%}(.*?))?\{%-?\s*endif\s*-?%}",
        lambda m: m.group(2) or "", sql, flags=re.DOTALL,
    )

    # 4. Remove {{ config(...) }}
    sql = re.sub(r"\{\{-?\s*config\s*\(.*?\)\s*-?\}\}", "", sql, flags=re.DOTALL)

    # 5. Expand custom macros FIRST (before var/ref/source, so macro bodies get resolved)
    if macro_sources:
        macro_defs = parse_macro_defs(macro_sources)
        sql = expand_macros(sql, macro_defs)

    # 6. Replace {{ ref('...') }}
    sql = re.sub(
        r"\{\{-?\s*ref\s*\(\s*['\"]([^'\"]+)['\"]\s*\)\s*-?\}\}",
        lambda m: ref_map.get(m.group(1), f"/* UNRESOLVED ref('{m.group(1)}') */"),
        sql,
    )

    # 7. Replace {{ source('...', '...') }}
    sql = re.sub(
        r"\{\{-?\s*source\s*\(\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\)\s*-?\}\}",
        lambda m: source_map.get((m.group(1), m.group(2)),
                                 f"/* UNRESOLVED source('{m.group(1)}', '{m.group(2)}') */"),
        sql,
    )

    # 8. Replace {{ var('...') }} — runs AFTER macro expansion so vars inside macro bodies resolve
    sql = _replace_vars(sql, _vars)

    # 9. Remove {% set ... %} statements
    sql = re.sub(r"\{%-?\s*set\s+.*?-?%}", "", sql, flags=re.DOTALL)

    # 10. Remove any remaining {% ... %} blocks (if/else/endif, for, etc.)
    # Handle remaining if/else/endif by keeping the first branch
    for _ in range(5):  # iterate for nested blocks
        prev = sql
        sql = re.sub(
            r"\{%-?\s*if\b.*?-?%}(.*?)(?:\{%-?\s*else\s*-?%}.*?)?\{%-?\s*endif\s*-?%}",
            r"\1", sql, flags=re.DOTALL,
        )
        if sql == prev:
            break

    # Strip any remaining Jinja tags that weren't handled
    sql = re.sub(r"\{%-?.*?-?%}", "", sql, flags=re.DOTALL)

    # 11. Remove any remaining unresolved {{ ... }} expressions
    sql = re.sub(r"\{\{-?.*?-?\}\}", "", sql)

    return sql


def main():
    if len(sys.argv) < 3:
        print("Usage: dbt_render.py <model_sql_file> <state_dir> [--project-root DIR] [--output FILE]")
        sys.exit(1)

    model_file = sys.argv[1]
    state_dir = sys.argv[2]
    output_file = None
    project_root = None

    i = 3
    while i < len(sys.argv):
        if sys.argv[i] == "--output" and i + 1 < len(sys.argv):
            output_file = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == "--project-root" and i + 1 < len(sys.argv):
            project_root = sys.argv[i + 1]
            i += 2
        else:
            i += 1

    # Auto-detect project root by walking up from model file
    if not project_root:
        d = os.path.dirname(os.path.abspath(model_file))
        while d != "/":
            if os.path.isfile(os.path.join(d, "dbt_project.yml")):
                project_root = d
                break
            d = os.path.dirname(d)

    with open(model_file) as f:
        model_sql = f.read()

    manifest = load_manifest(state_dir)
    ref_map = build_ref_map(manifest)
    source_map = build_source_map(manifest)
    macro_sources = collect_macro_sources(project_root) if project_root else ""
    project_vars = load_project_vars(project_root)

    rendered = render_model(model_sql, ref_map, source_map, macro_sources, project_root, project_vars)

    if output_file:
        with open(output_file, "w") as f:
            f.write(rendered)
    else:
        print(rendered)


if __name__ == "__main__":
    main()
