#!/usr/bin/env python3
"""Fast dbt model renderer using Jinja2 + manifest.json for full resolution.
Handles ref, source, config, var, env_var, and project/package macros."""
import json
import os
import sys
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
    import re
    return re.sub(
        r"\{%-?\s*(?:test|snapshot|materialization)\b.*?{%-?\s*end(?:test|snapshot|materialization)\s*-?%}",
        "",
        sql,
        flags=re.DOTALL,
    )


def collect_macro_sources(project_root):
    """Read all .sql files from macros/ and dbt_packages/*/macros/ directories."""
    sources = []
    dirs = [
        os.path.join(project_root, "macros"),
        *glob(os.path.join(project_root, "dbt_packages", "*", "macros")),
    ]
    for d in dirs:
        for path in glob(os.path.join(d, "**", "*.sql"), recursive=True):
            with open(path) as f:
                sources.append(f.read())
    return strip_dbt_block_tags("\n".join(sources))


def detect_incremental(model_sql):
    """Check if the model config sets materialized = 'incremental'."""
    import re
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

    # Load macros first, then the model
    full_template = macro_sources + "\n" + model_sql

    try:
        template = env.from_string(full_template)
        rendered = template.render()
    except Exception as e:
        # If Jinja rendering fails, fall back to simple regex
        rendered = regex_fallback(model_sql, ref_map, source_map, is_incremental, _vars)
        rendered += f"\n-- Jinja render warning: {e}\n"

    # Clean up blank lines
    import re
    rendered = re.sub(r"\n{3,}", "\n\n", rendered).strip() + "\n"
    return rendered


def regex_fallback(sql, ref_map, source_map, is_incremental=False, project_vars=None):
    """Simple regex fallback if Jinja2 rendering fails."""
    import re

    # Handle {% if is_incremental() %} ... {% else %} ... {% endif %} blocks
    # and {% if not is_incremental() %} ... {% endif %} blocks
    def resolve_incremental_blocks(text):
        # {% if is_incremental() %} ... {% else %} ... {% endif %}
        def replace_if_inc(m):
            if_body = m.group(1)
            else_body = m.group(2) or ""
            return if_body if is_incremental else else_body

        text = re.sub(
            r"\{%-?\s*if\s+is_incremental\s*\(\)\s*-?%}(.*?)(?:\{%-?\s*else\s*-?%}(.*?))?\{%-?\s*endif\s*-?%}",
            replace_if_inc, text, flags=re.DOTALL,
        )

        # {% if not is_incremental() %} ... {% else %} ... {% endif %}
        def replace_if_not_inc(m):
            if_body = m.group(1)
            else_body = m.group(2) or ""
            return if_body if not is_incremental else else_body

        text = re.sub(
            r"\{%-?\s*if\s+not\s+is_incremental\s*\(\)\s*-?%}(.*?)(?:\{%-?\s*else\s*-?%}(.*?))?\{%-?\s*endif\s*-?%}",
            replace_if_not_inc, text, flags=re.DOTALL,
        )
        return text

    sql = resolve_incremental_blocks(sql)

    sql = re.sub(r"\{\{\s*config\s*\(.*?\)\s*\}\}", "", sql, flags=re.DOTALL)

    def replace_ref(match):
        return ref_map.get(match.group(1), f"/* UNRESOLVED ref('{match.group(1)}') */")

    sql = re.sub(r"\{\{\s*ref\s*\(\s*['\"]([^'\"]+)['\"]\s*\)\s*\}\}", replace_ref, sql)

    def replace_source(match):
        key = (match.group(1), match.group(2))
        return source_map.get(key, f"/* UNRESOLVED source('{match.group(1)}', '{match.group(2)}') */")

    sql = re.sub(
        r"\{\{\s*source\s*\(\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\)\s*\}\}",
        replace_source, sql,
    )

    _vars = project_vars or {}

    def replace_var(match):
        name = match.group(1)
        default = match.group(3)  # group 3 is the default value if present
        if name in _vars:
            return str(_vars[name])
        if default is not None:
            return default
        return "Not defined."

    sql = re.sub(
        r"\{\{\s*var\s*\(\s*['\"]([^'\"]+)['\"]\s*(,\s*['\"]?([^'\")\s]+)['\"]?\s*)?\)\s*\}\}",
        replace_var, sql,
    )
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
