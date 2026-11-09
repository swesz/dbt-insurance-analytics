# Guide: the claims models

A walkthrough of the claims side of the project for someone learning insurance analytics. It
explains the business first and then where each idea lives in the code. The rules themselves are
specified in `docs/source-systems.md` (sections 2c, 3c, 3f, 3g and 5); this guide explains them.

## 1. The life of a claim

A **claim** starts with the *first notice of loss* (FNOL): a policyholder calls to say their car
was hit on 2 March. The claims system records the **loss date** (when it happened, 2 March) and
**reported_at** (when we heard about it). The gap is the **report lag**. For a fender bender it is
days. For a bodily injury claim it can be months, because the injured person may only file a
claim once treatment drags on.

An adjuster is assigned and the claim is `OPEN`. While it is open, the adjuster:

1. sets a **case reserve**, the estimate of what the claim will still cost;
2. pays (repair shop, medical bills, lawyers) and revises the reserve as facts come in;
3. collects **recoveries** where possible: *salvage* (selling the wrecked car) and *subrogation*
   (getting money back from the at-fault driver's insurer);
4. **closes** the claim when nothing more is expected, which zeroes the remaining reserve.

A closed claim can **reopen** (a new medical bill arrives, say): status `REOPENED`, a new reserve,
more payments, and it closes again. About 3% of closed claims do (`REOPENED_CLAIMS`). Statuses
written before the claims system upgrade on 2023-07-01 use one-letter codes (`O`, `C`, `R`).
`seeds/claim_status_map.csv` maps both generations, and staging keeps the raw value next to the
mapped one.

## 2. Exposures: one claim, several pots of money

One accident can hurt several parties under several coverages. Our insured's car (collision,
`COLL`, first party) and the other driver's car (property damage liability, `PD`, third party) are
two **exposures** on one claim. Reserves and payments are held per exposure, because each
coverage has its own limit, its own annual statement line and its own development pattern.
Liability exposures (`BI`, `PD`, `PERS_LIAB`) settle slowly; physical damage settles in weeks.

Money is also split by **cost category**:

- `LOSS`, also called indemnity: what we owe the claimant.
- `EXPENSE`, also called loss adjustment expense (LAE): what it costs us to handle the claim.
  `DCC` (defense and cost containment) covers lawyers and experts, and `AO` (adjusting and other)
  covers adjusting work.

So the finest grain of claims money is exposure x cost category. That is the grain of
`fct_claim_exposure_period_balances`.

## 3. Case reserves and erosion

A case reserve is a liability on the balance sheet: money we expect to pay on a claim we know
about. The source records it as a series of signed **changes** (`RESERVE` rows), and the
outstanding reserve at any moment is their running sum:

| reserve_reason | what happens |
|---|---|
| `INITIAL` | the first estimate |
| `REVISION` | the adjuster raises or lowers the estimate |
| `PAYMENT_EROSION` | a payment posts, and the reserve drops by the payment (never below zero) |
| `CLOSE` | the exposure closes, and the rest of the reserve is released to zero |
| `REOPEN` | a reopened exposure gets a new reserve |
| `VOID_RESTORE` | a voided payment's erosion is undone |

**Erosion** is what keeps the numbers from double counting. Before a payment, the 3,000 we expect
to pay sits in the reserve. After it, the 3,000 is paid, so it must leave the reserve. Without
erosion, incurred would count it twice.

## 4. Paid, incurred, and what neither includes

- **Net paid** = payments − recoveries. Cash out minus cash back.
- **Incurred** = net paid + outstanding case reserve. It is everything we know a claim costs:
  what has been paid plus what we still expect to pay on it.
- **IBNR** (incurred but not reported) is the part nobody has told us about yet: accidents that
  have happened but are not reported (pure IBNR), plus the amount by which today's case reserves
  will turn out to be too low (IBNER). **IBNR is not in any source system.** It is an actuarial
  estimate, made by projecting how past accident years developed (section 8). Every model here
  reports *reported* incurred, which is paid plus case reserves. Ultimate loss = reported incurred
  + IBNR.

`tests/claims/assert_claim_balances_match_dims_at_valuation.sql` compares the valuation-date
figures computed two ways: as running month-end balances (`fct_claim_exposure_period_balances`)
and as one direct sum (`dim_claims`, `dim_claim_exposures`). It compares paid loss, paid expense,
loss reserve and expense reserve each on its own, so two errors that cancel out inside incurred
cannot hide. Incurred = paid + reserve is how every model defines incurred, so the identity
itself needs no test.

## 5. Booking: which month does a transaction belong to?

Finance closes each month on its 4th business day, and a closed month never changes, because its
figures have gone into the general ledger and the financial statements. A transaction is
therefore **booked** in the first period, on or after its `transaction_date`'s month, that was
still open when the transaction was entered (`created_at`). If a payment dated 30 April is keyed
in on 9 May, after April closed on 6 May, it lands in May (`LATE_ENTERED_TRANSACTIONS`). The
macro `booked_accounting_period` implements the rule, and every claims model uses it through
`int_claims__financial_events`.

## 6. Voids, and why they are reversed in the void period

Sometimes a check goes to the wrong payee and is voided. The claims system **overwrites** the
payment row (`transaction_status = 'VOIDED'`, `voided_at`) and adds a `VOID_RESTORE` reserve row.
If we used only the current state and dropped voided payments, the payment would vanish from the
month it was made in. If that month is closed, its paid total would change after it was reported
to the ledger, and the claims figures would stop agreeing with the GL.

So `int_claims__financial_events` turns a voided payment into **two events**:

- the original `PAYMENT`, booked in its own period, as it was reported at that close;
- a `PAYMENT_VOID` of the same amount with the opposite sign, booked by the same rule using the
  void timestamp, which lands in the period the void happened.

Within one period the pair nets to zero; across periods, every closed month keeps its figure.
This is the same principle as the booking rule: corrections go forward and never rewrite history.
The unit test `test_financial_events_void_reversed_in_void_period`
(`models/intermediate/claims/_int_claims__models.yml`) pins the behavior.

## 7. CDC versions versus snapshots

The policy system is replicated Fivetran-style: one row per key, overwritten in place. When a term
is cancelled, its earlier state is gone, and the only way to keep history is a dbt **snapshot**
that copies the table on a schedule. A snapshot sees only what is there when it runs: two changes
between runs leave one trace.

The claims system is replicated as a **CDC change log in append mode**: every change in the source
arrives as a new row, a version. History is complete by construction, and no snapshot is needed.
The cost is that staging has to do the work a snapshot would have done:

- **Order the versions** by the source `updated_at`. `[updated_at, valid_to)` is when each version
  was the current state, the same shape as a snapshot's `dbt_valid_from` and `dbt_valid_to`.
- **Collapse re-loaded duplicates.** A loader rerun wrote some versions twice
  (`CDC_DUPLICATE_VERSIONS`): same key and `updated_at`, a different run. They become one, with a
  deterministic tiebreak (`macros/claims_cdc_versions.sql`), and
  `tests/claims/assert_cdc_duplicate_versions_are_exact.sql` checks that the copies really are
  identical.
- **Handle deletes.** A hard delete arrives as a last version with `__deleted = true`
  (`DELETED_CLAIMS`). The current state takes the latest version first and drops the key if that
  version is a delete. Filtering deletes *before* picking the latest version is a classic bug: the
  version before the delete would come back to life. Unit test:
  `test_claim_exposures_drop_keys_whose_latest_version_is_deleted`.

Two kinds of model come out of this:

- **History** (`stg_claims__claim_versions`, `stg_claims__claim_transaction_versions`): every
  distinct version. `dim_claims.was_reopened` comes from here, because a claim that reopened and
  closed again looks like any closed claim in its current state.
- **Current state** (`stg_claims__claims`, `__claim_exposures`, `__claim_transactions`,
  `__adjusters`): the latest version per key, with deleted keys removed.

## 8. Reading the loss development triangle

`rpt_loss_development_triangle` groups losses by **accident year** (the year of `loss_date`) and
looks at them at successive **development ages**: 12 months (31 December of the accident year),
24 months (a year later), and so on. Each cell is what was known at that evaluation date: the
cumulative paid, the case reserve and incurred booked by then, and the number of claims reported
by then.

```
              age 12     age 24     age 36     age 48
AY 2022       x          x          x          x
AY 2023       x          x          x
AY 2024       x          x
AY 2025       x
```

- **Read across a row** to see one accident year develop. Paid rises as claims settle. Incurred
  moves less, because reserves were already set, and its direction says whether reserves were
  adequate: rising incurred means reserves were too low.
- **Read down a column** to compare accident years at the same maturity, a fair comparison, since
  each is the same number of months old.
- **The diagonal** (the last cell of each row) is the book as of the latest evaluation date. In
  this year-end triangle that is the last year end, not the valuation date (see below).
- **The empty lower-right** is the future. The chain-ladder method
  (`analyses/chain_ladder_development_factors.sql`) fills it in. The ratio of the sums of two
  neighboring columns (the volume-weighted age-to-age factor) says how much losses typically grow
  between those ages. Multiplying the remaining factors projects each accident year to its
  ultimate, and ultimate − reported incurred is the IBNR estimate.

The triangle is evaluated on **booked periods**, so a cell never changes once its period is
closed. Only cells whose evaluation date is on or before the valuation date exist. With a
valuation date of 2026-09-30, accident year 2026 has no 12-month cell yet, so the quarterly
variant (`triangle_grain = 'QUARTERLY'`, accident quarters at ages 3, 6, 9, ...) is there to show
recent quarters.

### Which diagonal a reserve starts from

The `ANNUAL` grain above is the standard year-end triangle, so its latest diagonal is
2025-12-31, nine months before the valuation date. That suits comparing accident years at whole
ages, but it is the wrong starting point for a reserve at 2026-09-30. Projecting the 2025-12-31
figures to ultimate and subtracting today's incurred counts the development in between twice:
AUTO accident year 2025 had $6,454,093.90 incurred at 2025-12-31 and $6,877,610.57 at
2026-09-30, and the $423,516.67 between them would sit both in today's incurred and in the
projection.

So the triangle has a third grain, `ANNUAL_AT_VALUATION`: accident years evaluated on the
valuation date and its anniversaries (2026-09-30, 2025-09-30, ...), which makes the ages 9, 21,
33, 45 and 57 months. Its latest diagonal is the valuation date, the same figures as `dim_claims`
and `rpt_loss_ratio_by_accident_year`, and
`tests/claims/assert_triangle_latest_diagonal_matches_control_totals.sql` checks that diagonal
against the generator's control totals. The chain-ladder analysis uses this grain, so its IBNR is
the projected ultimate minus incurred at the valuation date.

**The current accident year gets no projection.** Accident year 2026 is 9 months old: only its
January to September accidents have happened. Its factor would be the one from 9 to 21 months,
learned from earlier years' age-9 cells (which also held only January to September accidents)
and their age-21 cells (which hold the whole year). For AUTO that factor is 1.4775, and the
quarterly cells show what it is made of: 1.0285 is the January to September accidents
developing, and 0.4490 is the October to December accidents, which had not happened at age 9.
Applied to 2026, the factor would project accidents that have not happened yet. Those will fall
in the unexpired months of policies still in force, which the unearned premium covers; a loss
reserve is for accidents that already happened. So the analysis shows 2026's reported incurred
and leaves its ultimate and IBNR empty. (Reserving estimates the current year's IBNR another
way, for example from an expected loss ratio on the premium earned so far.)

## 9. Worked example: one claim, month by month

Claim CL-2024-000123: a collision on 2024-03-02, one `COLL` exposure. Loss cost category only, to
keep it short. The April period closes on 2024-05-06.

| # | date | source row | event(s) in `int_claims__financial_events` | booked | paid_amount | reserve_change_amount |
|---|---|---|---|---|---|---|
| 1 | 03-04 | RESERVE INITIAL +5,000 | RESERVE_CHANGE | 2024-03 | 0 | +5,000 |
| 2 | 03-20 | PAYMENT 3,000 | PAYMENT | 2024-03 | +3,000 | 0 |
| 3 | 03-20 | RESERVE PAYMENT_EROSION −3,000 | RESERVE_CHANGE | 2024-03 | 0 | −3,000 |
| 4 | 04-10 | RESERVE REVISION +1,000 | RESERVE_CHANGE | 2024-04 | 0 | +1,000 |
| 5 | 04-25 | PAYMENT 2,500, **voided 05-08** | PAYMENT | 2024-04 | +2,500 | 0 |
|   |       |                                  | PAYMENT_VOID | 2024-05 | −2,500 | 0 |
| 6 | 04-25 | RESERVE PAYMENT_EROSION −2,500 | RESERVE_CHANGE | 2024-04 | 0 | −2,500 |
| 7 | 05-08 | RESERVE VOID_RESTORE +2,500 | RESERVE_CHANGE | 2024-05 | 0 | +2,500 |
| 8 | 05-09 | PAYMENT 2,500 (reissued) | PAYMENT | 2024-05 | +2,500 | 0 |
| 9 | 05-09 | RESERVE PAYMENT_EROSION −2,500 | RESERVE_CHANGE | 2024-05 | 0 | −2,500 |
| 10 | 05-20 | RECOVERY 800 (salvage) | RECOVERY | 2024-05 | −800 | 0 |
| 11 | 05-31 | RESERVE CLOSE −500 | RESERVE_CHANGE | 2024-05 | 0 | −500 |

Row 5 is a single source row: the void overwrote it, so its current state is `VOIDED`. The model
produces two events from it. The void came after April closed, so April keeps its 2,500, and May
carries the reversal.

The month-end balances in `fct_claim_exposure_period_balances` (LOSS):

| accounting_period | period_paid_amount | period_reserve_change_amount | itd_paid_amount | case_reserve_amount | incurred_amount |
|---|---|---|---|---|---|
| 2024-03 | 3,000 | +2,000 | 3,000 | 2,000 | 5,000 |
| 2024-04 | 2,500 | −1,500 | 5,500 | 500 | 6,000 |
| 2024-05 | −800 | −500 | 4,700 | 0 | 4,700 |
| 2024-06 | 0 | 0 | 4,700 | 0 | 4,700 |
| ... every month through the valuation period | 0 | 0 | 4,700 | 0 | 4,700 |

What to notice:

- May's paid is negative. A recovery and a reversal in one month can outweigh that month's
  payments. That is normal, and it is why paid is not tested to only rise.
- Incurred went 5,000 → 6,000 → 4,700. The revision in April raised it, and the salvage and the
  release of the last 500 lowered it. Read across the triangle, those movements are development.
- The balances continue after the claim closes. A balance is a stock, so a month without activity
  still has one, and the sums over all exposures for any month need every exposure's row.
- In the triangle, this claim contributes to accident year 2024: paid 4,700, incurred 4,700 and
  one reported claim at age 12 (2024-12-31) and every later age.

## 10. Data defects the claims models handle

| Code | Where it is handled |
|---|---|
| `CDC_DUPLICATE_VERSIONS` | `macros/claims_cdc_versions.sql`, used by every claims staging model |
| `DELETED_CLAIMS` | current-state staging models (latest version first, then drop deletes) |
| `LEGACY_STATUS_CODES` | `stg_claims__claim_versions` via `seeds/claim_status_map.csv` |
| `INCONSISTENT_CODE_CASING` | `stg_claims__claim_versions`: `upper(trim(...))`, tested against the seeds |
| `MALFORMED_POLICY_NUMBERS` | `stg_claims__claim_versions`: rebuilt as `XX-0000000` |
| `ORPHAN_CLAIMS` | `dim_claims.has_matching_policy`; warning-level relationships test |
| `LOSS_OUTSIDE_TERM` | `dim_claims.is_loss_outside_term`; warning-level test with a threshold |
| `VOIDED_PAYMENTS` | `int_claims__financial_events`: original plus reversal |
| `LATE_ENTERED_TRANSACTIONS` | the booking macro, through `int_claims__financial_events` |
| test-policy claims | flagged in staging (`is_test_policy_claim`), excluded from intermediate and marts |

`tests/claims/assert_claims_planted_issue_counts.sql` checks that each handled count equals what the
generator planted. The two control-total tests compare paid, reserves, claim counts and incurred
with the generator's independent Python figures.

## 11. Model map

| Layer | Model | Grain |
|---|---|---|
| staging | `models/staging/claims/stg_claims__claim_versions.sql` | claim version |
| staging | `models/staging/claims/stg_claims__claim_transaction_versions.sql` | transaction version |
| staging | `models/staging/claims/stg_claims__claims.sql` | claim (current) |
| staging | `models/staging/claims/stg_claims__claim_exposures.sql` | exposure (current) |
| staging | `models/staging/claims/stg_claims__claim_transactions.sql` | transaction (current) |
| staging | `models/staging/claims/stg_claims__adjusters.sql` | adjuster (current) |
| intermediate | `models/intermediate/claims/int_claims__financial_events.sql` | financial event |
| intermediate | `models/intermediate/claims/int_claims__exposure_balances_by_period.sql` | exposure x cost category x period |
| core | `models/marts/core/dim_claims.sql` | claim |
| core | `models/marts/core/dim_claim_exposures.sql` | exposure |
| core | `models/marts/core/dim_adjusters.sql` | adjuster |
| claims | `models/marts/claims/fct_claim_transactions.sql` (incremental) | financial event |
| claims | `models/marts/claims/fct_claim_exposure_period_balances.sql` | exposure x cost category x period |
| actuarial | `models/marts/actuarial/rpt_loss_development_triangle.sql` | grain x LOB x origin period x age |
| analysis | `analyses/chain_ladder_development_factors.sql` | factors and projections |

`fct_claim_transactions` is the one incremental model. The comment at its top explains the
choice of strategy (delete+insert on `financial_event_id`), the lookback window on the loader
timestamp, and what an incremental run cannot do.
`tests/claims/assert_fct_claim_transactions_matches_events.sql` checks it against a full rebuild
on every build.
