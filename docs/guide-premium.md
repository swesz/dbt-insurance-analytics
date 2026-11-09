# How premium flows from raw data to the marts

A walkthrough for learners. The rules themselves are specified in
[source-systems.md](source-systems.md), sections 3a-3e; terms are explained in
[insurance-glossary.md](insurance-glossary.md). This guide explains why the models are built the
way they are, and follows one policy through them with real numbers.

## 1. The three premium numbers

An insurer collects premium up front but provides coverage over time. Three figures describe
that, and every accounting period needs all three:

| Figure | Question it answers | Where |
|---|---|---|
| **Written premium** | How much premium did we commit to (or give back) in this period? | `fct_premium_by_policy_period.written_premium` |
| **Earned premium** | How much coverage did we actually provide in this period? | `.earned_premium` |
| **Unearned premium (UPR)** | How much coverage do we still owe at the period end? A liability. | `.unearned_premium_end` |

They are tied together by the rollforward that accountants check at every close:

```
UPR(end of P) = UPR(end of P-1) + written(P) - earned(P)
```

`tests/premium/assert_unearned_premium_rollforward_ties.sql` checks it for every policy and
coverage, to the cent.

## 2. The pipeline

```
raw.policy_admin.*                         (Fivetran-style: latest state, soft deletes kept)
  -> stg_policy_admin__*                   rename, cast, drop soft deletes, flag test policies
  -> int_premium__transaction_lines_booked one row per coverage line: booked period + window
  -> int_premium__line_earnings_by_period  line x month: ITD earned, earned, unearned
  -> fct_premium_by_policy_period          policy x coverage x month (the subledger)
     fct_policy_transaction_lines          the line detail
     fct_policy_month_end                  in force, in-force premium, exposure
```

| Step | File | What to look at |
|---|---|---|
| Staging | `models/staging/policy_admin/` | `is_test_policy` (policy_id 9000000 and up) is flagged here, filtered later |
| Booking | `models/intermediate/premium/int_premium__transaction_lines_booked.sql` | the call to `booked_accounting_period` |
| Earning | `models/intermediate/premium/int_premium__line_earnings_by_period.sql` | the period join and the two ITD calls |
| ITD formula | `macros/premium_earned_to_date.sql` | exact integer-cent rounding |
| Subledger | `models/marts/premium/fct_premium_by_policy_period.sql` | a plain sum of the line rows |
| In force | `models/marts/premium/fct_policy_month_end.sql` | rule 3e at each period end |

Why the line, not the transaction, is the unit of work: a transaction is split by coverage, and
each coverage can be reported on a different annual statement line (see `dim_coverages`). The
earning window is the same for every line of a transaction, but keeping lines lets every mart
be summed by coverage without re-splitting.

## 3. The booking rule: which period gets the written premium

A transaction is dated (`transaction_date`) and entered (`created_at`). Usually both fall in the
same month, and the transaction is booked in that month. But each month's books **close** on the
4th business day of the next month, and a closed period never changes again: its numbers have
been reported. So a transaction keyed in after its month closed lands in the next period that
is still open:

> booked period = the earliest period P with P.period_end_date >= transaction_date and
> created_at < P.close_date + 1 day

| Case | Dated | Entered | January closes | February closes | Booked |
|---|---|---|---|---|---|
| Same month | 2024-01-15 | 2024-01-15 09:00 | end of 2024-02-06 | end of 2024-03-06 | 2024-01 |
| Entered before the close | 2024-01-29 | 2024-02-06 17:30 | still open | | 2024-01 |
| Entered after the close | 2024-01-30 | 2024-02-07 08:00 | closed | open | 2024-02 |
| Entered after two closes | 2024-01-25 | 2024-03-07 10:00 | closed | closed | 2024-03 |

These are the four cases of the unit test `test_booking_rule_periods`
(`models/intermediate/premium/_int_premium__models.yml`). The rule lives in one shared macro,
`macros/booked_accounting_period.sql`, because claim transactions are booked the same way and
the ledger must see one consistent rule.

## 4. The earning method

Premium is earned evenly per day over the line's **window**:
`[effective_date, term_expiration_date)` (the end date is exclusive: coverage stops at 00:00 on
it). A new-business line's window is the whole term; an endorsement's is the rest of the term;
a cancellation line has negative premium and earns over `[cancellation date, expiration)`, which
exactly offsets the original lines' earning after the cancellation.

Inception-to-date (ITD) earned at the end of day d:

```
ITD(d) = round(written_premium * elapsed / window_days, 2)    elapsed = clamp(d + 1 - effective_date, 0, window_days)
```

and the earned premium of a period is a **difference of ITD values**:

```
earned(P) = ITD at P's end (lines booked <= P)  -  ITD at P-1's end (lines booked <= P-1)
```

### Why differences of ITD, not "days in the month x daily rate"

1. **Rounding adds up.** Each ITD is rounded once, to the cent. The monthly differences then
   sum to the last ITD exactly, so a fully earned line has earned exactly its written premium.
   Rounding each month's piece separately would leave stray cents.
   (`tests/premium/assert_expired_terms_fully_earned.sql` checks this per term.)
2. **Closed periods stay closed, and late changes catch up.** A line booked in March has no
   earning in February: February was closed without it. In March its prior ITD is 0, so March's
   earned includes every day that elapsed before March too. That is the "catch-up".
3. **The rollforward ties by construction.** UPR(P) = written to date - ITD earned. Subtract
   the same expression for P-1 and you get written(P) - earned(P).

### Why integer cents in the macro

DuckDB divides DECIMALs in DOUBLE, and a double cannot hold most decimal fractions exactly:
`round(1.005::double, 2)` returns `1.0`. The macro computes
`sign(n) * floor((2|n| + w) / (2w))` with `n = written cents x elapsed days`, `w = window days`,
all integers, which is exact and rounds a half cent away from zero, as the rule requires.

## 5. Worked example: one 6-month auto policy

One coverage keeps the numbers readable; the other coverages of a real policy work the same way,
line by line.

- **Term** 2024-01-01 to 2024-07-01: 182 days.
- **New business**, dated and entered 2024-01-01: 600.00, window 182 days. Booked 2024-01.
- **Backdated endorsement**: the insured adds a driver, a +120.00 change to the full-term
  premium, effective 2024-02-20 but dated 2024-03-05. Pro rata for the 132 days left:
  120.00 x 132 / 182 = **87.03**, window 132 days. Booked **2024-03**: February had closed
  without it.
- **Cancellation** at the insured's request, effective 2024-05-16: 46 of 182 days are returned
  on the 720.00 in-force premium (600 + 120): 720.00 x 46 / 182 = **-181.98**, window 46 days.
  Booked 2024-05.

ITD earned at each month end, then earned in the month (ITD minus the prior month's ITD):

| Period | Days elapsed (NB / END / CXL) | ITD NB | ITD END | ITD CXL | Written | Earned | UPR end |
|---|---|---|---|---|---|---|---|
| 2024-01 | 31 / - / - | 102.20 | | | 600.00 | 102.20 | 497.80 |
| 2024-02 | 60 / - / - | 197.80 | | | 0.00 | 95.60 | 402.20 |
| 2024-03 | 91 / 41 / - | 300.00 | 27.03 | | 87.03 | 129.23 | 360.00 |
| 2024-04 | 121 / 71 / - | 398.90 | 46.81 | | 0.00 | 118.68 | 241.32 |
| 2024-05 | 152 / 102 / 16 | 501.10 | 67.25 | -63.30 | -181.98 | 59.34 | 0.00 |
| 2024-06 | 182 / 132 / 46 | 600.00 | 87.03 | -181.98 | 0.00 | 0.00 | 0.00 |

How to read it:

- **March catch-up.** The endorsement's first ITD (27.03) covers 41 days: the 10 February days
  (6.59 of it) plus 31 March days. February's 95.60 is never restated.
- **May.** The cancellation line's ITD at 2024-05-31 is -63.30 for the 16 days from 5-16 to
  5-31, which cancels the 16 days the other two lines earned after the cancellation. Earned in
  May is effectively the premium for May 1-15 only.
- **UPR after the cancellation is 0.00.** The policy no longer owes coverage, so nothing is
  unearned. In June the three lines still move, but their earning sums to 0.00.
- **Totals.** Written 600.00 + 87.03 - 181.98 = 505.05; earned over the six months
  102.20 + 95.60 + 129.23 + 118.68 + 59.34 + 0.00 = 505.05. Fully earned, to the cent.
- **Rollforward**, March: 402.20 + 87.03 - 129.23 = 360.00.

The unit test `test_earning_formula_itd_differences` uses exactly these lines and expects these
numbers per line (plus a zero-day window, which is fully earned in its booked period). They were
computed by hand in Python with decimal arithmetic, not by the model.

## 6. Policies in force and exposure

`fct_policy_month_end` has one row per policy and month in which the policy had coverage on at
least one day. A policy is **in force** at a period end if a term covers that date
(`term_effective_date <= d < term_expiration_date`) and is not cancelled on or before it
(rule 3e, current state of the terms: a reinstated term counts as never cancelled).

- `in_force_term_premium`: the in-force term's premium from transactions effective by the period
  end. A cancellation effective later is not in it yet.
- `annualized_in_force_premium`: each line's premium per day of its window, times 365, so a
  mid-term change counts at its full rate rather than pro rata.
- `exposure_units` and `earned_exposure_years`: vehicles (auto) or dwellings (home), and
  covered days x units / 365. One car insured for a year is one car-year; claim frequency is
  claims per earned car-year.

## 7. How the results are checked

| Check | File |
|---|---|
| Written, earned, unearned and PIF per period and LOB match the generator's control totals (written and PIF exactly, the others within $1.00) | `tests/premium/assert_*_matches_control_totals.sql` |
| UPR rollforward ties per policy and coverage | `tests/premium/assert_unearned_premium_rollforward_ties.sql` |
| Terms expired by the valuation date are fully earned | `tests/premium/assert_expired_terms_fully_earned.sql` |
| Transaction lines sum to their header | `tests/premium/assert_transaction_lines_sum_to_header.sql` |
| Booking cases and earning formula | unit tests in `models/intermediate/premium/_int_premium__models.yml` |

The control totals come from the generator's own Python, so agreement means two independent
implementations of the same rules agree. They exist only for the default load; on any other
load those tests compare nothing and pass.
