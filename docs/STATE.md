# Project state (handover)

Second handover, written 2026-11-08 when the verification and review session stopped at its
context limit. Rewrite or delete this file before the repo becomes public.

## Verified in this session [V]
- History: the blocklisted term was removed from every commit with `git filter-repo
  --replace-text` (5 literal swaps that reproduce the wording HEAD already had). An independent
  script checked the rewrite: 43 commits, identical authors, dates and messages, HEAD tree
  byte-identical, only the 5 affected files changed. The public-safety scan over the full history
  reports 0 errors. The pre-rewrite history is kept as a single-file git backup in `~/backups/`
  (outside the repo; restore with `git clone <file>`). The in-repo backup branch the owner asked
  for was deleted after that file was verified, because the scanner reads every ref and would
  always fail on it, and because `git push --all` would publish it.
- From scratch, before the review fixes: `uv sync`, `pytest` (18 passed), generator, loader,
  `dbt build` (dev) and `dbt build --target prod`: each 786 pass, 2 warn, 0 error. The warns are
  the planted LOSS_OUTSIDE_TERM (13) and ORPHAN_CLAIMS (5). The generator writes byte-identical
  files on two runs. `dbt docs generate` works. The simulation (21 closes, 202 s) reproduced the
  snapshot history exactly (32,557 terms, 861 policyholders, 257 payments with history).
- Independent checks against raw, in SQL written separately from the models: all-time written
  premium equals the mart to the cent; earned + unearned - written = 0.00; GL reconciliation
  1,344 rows, 1,338 MATCHED, 6 EXPLAINED, 0 UNEXPLAINED; PIF as reported at the 2025-06 close and
  restated (6,522 / 6,524 AUTO) recounted from an as-of load by rule 3e.
- The earlier "32 of 42" as-reported rows was wrong: 26 rows differ (27 have any restatement).
- CI: `astral-sh/setup-uv@v10` did not exist (setup-uv publishes no moving major tag); pinned to
  `v10.3.3`. `actions/checkout@v7` and `actions/upload-artifact@v7` exist. `uv lock --check` ok.

## Changes committed this session
- Spec: the generator's deviations from the targets (source-systems.md 4a), each checked.
- Guard test `tests/generator_audit/assert_control_totals_cover_the_valuation_load.sql`: the
  control-total tests skip comparing when as_of differs, so a drifted default load would have
  made them all pass. Positive control: fails with as_of off by 1 second.
- README results section, filled with verified numbers (some need updating, see below).
- Three independent reviewers (premium, claims, accounting/actuarial) compared the SQL with the
  spec. Premium fixes (D-017 in-force premium, D-018 exact control totals, an overlap test, doc
  fixes) and claims fixes (D-019 chain ladder from the valuation date, D-020 null
  is_loss_outside_term, tests that could not fail removed or replaced, planted counts counted the
  generator's way) are merged into main. Each fix was checked against an independent query.

## Accounting fixes: finished, NOT merged (branch `worktree-agent-aa978e88b094c9a17`)
Worktree `.claude/worktrees/agent-aa978e88b094c9a17`, 9 commits on c864e48 (c0e2bab .. fb5bfbe).
Its own results, to recheck after merging [U until rechecked]: build with and without snapshot
history, dev and prod: 780 pass, 2 warn (planted), 0 error, 785 total on that branch alone.
pytest 18 passed; scan 0 errors.
- Aging (finding 1): a reinstatement debit is settled by its own term's cancellation credit
  (new `reversed_amount` column), refunds use remaining credits, credits settle their own term
  latest-due first, cash oldest-due first. Policies 1001 and 16789 now fully current. Past due
  176,638.86 -> 131,111.01; reinstated policies past due 82 -> 7 (the 7 are genuinely unpaid).
  New test `assert_aging_shows_nothing_past_due_for_paid_up_policies.sql` (fails with 75 rows on
  the old model). Note: `amount_cents / 100.0` is DOUBLE in DuckDB; compare decimals.
- 16 checks true by construction removed; the rollforward tests now compare with generator
  control totals (a one-cent mutation fails 114-224 rows).
- Reconciliation per source system: 1,570 rows, 1,564 MATCHED, 6 EXPLAINED, 0 UNEXPLAINED
  (POLICY_ADMIN 448, BILLING 224, CLAIMS 896, MANUAL 2); the 6 equal the generator's expected
  items. Seed gained `source_system`: an existing database needs
  `dbt seed --full-refresh -s gl_reconciling_items` once.
- `claim_frequency` counts claims; claimants stay as `claimant_frequency`. Auto BI 2023:
  0.012878 per exposure year (2024: 0.010210), severity 27,716.49 per claim.
- Tolerance macro returns 0. 2026-09 has no as-reported PIF. Aging column renamed
  `open_not_yet_due_amount`. Close-boundary assumption, recoveries to 5050, and skipped-close
  gap documented.
- Decision log entries to write (renumbered; D-017..D-020 are taken):
  - D-015 amended: "... no tolerance: every difference on the default load is 0.00 [V], and a
    one-cent allowance would let a one-cent conversion bug pass. Supersedes 0.01 per row." Accepted.
  - D-016 amended: the four allocation steps above; "pooling per policy showed 75 paid-up
    reinstated policies as past due (45,212.43) while total open was right [V]". Accepted.
  - D-021: Reconcile per source system (1000 and 1200 each receive two systems' journals, so a
    per-account comparison lets one system's error offset another's).
  - D-022: Claim frequency counts claims, severity is per claim (glossary, spec section 4);
    claimants kept because BI limits are per person. Extends D-014.
- Shared-file text it proposed:
  - README General ledger row: "1,570 account x source system x period x line rows (2022-01 to
    2026-08): 1,564 match, 6 are the two documented reconciling items, 0 unexplained, with no
    tolerance".
  - README History row: "21 month-end closes replayed in under 4 minutes; 20 of them (2025-01 to
    2026-08) had closed by the valuation date, and restated policies in force differ from the
    as-reported figure in 26 of their 40 period x line rows, by -1 to +3 policies".
  - README bodily injury sentence: "(1.3 claims per 100 exposure years, against 1.0 in 2024) and
    average severity ($27,700 per claim)".
  - README quickstart: the simulation command needs `--fresh` after a plain `dbt build` (it
    refuses otherwise [V by the agent]). Text: "Optional: `python
    scripts/simulate_month_end_closes.py --start 2025-01 --end 2026-09 --fresh` replays
    month-end closes and snapshots after each one, so the snapshots hold real history. The
    history exists only in the database the script writes, `warehouse/dev.duckdb` by default: a
    plain `dbt build` runs the snapshots once and records no past. To give prod the history,
    add `--dev-path warehouse/prod.duckdb`, then run `dbt build --target prod`."
  - data-issues.md BACKDATED_ENDORSEMENTS "Caught by": "earned and unearned premium control
    totals; GL reconciliation of 4100 and 2100" (the UPR rollforward cannot catch a wrong
    catch-up). Optional: "(source system MANUAL)" on GL_MANUAL_RECLASS, "(source system
    CLAIMS)" on GL_CLAIMS_INTERFACE_TIMING.
  - source-systems.md 3h, optional: "Every journal line carries its `source_system`; the
    reconciliation compares per source system, because 1000 and 1200 each receive two systems'
    journals. Every recovery in the data is a loss recovery and is posted to 5050."
- Merge care: `docs/guide-snapshots-and-actuarial.md` section 5 hunk sits next to the claims
  agent's edit and may conflict. `generator/README.md` (about line 115) says the expected-items
  file has the seed's layout; no longer true (the seed has `source_system`).
- Decision taken: after the merge, drop the accident-year YAML check "incurred = paid + reserve"
  in `_actuarial__models.yml` (true by construction) and replace "catastrophe + non-catastrophe
  = total" with `not_null` on `dim_claims.is_catastrophe`.
- Small-scale risk: the new aging test fails if no reinstated policy is paid up (99 qualify at
  scale 1.0).

## Next steps, in order
1. Accounting branch: review its commits, `git merge --no-ff` it, resolve any guide conflict,
   and apply everything in the section above (decision log, shared-file text, the two YAML
   checks).
2. Remove the worktrees and their branches: `git worktree remove .claude/worktrees/<name>` and
   `git branch -D worktree-agent-<id>` for both agents (claims: aa12b1be805086b06, merged).
   The scanner reads every branch.
3. Verify from scratch again on the merged code: generator, loader, `dbt build`, `dbt build
   --target prod`, then the simulation into separate files (`--raw-path
   warehouse/raw_sim.duckdb --dev-path warehouse/dev_sim.duckdb --fresh`) and a build on them.
4. README: recount the nodes ("792 nodes" is stale: the claims branch alone gives 795 total);
   update the reconciliation rows (new grain), the as-reported row (2026-09 drops out of the
   42), and the bodily injury frequency sentence (the 1.6 per 100 figure counted claimants). Replace
   the last loss-ratio sentence with: "The chain-ladder analysis in `analyses/` projects 2025 to
   ultimate (auto 63%, home 79%) and leaves 2026 unprojected, because that accident year is not
   over (docs/guide-claims.md section 8)." Recheck the guide numbers the claims agent flagged in
   guide-snapshots-and-actuarial.md section 7 if earned premium changed.
5. Delete leftovers (all gitignored): `warehouse/dev_sim.duckdb`, `raw_sim.duckdb`,
   `target_sim/`, `logs_sim/`, and any `dev_fix_*` or `target_*` from the agents.
6. `python scripts/check_public_safety.py` must report 0 errors.
7. Push (see GitHub below). Then check that the first CI run passes.

## GitHub CLI
gh 2.103.3 is installed in `C:\Program Files\GitHub CLI\` and that folder is on the machine
PATH, but VS Code was started before the install, so its terminals still have the old PATH.
Fix: quit VS Code completely (every window) and start it again, or in a running PowerShell
terminal run
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`.
Then the owner runs `gh auth login` (browser flow). Push only main, explicitly:
`gh repo create swesz/dbt-insurance-analytics --private --source . --remote origin`, then
`git push -u origin main`. (`--push` would push "local commits" without naming the refs.)

## Open items from the reviews (not fixed, low risk)
- Premium: `coverage_start_date` / `coverage_end_date` mean the earning window in the line
  models but the coverage period in `dim_policy_terms`; `valuation_date` is a fixed var, not
  read from `load_info`; the data has no cancellation or reinstatement booked after a close;
  date columns `date_day` and `date_of_birth` break the `_date` naming rule.
- Claims: the generator checks a catastrophe loss against the term only at the event start;
  roughly one seed in 5-8 could fail the planted-count test [E]. Not seen at seed 42.
- CLAUDE.md says known defects are tested "with `severity: warn` and thresholds", but with
  `severity: warn` dbt never applies `error_if`; the code correctly uses `severity: error` with
  `warn_if`/`error_if`. Owner to decide on the wording (Q-004).
- README: the BigQuery sandbox's DML restriction is confirmed only by Google's 2019 launch post;
  the current sandbox page could not be fetched in this session (Q-005).

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
- Q-004: CLAUDE.md wording on warn tests (above). Open.
- Q-005: Verify the sandbox's DML limit on the current page before going public. Open.

## Working pattern for parallel jobs
Give each job its own files: `DBT_DUCKDB_DEV_PATH=warehouse/dev_<name>.duckdb`,
`DBT_TARGET_PATH=target_<name>`, `DBT_LOG_PATH=logs_<name>`, and, when it needs different raw
data, `DBT_DUCKDB_RAW_PATH`. Or give an agent its own git worktree (it must generate its own
data there) and merge its branch. When editing files with Python on Windows, pass
`newline="\n"` to `write_text`. Local-only rules are in `CLAUDE.local.md` (gitignored).
