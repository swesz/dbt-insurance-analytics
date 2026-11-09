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

## D-008: Earned premium is computed in exact integer cents
- Status: accepted 2026-11-08
- `macros/premium_earned_to_date.sql` computes round(premium * elapsed / days) as integer
  arithmetic on cents, rounding half away from zero, instead of DECIMAL division.
- Reason: DuckDB evaluates DECIMAL / INTEGER as a DOUBLE, and a DOUBLE can round a half cent the
  wrong way: `round(1.005::double, 2)` is 1.0 [V]. The macro matched Python's Decimal on 200,000
  random cases including 357 exact half-cent ties [V, premium build]. The same DOUBLE behavior
  broke `cents_to_dollars` until it switched to multiplying by 0.01.
- Cost: `//` is DuckDB's integer division; another warehouse needs its own operator.

## D-009: Exposure units are the policy's current vehicle or dwelling count
- Status: accepted 2026-11-08
- The source keeps no add or remove dates for vehicles, so every month of a policy uses today's
  count. Revisit if the raw contract gains unit history.

## D-010: fct_claim_transactions is incremental with delete+insert and a loader-time lookback
- Status: accepted 2026-11-08
- Unique key `financial_event_id`; each run rebuilds the events whose source rows were loaded
  within `claims_incremental_lookback_days` (3) of the last high-water mark, so late-arriving
  CDC rows and voids are picked up. delete+insert was chosen over merge for its simpler, fully
  replaced key set; the reasoning is in the model's header.
- Check: `assert_fct_claim_transactions_matches_events` compares the fact with a full rebuild on
  every build. A full refresh and repeated incremental runs gave identical results [V, claims build].
- Known limit: an event whose source row disappears is not removed by an incremental run.

## D-011: A voided payment is two events
- Status: accepted 2026-11-08
- The payment stays in the period it was booked in, and a PAYMENT_VOID reversal is booked at the
  void, because closed periods never change (docs/source-systems.md 3f).

## D-012: Loss development triangles are evaluated on booked accounting periods
- Status: accepted 2026-11-08
- A cell at age n holds what was booked by the end of that evaluation period, so the triangle
  agrees with the ledger. It includes orphan claims and excludes expenses.

## D-013: Snapshot configuration
- Status: accepted 2026-11-08
- Snapshots read sources, not staging, so a later change to staging logic cannot rewrite history.
- `hard_deletes: ignore`: the policy and billing sources soft-delete (a flag), so a row never
  disappears from them.
- `dbt_valid_to_current: 9999-12-31`, so "current" rows can be found with a range condition
  instead of `is null`.
- `snap_policyholders` uses the check strategy on email, address and `_fivetran_deleted`, with
  `_fivetran_synced` as the time: a soft delete leaves the source `updated_at` unchanged, so a
  timestamp strategy would miss all 40 deletions [V, actuarial build].

## D-014: Frequency and severity attribute exposure by coverage earned
- Status: accepted 2026-11-08
- A policy's earned exposure counts for a coverage only in months it earns premium on that
  coverage (collision and comprehensive are optional). Orphan claims and losses outside the term
  are left out of frequency and severity.

## D-015: Ledger amounts are signed debit-positive; reconciling items are ledger minus subledger
- Status: proposed 2026-11-08
- Postings and balances use one signed amount (debit +, credit −). A documented reconciling item's
  `amount` is ledger minus subledger, so `unexplained_difference = difference - documented`.
  Tolerance 0.01 per row (`macros/accounting_reconciliation_tolerance.sql`).

## D-016: Receivable aging allocation
- Status: proposed 2026-11-08
- Refunds first use up the credits they pay out; remaining credits settle the latest-due
  installments first; cash settles the oldest-due first. The spec does not say whether a credit
  is refunded or applied to future installments [E].
