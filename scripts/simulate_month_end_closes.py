"""Replay the month-end closes, so the dbt snapshots record real history.

    python scripts/simulate_month_end_closes.py --start 2025-01 --end 2026-09
        [--raw-path warehouse/raw.duckdb] [--dev-path warehouse/dev.duckdb] [--fresh]
        [--input data/generated]

Why snapshots must run at every close
-------------------------------------
The policy and billing systems are replicated Fivetran-style (docs/source-systems.md 2a, 2b):
the raw table holds one row per key in its latest state. When a term is cancelled, the row is
overwritten, and the raw data no longer says the term was ever active. A dbt snapshot is the
fix, but it can only record what it sees when it runs: each run compares the source with the
versions it stored and adds a version for every row that changed since. Two changes between two
runs leave only the second; anything before the first run is never recorded. History is not in
the source to be recovered later, so a snapshot that starts today knows nothing about last year.

In production the snapshot runs on a schedule, and at least at each month-end close, so the
state the books closed on is kept. This project's raw data is generated in one go, so this
script replays that schedule: for each accounting period it rebuilds the raw database as the
connectors would have left it at the end of the period's close date
(`python -m loader --as-of <close date>T23:59:59`, docs/source-systems.md 2f) and runs
`dbt snapshot` against it. Each run sees one month of changes, as a scheduled job would have.

At the end it reloads the default as-of (the end of the valuation date) and snapshots once more:
the raw database is then the standard load again, so the generator's control totals and the
reconciliation tests apply to it, and the snapshots' current versions match it.

The claims system needs none of this: its CDC connector appends a row per change, so its
history is in the raw data already (docs/source-systems.md 2c).

Files: the loader writes --raw-path, dbt snapshot writes the snapshot tables into --dev-path
(through DBT_DUCKDB_RAW_PATH and DBT_DUCKDB_DEV_PATH, see profiles.yml). Nobody else may have
either file open while this runs. DBT_TARGET_PATH and DBT_LOG_PATH are passed through as set.

Order matters. A snapshot only moves forward: replaying an earlier as-of on top of history it
has already recorded would not undo it (a timestamp strategy ignores rows older than what it
stored). So the script refuses to start before the latest version already in the snapshots,
unless --fresh drops the snapshot tables first.

What it does not check: a gap. Starting after a close that was never replayed (history up to
the 2025-01 close, then --start 2025-03) snapshots two months of changes in one run, so a term
that changed twice in between keeps only its second state, and the skipped close shows the
state before both. The models' coverage check (fct_policy_in_force_at_close) notices only
terms entered in the gap, not every such case. The snapshot tables do not record which closes
were replayed (dbt_valid_from is source time), so the script cannot tell a gap from a quiet
month; replay the closes as one contiguous range, or start over with --fresh.

The last period may close after the valuation date (2026-09 closes 2026-10-06): its load is
the default load, since the data stops at the valuation date, and the models give it no
as-reported figure. Snapshots land in --dev-path only; to give the prod database history, pass
--dev-path warehouse/prod.duckdb (both dbt targets use the same schema names).
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import subprocess
import sys
import time
from pathlib import Path

import duckdb
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CALENDAR_PATH = REPO_ROOT / "seeds" / "accounting_periods.csv"
SNAPSHOT_DIR = REPO_ROOT / "snapshots"
# Schema of the snapshot tables, from dbt_project.yml (snapshots: +schema: snapshots); the
# project's generate_schema_name macro uses custom schema names as they are.
SNAPSHOT_SCHEMA = "snapshots"
END_OF_DAY = dt.time(23, 59, 59)


def read_close_dates() -> dict[str, dt.date]:
    """accounting_period -> close_date, from the calendar seed."""
    with CALENDAR_PATH.open(newline="", encoding="utf-8") as handle:
        return {
            row["accounting_period"]: dt.date.fromisoformat(row["close_date"])
            for row in csv.DictReader(handle)
        }


def snapshot_keys() -> dict[str, str]:
    """Snapshot name -> its unique_key, for the snapshots defined in snapshots/*.yml."""
    keys = {}
    for path in sorted(SNAPSHOT_DIR.glob("*.yml")):
        config = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for item in config.get("snapshots", []):
            keys[item["name"]] = item["config"]["unique_key"]
    return keys


def existing_snapshot_tables(dev_path: Path, names: list[str]) -> list[str]:
    if not dev_path.exists():
        return []
    with duckdb.connect(str(dev_path), read_only=True) as con:
        rows = con.execute(
            "select table_name from information_schema.tables where table_schema = ?",
            [SNAPSHOT_SCHEMA],
        ).fetchall()
    present = {row[0] for row in rows}
    return [name for name in names if name in present]


def latest_recorded_version(dev_path: Path, tables: list[str]) -> dt.datetime | None:
    """The latest dbt_updated_at in any snapshot table: how far the history already reaches."""
    if not tables:
        return None
    with duckdb.connect(str(dev_path), read_only=True) as con:
        latest = [
            con.execute(f"select max(dbt_updated_at) from {SNAPSHOT_SCHEMA}.{table}").fetchone()[0]
            for table in tables
        ]
    latest = [value for value in latest if value is not None]
    return max(latest) if latest else None


def drop_snapshot_tables(dev_path: Path, tables: list[str]) -> None:
    with duckdb.connect(str(dev_path)) as con:
        for table in tables:
            con.execute(f"drop table if exists {SNAPSHOT_SCHEMA}.{table}")
    print(f"dropped {', '.join(tables)} from {dev_path.as_posix()}")


def run(command: list[str], env: dict[str, str], label: str) -> None:
    """Run a step; show its output only when it fails."""
    result = subprocess.run(command, cwd=REPO_ROOT, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout[-4000:], result.stderr[-4000:], sep="\n", file=sys.stderr)
        sys.exit(f"{label} failed (exit code {result.returncode})")


def load_raw(as_of: dt.datetime | None, input_dir: str, raw_path: Path, env: dict[str, str]) -> None:
    command = [sys.executable, "-m", "loader", "--input", input_dir, "--output", str(raw_path), "--quiet"]
    if as_of is not None:
        command[3:3] = ["--as-of", as_of.isoformat()]
    run(command, env, f"loader as of {as_of.isoformat() if as_of else 'default'}")


def snapshot(env: dict[str, str]) -> None:
    run([sys.executable, "-m", "dbt.cli.main", "snapshot"], env, "dbt snapshot")


def summarize(dev_path: Path, keys: dict[str, str]) -> None:
    """Versions, keys, and keys with more than one version, per snapshot."""
    print("snapshot history:")
    with duckdb.connect(str(dev_path), read_only=True) as con:
        for table, key in keys.items():
            versions, distinct_keys, keys_with_history = con.execute(
                f"""
                select
                    sum(versions),
                    count(*),
                    count(case when versions > 1 then 1 end)
                from (
                    select {key}, count(*) as versions
                    from {SNAPSHOT_SCHEMA}.{table}
                    group by {key}
                )
                """
            ).fetchone()
            print(f"  {table:24} {versions or 0:>9,} versions {distinct_keys:>9,} keys "
                  f"{keys_with_history:>8,} with more than one version")


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Load raw as of each period's close and run dbt snapshot after each load."
    )
    parser.add_argument("--start", required=True, help="first accounting period, YYYY-MM")
    parser.add_argument("--end", required=True, help="last accounting period, YYYY-MM")
    parser.add_argument("--raw-path", type=Path, default=Path("warehouse/raw.duckdb"),
                        help="raw database the loader writes and dbt reads (default: %(default)s)")
    parser.add_argument("--dev-path", type=Path, default=Path("warehouse/dev.duckdb"),
                        help="dev database the snapshots are written to (default: %(default)s)")
    parser.add_argument("--input", default="data/generated",
                        help="generator output the loader reads (default: %(default)s)")
    parser.add_argument("--fresh", action="store_true",
                        help="drop the snapshot tables first and record history from --start")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    # A run takes minutes; show each close as it finishes, also when output goes to a file.
    sys.stdout.reconfigure(line_buffering=True)
    args = parse_args(argv)
    close_dates = read_close_dates()
    for name in ("start", "end"):
        if getattr(args, name) not in close_dates:
            sys.exit(f"--{name} {getattr(args, name)} is not a period in {CALENDAR_PATH.name}")
    if args.start > args.end:
        sys.exit("--start must not be after --end")
    raw_path = (REPO_ROOT / args.raw_path).resolve()
    dev_path = (REPO_ROOT / args.dev_path).resolve()
    if raw_path == dev_path:
        sys.exit("--raw-path and --dev-path must be different files")

    periods = [period for period in sorted(close_dates) if args.start <= period <= args.end]
    closes = [(period, dt.datetime.combine(close_dates[period], END_OF_DAY)) for period in periods]

    keys = snapshot_keys()
    existing = existing_snapshot_tables(dev_path, list(keys))
    if args.fresh and existing:
        drop_snapshot_tables(dev_path, existing)
        existing = []
    latest = latest_recorded_version(dev_path, existing)
    if latest is not None and latest > closes[0][1]:
        sys.exit(
            f"the snapshots in {dev_path.as_posix()} already hold versions up to {latest}, after "
            f"the first close ({closes[0][1]}). Replaying earlier states would not undo them. "
            "Use --fresh to start the history over, or a later --start."
        )

    env = dict(os.environ, DBT_DUCKDB_RAW_PATH=str(raw_path), DBT_DUCKDB_DEV_PATH=str(dev_path))
    started = time.perf_counter()
    for number, (period, as_of) in enumerate(closes, start=1):
        load_raw(as_of, args.input, raw_path, env)
        snapshot(env)
        print(f"[{number}/{len(closes)}] {period} closed {as_of:%Y-%m-%d}: loaded and snapshotted "
              f"({time.perf_counter() - started:.0f}s)")

    # Back to the standard load, so the control totals hold again and the snapshots' current
    # versions are the sources' current state.
    load_raw(None, args.input, raw_path, env)
    snapshot(env)
    print(f"reloaded the default as-of and snapshotted ({time.perf_counter() - started:.0f}s)")
    summarize(dev_path, keys)


if __name__ == "__main__":
    main()
