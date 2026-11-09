# warehouse/

Local DuckDB databases. Not in git: every file here is rebuilt from code.

| File | Plays the role of | Written by | Read by |
|---|---|---|---|
| `raw.duckdb` | the raw project that Fivetran/Rivery-style loaders write into | `python -m loader` | dbt (attached read-only as `raw`) |
| `dev.duckdb` | the development project | `dbt build` (default target `dev`) | you |
| `prod.duckdb` | the production project | `dbt build --target prod` | reports, exposures |

Each developer (or each parallel agent) can point dev at its own file with the
`DBT_DUCKDB_DEV_PATH` environment variable, the way each BigQuery developer gets a personal
dataset. See `profiles.yml`.
