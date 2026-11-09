# Architecture

## Data flow

```
generator/ (Python, seeded)          loader/ (Python + DuckDB)          dbt (this project)
  simulates 2022-01..2026-09   --->  warehouse/raw.duckdb          --->  warehouse/dev.duckdb
  writes data/generated/*.parquet      policy_admin  (Fivetran-style)      staging -> intermediate
  and control totals                   billing       (Fivetran-style)      -> marts (core, premium,
                                       claims        (Rivery CDC)            claims, accounting,
                                       general_ledger (file connector)       actuarial)
                                       generator_audit (answer key)        warehouse/prod.duckdb
```

## Layers

| Layer | Schema | Materialization | Job |
|---|---|---|---|
| sources | `raw.<system>` | loader tables | as the connectors deliver them |
| seeds | `reference` | table | small hand-maintained lookups: calendar, coverages, GL accounts |
| staging | `staging` | view | one model per source table: rename, cast, normalize codes, dedupe CDC versions, drop deletes and test records |
| intermediate | `intermediate` | view or table | business logic that is reused: booking, earning, claim financial events |
| marts | `core`, `premium`, `claims`, `accounting`, `actuarial` | table (one incremental) | what stakeholders query: dims, facts, reports |
| snapshots | `snapshots` | snapshot | history the sources overwrite, and month-end close figures |

## Model inventory

Planned names. The owner column is the work split used to build v1 in parallel.

| Area | Models | Owner |
|---|---|---|
| staging policy_admin | `stg_policy_admin__policyholders`, `__policies`, `__policy_terms`, `__policy_transactions`, `__policy_transaction_lines`, `__vehicles`, `__dwellings` | premium |
| intermediate premium | `int_premium__transaction_lines_booked`, `int_premium__line_earnings_by_period` | premium |
| core (policy side) | `dim_dates`, `dim_accounting_periods`, `dim_coverages`, `dim_policyholders`, `dim_policies`, `dim_policy_terms` | premium |
| premium marts | `fct_policy_transaction_lines`, `fct_premium_by_policy_period` (written, earned, unearned per policy, coverage, period), `fct_policy_month_end` (in force, in-force premium, exposure counts) | premium |
| staging claims | `stg_claims__claims`, `__claim_exposures`, `__claim_transactions`, `__adjusters` (current state) and `stg_claims__claim_versions`, `stg_claims__claim_transaction_versions` (history) | claims |
| intermediate claims | `int_claims__financial_events` (payments, recoveries, reserve changes, void reversals, booked period), `int_claims__exposure_balances_by_period` | claims |
| core (claims side) | `dim_claims`, `dim_claim_exposures`, `dim_adjusters` | claims |
| claims marts | `fct_claim_transactions` (incremental), `fct_claim_exposure_period_balances` (paid, reserve, incurred per exposure and period) | claims |
| actuarial (claims side) | `rpt_loss_development_triangle` | claims |
| staging billing, ledger | `stg_billing__installments`, `stg_billing__payments`, `stg_general_ledger__journal_lines` | accounting |
| intermediate accounting | `int_accounting__billing_cash_events`, `int_accounting__subledger_postings`, `int_accounting__gl_balances_by_period`, `int_accounting__installment_allocation` | accounting |
| accounting marts | `rpt_unearned_premium_rollforward`, `rpt_loss_reserve_rollforward`, `rpt_subledger_gl_reconciliation`, `rpt_trial_balance`, `rpt_premium_receivable`, `rpt_premium_receivable_aging` | accounting |
| actuarial | `rpt_loss_ratio_by_period`, `rpt_loss_ratio_by_accident_year`, `rpt_frequency_severity`, `fct_policy_in_force_at_close`, `rpt_policies_in_force_as_reported_vs_restated` | actuarial |
| snapshots | `snap_policy_terms`, `snap_policyholders`, `snap_billing_payments` (the month-end close figures are rebuilt from `snap_policy_terms`, so no separate close snapshot) | actuarial |
| exposures | `models/exposures.yml` | actuarial |

## Tests

- Generic tests in each folder's YAML: keys `unique` + `not_null`, `relationships`,
  `accepted_values`, and `dbt_utils` expression and combination tests.
- Singular tests in `tests/<domain>/`: rollforwards tie, incurred = paid + reserve, fully earned
  terms earned = written, dbt matches the generator's control totals, subledgers match the GL.
- Unit tests (dbt 1.8+ `unit_tests:`) for the logic most likely to break quietly: the booking
  rule, the earning formula, CDC deduplication, void reversals.
- Enforced contracts on the marts that downstream reports depend on.
