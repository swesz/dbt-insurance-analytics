# dbt-insurance-analytics

![ci](https://github.com/swesz/dbt-insurance-analytics/actions/workflows/ci.yml/badge.svg)

An analytics engineering project for a fictional US personal lines insurer (private passenger
auto and homeowners, 2022 to 2026). Four source systems arrive the way real loaders deliver them,
with the defects real data has. dbt turns them into premium, claims, accounting and actuarial
marts. Every key figure is reconciled to a general ledger and to control totals computed
independently in Python.

Everything runs locally on DuckDB in a few minutes, with no account and no cost, and CI rebuilds
it from scratch on every push.

<!-- RESULTS -->

## What is in it

| Area | What the models do |
|---|---|
| Sources | Policy administration and billing (Fivetran-style: current state, soft deletes), claims (Rivery-style append-mode CDC: one row per change), general ledger (monthly CSV exports, all text). See [docs/source-systems.md](docs/source-systems.md). |
| Data quality | 20 planted defects: test policies in production, CDC duplicates, deleted claims, legacy status codes, malformed policy numbers, orphans, late-entered and backdated transactions, voided and returned payments, a re-exported ledger file, a number format change. Each one is handled and tested. See [docs/data-issues.md](docs/data-issues.md). |
| Premium | Written premium by booked accounting period, earned and unearned premium, policies in force, in-force premium, earned exposure. |
| Claims | Case reserves with payment erosion, net paid, incurred, void reversals in the void period, reopened claims, claim and exposure balances per month, loss development triangles. |
| Accounting | Subledger-to-GL postings, a reconciliation with documented reconciling items, a trial balance, unearned premium and loss reserve rollforwards, premium receivable and aging. |
| Actuarial | Calendar-period and accident-year loss ratios with and without catastrophes, frequency and severity, chain-ladder development factors. |
| History | Snapshots of overwritten source rows, and a month-end close simulation that compares "as reported at close" with "restated today". |

dbt features used: sources with freshness, seeds, staging / intermediate / marts layers, views,
tables and an incremental model, YAML-configured snapshots, generic and singular tests with
warn thresholds, unit tests, model contracts, exposures, analyses, macros, a custom
`generate_schema_name`, and separate raw / dev / prod databases.

## Architecture

```mermaid
flowchart LR
    gen["generator<br/>(Python, seeded)"] --> files["data/generated<br/>(Parquet)"]
    files --> loader["loader<br/>(as of any date)"]
    loader --> raw[("raw.duckdb<br/>policy_admin · billing<br/>claims · general_ledger")]
    raw --> stg["staging<br/>(views)"]
    raw --> snap["snapshots"]
    seeds["seeds<br/>(reference)"] --> int
    stg --> int["intermediate"]
    int --> core["core<br/>dims"]
    int --> marts["premium · claims<br/>accounting · actuarial"]
    core --> marts
    snap --> marts
    marts --> exp["exposures<br/>close package · reserving · claims ops"]
```

Three databases stand in for three warehouse projects: `raw` is written only by the loader,
`dev` and `prod` only by dbt, and both attach `raw` read-only. Schemas name layers and domains
(`staging`, `core`, `premium`, ...), because the database already names the environment. See
[docs/architecture.md](docs/architecture.md) and [docs/decisions.md](docs/decisions.md).

## Why DuckDB and not BigQuery

The models target a cloud warehouse workflow, but run on DuckDB, because BigQuery without
billing (the sandbox) cannot run this project. Google's
[sandbox page](https://cloud.google.com/bigquery/docs/sandbox) lists these limits:

- no DML statements (MERGE, UPDATE, DELETE);
- no streaming and no Data Transfer Service;
- every table, view and partition expires after 60 days;
- a lifetime 10 GiB storage limit that is not refunded when data is deleted.

| Feature used here | BigQuery sandbox | DuckDB |
|---|---|---|
| Snapshots (`snapshots/`) | no: dbt snapshots run a MERGE | yes |
| Incremental model (`fct_claim_transactions`) | no: dbt-bigquery's merge, insert_overwrite and microbatch strategies all use MERGE | yes |
| History older than 60 days (snapshots, month-end close simulation) | no: tables expire | yes |
| Rebuilding everything on every run | eats into a lifetime storage limit | unlimited |
| Loader-style upserts, soft deletes, CDC in raw | no: needs DML or streaming | yes |
| CI on every push | needs cloud credentials in the repo's secrets | no credentials at all |
| Anyone can clone and run it | needs their own Google Cloud project | `uv sync` and go |

Enabling billing removes the limits, and this volume would likely stay within the free usage
tier, but it requires a payment method, and everyone who clones the repo would need their own
billed project. Moving to BigQuery later is mostly a new profile plus a few date functions; see
[docs/decisions.md](docs/decisions.md) (D-001).

## Quickstart

Requires [uv](https://docs.astral.sh/uv/). From the repo root:

```powershell
uv sync                         # Python 3.14, dbt, DuckDB and its CLI, into .venv
.venv\Scripts\Activate.ps1      # Git Bash / macOS / Linux: source .venv/Scripts/activate or .venv/bin/activate
python -m generator             # simulate 2022-01 .. 2026-09 into data/generated/
python -m loader                # build warehouse/raw.duckdb as the connectors would have left it
dbt deps
dbt build                       # seeds, models, snapshots and every test, into warehouse/dev.duckdb
dbt build --target prod         # the same into warehouse/prod.duckdb
```

Look at the results with the DuckDB CLI (installed into the venv). Attach raw first, since the
staging views read from it:

```powershell
duckdb warehouse/dev.duckdb "ATTACH 'warehouse/raw.duckdb' AS raw (READ_ONLY); select * from accounting.rpt_unearned_premium_rollforward order by accounting_period desc limit 12"
```

Optional: `python scripts/simulate_month_end_closes.py --start 2025-01 --end 2026-09` replays
month-end closes and snapshots after each one, so the snapshots hold real history.

## How the results are checked

A number counts only if something other than the code that produced it agrees with it.

1. **Control totals.** The generator computes written, earned and unearned premium, policies in
   force, paid losses, case reserves and claim counts in Python from its own records. The dbt
   models compute the same figures in SQL from the raw tables, and tests in `tests/` compare them
   per period and line of business.
2. **General ledger.** The ledger's journals are posted from the subledgers at each close. The
   reconciliation model rebuilds those postings from the marts and compares every account, period
   and line. Differences must be documented as reconciling items in
   `seeds/gl_reconciling_items.csv`, or a test fails.
3. **Planted defects.** The generator records how many rows it corrupted; tests check that
   staging removed or flagged exactly that many.
4. **Unit tests** pin the logic most likely to break quietly: the booking rule, the earning
   formula, CDC deduplication, void reversals, ledger amount parsing.

## Repo tour

| Path | What |
|---|---|
| `generator/` | The simulation: policies, renewals, endorsements, cancellations, billing, claims, ledger, defects, control totals |
| `loader/` | Builds `raw.duckdb` as of any moment; `raw_schema.sql` is the raw contract |
| `models/staging/` | One model per source table: rename, cast, normalize, deduplicate, flag |
| `models/intermediate/` | Booking, earning, claim financial events, subledger postings |
| `models/marts/` | `core` dims, `premium`, `claims`, `accounting`, `actuarial` |
| `snapshots/` | History of rows the policy and billing systems overwrite |
| `tests/` | Reconciliations, rollforwards, control totals, planted-defect counts |
| `analyses/` | Chain-ladder development factors |
| `seeds/` | Accounting calendar, coverages, states, loss causes, catastrophe events, GL accounts, reconciling items |
| `docs/` | Specification, decisions, glossary, and a guide per domain |

## Learning path

Start with [docs/insurance-glossary.md](docs/insurance-glossary.md), then follow one domain end
to end:

1. [docs/guide-premium.md](docs/guide-premium.md): from policy transactions to earned premium
   and policies in force.
2. [docs/guide-claims.md](docs/guide-claims.md): from CDC versions to incurred losses and
   triangles.
3. [docs/guide-accounting.md](docs/guide-accounting.md): subledgers, the ledger, reconciliation
   and rollforwards.
4. [docs/guide-snapshots-and-actuarial.md](docs/guide-snapshots-and-actuarial.md): snapshots,
   as-reported versus restated, loss ratios.

## How this was built

This project was built with Claude Code, an AI coding agent, working from the specification in
`docs/` (business rules, raw contract, defect catalog). I direct the work and review what it
produces; commits it drafted carry a `Co-Authored-By` trailer. The reconciliations and control
totals exist partly to make that review trustworthy: generated code has to agree with
independently computed numbers before it counts.

## Roadmap

- A cloud warehouse target (the SQL avoids DuckDB-only features where standard SQL works).
- One real public source next to the generated core, such as flood insurance claims.
- A hosted dbt docs site and a small dashboard on the marts.
- Reinsurance (ceded premium and losses) and IBNR estimates in the marts.
