# Source systems and business rules

The carrier is fictional: a US personal lines insurer writing private passenger **auto** and
**homeowners** in seven states (AZ, CO, GA, IL, NC, TN, TX). Nothing here describes a real
company. All data is produced by the generator in `generator/` with a fixed seed, so every run
produces the same data.

This file is the specification. The generator implements it, `loader/raw_schema.sql` fixes the
column layout, and the dbt models implement the business rules in section 3 independently of the
generator. Section 5 explains how the two are checked against each other.

## 1. Timeline

| Setting | Value |
|---|---|
| First policy effective date | 2022-01-01 |
| Valuation date (last simulated day) | 2026-09-30 |
| Accounting periods | calendar months, `YYYY-MM`, in `seeds/accounting_periods.csv` |
| Period close | 4th business day (Mon–Fri) of the following month, end of day |
| Timestamps | naive, in the carrier's local time; no time zones anywhere |

Nothing is created after the valuation date (`created_at`, `updated_at`, `voided_at` and so on
are all at or before 2026-09-30 23:59:59), but `effective_date` and `due_date` can be later,
because a transaction can be dated in advance.

## 2. The four systems and how they are loaded

### 2a. Policy administration (`raw.policy_admin`, Fivetran-style)
Policies, their terms, every premium transaction and its coverage lines, plus the insured
vehicles and dwellings. The connector keeps **one row per primary key in its latest state**:
when a term is cancelled, its row is overwritten, and the earlier status is gone. That is why
`snapshots/` exists. Deleted rows stay with `_fivetran_deleted = true`.

### 2b. Billing (`raw.billing`, Fivetran-style)
Installment schedules and payments received. **Amounts are integer cents**: the only system that
does this.

### 2c. Claims (`raw.claims`, Rivery-style CDC, append mode)
Claims, exposures (one per coverage and claimant), claim financial transactions, and adjusters.
The connector **appends one row per change event**, so a key appears once per version and the
latest version is the current state. A hard delete in the source arrives as a version with
`__deleted = true`. History is in the raw data already; no snapshot is needed to recover it.

### 2d. General ledger (`raw.general_ledger`, file connector)
At each period close the ERP exports that period's journal lines to a CSV file
(`gl_export_YYYY_MM.csv`), and the file connector loads it. **Every column is text.**

### 2e. Loader metadata conventions
| Column | Meaning |
|---|---|
| `_fivetran_synced` | when the connector last wrote the row. Syncs run every 6 hours (00:00, 06:00, 12:00, 18:00), so this is the first sync boundary at or after the row's last change |
| `_fivetran_deleted` | soft delete flag |
| `_rivery_last_update` | when the loader wrote this version: the source `updated_at` plus 1–90 minutes |
| `_rivery_run_id` | the hourly run that loaded the version, `run_YYYYMMDDHH` |
| `_rivery_river_id` | constant per table, e.g. `river_claims_claims` |
| `__deleted` | true on the version recording a source hard delete |
| `_file`, `_line`, `_modified` | file connector: source file, line in it, file modification time |

The column names follow the vendors' documented conventions as far as public docs show them; the
loader imitates them and is not either product.

### 2f. Loading as of a point in time
`python -m loader --as-of 2025-06-05T23:59:59` rebuilds `raw.duckdb` as the connectors would
have left it at that moment: only rows created by then, Fivetran tables in their state at that
moment, CDC tables with the versions written by then, and GL files for the periods closed by
then. The default as-of is the end of the valuation date. Loading month by month and running
`dbt snapshot` after each load is how the snapshots in this project get real history
(`scripts/simulate_month_end_closes.py`).

## 3. Business rules

dbt implements these; the generator uses the same definitions to compute its control totals.

### 3a. Products and terms
| | Auto (`PA-`) | Home (`HO-`) |
|---|---|---|
| Term length | 6 months | 12 months |
| Coverages (seeds/coverages.csv) | BI, PD always; COLL and COMP when physical damage is carried | DWELLING, CONTENTS, PERS_LIAB always |
| Exposure unit | vehicle | dwelling |
| Renewal | a new term starts on the prior term's expiration date | same |

A term covers `[term_effective_date, term_expiration_date)`: the expiration date is exclusive.

### 3b. Premium transactions
- Every premium movement is a row in `policy_transactions`, split by coverage in
  `policy_transaction_lines`. `term_written_premium` on the term is just the running total.
- `NEW_BUSINESS` and `RENEWAL` write the full term premium, effective on the term start.
- `ENDORSEMENT` writes the premium change for the rest of the term: the change in full-term
  premium times the remaining fraction of the term (days left / term days). Some endorsements are **backdated**: `effective_date` before
  `transaction_date`.
- `CANCELLATION` returns the unearned premium pro rata: minus each coverage's in-force premium
  times `(term_expiration_date - cancellation date) / term days`. A flat cancellation (effective
  on the term start) returns everything.
- `REINSTATEMENT` reverses the cancellation exactly, effective on the cancellation date.

### 3c. Written premium and the accounting period (booking rule)
A transaction is **booked** in the first accounting period, on or after the period containing
its `transaction_date`, that was still open when the transaction was entered (`created_at`):

> booked period = the earliest period P with P.period_end_date >= transaction_date and
> created_at < P.close_date + 1 day

Usually that is the month of `transaction_date`. A transaction keyed in after its month has
closed lands in the next open period, because closed periods never change. Written premium of a
period is the sum of `written_premium` booked in it. Claim transactions use the same rule. Payment
voids are booked by the same rule using the void timestamp as both dates.

### 3d. Earned and unearned premium
Each transaction line earns evenly per day over its own coverage window
`[effective_date, term_expiration_date)` of the term it belongs to. Cancellation lines earn
negatively over `[cancellation date, term_expiration_date)`, which offsets the original lines'
earning after the cancellation. Because each line is rounded to the cent on its own, a cancelled
term can keep a few cents of unearned premium (positive or negative) after its cancellation date.

- Inception-to-date earned of a line at date d (inclusive):
  `round(written_premium * elapsed / window_days, 2)` with
  `elapsed = clamp((d + 1) - effective_date, 0, window_days)`, rounding half away from zero.
  A zero-day window is fully earned at once.
- **Earned premium of period P** = ITD earned at P's end date over lines booked in P or earlier,
  minus ITD earned at the prior period's end date over lines booked in the prior period or
  earlier. A backdated endorsement therefore "catches up" its already-elapsed earning in the
  period it is booked in, and no closed period changes.
- **Unearned premium at the end of P** = ITD written (booked ≤ P) − ITD earned at P's end.
  By construction: UPR(P) = UPR(P−1) + written(P) − earned(P).

### 3e. Policies in force (PIF)
A policy is in force at date d if one of its terms has
`term_effective_date <= d < term_expiration_date` and is not cancelled on or before d
(`cancellation_effective_date is null or cancellation_effective_date > d`). PIF of period P is
the count at P's end date, using the current state of the terms.

### 3f. Claims financials
- An **exposure** is one coverage and one claimant on a claim; reserves and payments are per
  exposure and per cost category (`LOSS`, `EXPENSE`; expenses are `DCC` defense and cost
  containment or `AO` adjusting and other).
- `RESERVE` rows are signed changes to the case reserve; the outstanding case reserve is their
  running sum. When a payment posts, the system adds a `PAYMENT_EROSION` reserve row that lowers
  the reserve by the payment, but not below zero. Closing an exposure zeroes its reserve with a
  `CLOSE` row; reopening sets a new one with `REOPEN`.
- `PAYMENT` amounts are positive; `RECOVERY` (salvage, subrogation) amounts are positive money
  received. **Net paid = payments − recoveries.**
- **Incurred = net paid + outstanding case reserve.** (IBNR is not in the source data; it is an
  actuarial estimate, see the triangles.)
- **Voided payments**: the source overwrites the payment row with `transaction_status =
  'VOIDED'` and `voided_at`, and adds a `VOID_RESTORE` reserve row. For accounting, the payment
  stays in the period it was originally booked in, and a reversal of the same amount is booked
  at the void. Only the CDC history shows both events.

### 3g. Claim status
`OPEN` → `CLOSED`, and possibly `REOPENED` → `CLOSED` again. Before the claims system upgrade on
2023-07-01 the system wrote single-letter codes (`O`, `C`, `R`); rows written before that date
keep them. `seeds/claim_status_map.csv` maps both.

### 3h. General ledger postings
At each close, one journal per source system and line of business, from the subledgers as booked
in 3c. Debits and credits are both non-negative; a negative amount swaps the sides.

| Source | Entry |
|---|---|
| POLICY_ADMIN | Dr 1200 Premiums receivable / Cr 4000 Premiums written, for written premium |
| POLICY_ADMIN | Dr 4100 Change in UPR / Cr 2100 UPR, for the increase in unearned premium |
| BILLING | Dr 1000 Cash / Cr 1200 Premiums receivable, for settled payments net of refunds and returns, by month of `received_at` (returns by month of `returned_at`) |
| CLAIMS | Dr 5000 Losses paid / Cr 1000 Cash; Dr 1000 / Cr 5050 Salvage and subrogation; Dr 5200 LAE paid / Cr 1000 |
| CLAIMS | Dr 5100 Change in loss reserves / Cr 2200 Loss reserves; Dr 5300 / Cr 2300 for LAE reserves |
| MANUAL | adjustments posted by accountants (see docs/data-issues.md) |

Test policies and deleted claims never reach the ledger. Test policies follow a QA convention: `policy_id` 9000000 and up (so their policy numbers are `PA-9xxxxxx` or `HO-9xxxxxx`), and their policyholders' email ends in `@test.example.com`. They have terms, transactions, billing and occasionally claims, like real policies.

## 4. Volume and realism targets (scale 1.0)

| Measure | Target |
|---|---|
| Policies written over the period | about 25,000 (auto ~65%, home ~35%) |
| New business per month | grows from about 250 (2022) to about 600 (2026) |
| Retention at renewal | auto ~88%, home ~90% |
| Mid-term cancellations | ~6% of terms: insured request 60%, nonpayment 35%, underwriting 5% |
| Reinstatements | ~10% of nonpayment cancellations, within 15 days |
| Endorsements | ~20% of auto terms, ~10% of home terms; ~15% of those backdated 1–30 days |
| Premium | auto ~$600 per vehicle per 6-month term, home ~$1,800 per year, varied by state; rate increases at renewal of about +8% (2023), +12% (2024), +6% (2025), +4% (2026) |
| Claim frequency | per exposure year: auto COLL 0.05, COMP 0.04, PD 0.035, BI 0.012; home property 0.06, liability 0.003; plus catastrophe events |
| Severity | lognormal; mean auto COLL ~$5k, COMP ~$2.5k, PD ~$4.5k, BI ~$20k (capped at a $100k limit); home ~$12k property, ~$25k liability; trend ~+6%/year |
| Settlement | physical damage 1–3 months, PD 1–4, BI 6–36, property 2–8, liability 6–30 |
| Report lag | mostly days; a tail of months for BI and liability, a few over a year |
| Reserving | case reserves start from an average and are revised 1–4 times: BI tends to develop upward, property downward |
| Loss ratio (loss only, to earned) | auto 60–75%, home 50–65% outside catastrophe years |

The catastrophe events are listed in `seeds/catastrophe_events.csv` and are fictional.

### 4a. Where the generated data departs from the targets
The generator (seed 42, scale 1.0) follows the rules above with these deviations. They are
deliberate or accepted, and the models are built for the data as generated.

- **Home premium** is lower than the $1,800 target: the average annualized home term premium
  rises from about $1,230 (terms starting in 2022) to about $1,690 (2026). The lower rate keeps
  the home loss ratio inside its target range.
- **Renewals are written 30 days before the new term starts**, so renewal premium is booked, and
  sits in unearned premium, before its term begins. New business is written 0–30 days ahead.
- **Every control total excludes test policies** (section 5), not only written premium.
- **Orphan claims have no financial transactions**: they are reported, then closed without
  payment.
- **The 2025-08 claims interface timing issue moves payments only**: both legs of the payment
  entries (5000 and 5200 against 1000 cash) move to 2025-09. The reserve erosion of those
  payments (5100 and 5300) stays in 2025-08.
- **A voided payment is reissued** as a new payment a few days later, so the claimant is still
  paid; the void and the reissue are separate transactions.
- **Accident-year loss ratios outside the auto target**: auto is about 87% in 2023 (bodily
  injury claim-count noise, about 2.6 standard deviations) and about 58% in 2025 (immature at the
  valuation date). Home excluding catastrophes is 52–65% in every accident year.

## 5. How results are checked

The generator computes control totals in Python from its own records
(`raw.generator_audit.control_totals`), and the dbt models compute the same figures in SQL from
the raw tables. Neither uses the other's code. Tests in `tests/` compare them.

| metric | grain | Definition |
|---|---|---|
| `written_premium` | accounting_period | 3c, test policies excluded |
| `earned_premium` | accounting_period | 3d |
| `unearned_premium_end` | accounting_period | 3d |
| `policies_in_force_end` | accounting_period | 3e |
| `paid_loss_net` | accounting_period | loss payments − loss recoveries, booked per 3c, voids reversed at the void |
| `paid_expense` | accounting_period | expense payments, same booking |
| `case_reserve_loss_end` | accounting_period | sum of LOSS reserve changes booked ≤ P |
| `case_reserve_expense_end` | accounting_period | same for EXPENSE |
| `claims_reported` | accounting_period | claims by month of `reported_at` (deleted and test excluded) |
| `incurred_loss` | accident_year | net paid loss + outstanding loss reserve at the valuation date, by year of `loss_date` |
| `paid_loss_net` | accident_year | net paid loss at the valuation date, by year of `loss_date` |
| `claim_count` | accident_year | claims by year of `loss_date` |

The control totals are valid only for a load at their `as_of` (the default load). Tests compare
only when `raw.generator_audit.load_info.as_of` matches. Tolerance: none. Every figure must match
to the cent, including earned and unearned premium: both implementations round each line's
inception-to-date earned amount the same way, in integer cents (D-008).
