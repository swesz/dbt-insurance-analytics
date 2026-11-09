# Planted data issues

Real source data is never clean, so the generator plants the problems below on purpose. Each one
has a code, a model that handles it, and a test that would fail if the handling broke. The
generator records how many rows each issue affects in `raw.generator_audit.planted_issues`
(counts for the default, valuation-date load).

| Code | Where | What is wrong | Handled in | Caught by |
|---|---|---|---|---|
| `TEST_POLICIES` | policy_admin.policyholders, policies (+ their terms, transactions, claims) | 25 QA test policies in production data. QA convention: their `policy_id` is 9000000 or higher (policy numbers `PA-9xxxxxx`, `HO-9xxxxxx`), and their policyholders' email ends in `@test.example.com` | staging flags them (`is_test_policy`, `is_test_record`) without joins; intermediate models and marts exclude them | GL reconciliation (the ledger never had them); planted-count test |
| `SOFT_DELETED_POLICYHOLDERS` | policy_admin.policyholders | duplicate customer records removed in the source, `_fivetran_deleted = true`, 40 | staging filters `_fivetran_deleted` | not_null/relationships on policies → policyholders |
| `SOFT_DELETED_POLICIES` | policy_admin.policies | policies created in error and deleted, no transactions, 30 | staging filters | planted-count test |
| `CDC_DUPLICATE_VERSIONS` | claims.* | a rerun loaded 333 of 64,300 versions (0.52%: 36 claims, 51 exposures, 245 transactions, 1 adjuster) twice: same key and `updated_at`, different `_rivery_run_id` | staging keeps one row per key (latest version, deterministic tiebreak) | unique test on the staging key |
| `DELETED_CLAIMS` | claims.claims, claim_exposures | duplicate first notices of loss deleted in the source, `__deleted = true` on the last version, 22 claims (0.49%) and their 22 exposures, no financial transactions | staging drops keys whose latest version is deleted | planted-count test |
| `LEGACY_STATUS_CODES` | claims.claims | versions written before 2023-07-01 use `O`, `C`, `R` | `seeds/claim_status_map.csv` | accepted_values on the mapped status |
| `INCONSISTENT_CODE_CASING` | claims.claims.loss_cause, loss_state | mixed case and stray spaces, e.g. `' Hail'`, `'collision'`, `'tx'`, 267 of 8,597 claim versions (3.1%) | staging `upper(trim(...))` | accepted_values against seeds/loss_causes.csv and seeds/states.csv |
| `MALFORMED_POLICY_NUMBERS` | claims.claims.policy_number | lowercase, missing dash, or padded with spaces, e.g. `'pa-0001234'`, `'PA0001234'`, 91 of 8,597 claim versions (1.1%) | staging normalizes to `XX-0000000` | relationships to policies |
| `ORPHAN_CLAIMS` | claims.claims | 5 claims on policy numbers that never existed (legacy book not migrated) | kept, flagged `has_matching_policy = false`; `is_loss_outside_term` is null for them (D-020) | relationships test that warns at the planted count and fails above 20 (`severity: error` with `warn_if`/`error_if`); planted-count test |
| `LOSS_OUTSIDE_TERM` | claims.claims | 13 claims (0.29%) have a loss date before the term or after cancellation; all closed without payment | flagged in the claims mart | warn-level test with a threshold |
| `LATE_ENTERED_TRANSACTIONS` | policy_transactions, claim_transactions | 1,254 of 82,236 policy transactions (1.52%) and 664 of 44,206 claim transactions (1.50%) are entered 1–20 days after their `transaction_date`, some after the period closed | booking rule (source-systems.md 3c) | unit test of the booking macro; GL reconciliation |
| `BACKDATED_ENDORSEMENTS` | policy_transactions | 1,490 of 10,047 endorsements (14.8%) take effect 1–30 days before they are dated | earned premium catch-up (3d) | earned and unearned premium control totals; GL reconciliation of 4100 and 2100 |
| `VOIDED_PAYMENTS` | claims.claim_transactions | 80 of 9,567 claim payments (0.84%) voided later: the source overwrites the row | reversal built from the current `VOIDED` row, which keeps the payment's amount and dates, booked at its `voided_at` (3f) | closed-period paid totals equal the GL |
| `REOPENED_CLAIMS` | claims.claims | 110 of 3,850 closed claims (2.9%) reopen with new reserves and payments | status history from CDC (`dim_claims.was_reopened`) | planted-count test (109 real claims + 1 test-policy claim) |
| `BILLING_AMOUNTS_IN_CENTS` | billing.* | integer cents, every other system uses dollars | staging divides by 100 | billed total = written total test |
| `RETURNED_PAYMENTS` | billing.payments | 3,038 of 299,262 payments (1.02%) returned (insufficient funds) later: the row is overwritten | cash by month of receipt and return | GL reconciliation of cash |
| `GL_FILE_REEXPORTED` | general_ledger.journal_lines | the 2025-03 export was corrected and loaded again as `gl_export_2025_03_v2.csv`: both files are in the table | staging keeps only the latest file per period | unique test on (journal_id, line_number) |
| `GL_AMOUNT_FORMAT_CHANGE` | general_ledger.journal_lines | from 2025-01 the export writes thousands separators: `'1,234.56'` | staging strips `,` before casting | not_null on parsed amounts |
| `GL_MANUAL_RECLASS` | general_ledger.journal_lines | 2024-06: accountants moved written premium between AUTO and HOME with a manual journal (source system MANUAL) | documented in `seeds/gl_reconciling_items.csv` | GL reconciliation test |
| `GL_CLAIMS_INTERFACE_TIMING` | general_ledger.journal_lines | 2025-08: the claims interface missed the payments entered on the period's last day; they were posted in 2025-09 (source system CLAIMS) | documented in `seeds/gl_reconciling_items.csv` | GL reconciliation test |

Counting note: MALFORMED_POLICY_NUMBERS counts raw claim rows (CDC versions, rerun copies included), not claims: its rows fall on fewer distinct claims.
