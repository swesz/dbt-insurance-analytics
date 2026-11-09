# Planted data issues

Real source data is never clean, so the generator plants the problems below on purpose. Each one
has a code, a model that handles it, and a test that would fail if the handling broke. The
generator records how many rows each issue affects in `raw.generator_audit.planted_issues`
(counts for the default, valuation-date load).

| Code | Where | What is wrong | Handled in | Caught by |
|---|---|---|---|---|
| `TEST_POLICIES` | policy_admin.policyholders, policies (+ their terms, transactions, claims) | about 25 QA test policies in production data: policyholder email ends in `@test.example.com` | staging excludes them | GL reconciliation (the ledger never had them); planted-count test |
| `SOFT_DELETED_POLICYHOLDERS` | policy_admin.policyholders | duplicate customer records removed in the source, `_fivetran_deleted = true`, about 40 | staging filters `_fivetran_deleted` | not_null/relationships on policies → policyholders |
| `SOFT_DELETED_POLICIES` | policy_admin.policies | policies created in error and deleted, no transactions, about 30 | staging filters | planted-count test |
| `CDC_DUPLICATE_VERSIONS` | claims.* | a rerun loaded about 0.5% of versions twice: same key and `updated_at`, different `_rivery_run_id` | staging keeps one row per key (latest version, deterministic tiebreak) | unique test on the staging key |
| `DELETED_CLAIMS` | claims.claims, claim_exposures | duplicate first notices of loss deleted in the source, `__deleted = true` on the last version, about 0.5% of claims, no financial transactions | staging drops keys whose latest version is deleted | planted-count test |
| `LEGACY_STATUS_CODES` | claims.claims | versions written before 2023-07-01 use `O`, `C`, `R` | `seeds/claim_status_map.csv` | accepted_values on the mapped status |
| `INCONSISTENT_CODE_CASING` | claims.claims.loss_cause, loss_state | mixed case and stray spaces, e.g. `' Hail'`, `'collision'`, `'tx'`, about 3% | staging `upper(trim(...))` | accepted_values against seeds/loss_causes.csv and seeds/states.csv |
| `MALFORMED_POLICY_NUMBERS` | claims.claims.policy_number | lowercase, missing dash, or padded with spaces, e.g. `'pa-0001234'`, `'PA0001234'`, about 1% | staging normalizes to `XX-0000000` | relationships to policies |
| `ORPHAN_CLAIMS` | claims.claims | about 5 claims on policy numbers that never existed (legacy book not migrated) | kept, flagged `has_matching_policy = false` | relationships test with `severity: warn` |
| `LOSS_OUTSIDE_TERM` | claims.claims | about 0.3% of claims have a loss date before the term or after cancellation; all closed without payment | flagged in the claims mart | warn-level test with a threshold |
| `LATE_ENTERED_TRANSACTIONS` | policy_transactions, claim_transactions | about 1.5% are entered 1–20 days after their `transaction_date`, some after the period closed | booking rule (source-systems.md 3c) | unit test of the booking macro; GL reconciliation |
| `BACKDATED_ENDORSEMENTS` | policy_transactions | about 15% of endorsements take effect 1–30 days before they are dated | earned premium catch-up (3d) | rollforward test; control totals |
| `VOIDED_PAYMENTS` | claims.claim_transactions | about 1% of payments voided later: the source overwrites the row | reversal built from CDC history (3f) | closed-period paid totals equal the GL |
| `REOPENED_CLAIMS` | claims.claims | about 3% of closed claims reopen with new reserves and payments | status history from CDC | incurred = paid + reserve test |
| `BILLING_AMOUNTS_IN_CENTS` | billing.* | integer cents, every other system uses dollars | staging divides by 100 | billed total = written total test |
| `RETURNED_PAYMENTS` | billing.payments | about 1% of payments returned (insufficient funds) later: the row is overwritten | cash by month of receipt and return | GL reconciliation of cash |
| `GL_FILE_REEXPORTED` | general_ledger.journal_lines | the 2025-03 export was corrected and loaded again as `gl_export_2025_03_v2.csv`: both files are in the table | staging keeps only the latest file per period | unique test on (journal_id, line_number) |
| `GL_AMOUNT_FORMAT_CHANGE` | general_ledger.journal_lines | from 2025-01 the export writes thousands separators: `'1,234.56'` | staging strips `,` before casting | not_null on parsed amounts |
| `GL_MANUAL_RECLASS` | general_ledger.journal_lines | 2024-06: accountants moved written premium between AUTO and HOME with a manual journal | documented in `seeds/gl_reconciling_items.csv` | GL reconciliation test |
| `GL_CLAIMS_INTERFACE_TIMING` | general_ledger.journal_lines | 2025-08: the claims interface missed the payments entered on the period's last day; they were posted in 2025-09 | documented in `seeds/gl_reconciling_items.csv` | GL reconciliation test |

The generator agent replaces each "about" with the exact count it planted once the generator is
final, and the counts must match `raw.generator_audit.planted_issues`.
