# generator/

A seeded simulation of a fictional US personal lines carrier (private passenger auto and
homeowners, seven states) from its first policy on 2022-01-01 to the valuation date. It produces
the four source systems the dbt project reads: policy administration, billing, claims and the
general ledger, with the defects in `docs/data-issues.md` planted on purpose, and an answer key
of control totals computed in Python.

```
python -m generator [--seed 42] [--scale 1.0] [--valuation-date 2026-09-30] [--out data/generated]
python -m loader    [--as-of 2026-09-30T23:59:59] [--input data/generated] [--output warehouse/raw.duckdb]
pytest                                    # generator/tests, at scale 0.05, a few seconds
GENERATOR_TEST_SCALE=1.0 pytest           # the same checks on the full book
```

The specification is `docs/source-systems.md`; the raw table layout is `loader/raw_schema.sql`.
Reference data shared with dbt (coverages, states, loss causes, catastrophe events, the
accounting calendar, GL accounts, claim status codes) is read from `seeds/`, never copied.
Every tunable number is in `config.py`.

## Modules, in the order they run (`run.py`)

| Step | Module | What happens |
|---|---|---|
| 1 | `policies.py` | New business arrives each month; each policy lives term by term: endorsements, cancellations, reinstatements, renewals, expirations |
| 2 | `billing.py` | Every premium transaction is billed in installments; customers pay, a few payments bounce, refunds go out on cancellation |
| 3 | `claims.py` | Losses occur on in-force terms, plus catastrophe events; each exposure gets reserves, revisions, payments, recoveries, sometimes a void or a reopen |
| 4 | `defects.py` | Typing defects in the claims system (casing, policy numbers) |
| 5 | `controls.py` | The subledger: booking (3c), earning (3d), PIF (3e), claim financials (3f), in integer cents; this gives the control totals |
| 6 | `ledger.py` | Month-end journals posted from that subledger, exported as CSV files, with the GL defects |
| 7 | `output.py` | CDC metadata and duplicate versions, then Parquet and CSV files in `data/generated/` |

Helpers: `config.py` (settings), `rand.py` (seeded randomness), `money.py` (cents and rounding),
`timeline.py` (dates, the accounting calendar and the booking rule), `seeds.py`, `people.py`
(fictional names), `report.py` (the calibration summary printed after each run).

## How the simulation works

### Policies (docs/source-systems.md 3a, 3b)
- **New business** grows linearly from about 250 policies a month (2022) to about 600 (2026),
  65% auto. A policy is bound on a random day and starts on that day or up to 30 days later.
  15% of home policies are bought by an existing auto customer.
- **Premium** per coverage = base rate x state factor x the policy's rating factor x vehicles x
  the rate level of the term's start year. Rate levels step up every January 1st: +8% (2023),
  +12% (2024), +6% (2025), +4% (2026). Each policy has a hidden risk factor (lognormal, mean 1)
  that drives both its claim frequency and, with some pricing noise, its premium.
- **Endorsements** (20% of auto terms, 10% of home) change the full-term premium by -20% to
  +25% and write the change times the remaining fraction of the term; 15% are backdated 1 to 30
  days. The change persists into renewals.
- **Cancellations** hit about 6% of terms: insured request (15% of them flat, effective on the
  term start), nonpayment (monthly plans only: an installment is missed and a nightly batch
  cancels 20 days later; 10% are reinstated within 15 days), underwriting (30 days' notice).
  The cancellation returns each coverage's in-force premium times the unearned fraction.
- **Renewals** are processed 30 days before expiration: 88% of auto and 90% of home terms renew,
  so renewal premium is written (and sits in unearned premium) before the term starts.
- About 3.6% of new business, endorsements and insured cancellations are **keyed in late**,
  1 to 20 days after their transaction date, but never after the next event on the same term.

### Billing
New business and renewals are billed in one installment or monthly (6 for auto, 12 for home);
other transactions in one. Installments of a transaction add up to its premium to the cent.
Each installment is paid around its due date (the first new business installment at bind);
collection stops when a cancellation is processed, and the customer is refunded what they paid
beyond the premium they owe. Credit endorsements are refunded. About 1.6% of ACH and check
payments are returned a few days later and paid again by card.

### Claims
- **Frequency** per vehicle-year or dwelling-year, scaled by the policy's risk factor and state
  factor: at-fault auto accidents 0.035 (always a third-party PD exposure; COLL 70% of the time
  if carried; BI 29% of the time, one or two claimants), single-vehicle collisions 0.0255, comp
  0.04 (glass, animal, vandalism, theft, hail), home property 0.06, home liability 0.003. Each
  catastrophe in `seeds/catastrophe_events.csv` adds claims for in-force policies in its states.
- **Severity** is lognormal with the means in `config.py`, trended +6% a year by loss date and
  capped at the limit (BI $100k per claimant). 8% to 25% of exposures close without payment.
- **Report lag**: mostly days; injured claimants and liability claims have a tail of months,
  a few over a year. Claims not reported by the valuation date are not in the data (IBNR).
- **Reserving**: the initial case reserve is an average for the coverage, not the claim:
  0.55x the mean for BI, 1.25x for property. Revisions (1 to 4) re-estimate the remaining loss
  with a bias that fades as the claim matures, so BI incurred develops upward and property
  incurred downward. Each payment erodes the reserve (never below zero); closing releases what
  is left; about 3% of closed claims reopen with a new reserve and payment.
- **Voids**: about 3% of interim payments are voided days later and reissued; the source
  overwrites the payment row, adds a VOID_RESTORE reserve row, and only the CDC history shows
  both events.

### Time and the connectors
Everything people key in happens during office hours (08:00 to 17:00); batches run between
01:00 and 02:30. So a load as of the end of any day sees everything that happened that day: the
18:00 Fivetran sync and the Rivery runs (1 to 90 minutes after each change) have picked it up.
The generator writes every version of every row with the time it changed (`_version_at`), and
the CDC tables with their Rivery metadata; `python -m loader --as-of` rebuilds the raw database
as the connectors would have left it at any moment. Nothing is created after the valuation date.

## How the defects are planted

| Code | Where in the code |
|---|---|
| `TEST_POLICIES` | `policies.PolicySimulator.run`: 25 policies with ids from 9000001, simulated like the rest |
| `SOFT_DELETED_POLICYHOLDERS`, `SOFT_DELETED_POLICIES` | `policies.plant_soft_deleted_*`: a version with `_is_deleted` |
| `CDC_DUPLICATE_VERSIONS` | `defects.add_rivery_metadata`: 0.5% of versions loaded again by a later run |
| `DELETED_CLAIMS` | `claims.plant_duplicates`: a second FNOL deleted 1 to 5 days later |
| `LEGACY_STATUS_CODES` | `output.claims_rows`: versions before 2023-07-01 get the seed's one-letter codes |
| `INCONSISTENT_CODE_CASING`, `MALFORMED_POLICY_NUMBERS` | `defects.plant_typing_defects`: per claim, on every version |
| `ORPHAN_CLAIMS`, `LOSS_OUTSIDE_TERM` | `claims.plant_orphans`, `claims.plant_loss_outside_term` |
| `LATE_ENTERED_TRANSACTIONS` | `policies.entry_time` and step 4 of `claims.play_out` |
| `BACKDATED_ENDORSEMENTS` | `policies.simulate_terms` |
| `VOIDED_PAYMENTS`, `REOPENED_CLAIMS` | steps 3 and 1 of `claims.play_out` |
| `RETURNED_PAYMENTS` | `billing.BillingSimulator.pay` |
| GL issues | `ledger.build_ledger` |

The exact counts are computed after generation (`defects.count_planted`), written to
`planted_issues.parquet` and loaded into `raw.generator_audit.planted_issues`. The tests count
every one of them again with SQL on the loaded data. `data/generated/gl_reconciling_items_expected.csv`
lists the GL-minus-subledger differences (debit minus credit) that the manual reclass and the
claims interface timing issue create, in the layout of `seeds/gl_reconciling_items.csv` without
its `source_system` column (the reclass is MANUAL, the timing item CLAIMS).

## Scale, seed and determinism
`--scale` multiplies new business volumes and the planted counts (with small minimums), so
`--scale 0.05` gives a book of about 1,200 policies for quick tests. Each module draws from its
own `random.Random` stream seeded with `"<seed>:<module>"`, never from the global random state,
so the same seed and scale always give identical data (a test generates twice and compares). At scale 1.0 the generator runs in
about 15 seconds and the loader in about 4.

## Simplifications
Vehicles and dwellings never change; endorsements re-rate the policy instead of adding a vehicle.
A cancelled policy never renews. Claims keep the adjuster assigned at first notice. Vehicle makes
are invented names. Deductibles, reinsurance, IBNR and premium taxes are out of scope.
