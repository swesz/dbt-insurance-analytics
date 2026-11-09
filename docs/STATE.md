# Project state (handover)

Written 2026-11-08 when the first build session handed over. Rewrite or delete this file before
the repo becomes public.

## Done and committed
- Scaffold: Python 3.14, dbt-core 1.12.6, dbt-duckdb 1.11.1, DuckDB 2.0.0, dbt_utils 1.4.1.
- Contract and rules: `loader/raw_schema.sql`, `docs/source-systems.md`, `docs/data-issues.md`,
  `docs/architecture.md` (model inventory and who owned what), `docs/decisions.md` (D-001..D-007).
- Seeds, `generate_schema_name`, `booked_accounting_period` (checked on 4 cases), `cents_to_dollars`.
- `scripts/check_public_safety.py` (checked with a positive control: it caught a local path, a
  private email, a blocklisted string and a non-noreply identity) and `.github/workflows/ci.yml`.
- `docs/insurance-glossary.md`; `README.md` draft (the `<!-- RESULTS -->` marker still needs
  verified numbers).
- Premium and claims models, tests and guides: committed by their agents, but validated only
  against an empty raw database so far.

## In flight at handover
Five background agents were still running. Each commits its own work; their final reports went
to the old session, so judge their results from `git log` and by rerunning everything.

| Agent | Owns | Finishes when |
|---|---|---|
| generator (done) | `generator/`, `loader/` (not `raw_schema.sql`), exact counts in `docs/data-issues.md` | done: `warehouse/RAW_READY` exists |
| premium (done) | `models/staging/policy_admin`, `intermediate/premium`, `marts/premium`, policy dims in `marts/core`, `tests/premium`, `docs/guide-premium.md` | validated against real data |
| claims (done) | `models/staging/claims`, `intermediate/claims`, `marts/claims`, claim dims, the triangle, `analyses/`, `tests/claims`, `docs/guide-claims.md` | same |
| accounting (done) | `models/staging/billing`, `staging/general_ledger`, `intermediate/accounting`, `marts/accounting`, `tests/accounting`, `seeds/gl_reconciling_items.csv`, `docs/guide-accounting.md` | reconciliation has no unexplained differences |
| actuarial + snapshots (done) | `marts/actuarial` (not the triangle), `snapshots/`, `models/exposures.yml`, `tests/actuarial`, `scripts/simulate_month_end_closes.py`, `docs/guide-snapshots-and-actuarial.md` | simulation shows real snapshot history |

## Generator results (from its final report; not yet rechecked by anyone else)
- Done: `warehouse/raw.duckdb` loaded at the default as-of, `warehouse/RAW_READY` created.
  Generator 13 s, loader 4 s at scale 1.0. `pytest`: 18 passed. Two runs gave identical data.
- Volume (seed 42): 24,316 policies, 68,558 terms, 290,285 transaction lines, 352,980
  installments, 299,262 payments, 4,477 claims (8,597 CDC rows), 44,206 claim transactions,
  1,822 GL lines. PIF at 2026-09: 8,784 auto and 6,460 home.
- Exact planted counts are in `docs/data-issues.md` and `raw.generator_audit.planted_issues`.
- Deviations from `docs/source-systems.md`, to document there:
  - home premium is about $1,270–1,720 a year, not $1,800, so the home loss ratio lands in range;
  - renewals are written 30 days before the term starts;
  - every control total excludes test policies;
  - orphan claims have no financial transactions;
  - the 2025-08 timing issue moves payments only, not their reserve erosion;
  - voided payments are reissued as a new payment.
- Accepted: auto accident-year loss ratio of 87% in 2023 (BI claim-count noise, +2.6σ) and 58% in
  2025 (immature), against the 60–75% target. Home excluding catastrophes is 52–65% in every year.
- The generator's expected reconciling items are in
  `data/generated/gl_reconciling_items_expected.csv`. Do not copy them into the seed: the
  accounting agent documents what its reconciliation finds, and the expected file is used
  afterwards only to check that.

## Premium results (from its final report)
- Its slice builds 218 nodes, all passing. Written, earned, unearned and PIF control totals
  match the generator to the cent in all 114 period × LOB rows, and an independent Python
  re-implementation agrees with both for the periods it checked.
- Fixed during validation: month-end rows with 0 covered days on flat-cancelled terms, and
  0 exposure units for policies keyed in late.
- Own definitions, to review: `in_force_term_premium` and `annualized_in_force_premium`.
- Run its slice with `--indirect-selection=cautious`, so tests from other domains don't run in a
  partial dev file.

## Claims results (from its final report)
- Its slice builds 316 nodes: 314 pass and 2 warn, the planted LOSS_OUTSIDE_TERM (13) and
  ORPHAN_CLAIMS (5) at their exact counts. Period and accident-year control totals match the
  generator to the cent, and every planted count matches.
- Incremental check: full refresh and incremental runs give identical results; a 3-day lookback
  restored deleted late rows.
- To review: `is_loss_outside_term` is null for the orphans. Warn tests use
  `severity: error` with `warn_if`/`error_if`, because with `severity: warn` dbt never applies
  `error_if`.

## Actuarial and snapshot results (from its final report)
- Its 100 nodes pass. The simulation ran 2025-01..2026-09 in 201 s: 32,557 terms, 861
  policyholders and 257 payments have more than one snapshot version.
- As-reported PIF differs from restated in 32 of 42 period × LOB rows (late new business, late
  cancellations, reinstatements). A raw load as of the 2025-06 close counts AUTO 6,337 and
  HOME 4,460, equal to the model's as-reported figures.
- A full-project build in its dev file showed 3 accounting test errors while the accounting agent
  was still working: recheck once accounting reports.
- After any regeneration, rerun the simulation with `--fresh`.

## Accounting results (from its final report), and status after all five agents
- Full project build, run by the accounting agent: 786 pass, 2 warn (the planted claims
  defects), 0 error. The reconciliation has 1,344 rows: 1,338 MATCHED and 6 EXPLAINED, which are
  the planted 2024-06 reclass and the 2025-08/09 timing item.
- The agent's 6 reconciling items equal the generator's expected list exactly [V, coordinator].
- Fixed upstream: `cents_to_dollars` returned DOUBLE, and now returns DECIMAL.
- All five agents finished. No agent is running any more.
- Wording: the generator used a term from the external blocklist for home policies bought by
  auto customers. It is renamed in the current files, but earlier commits still contain it, so
  the public-safety scan fails on history until the history is rewritten or squashed before the
  first push (owner's choice). Run the scan to see the affected blobs.

## Next steps, in order
1. Confirm every agent has finished: `warehouse/RAW_READY` exists, the commits have stopped,
   and no `python` or `dbt` processes are left running.
2. Verify from scratch: `uv sync`, `pytest`, `python -m generator`, `python -m loader`,
   `dbt deps`, `dbt build`, and `dbt build --target prod`. Every test must pass or be a documented
   warn. The control-total tests, the GL reconciliation (no UNEXPLAINED rows) and the
   rollforwards must pass.
3. Delete the per-agent leftovers, which are all gitignored: `warehouse/dev_*.duckdb`,
   `raw_empty.duckdb`, `raw_sim.duckdb`, `target_*/` and `logs_*/`.
4. Have someone not anchored on the build review the SQL against `docs/source-systems.md`. The
   earning and claim-event models were reviewed once and looked right.
5. README: fill in the results with verified numbers and check that every link resolves.
6. Run `python scripts/check_public_safety.py` (its blocklist is outside the repo).
7. Push: gh 2.103.3 is installed but not logged in. The owner runs `gh auth login`, then
   `gh repo create swesz/dbt-insurance-analytics --private --source . --push`. The repo becomes
   public only after the owner has reviewed it on GitHub.

## Owner decisions (2026-11-08)
DuckDB only, newest versions. Three databases: raw, dev, prod. Generated data with planted
issues at realistic volume. Repo name `dbt-insurance-analytics`. Keep the Co-Authored-By
trailers and a README paragraph on how the project was built. GitHub CLI only. Private first.

## Questions answered by the owner
- Q-001: The README paragraph "How this was built" speaks in the owner's voice. Answer
  (2026-11-08): keep it for now; the owner reviews it with the rest before going public.
- Q-002: License. Answer (2026-11-08): MIT, copyright under the GitHub handle (`LICENSE`).
- Q-003: Other public repos on the profile. Answer (2026-11-08): make `test01_employee_api` and
  `test02_hr_ext-api` private before the link goes out; the machine-learning repo stays public.
  This needs `gh auth login` first, then
  `gh repo edit swesz/<repo> --visibility private --accept-visibility-change-consequences`
  for each of the two, or the owner does it in the GitHub settings.

## Working pattern for parallel jobs
Give each job its own files: `DBT_DUCKDB_DEV_PATH=warehouse/dev_<name>.duckdb`,
`DBT_TARGET_PATH=target_<name>`, `DBT_LOG_PATH=logs_<name>`, and, when it needs different raw
data, `DBT_DUCKDB_RAW_PATH`. Local-only rules are in `CLAUDE.local.md` (gitignored).
