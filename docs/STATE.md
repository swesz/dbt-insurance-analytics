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
| generator | `generator/`, `loader/` (not `raw_schema.sql`), exact counts in `docs/data-issues.md` | it creates `warehouse/RAW_READY` |
| premium | `models/staging/policy_admin`, `intermediate/premium`, `marts/premium`, policy dims in `marts/core`, `tests/premium`, `docs/guide-premium.md` | validated against real data |
| claims | `models/staging/claims`, `intermediate/claims`, `marts/claims`, claim dims, the triangle, `analyses/`, `tests/claims`, `docs/guide-claims.md` | same |
| accounting | `models/staging/billing`, `staging/general_ledger`, `intermediate/accounting`, `marts/accounting`, `tests/accounting`, `seeds/gl_reconciling_items.csv`, `docs/guide-accounting.md` | reconciliation has no unexplained differences |
| actuarial + snapshots | `marts/actuarial` (not the triangle), `snapshots/`, `models/exposures.yml`, `tests/actuarial`, `scripts/simulate_month_end_closes.py`, `docs/guide-snapshots-and-actuarial.md` | simulation shows real snapshot history |

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
