# dbt-insurance-analytics

Instructions for Claude Code in this repo.

## Working rules
- Commit after every completed change, without waiting to be asked. Commit only your own paths:
  `git commit -m "<message>" -- <paths>`. If git reports `index.lock`, wait a few seconds and retry.
- Use US English everywhere.
- This repo is public. No local absolute paths, no personal names or emails other than the
  GitHub handle and its noreply address, and no real companies other than tool vendors (dbt,
  DuckDB, Fivetran, Rivery and the like). Run `python scripts/check_public_safety.py` before
  every push.
- Record decisions in `docs/decisions.md` (D-###, never renumbered).
- The data is generated. Change `loader/raw_schema.sql` first, then the generator, then dbt.

## Running things (from the repo root)
- Setup: `uv sync`, then `.venv\Scripts\Activate.ps1` (PowerShell) or
  `source .venv/Scripts/activate` (Git Bash).
- Data: `python -m generator`, then `python -m loader` (writes `warehouse/raw.duckdb`).
- dbt: `dbt deps`, then `dbt build`. `--target prod` builds `warehouse/prod.duckdb`.
- Parallel work: give each job its own dev file, target and log directory:
  `DBT_DUCKDB_DEV_PATH=warehouse/dev_<name>.duckdb`, `DBT_TARGET_PATH=target_<name>`,
  `DBT_LOG_PATH=logs_<name>`, and `DBT_DUCKDB_RAW_PATH` when it needs different raw data.
- Open questions (Q-###) and known limitations are in `docs/open-items.md`.
- Python tests: `pytest`.

## SQL conventions
- Lowercase SQL, 4-space indent, trailing commas, explicit `as` for every alias.
- Each model starts with import CTEs (`with policies as (select * from {{ ref(...) }})`), then
  logical CTEs, and ends with `select * from final`. Marts list their columns explicitly.
- Only staging models read `source()`. Everything else uses `ref()`.
- Names: `stg_<source>__<entity>`, `int_<domain>__<what>`, `dim_<entity>`, `fct_<process>`,
  `rpt_<report>`. Money columns end in `_amount` or describe the measure (`written_premium`);
  dates end in `_date`, timestamps in `_at`, booleans start with `is_` or `has_`.
- Comment the why, not the what: business rules, the reason for a filter, a tiebreak. Readers
  are learning analytics engineering, so a short explanation of a non-obvious rule is welcome.
- Every model has a YAML entry with a description, its primary key tested `unique` and
  `not_null`, and descriptions for its columns.
- Known source defects are tested with `severity: error` plus `warn_if` and `error_if`
  thresholds: the planted count warns, so the build stays green and the count stays visible,
  and a count above the threshold fails. Not `severity: warn`: with it dbt never evaluates
  `error_if`, so the test could never fail. See `docs/data-issues.md`.
