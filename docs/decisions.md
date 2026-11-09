# Decisions

IDs are permanent and never reused. Status: proposed, accepted, superseded (by D-###).

## D-001: DuckDB, with three databases standing in for raw, dev and prod projects
- Status: accepted 2026-11-08
- `warehouse/raw.duckdb` is written only by the loader; `dev.duckdb` and `prod.duckdb` are
  written only by dbt and attach raw read-only. In a cloud warehouse these would be three
  projects (or databases); dbt's `database` maps to the file here.
- Reason: runs anywhere with no account, no cost and no credentials, including CI. The SQL avoids
  DuckDB-only features where standard SQL works, so moving to a cloud warehouse later is mostly a
  profile change plus a few date functions.
- Cost: no warehouse-specific features (partitioning, clustering, IAM).

## D-002: Generated data with planted defects instead of a public dataset
- Status: accepted 2026-11-08
- No public dataset has policy transactions, claim reserve and payment histories, billing and a
  general ledger that tie to each other. A seeded Python generator produces all of them,
  deterministically, plus the defects in `docs/data-issues.md`.
- The generator also writes control totals computed in Python; dbt's SQL is checked against
  them (`docs/source-systems.md`, section 5).

## D-003: Schemas name layers, not environments
- Status: accepted 2026-11-08
- `macros/generate_schema_name.sql` uses custom schema names as they are (`staging`, `core`,
  `claims`, ...) instead of dbt's default `<target_schema>_<custom>`, because each environment is
  its own database file already.

## D-004: Raw keeps the loaders' types; only file-loaded data is text
- Status: accepted 2026-11-08
- Fivetran- and Rivery-style connectors write typed columns, so `policy_admin`, `billing` and
  `claims` arrive typed. The ledger arrives from CSV files, so `general_ledger` is all text and
  staging parses it.

## D-005: Booking rule for accounting periods
- Status: accepted 2026-11-08
- A transaction is booked in the first period on or after its `transaction_date`'s period that
  was still open at `created_at` (macro `booked_accounting_period`). Closed periods never change.

## D-006: Earned premium as the difference of inception-to-date earned
- Status: accepted 2026-11-08
- Earned(P) = ITD earned at P's end over lines booked ≤ P, minus the same at P−1. Backdated
  changes catch up in the period they are booked in, and the unearned premium rollforward ties
  by construction.

## D-007: Newest versions: Python 3.14, dbt-core 1.12.6, dbt-duckdb 1.11.1, DuckDB 2.0.0
- Status: accepted 2026-11-08
- Python 3.15 exists, but dbt-core 1.12.6 lists support up to 3.14 [V, PyPI classifiers].
