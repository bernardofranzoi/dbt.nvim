#!/usr/bin/env python3
"""Run a SQL query against BigQuery or Databricks using credentials from ~/.dbt/profiles.yml."""
import csv
import os
import sys


def load_profile(profile_name="default"):
    import yaml

    profiles_path = os.path.expanduser("~/.dbt/profiles.yml")
    with open(profiles_path) as f:
        profiles = yaml.safe_load(f)

    profile = profiles.get(profile_name, {})
    target_name = profile.get("target", "dev")
    target = profile.get("outputs", {}).get(target_name, {})

    if not target:
        print(f"Error: profile '{profile_name}' target '{target_name}' not found")
        sys.exit(1)

    return target


def format_vertical(headers, rows):
    """Format results in vertical/record mode — one column per line, one block per row."""
    if not rows:
        return "Query returned 0 rows."

    max_header_len = max(len(h) for h in headers)
    lines = []
    for i, row in enumerate(rows):
        lines.append(f"*** row {i + 1} ***")
        for header, val in zip(headers, row):
            val = str(val) if val is not None else "NULL"
            lines.append(f"  {header.rjust(max_header_len)}: {val}")
        lines.append("")

    return "\n".join(lines)


def format_table(headers, rows):
    if not rows:
        return "Query returned 0 rows."

    str_rows = []
    for row in rows:
        str_row = []
        for val in row:
            val = str(val) if val is not None else "NULL"
            if len(val) > 60:
                val = val[:57] + "..."
            str_row.append(val)
        str_rows.append(str_row)

    widths = [len(h) for h in headers]
    for row in str_rows:
        for i, val in enumerate(row):
            widths[i] = max(widths[i], len(val))

    # If table would be wider than terminal, use vertical mode
    total_width = sum(widths) + 3 * (len(widths) - 1)
    try:
        term_width = os.get_terminal_size().columns
    except OSError:
        term_width = 120
    if total_width > term_width:
        return format_vertical(headers, rows)

    lines = []
    lines.append(" | ".join(h.ljust(w) for h, w in zip(headers, widths)))
    lines.append("-+-".join("-" * w for w in widths))
    for row in str_rows:
        lines.append(" | ".join(v.ljust(w) for v, w in zip(row, widths)))

    return "\n".join(lines)


def write_csv(headers, rows, csv_path):
    """Write query results to a CSV file."""
    with open(csv_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(headers)
        for row in rows:
            writer.writerow(["" if val is None else val for val in row])
    print(f"\nCSV saved to: {csv_path}")


def run_bigquery(target, sql, limit):
    from google.cloud import bigquery

    client = bigquery.Client.from_service_account_json(
        target["keyfile"],
        project=target["project"],
    )

    if limit:
        sql = f"SELECT * FROM ({sql}) __q LIMIT {limit}"

    print(f"Adapter:  bigquery")
    print(f"Project:  {target['project']}")
    print(f"Dataset:  {target.get('dataset', 'N/A')}")
    print(f"Location: {target.get('location', 'US')}")
    print("Running query...")
    print("=" * 60)

    job_config = bigquery.QueryJobConfig()
    dataset_ref = target.get("dataset")
    if dataset_ref:
        job_config.default_dataset = f"{target['project']}.{dataset_ref}"
    query_job = client.query(sql, job_config=job_config)
    results = query_job.result()

    headers = [field.name for field in results.schema]
    rows = [list(row.values()) for row in results]
    print(format_table(headers, rows))

    bytes_processed = query_job.total_bytes_processed or 0
    bytes_billed = query_job.total_bytes_billed or 0
    print(f"\n{len(rows)} row(s) returned")
    print(f"Bytes processed: {bytes_processed:,}")
    print(f"Bytes billed:    {bytes_billed:,}")

    return headers, rows


def run_databricks(target, sql, limit):
    from databricks import sql as dbsql

    if limit:
        sql = f"SELECT * FROM ({sql}) __q LIMIT {limit}"

    print(f"Adapter:  databricks")
    print(f"Host:     {target['host']}")
    print(f"Catalog:  {target.get('catalog', 'N/A')}")
    print(f"Schema:   {target.get('schema', 'N/A')}")
    print("Running query...")
    print("=" * 60)

    connection = dbsql.connect(
        server_hostname=target["host"],
        http_path=target["http_path"],
        access_token=target["token"],
        catalog=target.get("catalog"),
        schema=target.get("schema"),
    )

    try:
        cursor = connection.cursor()
        cursor.execute(sql)
        headers = [desc[0] for desc in cursor.description]
        rows = [list(row) for row in cursor.fetchall()]
        print(format_table(headers, rows))
        print(f"\n{len(rows)} row(s) returned")
    finally:
        cursor.close()
        connection.close()

    return headers, rows


def main():
    if len(sys.argv) < 2:
        print("Usage: dbt_query.py <sql_file> [--profile PROFILE] [--limit N] [--csv FILE]")
        sys.exit(1)

    sql_file = sys.argv[1]
    profile_name = "default"
    limit = None
    csv_path = None

    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == "--profile" and i + 1 < len(sys.argv):
            profile_name = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == "--limit" and i + 1 < len(sys.argv):
            limit = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == "--csv" and i + 1 < len(sys.argv):
            csv_path = sys.argv[i + 1]
            i += 2
        else:
            i += 1

    with open(sql_file) as f:
        sql = f.read().strip()

    if not sql:
        print("Error: empty SQL file")
        sys.exit(1)

    try:
        os.unlink(sql_file)
    except OSError:
        pass

    target = load_profile(profile_name)
    adapter_type = target.get("type")

    try:
        if adapter_type == "bigquery":
            headers, rows = run_bigquery(target, sql, limit)
        elif adapter_type == "databricks":
            headers, rows = run_databricks(target, sql, limit)
        else:
            print(f"Error: unsupported adapter type '{adapter_type}'")
            sys.exit(1)

        if csv_path:
            write_csv(headers, rows, csv_path)

    except Exception as e:
        print(f"\nQuery error:\n{e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
