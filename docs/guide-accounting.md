# How the subledgers reach the general ledger

A walkthrough for learners. The rules are specified in [source-systems.md](source-systems.md)
(sections 2b, 2d, 3c, 3d, 3f and the posting table in 3h); the defects are in
[data-issues.md](data-issues.md). The premium and claims guides explain how the subledgers
themselves are built. This guide picks up where they stop: how their figures become ledger
entries, how the ledger is checked against them, and how to read the reports an accountant
signs off at each close.

## 1. Subledgers and the ledger

The **general ledger** (GL) holds one balance per account: cash, premiums receivable, the
unearned premium reserve, losses paid, and so on. It is what the financial statements are built
from. It does not hold policies or claims; that detail lives in the **subledgers**: the policy
administration system (premium), billing (cash from customers) and claims (payments and
reserves). At each month's close, each subledger summarizes its month into journal entries and
sends them to the ledger.

```
premium:  fct_premium_by_policy_period          --+
billing:  int_accounting__billing_cash_events   --+--> int_accounting__subledger_postings
claims:   fct_claim_transactions                --+    (what the ledger should hold)
                                                                  |
                                                                  v
ledger:   stg_general_ledger__journal_lines  ----------> rpt_subledger_gl_reconciliation
              |                                         (does it? + documented items)
              +--> rpt_trial_balance
              +--> int_accounting__gl_balances_by_period --> the rollforwards, the receivable
```

In this project the ledger arrives as monthly CSV exports (`raw.general_ledger.journal_lines`),
and the models rebuild, independently, the entries the subledgers *should* have sent. Comparing
the two is the reconciliation.

| Step | File |
|---|---|
| Billing staging (cents to dollars, test policies flagged) | `models/staging/billing/` |
| Ledger staging (text parsing, latest file per period) | `models/staging/general_ledger/stg_general_ledger__journal_lines.sql` |
| Billing cash by month, returns reversed | `models/intermediate/accounting/int_accounting__billing_cash_events.sql` |
| Expected postings | `models/intermediate/accounting/int_accounting__subledger_postings.sql` |
| Ledger balances and documented items | `models/intermediate/accounting/int_accounting__gl_balances_by_period.sql` |
| Reconciliation | `models/marts/accounting/rpt_subledger_gl_reconciliation.sql` |
| Trial balance | `models/marts/accounting/rpt_trial_balance.sql` |
| UPR rollforward | `models/marts/accounting/rpt_unearned_premium_rollforward.sql` |
| Case reserve rollforward | `models/marts/accounting/rpt_loss_reserve_rollforward.sql` |
| Receivable and aging | `models/marts/accounting/rpt_premium_receivable.sql`, `rpt_premium_receivable_aging.sql`, `models/intermediate/accounting/int_accounting__installment_allocation.sql` |
| Reconciling items | `seeds/gl_reconciling_items.csv` |
| Tests | `tests/accounting/` |

## 2. Double entry, and the one sign convention used here

Every entry debits one account and credits another by the same amount, so the ledger always
balances: total debits equal total credits. Whether a debit increases or decreases an account
depends on the account's **normal balance** (`seeds/gl_accounts.csv`): assets and expenses
grow with debits, liabilities and revenue grow with credits.

The entries the subledgers send (source-systems.md 3h):

| Business event | Debit | Credit | Why |
|---|---|---|---|
| Premium written | 1200 Premiums receivable | 4000 Premiums written | the customer now owes the premium; revenue is recognized as written |
| UPR increases | 4100 Change in UPR | 2100 Unearned premium | part of what was written is not earned yet; it is a liability until the coverage is provided |
| Customer pays | 1000 Cash | 1200 Premiums receivable | cash in, receivable settled |
| Loss paid | 5000 Losses paid | 1000 Cash | expense, cash out |
| Salvage or subrogation recovered | 1000 Cash | 5050 Salvage and subrogation | cash in, reduces the loss expense |
| LAE paid | 5200 LAE paid | 1000 Cash | expense, cash out |
| Case reserve increases | 5100 / 5300 Change in reserves | 2200 / 2300 Case reserves | the expected cost is an expense now, and a liability until paid |

A negative amount swaps the sides: a cancellation credits 1200 and debits 4000; a month that
earns more than it writes lowers the UPR, debiting 2100 and crediting 4100.

**Convention in every accounting model:** amounts are *signed*, debit positive and credit
negative. An entry is two legs that sum to zero, a trial balance sums to zero, and the
reconciliation is a subtraction whatever the account type. Reports that present a liability
(the rollforwards) flip the sign so a reserve reads as a positive number, and say so.

Notice what 4000 and 4100 do together. The income statement shows premiums written (4000,
credit) less the change in UPR (4100, debit). Written minus the increase in unearned is exactly
**earned premium**: the ledger never posts earned premium directly; it falls out of the two
entries.

## 3. The booking rule, and why closed periods never change

Each month closes on the 4th business day of the next month. At the close the ledger receives
that month's entries, the financial statements are produced, and the month is **closed**: no
entry can be added to it again. If a closed month could still change, the statements already
reported would no longer match the books.

So every subledger books by the same rule (source-systems.md 3c, macro
`booked_accounting_period`): a transaction goes into the first period, on or after the month it
is dated in, that was still open when it was keyed in. A transaction dated March 30 but entered
April 8, after March closed, is booked in April.

Two events need care because the source overwrites a row that was already reported:

- **A voided claim payment** (the claims system marks it VOIDED): the payment stays in the month
  it was booked in, and a reversal is booked in the month of the void
  (`int_claims__financial_events`).
- **A returned customer payment** (the bank bounces it, billing marks it RETURNED): the receipt
  stays in the month the money came in, and the return is booked in the month of `returned_at`
  (`int_accounting__billing_cash_events`).

In both cases, using only the current state would quietly change a month that has been closed,
and the reconciliation of that month would break. That is the test that catches it.

## 4. What a reconciliation proves, and reconciling items

`rpt_subledger_gl_reconciliation` compares, per closed period, line of business and account:

```
difference              = gl_amount - subledger_amount
unexplained_difference  = difference - documented_items_amount
status                  MATCHED | EXPLAINED | UNEXPLAINED
```

A row at zero proves that the ledger's figure is fully supported by the detail: nothing was
posted twice, to the wrong line or account, or left out. It does not prove that the detail is
right; the control-total tests in `tests/premium` and `tests/claims` check that.

Not every difference is an error. An accountant may post a manual journal, or an interface may
deliver an entry a month late. Those are **reconciling items**: a difference that is understood,
correct, and documented. Each is a row in `seeds/gl_reconciling_items.csv`:

| Column | Meaning |
|---|---|
| `accounting_period`, `account_number`, `line_of_business` | the reconciliation row it explains |
| `amount` | the amount by which the ledger differs from the subledger, signed like `difference` |
| `item_type` | `MANUAL_JOURNAL`, `TIMING`, ... |
| `explanation` | what happened, which journal, and when it reverses, in words a reviewer can check |

The rules that make this a control and not a fudge:

1. One item per affected row, with its own amount: a timing difference has two sides (the month
   the entry was missing and the month it arrived), and both are documented.
2. An item that no longer matches a difference makes the row UNEXPLAINED again: stale
   documentation is a finding too.
3. A difference caused by a bug is fixed, never documented.

`tests/accounting/assert_reconciliation_has_no_unexplained_difference.sql` fails the build if any
row is unexplained by any amount, even a cent. There is no tolerance
(`macros/accounting_reconciliation_tolerance.sql` is zero): both sides are sums of two-decimal
amounts kept as DECIMAL, so a correct reconciliation is exact, and a "within a penny" allowance
would only hide the bugs that produce penny differences, such as a cents-to-dollars conversion
done in floating point.

## 5. How to read the reports

### Trial balance (`rpt_trial_balance`)

One row per period, account and line of business, with the period's debits, credits and net
activity. Balance sheet accounts also show `itd_balance_amount`, the balance at the period end
(inception to date). Income statement accounts restart every fiscal year, so they show
`ytd_net_activity_amount` instead. The first check of any close is that debits equal credits
(`assert_trial_balance_balances.sql`); it is checked per period, not per line, because a manual
reclass between lines balances only across both.

### Unearned premium rollforward (`rpt_unearned_premium_rollforward`)

```
opening UPR + written - earned = closing UPR          (the subledger ties)
closing UPR = GL 2100 balance - documented items      (the ledger agrees)
```

The first line is the premium subledger's own consistency: written, earned and closing are
separate columns of `fct_premium_by_policy_period`, so it can fail (tests/premium checks it per
policy and coverage). The opening is simply the prior row's closing, which is not tested
because it cannot differ. The second line is the evidence: the ledger's 2100, which only ever
received the monthly "increase in UPR" postings, adds up to the liability the policies say we
owe. `assert_unearned_premium_rollforward_ties_to_gl.sql` also compares written, earned and
closing UPR with the generator's control totals, computed in Python from its own records. Read
across a row: the opening liability, what was added by selling coverage, what was released by
providing it, and what is left.

### Case reserve rollforward (`rpt_loss_reserve_rollforward`)

```
incurred = paid + (closing - opening)     so     opening + incurred - paid = closing
```

Per line of business and cost category (LOSS on 2200, EXPENSE on 2300). Incurred is the
period's cost of claims. A payment that erodes the reserve by the same amount leaves incurred
unchanged: the cost was recognized when the reserve was set. A reserve increase raises
incurred although no money moved. Paid is net of recoveries, with voided payments reversed in
the month of the void.

Unlike the UPR rollforward, this one foots by definition: the report computes incurred as paid
plus the change in reserve, and the opening as the closing minus that change, so "opening +
incurred - paid = closing" cannot fail and is not tested. A test of it would look like evidence
and prove nothing. What `assert_loss_reserve_rollforward_ties_to_gl.sql` checks instead is the
closing reserve against the ledger's 2200 / 2300 in every closed period, and the closing
reserve and paid against the generator's control totals. (It also compares the closing reserve
with `fct_claim_exposure_period_balances`. Both are built from `int_claims__financial_events`,
so that part checks aggregation and the incremental claims fact, not the booking.)

### Premium receivable and aging (`rpt_premium_receivable`, `rpt_premium_receivable_aging`)

The ledger's 1200 is debited when premium is written and credited when cash arrives, so it holds
written minus collected. For a customer on a monthly plan, most of that is not due yet: the
whole term's premium is written on day one. The report splits the receivable into the
billed-and-due part (due installments minus cash) and the not-yet-due part (installments
scheduled later).

The aging needs to know which installments are still unpaid, but billing never links a payment
to an installment. `int_accounting__installment_allocation` builds that link in four steps:

1. A reinstatement cancels its cancellation. Billing bills the cancellation's return premium
   as a credit and the reinstatement as a debit of the same amount; the two offset each other
   without cash (source-systems.md 3b). So the reinstatement debit is settled by the
   cancellation credit of the same term, and that credit is used up.
2. Refunds use up the credits that are left. A credit installment (a cancellation that was not
   reversed, a credit endorsement) lowers what the customer owes, unless billing paid it out as
   a refund; a refunded credit is settled and must not lower anything else. Only refunds beyond
   the credits reduce the cash.
3. The remaining credits settle the latest installments of their own term first, because a
   cancellation removes the end of that term's coverage. Only a credit larger than everything
   its term billed would go on to the rest of the policy.
4. The policy's cash settles the oldest installments first (first in, first out).

What is left open is aged by days past due. Over 90 days matters beyond collections: statutory
accounting does not count such premium as an asset.

Why step 1 and "own term first" matter. A first version pooled all credits per policy and
treated a reinstatement debit like any other charge. A reinstated customer who then paid every
installment on time (policy 16789, home: missed one installment in 2025-09, cancelled,
reinstated, paid on schedule ever since) showed all of the 1,515.40 it owes as past due, most of
it over 90 days: the cancellation credit had settled the renewal's installments, not yet due,
and the reinstatement debit had used up cash that paid real installments. Total open did not
change, so the tests that tie the aging to the receivable and the ledger could not see it.
`assert_aging_shows_nothing_past_due_for_paid_up_policies.sql` now checks the buckets
themselves: it finds, from billing directly, the policies that have paid everything due and
have no credit left to allocate, and requires that none of them shows money past due. On the
default load the fix lowered total past due from 176,638.86 to 131,111.01, and the policies
with a reinstatement showing anything past due from 82 to 7 (each of those 7 has a genuinely
unpaid installment).

## 6. A worked example

One 6-month auto policy, effective 2024-01-01 (182 days), 600.00 written in January, billed
monthly at 100.00 on the 1st of each month, and paid on time. It has one claim: a 5,000.00 loss
reserve set in February, and a 1,000.00 payment in March that erodes the reserve to 4,000.00.
Earned premium per month is the premium guide's example: 102.20 in January, 95.60 in February,
102.20 in March.

**January entries** (signed, debit +):

| Entry | Account | Amount |
|---|---|---|
| written premium | 1200 | +600.00 |
| | 4000 | -600.00 |
| UPR increase = written - earned = 600.00 - 102.20 | 4100 | +497.80 |
| | 2100 | -497.80 |
| cash | 1000 | +100.00 |
| | 1200 | -100.00 |

Debits 600.00 + 497.80 + 100.00 = 1,197.80 = credits. On the income statement, 4000 and 4100
together show 600.00 - 497.80 = 102.20, January's earned premium.

**February:** UPR increase = 0 - 95.60 = -95.60, so 2100 is *debited* 95.60 (the liability
shrinks) and 4100 credited. Cash +100.00. Reserve: 5100 +5,000.00, 2200 -5,000.00.
**March:** UPR -102.20 again; cash +100.00; payment 5000 +1,000.00 and 1000 -1,000.00; erosion
5100 -1,000.00 and 2200 +1,000.00.

**UPR rollforward:**

| Period | Opening | + Written | - Earned | = Closing | GL 2100 (credit balance) |
|---|---|---|---|---|---|
| 2024-01 | 0.00 | 600.00 | 102.20 | 497.80 | 497.80 |
| 2024-02 | 497.80 | 0.00 | 95.60 | 402.20 | 497.80 - 95.60 = 402.20 |
| 2024-03 | 402.20 | 0.00 | 102.20 | 300.00 | 300.00 |

**Case reserve rollforward (LOSS):**

| Period | Opening | Paid | Incurred | Closing | GL 2200 |
|---|---|---|---|---|---|
| 2024-02 | 0.00 | 0.00 | 5,000.00 | 5,000.00 | 5,000.00 |
| 2024-03 | 5,000.00 | 1,000.00 | 1,000.00 - 1,000.00 = 0.00 | 4,000.00 | 4,000.00 |

5,000.00 + 0.00 - 1,000.00 = 4,000.00: the payment did not change incurred, because the cost had
been recognized in February.

**Receivable at the end of March:** written 600.00, billed and due 300.00 (three installments),
collected 300.00. Receivable (GL view) 300.00 = billed-and-due receivable 0.00 + not yet due
300.00. Nothing is past due.

**A reconciling item.** Suppose the claims interface had sent the March payment in April. The
ledger's March 5000 would be 1,000.00 short and April's 1,000.00 over. The reconciliation shows
a difference of -1,000.00 on 2024-03 / 5000 and +1,000.00 on 2024-04 / 5000 (and the opposite
on 1000). With four rows in the reconciling-items seed, one per period and account, all four
rows become EXPLAINED. The case reserve rollforward is unaffected, because only the payment was
late: the erosion is a reserve posting, and it went through on time. Section 7 shows that this
is exactly what happened in this data set.

## 7. The reconciliation of this data set

On the default load (valuation 2026-09-30), the ledger has exports for 56 closed periods,
2022-01 to 2026-08; 2026-09 is still open, so the reports show subledger figures for it and
null GL columns. Of 1,344 reconciliation rows, 1,338 are MATCHED and 6 are EXPLAINED by the
items in `seeds/gl_reconciling_items.csv`:

| Period | Account | Line | Difference (GL - subledger) | Item |
|---|---|---|---|---|
| 2024-06 | 4000 | AUTO | +25,523.10 | manual journal JE-2024-06-0007 moved written premium from AUTO to HOME |
| 2024-06 | 4000 | HOME | -25,523.10 | the other side of the same journal |
| 2025-08 | 5000 | AUTO | -11,926.78 | five AUTO loss payments entered on Sunday 2025-08-31, booked in 2025-08, that the claims interface did not send at the close |
| 2025-08 | 1000 | AUTO | +11,926.78 | their cash side |
| 2025-09 | 5000 | AUTO | +11,926.78 | the same payments, posted in 2025-09 |
| 2025-09 | 1000 | AUTO | -11,926.78 | their cash side |

How each was found. The reconciliation showed the six rows; for the reclass, the ledger had a
two-line MANUAL journal of exactly 25,523.10 and no subledger has manual journals. For the
timing item, the five payments were found in `fct_claim_transactions` (booked 2025-08, entered
2025-08-31) and add up to the difference to the cent; recoveries entered the same day and every
reserve change were posted on time, which is why 5050, 2200 and the reserve rollforward show no
difference.

Two other things the ledger checks turned up:

- **The re-exported 2025-03 file.** The first export (28 lines) lacked both BILLING journals,
  so March's premium collections were missing from it; the corrected `_v2` file (32 lines)
  matches the subledgers. Keeping the first file would leave 1,000,922.33 (AUTO) and 576,036.19
  (HOME) of collections out of the ledger; keeping both would count every other March journal
  twice. Staging keeps the newest file, and
  `assert_gl_reexport_removed_rows_match_planted.sql` checks that exactly the 28 lines go.
- **A unit bug, not a reconciling item.** `assert_installments_equal_written_premium.sql` first
  failed on a third of all terms by fractions of a cent: `cents_to_dollars` divided a DECIMAL by
  100, which DuckDB computes in floating point. The macro was fixed (it now multiplies by 0.01,
  which stays DECIMAL), and every term ties to the cent. This is the rule from section 4 in
  practice: a difference caused by a bug is fixed, never documented.

The rollforwards' closing balances agree with the ledger in every closed period, and their
written, earned, paid and closing figures with the generator's own control totals in every
period. For 2025-08, AUTO: UPR 4,009,500.90 + 1,170,585.42 written - 1,042,830.87
earned = 4,137,255.45, equal to the ledger's 2100 balance; case reserve (LOSS) 2,831,097.88 +
757,524.00 incurred - 403,479.85 paid = 3,185,142.03, equal to the ledger's 2200 balance.

