# Guide: snapshots, the month-end close and the actuarial reports

A walkthrough for learners. It explains why the policy tables are snapshotted and the claims
tables are not, what the month-end close simulation does, and how to read the actuarial reports
built on top: policies in force as reported versus restated, loss ratios, frequency and
severity, and how they connect to the loss development triangle. Rules are specified in
[source-systems.md](source-systems.md); terms are in [insurance-glossary.md](insurance-glossary.md).
The claims side is in [guide-claims.md](guide-claims.md), the premium side in
[guide-premium.md](guide-premium.md).

| What | File |
|---|---|
| Snapshot configs | `snapshots/snap_policy_terms.yml`, `snap_policyholders.yml`, `snap_billing_payments.yml` |
| Close simulation | `scripts/simulate_month_end_closes.py` |
| PIF as reported vs restated | `models/marts/actuarial/fct_policy_in_force_at_close.sql`, `rpt_policies_in_force_as_reported_vs_restated.sql` |
| Loss ratios | `models/marts/actuarial/rpt_loss_ratio_by_period.sql`, `rpt_loss_ratio_by_accident_year.sql` |
| Frequency and severity | `models/marts/actuarial/rpt_frequency_severity.sql` |
| Triangle and chain ladder | `models/marts/actuarial/rpt_loss_development_triangle.sql`, `analyses/chain_ladder_development_factors.sql` |
| Tests | `tests/actuarial/`, `models/marts/actuarial/_actuarial__models.yml` |
| Who uses them | `models/exposures.yml` |

## 1. Two ways a source can keep history

A source table can arrive in the warehouse in two shapes.

**Latest state** (the policy and billing systems, Fivetran-style, source-systems.md 2a and 2b).
One row per key, overwritten when the source changes. Term 31229 in the generated data is an
auto renewal covering 2025-03-08 to 2025-09-08. A nightly batch cancelled it for nonpayment,
effective 2025-05-28, and it was reinstated on 2025-06-08. Loaded at two closes:

| loaded as of | term_id | term_status | cancellation_effective_date | updated_at |
|---|---|---|---|---|
| 2025-05-06 (April close) | 31229 | ACTIVE | | 2025-04-05 12:27 |
| 2025-06-05 (May close) | 31229 | CANCELLED | 2025-05-28 | 2025-05-28 01:09 |
| 2025-07-04 (June close) | 31229 | ACTIVE | | 2025-06-08 16:45 |

Each load replaces the one before. Today's raw table has one row for the term, `EXPIRED` with no
cancellation date, and nothing says it was ever cancelled.

**Change log** (the claims system, Rivery-style CDC in append mode, 2c). Every change arrives as
a new row, a version, and old rows stay (illustrative rows):

| claim_id | claim_status | updated_at |
|---|---|---|
| 812 | OPEN | 2025-03-04 09:30 |
| 812 | CLOSED | 2025-04-18 15:02 |
| 812 | REOPENED | 2025-07-01 11:45 |

The history is already in raw. Staging orders the versions and builds `[updated_at, valid_to)`
ranges itself (`macros/claims_cdc_versions.sql`, guide-claims.md section 7). A snapshot of a
claims table would only copy what is already there, and miss the changes between its runs.

So: **the claims tables need no snapshot; the policy and billing tables do**, because a snapshot
is the only way to keep a latest-state table's past.

## 2. How a dbt snapshot works

Each `dbt snapshot` run compares the source with the versions the snapshot table holds:

1. A key that is new gets a first version, valid from now on (`dbt_valid_to` = the "current"
   value).
2. A key that changed gets its current version closed (`dbt_valid_to` = the new version's start)
   and a new current version inserted.
3. A key that did not change is left alone.

A snapshot only knows what it saw. Two changes between two runs leave one version (the second);
anything before the first run never appears. That is the whole reason section 3 exists.

Term 31229 from section 1 in `snap_policy_terms`, after the simulation in section 3 snapshotted
every close from 2025-01 on:

| term_status | cancellation_effective_date | dbt_valid_from | dbt_valid_to | what happened |
|---|---|---|---|---|
| ACTIVE | | 2025-02-06 02:17 | 2025-04-05 12:27 | renewal written |
| ACTIVE | | 2025-04-05 12:27 | 2025-05-28 01:09 | endorsement |
| CANCELLED | 2025-05-28 | 2025-05-28 01:09 | 2025-06-08 16:45 | nonpayment cancellation |
| ACTIVE | | 2025-06-08 16:45 | 2025-09-08 01:05 | reinstated |
| EXPIRED | | 2025-09-08 01:05 | 9999-12-31 00:00 | term ended |

Five versions, because every change fell in a different month. The version current at the end
of the May close date (2025-06-05) is the cancelled one: the May close counted this policy out
of force. Section 4 comes back to it.

### Timestamp or check strategy

How does dbt decide that a row changed?

| | timestamp | check |
|---|---|---|
| Changed when | the row's `updated_at` is later than the stored version's | any of `check_cols` differs from the stored version |
| `dbt_valid_from` | the row's `updated_at`: when the source changed | the run time, unless you set `updated_at` |
| Needs | an `updated_at` the source bumps on every change you care about | nothing |
| Cost | compares one column | compares every listed column |
| Use for | well-behaved application tables | tables without a trustworthy change timestamp |

The project uses both, on purpose:

- `snap_policy_terms` and `snap_billing_payments`: **timestamp** on `updated_at`. The source bumps
  it on every change to a term (cancel, reinstate, endorse, expire) and on a payment's return.
  `dbt_valid_from` is then the source's own change time, so "which version was current at the
  end of a close date" has an exact answer.
- `snap_policyholders`: **check** on email, address and `_fivetran_deleted`, with
  `updated_at: _fivetran_synced`. The source bumps `updated_at` when the address changes, but a
  soft delete is set by the connector, not the application, and leaves `updated_at` untouched.
  A timestamp strategy would never record those deletions. The check strategy notices them. Its
  default timestamp, the run time, would be useless here (the simulation replays two years in a
  few minutes), so it takes the connector's write time instead: the moment the warehouse learned
  of the change. The source `updated_at` would not do as that timestamp either: on a soft delete
  it is unchanged, so the delete version would start at the same instant as the version before
  it and get the same `dbt_scd_id`.

### Snapshot sources, not staging

All three snapshots read `source(...)`, not `stg_...`. A snapshot is the only copy of the past and
cannot be rebuilt, so whatever logic runs before it is baked into history. Staging changes (a new
cast, a renamed column, a fixed filter); a snapshot of staging would hold a mix of logic versions
forever. Staging also drops rows (soft deletes, test policies), so a row leaving the view would
look like a hard delete. Snapshot the source as it is, with `select *`, and clean up downstream,
where the cleanup can be fixed and rerun over all of history.

### hard_deletes and dbt_valid_to_current

- `hard_deletes: ignore`. Fivetran-style tables never lose rows: a delete arrives as
  `_fivetran_deleted = true`, which the snapshot records as an ordinary change. A key that vanishes
  means a connector accident or a load at an earlier as-of, not a business event. `invalidate`
  or `new_record` would write that accident into history, stamped with the run's wall-clock time.
  `ignore` keeps the last version current, and
  `tests/actuarial/assert_snapshot_current_keys_exist_in_source.sql` warns about it instead.
- `dbt_valid_to_current: 9999-12-31`. dbt's default for a current version is null. A far-future
  date makes "the version current at time t" one range condition,
  `dbt_valid_from <= t and dbt_valid_to > t`, with no `or dbt_valid_to is null`. It has to be set
  before the first run: dbt does not rewrite versions that are already current.

## 3. The month-end close simulation

```
python scripts/simulate_month_end_closes.py --start 2025-01 --end 2026-09 --fresh
```

For each period from `--start` to `--end` it:

1. rebuilds the raw database as the connectors would have left it at the end of the period's
   close date: `python -m loader --as-of 2025-02-06T23:59:59` for 2025-01 (source-systems.md 2f);
2. runs `dbt snapshot` against it.

Each snapshot run therefore sees exactly one month of changes, as a job scheduled at every close
would have. At the end it reloads the default as-of (the end of the valuation date) and snapshots
once more, so the raw database is the standard load again: the generator's control totals apply
to it and the snapshots' current versions match it.

Two rules follow from "a snapshot only moves forward":

- **Order matters.** Loading an earlier as-of on top of recorded history would not undo it. The
  script refuses to start before the newest version already recorded, unless `--fresh` drops the
  snapshot tables first.
- **History starts at the first run.** Periods before `--start` have no as-reported figures. The
  models detect this themselves (section 4) rather than trusting a parameter.

`--raw-path` and `--dev-path` choose the files (defaults `warehouse/raw.duckdb` and
`warehouse/dev.duckdb`). The loader replaces the raw file at every close, so nothing else may be
reading it while the script runs.

What a run from 2025-01 to 2026-09 recorded (21 closes plus the final reload, about three and a
half minutes):

| snapshot | versions | keys | keys with more than one version |
|---|---|---|---|
| `snap_policy_terms` | 105,576 | 68,558 | 32,557 |
| `snap_policyholders` | 23,943 | 23,082 | 861 |
| `snap_billing_payments` | 299,519 | 299,262 | 257 |

How to read it:

- Term versions change status ACTIVE → EXPIRED 29,333 times, ACTIVE → ACTIVE (an endorsement)
  5,704, ACTIVE → CANCELLED 1,966, and CANCELLED → ACTIVE 15: reinstatements where a close fell
  between the cancellation and the reinstatement. Reinstatements come within 15 days, so most
  never show up as a cancelled version at all.
- 3,038 payments are RETURNED today, but only 257 have a SETTLED version. Banks return payments
  a few days after receipt, so most are received and returned between two closes, and no
  snapshot ever saw them settled. That is the "only what it sees" rule at work.
- 40 policyholder versions record a soft delete, and every one of them has `updated_at` equal
  to `created_at`: a timestamp strategy on `updated_at` would have recorded none of them.
- The oldest `dbt_valid_from` is 2022-01-24, although the first run was at the 2025-02-06 close:
  a term that had not changed since 2022 enters the snapshot with its 2022 `updated_at`. The
  validity ranges are source times, not run times, which is what makes point-in-time queries
  work, and also why the snapshot cannot tell on its own which closes it really saw (section 4).

## 4. Policies in force: as reported versus restated

Policies in force (PIF) at a period end is a count of policies with a term covering that day and
no cancellation effective by then (rule 3e). The rule is fixed, but the data it reads keeps
changing after the books close:

- new business keyed in late, with an effective date in the closed month;
- a nonpayment cancellation effective in the month, reinstated after the close, which erases the
  cancellation from the current state;
- a cancellation entered after the close but effective on or before the period end.

`fct_policy_month_end` applies the rule to the **current** state of the terms: PIF **restated**
with everything known today. `fct_policy_in_force_at_close` applies the same rule to the term
versions in `snap_policy_terms` that were current at the end of the period's close date: PIF
**as reported**, the number the month-end report actually showed.
`rpt_policies_in_force_as_reported_vs_restated` puts the two side by side per period and line,
with the difference split by reason.

How to read a row:

| column | meaning |
|---|---|
| `policies_in_force_as_reported` | what the close report said |
| `policies_in_force_restated` | what the same rule says today for the same date |
| `policies_in_force_difference` | restated − as reported: positive means the period looks bigger in hindsight |
| `term_entered_after_close_count` ... | how many policies each reason added or dropped |
| `main_restatement_driver` | the reason behind most of them |
| `has_as_reported` | false for periods before the snapshot history starts |

A real row, May 2025, AUTO:

| | policies |
|---|---|
| as reported at the close (end of 2025-06-05) | 6,337 |
| + new business keyed in after the close, effective in May | 2 |
| + reinstated after the close (term 31229 from section 2) | 1 |
| − cancelled after the close, effective by May 31 | 1 |
| = restated today | 6,339 |

The as-reported figure was checked without any snapshot: loading raw as of
`2025-06-05T23:59:59` and counting rule 3e directly on `raw.policy_admin.policy_terms` gives
6,337 AUTO and 4,460 HOME, the model's figures. Over the 21 covered periods the differences run
from −1 to +3 per period and line, 51 restated policy-periods in all: 33 late-entered terms
(the most common driver), 11 cancellations entered after the close and 7 reinstatements. Small,
because few transactions are entered late, but a closed month's PIF is rarely exactly what the
board pack said.

**Which periods have an as-reported figure.** The model does not take the simulation's start
date as a parameter; it checks the data. For a close the snapshot did not see, the versions it
holds are the states of its first run, and every term that changed in between has no version
current at that close. So a period counts as covered only if every term entered by its close has
a version current at the close. The others get a null as-reported count, not a wrong one.

**The test.** `tests/actuarial/assert_pif_as_reported_equals_restated_when_unchanged.sql`: for
every policy whose terms that could be in force at the period end look the same at the close and
today (same effective, expiration and cancellation dates, present on both sides), the two
statuses must agree, because the same rule then reads the same data. It is formulated per
policy, not per period, because terms change every day and no period would be fully unchanged.
It also fails if a covered period has no comparable policy at all, so it cannot pass by checking
nothing.

## 5. Calendar-period and accident-year loss ratios

Both are incurred loss over earned premium. They differ in which losses count.

**Calendar period** (`rpt_loss_ratio_by_period`): the losses booked in the period, whatever year
the accident happened.

```
calendar-period incurred = net paid in the period + change in case reserves in the period
```

It is what the income statement shows (accounts 5000 and 5100) and never changes once the period
is closed. But it mixes years: raising the reserve on a 2023 injury claim by $50,000 in June 2026
puts $50,000 into June 2026's loss ratio.

**Accident year** (`rpt_loss_ratio_by_accident_year`): the losses of accidents that happened in
the year, valued today, against the premium earned in that calendar year.

```
accident-year incurred = net paid to date + outstanding case reserve, for claims with loss_date in the year
```

The 2023 reserve increase above belongs to accident year 2023. A year's figure moves as its own
claims develop, which is why pricing and reserving use it. The price is maturity: the latest
years are not final (`development_age_months` says how old each row is).

The two side by side, from the reports (valuation 2026-09-30; 2026 is January to September):

| year | AUTO accident year | AUTO calendar | HOME accident year | HOME calendar |
|---|---|---|---|---|
| 2022 | 71.4% | 64.1% | 66.2% | 70.7% |
| 2023 | 87.0% | 73.5% | 85.8% | 94.3% |
| 2024 | 69.1% | 66.4% | 59.3% | 54.9% |
| 2025 | 58.2% | 60.5% | 78.3% | 80.1% |
| 2026 | 62.5% | 68.1% | 64.5% | 62.3% |

(Calendar columns are the sums of the twelve monthly rows of `rpt_loss_ratio_by_period`.)

Worked through for AUTO 2024. The accident year: claims with a 2024 loss date have $4,914,366.96
paid and $550,544.48 still reserved at the valuation date, $5,464,911.44 incurred, against
$7,906,916.42 earned in calendar 2024: 69.1%. The calendar year: everything booked in the twelve
2024 periods, $5,253,584.37, against the same premium: 66.4%. The calendar figure is lower
because it contains only what the 2024 accidents had cost by 31 December 2024 (their later
development lands in 2025 and 2026), plus whatever the 2022 and 2023 accidents developed during
2024. The accident-year incurred was checked by hand against raw: summing the latest CDC
versions of the 2024 claims' loss transactions directly gives the same $5,464,911.44 and 723
claims, as do the generator's control totals.

The split by **catastrophe** (claims tied to an event in `seeds/catastrophe_events.csv`) is in
both reports. A single event can add several points to one year; the non-catastrophe ratio is the
one to compare across years and with the pricing target (source-systems.md 4: auto 60-75%, home
50-65% outside catastrophe years). The generated data runs above that band for AUTO accident
year 2023 (84.4% without catastrophes). That is the data, not the report: both its earned
premium and its incurred loss equal the generator's own control totals. **LAE** (loss adjustment expense, the EXPENSE cost category) is
reported apart in the calendar-period report: `lae_ratio` on incurred, `paid_lae_ratio` on paid,
and `loss_and_lae_ratio` for the total.

## 6. Frequency and severity

`rpt_frequency_severity` splits the loss cost per unit of exposure into how often and how much,
per accident year, line and coverage:

```
frequency    = claims / earned exposure years
severity     = incurred loss / claims
pure premium = incurred loss / earned exposure years = frequency x severity
```

**Earned exposure** is one vehicle (auto) or dwelling (home) insured for a year, from
`fct_policy_month_end.earned_exposure_years` (covered days x units / 365). That model has it per
policy, not per coverage, and not every policy carries every coverage: collision and
comprehensive are optional. The report gives a policy's exposure in a month to a coverage only if
the policy earned premium on that coverage in that month (`fct_premium_by_policy_period`). Giving
collision the exposure of every auto policy would put cars that cannot have a collision claim in
the denominator.

**Claims** are claim exposures (one coverage and one claimant), so a crash that damages our car
and another one counts once for COLL and once for PD. Only claims on matched policies with the
loss inside a term count: orphan claims have no exposure in the base, and claims outside a term
were not covered. Catastrophes are a separate row (`is_catastrophe_included`), because one storm
adds hundreds of claims to one year and hides the trend.

Accident year 2025, catastrophes excluded:

| coverage | exposure years | claims | frequency | severity | pure premium | premium per exposure year |
|---|---|---|---|---|---|---|
| AUTO BI | 10,176.7 | 118 | 0.0116 | $16,205 | $187.90 | $404.53 |
| AUTO PD | 10,176.7 | 351 | 0.0345 | $4,987 | $171.99 | $260.99 |
| AUTO COLL | 8,683.8 | 458 | 0.0527 | $4,614 | $243.33 | $411.05 |
| AUTO COMP | 8,683.8 | 366 | 0.0421 | $2,666 | $112.35 | $169.10 |
| HOME DWELLING | 4,594.7 | 260 | 0.0566 | $13,530 | $765.60 | $1,243.49 |
| HOME CONTENTS | 4,594.7 | 126 | 0.0274 | $4,613 | $126.50 | $296.87 |
| HOME PERS_LIAB | 4,594.7 | 7 | 0.0015 | $33,563 | $51.13 | $59.90 |

Reading the COLL row: 458 collision claims in 8,683.8 car-years is 0.0527, about one claim per
19 car-years; at $4,614 each that is 0.05274169 x 4,613.54 = $243.33 of loss per car-year. The
collision premium is $411.05 per car-year, so the coverage's loss ratio is 243.33 / 411.05 =
59.2%.

Three things to notice:

- COLL and COMP have 85% of the auto exposure, BI and PD 99.997%: the attribution rule at work
  (most, not all, auto policies carry physical damage). The tiny gap for the mandatory coverages
  is a few days in months where a policy's net earned premium was not positive.
- BI has 118 exposures on 97 claims: one accident can injure several people.
- PERS_LIAB and BI look cheap for 2025 because they are immature: liability claims are reported
  late and reserves develop upward. Their frequency and severity will rise as the year ages.

## 7. The triangle, the chain ladder and the loss ratios

The accident-year loss ratio uses one number per accident year: incurred at the valuation date,
the latest diagonal of `rpt_loss_development_triangle`. The triangle keeps the same figure at
every earlier age too (guide-claims.md section 8), and the chain ladder
(`analyses/chain_ladder_development_factors.sql`) turns the pattern into a projection:

1. Age-to-age factors: for each pair of ages, the sum of incurred at the later age over the sum at
   the earlier age, across the accident years that have both.
2. Cumulative factors: the product of the factors from an age to the last observed one.
3. Ultimate loss = latest incurred x the cumulative factor at its age. IBNR = ultimate − incurred.

Divide the ultimate by the same earned premium and you get the **ultimate loss ratio**, the
figure the reported accident-year loss ratio grows toward. Worked through with round numbers: an
accident year 24 months old shows $6.0M incurred on $10.0M earned premium (60%). If the
cumulative factor from 24 months is 1.05, the ultimate is $6.3M, IBNR $0.3M, and the ultimate
loss ratio 63%. For a 12-month-old year with a factor of 1.15, the same 60% reported becomes 69%.
That is why comparing the latest accident year's reported ratio with older ones flatters it.

Two cautions the analysis comments repeat: this history is under five years, so there is no tail
factor beyond the oldest age; and catastrophe years develop differently, so actuaries often pick
factors without them.

## 8. What the tests guarantee

| Test | What it proves |
|---|---|
| `assert_loss_ratio_earned_premium_matches_premium_mart` | both loss ratio reports carry exactly the premium subledger's earned premium, per period or year and line |
| `assert_loss_ratio_incurred_matches_claims_mart` | the period report ties to `fct_claim_transactions`, the accident-year report to `fct_claim_exposure_period_balances` at valuation: each against a mart it is not built from |
| `assert_frequency_times_severity_equals_pure_premium` | the three ratios use one base, within a rounding bound derived in the test |
| `assert_snapshot_one_current_version_per_key` | no key is current twice |
| `assert_snapshot_versions_are_contiguous` | each key's versions form one timeline without gaps or overlaps |
| `assert_snapshot_current_keys_exist_in_source` (warn) | no current key vanished from the source |
| `assert_pif_as_reported_equals_restated_when_unchanged` | as reported and restated agree wherever nothing relevant changed after the close |

The YAML adds the identities per row: incurred = paid + reserve change, catastrophe +
non-catastrophe = total, and a PIF difference that is fully explained by the counted reasons.
