# Project state (handover)

Third handover, written 2026-11-08 after the review fixes were merged and the merged code was
verified from scratch. What is left is the push. Rewrite or delete this file before the repo
becomes public.

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

## Next steps, in order
1. GitHub CLI in VS Code terminals (see below), then the owner runs `gh auth login`.
2. `gh repo create swesz/dbt-insurance-analytics --private --source . --remote origin`, then
   `git push -u origin main`. Do not use `--push` or `git push --all`.
3. Check that the first CI run passes (`gh run list`, `gh run watch`).
4. Q-003: make `test01_employee_api` and `test02_hr_ext-api` private.
5. Before going public: the owner reviews everything (Q-001), Q-004 and Q-005 are answered, and
   this file is deleted or rewritten.

## GitHub CLI
gh 2.103.3 is installed in `C:\Program Files\GitHub CLI\` and is on the machine PATH [V], but
every process started from VS Code before the install, its terminals and Claude Code included,
still has the old PATH, so `gh` is not found there. Either quit VS Code completely (every
window) and start it again, or in each open PowerShell terminal run once:
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`.
Without either, the full path works: `& 'C:\Program Files\GitHub CLI\gh.exe' auth login`.
`gh auth status` reported "not logged in" on 2026-11-08.

## Open items from the reviews (not fixed, low risk)
- Premium: `coverage_start_date` / `coverage_end_date` mean the earning window in the line
  models but the coverage period in `dim_policy_terms`; `valuation_date` is a fixed var, not
  read from `load_info`; the data has no cancellation or reinstatement booked after a close;
  date columns `date_day` and `date_of_birth` break the `_date` naming rule.
- Claims: the generator checks a catastrophe loss against the term only at the event start;
  roughly one seed in 5-8 could fail the planted-count test [E]. Not seen at seed 42.
- Accounting: every recovery is posted to 5050; an expense recovery would be misposted (comment
  in `int_accounting__subledger_postings`). The aging test fails if no reinstated policy is paid
  up (99 qualify at scale 1.0), so a very small `--scale` could fail it.
- The generator's `gl_reconciling_items_expected.csv` has no `source_system` column; the README
  in `generator/` says so.

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
  After `gh auth login`:
  `gh repo edit swesz/<repo> --visibility private --accept-visibility-change-consequences`
  for each of the two, or the owner does it in the GitHub settings.
- Q-004: CLAUDE.md says known defects are tested "with `severity: warn` and thresholds", but
  with `severity: warn` dbt never applies `error_if`; the code correctly uses `severity: error`
  with `warn_if`/`error_if`. Owner to decide on the wording. Open.
- Q-005: The BigQuery sandbox's DML restriction in the README is confirmed only by Google's 2019
  launch post; verify it on the current page before going public. Open.

## Working pattern for parallel jobs
Give each job its own files: `DBT_DUCKDB_DEV_PATH=warehouse/dev_<name>.duckdb`,
`DBT_TARGET_PATH=target_<name>`, `DBT_LOG_PATH=logs_<name>`, and, when it needs different raw
data, `DBT_DUCKDB_RAW_PATH`. Or give an agent its own git worktree (it must generate its own
data there) and merge its branch. A worktree with long build paths may fail `git worktree
remove` with "Filename too long": delete the leftover folder with
`Remove-Item -LiteralPath '\\?\<full path>' -Recurse -Force`. When editing files with Python on
Windows, pass `newline="\n"` to `write_text`. Local-only rules are in `CLAUDE.local.md`
(gitignored).
