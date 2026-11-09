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
- Rejected: BigQuery without billing (the sandbox). Google's sandbox page lists these limits
  [V, checked 2026-11-08]: no DML statements, no streaming, no Data Transfer Service; every
  table, view and partition expires after 60 days; a lifetime 10 GiB storage limit that is not
  refunded when data is deleted; 1 TiB of query processing per month. What that means for this
  project [E, from how dbt-bigquery builds these]:
  - Snapshots run a MERGE, which is DML, so none of `snapshots/` could run.
  - Every dbt-bigquery incremental strategy (merge, insert_overwrite, microbatch) writes with
    MERGE, so `fct_claim_transactions` could only be a full-refresh table.
  - Snapshot history and the month-end close simulation exist to keep history for longer than
    60 days, and the sandbox deletes it after 60.
  - dbt rebuilds tables on every run, which eats into a lifetime storage limit.
  - Fivetran- and Rivery-style loading (upserts, soft deletes, CDC) needs DML or streaming, so
    even the raw layer could not be maintained the way the connectors maintain it.
  - CI would need cloud credentials, which a public repo should not hold.
- Rejected: BigQuery with billing enabled. It lifts these limits and would likely stay within the
  free usage tier at this volume [U], but it needs a payment method and carries a risk of
  charges, and anyone cloning the repo would need their own billed project to run it.
- DuckDB has none of these limits: MERGE, incremental models and snapshots run locally, nothing
  expires, and CI runs the full build with no secrets.

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
