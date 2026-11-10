# Project state (handover)

Third handover, written 2026-11-08 after the review fixes were merged and the merged code was
verified from scratch, updated 2026-11-09 with the first pull requests ("Pull requests"). Rewrite or
delete this file before the repo becomes public.

## Done and verified on the merged code [V, 2026-11-08]
- All three review branches (premium, claims, accounting) are merged into main. Their worktrees
  and branches are deleted: main is the only branch, so the scanner and `git push` see nothing
  else.
- From an empty warehouse: `uv sync`, `pytest` (18 passed), generator, loader, `dbt build` (dev)
  and `dbt build --target prod`: each 778 pass, 2 warn, 0 error, 783 nodes, about a minute. The
  warns are the planted LOSS_OUTSIDE_TERM (13) and ORPHAN_CLAIMS (5).
- Close simulation into separate files (`--raw-path warehouse/raw_sim.duckdb --dev-path
  warehouse/dev_sim.duckdb --fresh`): 21 closes in 199 s, the same snapshot history as before
  (32,557 terms, 861 policyholders, 257 payments with more than one version), then a build on
  those files: 778 pass, 2 warn, 0 error. The sim files are deleted again; `warehouse/dev.duckdb`
  now holds a plain build, without snapshot history.
- Independent checks, in scripts written apart from the models:
  - GL: the ledger amount recomputed from raw journal lines (latest file per period, commas
    stripped) equals the report on all 1,570 account x source system x period x line rows;
    1,564 MATCHED, 6 EXPLAINED, 0 UNEXPLAINED; the 6 differences equal the generator's planted
    items exactly.
  - PIF: as-of loads at the 2025-06 and 2026-08 closes, counted by rule 3e, equal the report's
    as-reported and restated figures (2025-06 AUTO 6,522 / 6,524). The report has as-reported
    figures for 40 period x line rows (2025-01 to 2026-08); 26 differ, by -1 to +3. 2026-09 has
    none.
  - Bodily injury: auto BI claims and claimants per accident year counted from raw (2023: 58
    and 73; 2024: 75 and 89) equal the report. 2023 has the highest claim frequency (0.012878)
    and severity (27,716.49).
  - Chain ladder: the analysis reproduces the guide's AUTO 2025 figures to the cent; 2025
    ultimate loss ratios are auto 63.1%, home 78.6%.
- README results, decision log (D-015 and D-016 amended, D-021, D-022), data-issues, spec 3h and
  the guides are updated to these numbers.
- The accident-year identity checks are dropped as true by construction (incurred = paid +
  reserve, catastrophe split, non-catastrophe count <= count). `dim_claims.is_catastrophe`
  already had `not_null`, so nothing replaced them.
- `python scripts/check_public_safety.py`: 0 errors.

## Pushed [V, 2026-11-08]
- `swesz/dbt-insurance-analytics` exists on GitHub, PRIVATE, with main as its only branch
  (remote `origin`). Push main explicitly (`git push`); never `--all`.
- The first CI run (42561363861) passed in 1m09s with the same results as the local run: scan
  0 errors, pytest 18 passed, `dbt build` 778 pass, 2 warn (13, 5), 0 error, 783 nodes.
  GitHub annotated that `ubuntu-latest` is moving to Ubuntu 26 (from 2026-10-19).
- Q-003 done: `test01_employee_api` and `test02_hr_ext-api` are private (neither had stars or
  forks); `Financial-Sentiment-ML-DeepLearning` stays public.

## Pull requests [2026-11-09]
- Changes now go through pull requests: branch, push only that branch, `gh pr create`; the owner
  reviews in written PR comments; address them; merge only after the owner's go-ahead in a PR
  comment and a passing CI run. GitHub does not let a pull request's author approve it, and
  branch protection is not available for a private repo on the free plan (the API returns 403
  [V]), so GitHub enforces neither: its merge button works even with a failing check.
- PR #1, branch `valuation-date-from-load`: the valuation date read from the load (D-024,
  accepted). Verified locally [V]: dev, prod and replayed-close builds 782 pass, 2 warn,
  0 error, 787 nodes; all 61 relations identical to main row by row (prod and the replay differ
  only by the float noise in the open items); on data valued 2026-03-31, 13 of 13 valuation
  checks against raw (main: 1 of 13). The PR description has the full table and both check
  scripts.
- Review of PR #1: the owner gave the go-ahead after a green CI run. D-024 was set to accepted
  on the branch before the merge, so the merge brings it to main; the branch is deleted on
  merge.
- PR #1's first CI runs (42745261423, 42745482373) failed at the public-safety step: a
  `pull_request` run checks out GitHub's merge commit, whose committer is
  `GitHub <noreply@github.com>`, and the scanner then accepted only personal noreply addresses.
  Fixed in PR #2 (merged), which accepts exactly that address. A re-run reuses the run's
  original merge commit, built on main from before #2 (GitHub's documented behavior, not
  tried), so main was merged into the branch instead, which starts a fresh run.
- Rechecked 2026-11-09 on the merge of the branch into main, with GitHub as committer, as CI
  sees it [V]: scan 0 errors; `pytest` 18 passed; `dbt build` 782 pass, 2 warn (13, 5), 0 error,
  787 nodes; on data valued 2026-03-31, 781 pass and only the known reconciliation seed failure
  (12 rows). A separate check script (expected values from `load_info` and the control totals
  only) passed 10 of 10 on both data sets, including claims incurred by accident year, which
  reach the date through the `claims_valuation_period` macro.

## Next steps
1. Before going public: the owner reviews everything (Q-001), Q-004 and Q-005 are answered, and
   this file is deleted or rewritten. Then
   `gh repo edit swesz/dbt-insurance-analytics --visibility public --accept-visibility-change-consequences`.

## GitHub CLI
gh 2.103.3 is installed in `C:\Program Files\GitHub CLI\` and is on the machine PATH [V], but
every process started from VS Code before the install, its terminals and Claude Code included,
still has the old PATH, so `gh` is not found there. Either quit VS Code completely (every
window) and start it again, or in each open PowerShell terminal run once:
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`.
Without either, the full path works: `& 'C:\Program Files\GitHub CLI\gh.exe' auth login`.
Logged in on 2026-11-08 as swesz (keyring), HTTPS, scopes gist, read:org, repo, workflow. The
`workflow` scope is needed to push changes to `.github/workflows/`.

## Open items from the reviews (not fixed, low risk)
- Premium: `coverage_start_date` / `coverage_end_date` mean the earning window in the line
  models but the coverage period in `dim_policy_terms`; the data has no cancellation or
  reinstatement booked after a close; date columns `date_day` and `date_of_birth` break the
  `_date` naming rule. (The fixed `valuation_date` var is replaced by the load's date: D-024.)
- Premium: `fct_policy_month_end.in_force_term_premium` and `annualized_in_force_premium` are
  not reproducible to the cent. `written_premium * term_days / window_days` divides a DECIMAL,
  which DuckDB returns as DOUBLE, so the sum depends on the parallel summation order, and a
  term whose exact value is a half cent rounds either way (term 53650: exactly 468.835, summed
  as 468.83499...). Two builds of the same code on the same data differed by 0.01 in 1 to 3
  terms, every other column and table identical; every build passed [V, 2026-11-09]. Likely
  fix: keep the division in DECIMAL, or round per line before summing [E].
- Claims: the generator checks a catastrophe loss against the term only at the event start;
  roughly one seed in 5-8 could fail the planted-count test [E]. Not seen at seed 42.
- Accounting: every recovery is posted to 5050; an expense recovery would be misposted (comment
  in `int_accounting__subledger_postings`). The aging test fails if no reinstated policy is paid
  up (99 qualify at scale 1.0), so a very small `--scale` could fail it.
- The generator's `gl_reconciling_items_expected.csv` has no `source_system` column; the README
  in `generator/` says so.
- `seeds/gl_reconciling_items.csv` fits the default run only. Data generated with
  `--valuation-date 2026-03-31` plants a different 2025-08 claims timing item (auto 5000
  -15,993.24 instead of -11,926.78, plus 5200 and home lines), so
  `assert_reconciliation_has_no_unexplained_difference` fails with 12 rows; each equals the
  generator's planted item exactly [V, 2026-11-09]. Every other test passes on that data.

## Owner decisions (2026-11-08)
DuckDB only, newest versions. Three databases: raw, dev, prod. Generated data with planted
issues at realistic volume. Repo name `dbt-insurance-analytics`. Keep the Co-Authored-By
trailers and a README paragraph on how the project was built. GitHub CLI only. Private first.

## Questions
- Q-001: The README paragraph "How this was built" speaks in the owner's voice. Answer
  (2026-11-08): keep it for now; the owner reviews it with the rest before going public.
- Q-002: License. Answer (2026-11-08): MIT, copyright under the GitHub handle (`LICENSE`).
- Q-003: Other public repos on the profile. Answer (2026-11-08): make `test01_employee_api` and
  `test02_hr_ext-api` private before the link goes out; the machine-learning repo stays public.
  Done 2026-11-08 [V].
- Q-004: CLAUDE.md says known defects are tested "with `severity: warn` and thresholds", but
  with `severity: warn` dbt never applies `error_if`; the code correctly uses `severity: error`
  with `warn_if`/`error_if`. Owner to decide on the wording. Open.
- Q-005: The BigQuery sandbox's DML restriction in the README is confirmed only by Google's 2019
  launch post; verify it on the current page before going public. Open.
- Q-006: On an as-of load earlier than the valuation date (`python -m loader --as-of
  2025-06-05T23:59:59`), the data stops at the as-of, but `load_info.valuation_date`, and with
  it every model, stays at the generator's date, as the var did (D-024). The close simulation
  only snapshots those loads, so nothing built today is affected. Should the models value at
  `least(valuation_date, cast(as_of as date))` so that a full build on a replay is consistent?
  The control-total tests skip such loads, so this would need its own check. Open.

## Working pattern for parallel jobs
Give each job its own files: `DBT_DUCKDB_DEV_PATH=warehouse/dev_<name>.duckdb`,
`DBT_TARGET_PATH=target_<name>`, `DBT_LOG_PATH=logs_<name>`, and, when it needs different raw
data, `DBT_DUCKDB_RAW_PATH`. Or give an agent its own git worktree (it must generate its own
data there) and merge its branch. A worktree with long build paths may fail `git worktree
remove` with "Filename too long": delete the leftover folder with
`Remove-Item -LiteralPath '\\?\<full path>' -Recurse -Force`. When editing files with Python on
Windows, pass `newline="\n"` to `write_text`. Local-only rules are in `CLAUDE.local.md`
(gitignored).
