"""Load the generated sources into warehouse/raw.duckdb as the connectors would have at --as-of.

The generator writes every version of every source row (data/generated/). This module plays the
connectors (docs/source-systems.md 2e and 2f):

- Fivetran-style tables (policy_admin, billing) keep one row per primary key: the latest version
  that a sync had picked up by --as-of. Syncs run at 00:00, 06:00, 12:00 and 18:00, so a version
  changed at `_version_at` is synced at the first boundary at or after it, and that boundary is
  its `_fivetran_synced`. Deleted rows stay, with `_fivetran_deleted = true`.
- Rivery-style CDC tables (claims) are append-only: every version loaded by --as-of
  (`_rivery_last_update <= as_of`), including the duplicates a rerun loaded.
- The GL file connector holds every export file synced by --as-of, all columns as text.
- generator_audit gets the load info, the control totals and the planted issue counts.

The tables are created by executing loader/raw_schema.sql, the raw data contract. The database is
built in a temporary file next to the target and swapped in only when complete, so a failed load
never leaves a half-built raw.duckdb behind.
"""

from __future__ import annotations

import csv
import datetime as dt
import json
import os
import time
from pathlib import Path

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq

SCHEMA_SQL = Path(__file__).resolve().parent / "raw_schema.sql"
SIX_HOURS = dt.timedelta(hours=6)

FIVETRAN_TABLES = {
    "policy_admin": {
        "policyholders": "policyholder_id",
        "policies": "policy_id",
        "policy_terms": "term_id",
        "policy_transactions": "transaction_id",
        "policy_transaction_lines": "transaction_line_id",
        "vehicles": "vehicle_id",
        "dwellings": "dwelling_id",
    },
    "billing": {"installments": "installment_id", "payments": "payment_id"},
}
CDC_TABLES = {
    "claims": "claim_id",
    "claim_exposures": "exposure_id",
    "claim_transactions": "claim_transaction_id",
    "adjusters": "adjuster_id",
}


class LoadError(RuntimeError):
    pass


def next_sync(moment: dt.datetime) -> dt.datetime:
    floor = moment.replace(hour=moment.hour - moment.hour % 6, minute=0, second=0, microsecond=0)
    return floor if floor == moment else floor + SIX_HOURS


def sql_text(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def sql_timestamp(value: dt.datetime) -> str:
    return f"timestamp '{value.isoformat(sep=' ')}'"


def target_columns(con: duckdb.DuckDBPyConnection, schema: str, table: str) -> list[str]:
    rows = con.execute(
        "select column_name from information_schema.columns "
        "where table_schema = ? and table_name = ? order by ordinal_position",
        [schema, table],
    ).fetchall()
    return [r[0] for r in rows]


def load_fivetran(con, schema: str, table: str, key: str, path: Path, as_of: dt.datetime) -> int:
    select = []
    for column in target_columns(con, schema, table):
        if column == "_fivetran_synced":
            select.append("_synced as _fivetran_synced")
        elif column == "_fivetran_deleted":
            select.append("_is_deleted as _fivetran_deleted")
        else:
            select.append(column)
    # time_bucket floors to 6-hour boundaries from midnight; flooring one microsecond earlier and
    # adding 6 hours gives the first boundary at or after the change.
    con.execute(f"""
        insert into {schema}.{table}
        select {", ".join(select)}
        from (
            select
                *,
                time_bucket(interval 6 hours, _version_at - interval 1 microsecond) + interval 6 hours as _synced
            from read_parquet({sql_text(path.as_posix())})
        )
        where _synced <= {sql_timestamp(as_of)}
        qualify row_number() over (partition by {key} order by _version_at desc) = 1
        order by {key}
    """)
    return con.execute(f"select count(*) from {schema}.{table}").fetchone()[0]


def load_cdc(con, table: str, key: str, path: Path, as_of: dt.datetime) -> int:
    columns = ", ".join(target_columns(con, "claims", table))
    con.execute(f"""
        insert into claims.{table}
        select {columns}
        from read_parquet({sql_text(path.as_posix())})
        where _rivery_last_update <= {sql_timestamp(as_of)}
        order by _rivery_last_update, {key}, updated_at
    """)
    return con.execute(f"select count(*) from claims.{table}").fetchone()[0]


def load_ledger(con, input_dir: Path, as_of: dt.datetime) -> int:
    manifest = pq.read_table(input_dir / "gl_files.parquet").to_pylist()
    columns = target_columns(con, "general_ledger", "journal_lines")
    data = {c: [] for c in columns}
    for entry in sorted(manifest, key=lambda e: (e["modified_at"], e["file_name"])):
        synced = next_sync(entry["modified_at"])
        if synced > as_of:
            continue
        with (input_dir / "gl" / entry["file_name"]).open(newline="", encoding="utf-8") as f:
            reader = csv.reader(f)
            header = next(reader)
            for line_number, values in enumerate(reader, start=1):
                for name, value in zip(header, values):
                    data[name].append(value)  # text, exactly as in the file ('' stays '')
                data["_file"].append(entry["file_name"])
                data["_line"].append(line_number)
                data["_modified"].append(entry["modified_at"])
                data["_fivetran_synced"].append(synced)
    types = {"_line": pa.int64(), "_modified": pa.timestamp("us"), "_fivetran_synced": pa.timestamp("us")}
    arrow = pa.table({c: pa.array(data[c], type=types.get(c, pa.string())) for c in columns})
    con.register("gl_lines", arrow)
    con.execute(f"insert into general_ledger.journal_lines select {', '.join(columns)} from gl_lines")
    con.unregister("gl_lines")
    return arrow.num_rows


def ensure_not_locked(path: Path) -> None:
    """Fail early, with a clear message, if another process holds the target database."""
    if not path.exists():
        return
    try:
        duckdb.connect(str(path)).close()
    except duckdb.Error as exc:
        raise LoadError(
            f"{path.as_posix()} is open in another process (dbt, the duckdb CLI, a notebook?). "
            f"Close it and run the loader again. DuckDB said: {exc}"
        ) from exc


def remove_database(path: Path) -> None:
    for p in (path, path.with_name(path.name + ".wal")):
        if p.exists():
            p.unlink()


def load(as_of: dt.datetime | None, input_dir: Path, output: Path, verbose: bool = True) -> dict[str, int]:
    started = time.perf_counter()
    metadata_path = input_dir / "metadata.json"
    if not metadata_path.exists():
        raise LoadError(f"{metadata_path.as_posix()} not found: run `python -m generator` first")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if as_of is None:
        as_of = dt.datetime.fromisoformat(metadata["as_of"])

    output.parent.mkdir(parents=True, exist_ok=True)
    ensure_not_locked(output)
    temporary = output.with_name(f"{output.name}.tmp-{os.getpid()}")
    remove_database(temporary)
    counts: dict[str, int] = {}
    try:
        con = duckdb.connect(str(temporary))
        con.execute(SCHEMA_SQL.read_text(encoding="utf-8"))
        for schema, tables in FIVETRAN_TABLES.items():
            for table, key in tables.items():
                counts[f"{schema}.{table}"] = load_fivetran(con, schema, table, key, input_dir / f"{table}.parquet", as_of)
        for table, key in CDC_TABLES.items():
            counts[f"claims.{table}"] = load_cdc(con, table, key, input_dir / f"{table}.parquet", as_of)
        counts["general_ledger.journal_lines"] = load_ledger(con, input_dir, as_of)

        con.execute(
            "insert into generator_audit.load_info values (?, ?, ?, ?, ?)",
            [as_of, dt.date.fromisoformat(metadata["valuation_date"]), metadata["seed"], metadata["scale"],
             dt.datetime.now().replace(microsecond=0)],
        )
        for table in ("control_totals", "planted_issues"):
            columns = ", ".join(target_columns(con, "generator_audit", table))
            path = sql_text((input_dir / f"{table}.parquet").as_posix())
            con.execute(f"insert into generator_audit.{table} select {columns} from read_parquet({path})")
            counts[f"generator_audit.{table}"] = con.execute(f"select count(*) from generator_audit.{table}").fetchone()[0]
        con.execute("checkpoint")
        con.close()
    except BaseException:
        try:
            con.close()
        except Exception:
            pass
        remove_database(temporary)
        raise

    for attempt in range(5):
        try:
            os.replace(temporary, output)
            break
        except PermissionError as exc:
            if attempt == 4:
                remove_database(temporary)
                raise LoadError(
                    f"could not replace {output.as_posix()}: another process has it open. "
                    "Close it and run the loader again."
                ) from exc
            time.sleep(1)
    stale_wal = output.with_name(output.name + ".wal")
    if stale_wal.exists():
        stale_wal.unlink()  # a WAL left by an earlier crashed session belongs to the old file

    if verbose:
        for name, n in counts.items():
            print(f"  {name:45} {n:>10,}")
        print(f"loaded {output.as_posix()} as of {as_of.isoformat()} in {time.perf_counter() - started:.1f}s")
    return counts
