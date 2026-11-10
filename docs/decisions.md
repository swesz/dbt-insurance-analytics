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
  within `claims_incremental_lookback_days` (3) of the last high-water mark, as a safeguard for
  rows a pipeline delivers late or out of order. With this data a strict high-water mark misses
  nothing (a 0-day lookback matched a full rebuild [V, claims fix]), so the window only
  re-processes unchanged events. delete+insert was chosen over merge for its simpler, fully
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
- Three grains: `ANNUAL` (year ends), `QUARTERLY`, and `ANNUAL_AT_VALUATION` (the valuation date
  and its anniversaries, D-019).

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
- Status: accepted 2026-11-08 (amended: the tolerance was 0.01 per row when proposed)
- Postings and balances use one signed amount (debit +, credit −). A documented reconciling item's
  `amount` is ledger minus subledger, so `unexplained_difference = difference - documented`.
- No tolerance (`macros/accounting_reconciliation_tolerance.sql` returns 0): every difference on
  the default load is 0.00 [V], and a one-cent allowance would let a one-cent conversion bug
  pass. Supersedes 0.01 per row.

## D-016: Receivable aging allocation
- Status: accepted 2026-11-08 (amended: steps 1 and 3 added after the accounting review)
- Four steps in `int_accounting__installment_allocation`: (1) a reinstatement debit is settled
  by its own term's cancellation credit (`reversed_amount`); (2) refunds use up the credits that
  remain, oldest first; (3) the credits left settle their own term's installments, latest due
  first, and only the rest goes to the policy's other terms; (4) cash settles the oldest due
  first.
- Why: pooling credits and cash per policy showed 75 paid-up reinstated policies as past due
  (45,212.43) while total open was right [V]. The spec does not say whether a credit is refunded
  or applied to future installments [E].
- Check: `assert_aging_shows_nothing_past_due_for_paid_up_policies` (fails with 75 rows on the
  pooled allocation).

## D-017: In-force premium is the full-term premium at current rates
- Status: accepted 2026-11-08
- `fct_policy_month_end.in_force_term_premium` rebuilds each line's full-term amount as
  written x term days / window days, because the source writes endorsements pro rata; summing
  written premium made a rate change count for less the later in the term it happened.
  `annualized_in_force_premium` multiplies by 12 / term months (auto x 2, home x 1), not by
  365 / term days, so a term's day count does not move it.
- Cost: the source rounds pro rata amounts to the cent, so a line with a window of a few days
  can be rebuilt a few cents off. Checked: every in-force month whose term has only new
  business or renewal lines matches written premium exactly (395,966 rows) [V].

## D-018: Control totals match to the cent, with no tolerance
- Status: accepted 2026-11-08; supersedes the $1.00 tolerance on earned and unearned premium
- Both implementations round each line's inception-to-date earned amount the same way (D-008),
  and every period and line matched exactly [V]. A tolerance would hide the small errors a
  test exists for: one day of a $60 coverage is 33 cents.
- A guard test fails when the load is the default one but no control totals match its as_of,
  so the comparisons cannot pass by being skipped.

## D-019: The chain ladder projects from the valuation date; the current accident year is not
- Status: accepted 2026-11-08
- The year-end `ANNUAL` triangle's latest diagonal was 2025-12-31, so IBNR was measured from
  9-month-old incurred and accident year 2026 was missing. The triangle adds
  `ANNUAL_AT_VALUATION` (ages 9, 21, 33, ... for a September valuation) and the analysis uses
  it, so IBNR = ultimate - incurred at the valuation date.
- An accident year younger than 12 months gets no ultimate or IBNR: its 9-to-21-month factor is
  mostly October-December accidents arriving (auto 1.4775 = 1.0285 development + 0.4490 new
  accidents [V, claims fix]), which belong to unearned premium, not to a reserve.
- Rejected: rolling up quarterly cells, which works only for quarter-end valuation dates.
  Check: `assert_triangle_latest_diagonal_matches_control_totals`.

## D-020: is_loss_outside_term is null for orphan claims
- Status: accepted 2026-11-08
- With no policy there is no term to check. True would merge ORPHAN_CLAIMS into
  LOSS_OUTSIDE_TERM and report a check never made; false would assert coverage nobody verified.
  Pinned by the test `(is_loss_outside_term is null) = (not has_matching_policy)`.
- Filter with `is not true`: `where not is_loss_outside_term` silently drops the 5 orphans.

## D-021: The ledger is reconciled per source system
- Status: accepted 2026-11-08
- `rpt_subledger_gl_reconciliation` compares per accounting period x line of business x
  account x source system. Two accounts are fed by two systems (1000 Cash by billing and
  claims, 1200 Receivable by policy admin and billing), so compared per account only, an error
  in one system's journal and an opposite error in the other's would cancel out and show
  MATCHED.
- The seed `gl_reconciling_items` gained `source_system`. An existing database needs
  `dbt seed --full-refresh -s gl_reconciling_items` once.

## D-022: Claim frequency counts claims; severity is per claim
- Status: accepted 2026-11-08; extends D-014
- `claim_frequency` = distinct claims / earned exposure years and `average_incurred_severity`
  = incurred / claims, as in the glossary and the frequency targets of
  `docs/source-systems.md` section 4. Before, both counted exposures (one coverage and one
  claimant), which overstated bodily injury frequency.
- `claimant_frequency` keeps the exposure count, because bodily injury limits apply per
  person.

## D-023: CI runs on a named runner image
- Status: accepted 2026-11-08
- `runs-on: ubuntu-26.04`, not `ubuntu-latest`. The label moves to a new release on GitHub's
  schedule (it moved to Ubuntu 26 from 2026-10-19), so the same commit could build on a
  different system without any change in the repo. The first two CI runs passed on
  `ubuntu-26.04` [V].
- Cost: the image has to be moved by hand when GitHub retires it.

## D-024: The valuation date is read from the load, through a one-row model
- Status: proposed 2026-11-09 (pull request; accepted when merged)
- `stg_generator_audit__load_info` selects `valuation_date` from `raw.generator_audit.load_info`,
  which the loader fills from the generator's metadata. Every model, the
  `claims_valuation_period` macro, the chain-ladder analysis and the tests take the date from
  it (models and the macro cross join it). The `valuation_date` var is removed, so a leftover
  `var('valuation_date')` fails to compile instead of using a stale date.
- Reason: the var and the data could disagree. Data generated with
  `--valuation-date 2026-03-31`, built with the var still at 2026-09-30, valued everything six
  months past the end of the data: 2026 auto earned premium 8,510,765.84 against the
  generator's 3,581,462.14, auto policies in force 1,222 against 8,033, 8,623 policies past due
  since dates after the data stops, and 7 failing tests [V, 2026-11-09].
- An exception to the answer-key rule: models never read `generator_audit`, except this one
  column. `load_info` is load metadata (what was loaded, and up to when), not an answer, and a
  real warehouse would take the same fact from its pipeline's load metadata or a reporting
  calendar [E]. The control totals and planted-issue counts stay test-only.
- A one-row model rather than a `run_query` macro:
  - The dependency is a node: the lineage graph and `dbt ls -s stg_generator_audit__load_info+`
    show which models depend on the valuation date. A macro's query is hidden in Jinja, and dbt
    sees the dependency only if the macro also calls `ref` or `source` at parse time.
  - Plain SQL, nothing at compile time. A `run_query` macro queries the database every time a
    model compiles, needs a placeholder while dbt parses, and a raw database must already be
    loaded for `dbt compile` to work.
  - Only staging models read `source()`; a macro called from marts would break that rule or
    need this model anyway.
  - Unit tests mock it with `given`, like any other input. A macro would need
    `overrides: macros:` in each test.
  - A test requires exactly one row (`tests/generator_audit/assert_one_valuation_date.sql`):
    with none, every consumer's cross join would return no rows without an error; with two,
    each would double. `dbt build` runs it before any model that reads the date.
- Cost: the date is a column, not a literal in the compiled SQL. Each consumer has one more
  import CTE and cross join, and the compiled SQL no longer shows the date. A warehouse that
  prunes partitions only on constant filters would not prune on it [E]; no model here filters a
  partitioned table, and DuckDB has none.
- Rejected: a `run_query` macro (above). Deriving the date from the data, such as the latest
  `created_at`: a guess that comes out a day early when the last simulated day is quiet, as can
  happen at a small `--scale` [E].
- Not changed: on an as-of load earlier than the valuation date (the close simulation's
  replays), `load_info.valuation_date` is still the generator's, as the var was. Q-006 in
  `docs/STATE.md`.
