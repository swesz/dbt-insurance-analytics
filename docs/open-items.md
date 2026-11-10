# Open items

Questions that are still open, and known limitations found in the reviews that are not fixed
yet. Decisions are in [decisions.md](decisions.md), planted source defects in
[data-issues.md](data-issues.md). Tags: [V] verified, [E] estimate.

## Open questions

IDs are permanent and never reused. Answered questions stay in the list.

- Q-006: On an as-of load earlier than the valuation date (`python -m loader --as-of
  2025-06-05T23:59:59`), the data stops at the as-of, but `load_info.valuation_date`, and with
  it every model, stays at the generator's date, as the old var did (D-024). The close
  simulation only snapshots those loads, so nothing built today is affected. Should the models
  value at `least(valuation_date, cast(as_of as date))` so that a full build on a replay is
  consistent? The control-total tests skip such loads, so this would need its own check. Open.
- Q-005: The README's list of BigQuery sandbox limits was confirmed only by Google's 2019 launch
  post. Answered (2026-11-09): Google's current
  [sandbox page](https://docs.cloud.google.com/bigquery/docs/sandbox) lists all four: no DML
  statements, streaming or Data Transfer Service; tables, views and partitions expire after 60
  days; a lifetime 10 GiB storage limit, "not refunded upon data deletion" [V]. The page names
  DML only as a category, so the README now gives MERGE, UPDATE and DELETE as examples.
- Q-004: CLAUDE.md said known defects are tested "with `severity: warn` and thresholds", but
  with `severity: warn` dbt never evaluates `error_if`, so such a test can never fail. Answered
  (2026-11-09): the code was right (`severity: error` with `warn_if` and `error_if`), and
  CLAUDE.md now says so.
- Q-003: Concerned the owner's other GitHub repositories, not this project. Answered
  2026-11-08.
- Q-002: License. Answered (2026-11-08): MIT, copyright under the GitHub handle (`LICENSE`).
- Q-001: The README paragraph "How this was built" speaks in the owner's voice. Answered
  (2026-11-08, confirmed 2026-11-09): keep it.

## Known limitations

Low risk, not fixed. Each one says what would go wrong and when.

### Premium
- `coverage_start_date` and `coverage_end_date` mean the earning window in the line models but
  the coverage period in `dim_policy_terms`.
- The data has no cancellation or reinstatement booked after a close.
- The date columns `date_day` and `date_of_birth` break the `_date` naming rule.
- `fct_policy_month_end.in_force_term_premium` and `annualized_in_force_premium` are not
  reproducible to the cent. `written_premium * term_days / window_days` divides a DECIMAL, which
  DuckDB returns as DOUBLE, so the sum depends on the parallel summation order, and a term whose
  exact value is a half cent rounds either way (term 53650: exactly 468.835, summed as
  468.83499...). Two builds of the same code on the same data differed by 0.01 in 1 to 3 terms;
  every other column and table was identical, and every build passed [V, 2026-11-09]. Likely
  fix: keep the division in DECIMAL, or round per line before summing [E].

### Claims
- The generator checks a catastrophe loss against the policy term only at the event start, so
  roughly one seed in 5 to 8 could fail the planted-count test [E]. Not seen at seed 42.

### Accounting
- Every recovery is posted to account 5050, so an expense recovery would be misposted (see the
  comment in `int_accounting__subledger_postings`).
- The aging test fails if no reinstated policy is paid up. 99 qualify at scale 1.0, so only a
  very small `--scale` could fail it.
- The generator's `gl_reconciling_items_expected.csv` has no `source_system` column;
  `generator/README.md` says so.
- `seeds/gl_reconciling_items.csv` fits the default run only. Data generated with
  `--valuation-date 2026-03-31` plants a different 2025-08 claims timing item (auto 5000
  -15,993.24 instead of -11,926.78, plus 5200 and home lines), so
  `assert_reconciliation_has_no_unexplained_difference` fails with 12 rows, each equal to the
  generator's planted item [V, 2026-11-09]. Every other test passes on that data.
