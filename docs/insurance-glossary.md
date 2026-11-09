# Insurance glossary

The terms this project uses, in the sense it uses them. Personal lines property and casualty
(P&C) insurance in the US: private passenger auto and homeowners.

## Policies and premium

| Term | Meaning |
|---|---|
| Policy | The contract between the insurer and the policyholder. Has a number that stays the same across renewals. |
| Term | One coverage period of a policy: 6 months for auto, 12 for home here. Each renewal starts a new term. |
| Coverage | One part of the protection a policy gives, with its own premium and limit: bodily injury liability (BI), property damage liability (PD), collision (COLL) and comprehensive (COMP) for auto; dwelling, personal property (contents) and personal liability for home. |
| Line of business (LOB) | A group of coverages reported together: here AUTO and HOME. Regulators use finer annual statement lines (see below). |
| Policy transaction | Any event that changes premium: new business, renewal, endorsement, cancellation, reinstatement. |
| Endorsement | A mid-term change to the policy (add a driver, raise a limit). Its premium is the rate change times the remaining fraction of the term. |
| Backdated | A transaction whose effective date is before the date it was processed. |
| Cancellation | Ends a term early. Pro rata cancellation returns the unearned part of the premium; a flat cancellation returns all of it (as if the term never started). |
| Reinstatement | Undoes a cancellation, usually after a late payment arrives. |
| Written premium | Premium booked by transactions in a period: the sales figure. Can be negative (cancellations). |
| Earned premium | The part of written premium for coverage already provided: a 6-month term written in January is about 1/6 earned at the end of January. This is the revenue. |
| Unearned premium (UPR) | Written minus earned: premium for coverage still owed to the policyholder. A liability on the balance sheet. |
| Policies in force (PIF) | Policies with coverage in effect on a date, typically the month end. |
| In-force premium | The premium of the policies in force, often annualized (auto premium × 2 for 6-month terms). |
| Exposure (premium side) | The unit premium is charged for: a vehicle-year for auto, a house-year for home. Earned exposure is the denominator of frequency. |
| Retention | The share of policies that renew at the end of their term. |

## Claims

| Term | Meaning |
|---|---|
| Claim | A request for payment after a loss (an accident, a hailstorm). Has a loss date and a reported date. |
| FNOL | First notice of loss: when the claim is reported. |
| Exposure (claims side) | One coverage and one claimant on a claim: an accident can create a collision exposure for the insured's car and a PD exposure for the other driver's. Not the same as the premium-side exposure. |
| Case reserve | The adjuster's estimate of what is still to be paid on an open claim. Revised as facts emerge; erodes as payments go out; set to zero at closing. |
| Paid | Money paid out on claims. Net paid subtracts recoveries. |
| Recovery | Money coming back: salvage (selling the wrecked car) and subrogation (collecting from the at-fault party's insurer). |
| Incurred | Paid + case reserve: the insurer's current estimate of the claim's total cost, as known today. |
| IBNR | Incurred but not reported: claims that have happened but are not yet known, plus future development on known claims. Not in any source system; actuaries estimate it, for example with the chain-ladder method. |
| Ultimate | The final cost of a group of claims once all are closed: incurred + IBNR. |
| LAE | Loss adjustment expense: the cost of handling claims. DCC (defense and cost containment: lawyers, experts) is attached to specific claims; A&O (adjusting and other) covers the rest. |
| Reopened claim | A closed claim that receives new activity, such as a late medical bill. |
| Void | Cancelling an issued payment (a lost check). Accounting books a reversal in the period of the void; the original period stays as reported. |
| Catastrophe (cat) | A single event causing many claims, such as a hailstorm. Tracked by a cat code because it distorts trends. |

## Actuarial

| Term | Meaning |
|---|---|
| Accident year (AY) | Groups claims by the year of the loss date, whatever the year of payment. |
| Calendar year | Groups transactions by the period they are booked in. |
| Development age | How long after the start of the accident year a figure is measured: 12, 24, 36 months... |
| Loss development triangle | Accident years as rows, development ages as columns, cumulative paid or incurred in the cells. The triangle shape comes from recent years having fewer ages. |
| Age-to-age factor | How much a cumulative figure grows from one age to the next, e.g. 24-month incurred / 12-month incurred. |
| Chain ladder | Projects each accident year to ultimate by multiplying its latest figure by the remaining age-to-age factors. |
| Frequency | Claims per earned exposure unit. |
| Severity | Average cost per claim. Frequency × severity = pure premium (loss cost per exposure). |
| Loss ratio | Losses divided by earned premium. Calendar-year: incurred in the period / earned in the period. Accident-year: incurred of the AY's claims / earned premium of that year. |

## Accounting

| Term | Meaning |
|---|---|
| Accounting period | A month here, `YYYY-MM`. |
| Close | Finalizing a period: after the close date, nothing more is booked into it. |
| Booking rule | Which period a transaction belongs to (docs/source-systems.md, 3c): its own period if entered before that period closed, else the first period still open. |
| Subledger | A detailed record of one area (policy transactions, claim transactions, billing) that feeds summarized entries to the general ledger. |
| General ledger (GL) | The company's official book of accounts, built from journal entries with debits and credits. |
| Journal entry | A balanced set of debits and credits posted to GL accounts. |
| Reconciliation | Proving two records agree (subledger vs GL), and explaining every difference as a documented reconciling item. |
| Rollforward | Opening balance + additions − reductions = closing balance. Unearned premium: opening + written − earned. Case reserves: opening + incurred − paid. |
| Trial balance | All GL account balances at a date; debits equal credits. |
| Premiums receivable | Premium billed or written but not yet collected. |
| Annual statement line | The line of business in the statutory financial statement filed with state regulators, e.g. 19.2 other private passenger auto liability, 21.1 private passenger auto physical damage, 4 homeowners multiple peril. |
| Schedule P | The part of the statutory annual statement with loss development triangles by line. |
