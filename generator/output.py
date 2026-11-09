"""Write the simulation to data/generated/ in the intermediate "version" form.

Every mutable source row is written once per version, so the loader can rebuild the sources at
any point in time:

- policy_admin and billing tables (Fivetran-style in raw) carry every version of each row plus
  `_version_at` (when the source row changed) and `_is_deleted`. The loader keeps the latest
  version per key that a sync had picked up by --as-of, and derives _fivetran_synced from
  `_version_at`.
- claims tables (Rivery CDC in raw) already are a change log; they are written with the CDC
  metadata, including the planted duplicate versions, and the loader keeps the versions loaded
  by --as-of.
- the general ledger is written as the CSV files the ERP exports (gl/), plus gl_files.parquet
  listing each file's period and modification time.
- control_totals.parquet and planted_issues.parquet are the answer key; metadata.json records the
  seed, scale and valuation date.

Money is written as decimal(12, 2), billing amounts as integer cents, as in the raw contract.
"""

from __future__ import annotations

import datetime as dt
import json
import shutil
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from .billing import BillingBook
from .claims import ClaimsBook
from .config import Config
from .defects import add_rivery_metadata
from .ledger import Ledger, write_ledger_files
from .money import cents_to_arrow
from .policies import PolicyBook
from .rand import Rng
from .timeline import next_sync

TS = pa.timestamp("us")
MONEY = "money"


def table_from_rows(schema: list[tuple[str, object]], rows: list) -> pa.Table:
    columns = list(zip(*rows)) if rows else [[] for _ in schema]
    arrays = []
    for (name, typ), values in zip(schema, columns):
        if typ == MONEY:
            arrays.append(cents_to_arrow(list(values)))
        elif typ == "decimal18":
            arrays.append(pa.array(list(values), type=pa.decimal128(18, 2)))
        else:
            arrays.append(pa.array(list(values), type=typ))
    return pa.Table.from_arrays(arrays, names=[name for name, _ in schema])


VERSION_COLUMNS = [("_version_at", TS), ("_is_deleted", pa.bool_())]
CDC_COLUMNS = [("_rivery_last_update", TS), ("_rivery_run_id", pa.string()), ("_rivery_river_id", pa.string())]


def policy_admin_tables(book: PolicyBook) -> dict[str, tuple[list, list]]:
    tables = {}

    rows = []
    for h in book.holders:
        for version_at, updated_at, zip_code, deleted in h.versions:
            rows.append((h.policyholder_id, h.first_name, h.last_name, h.date_of_birth, h.email, h.state,
                         zip_code, h.created_at, updated_at, version_at, deleted))
    tables["policyholders"] = ([
        ("policyholder_id", pa.int64()), ("first_name", pa.string()), ("last_name", pa.string()),
        ("date_of_birth", pa.date32()), ("email", pa.string()), ("address_state", pa.string()),
        ("address_zip", pa.string()), ("created_at", TS), ("updated_at", TS),
    ] + VERSION_COLUMNS, rows)

    rows = []
    for p in book.policies:
        updated = p.created_at
        for version_at, status, deleted in p.versions:
            if not deleted:
                updated = version_at  # a delete does not change the source row's updated_at
            rows.append((p.policy_id, p.policy_number, p.holder.policyholder_id, p.lob, p.state, p.channel,
                         p.original_effective_date, status, p.created_at, updated, version_at, deleted))
    tables["policies"] = ([
        ("policy_id", pa.int64()), ("policy_number", pa.string()), ("policyholder_id", pa.int64()),
        ("line_of_business", pa.string()), ("risk_state", pa.string()), ("sales_channel", pa.string()),
        ("original_effective_date", pa.date32()), ("policy_status", pa.string()), ("created_at", TS),
        ("updated_at", TS),
    ] + VERSION_COLUMNS, rows)

    rows = []
    for t in book.terms:
        for version_at, status, cancel_date, reason, written in t.versions:
            rows.append((t.term_id, t.policy.policy_id, t.term_number, t.start, t.expiration, t.policy.billing_plan,
                         status, cancel_date, reason, written, t.created_at, version_at, version_at, False))
    tables["policy_terms"] = ([
        ("term_id", pa.int64()), ("policy_id", pa.int64()), ("term_number", pa.int32()),
        ("term_effective_date", pa.date32()), ("term_expiration_date", pa.date32()),
        ("billing_plan", pa.string()), ("term_status", pa.string()),
        ("cancellation_effective_date", pa.date32()), ("cancellation_reason", pa.string()),
        ("term_written_premium", MONEY), ("created_at", TS), ("updated_at", TS),
    ] + VERSION_COLUMNS, rows)

    rows, line_rows = [], []
    line_id = 0
    for x in book.transactions:
        rows.append((x.transaction_id, x.term.policy.policy_id, x.term.term_id, x.transaction_type,
                     x.transaction_date, x.effective_date, x.written, x.created_at, x.created_at, False))
        for coverage, cents in x.lines:
            line_id += 1
            line_rows.append((line_id, x.transaction_id, coverage, cents, x.created_at, False))
    tables["policy_transactions"] = ([
        ("transaction_id", pa.int64()), ("policy_id", pa.int64()), ("term_id", pa.int64()),
        ("transaction_type", pa.string()), ("transaction_date", pa.date32()), ("effective_date", pa.date32()),
        ("written_premium", MONEY), ("created_at", TS),
    ] + VERSION_COLUMNS, rows)
    tables["policy_transaction_lines"] = ([
        ("transaction_line_id", pa.int64()), ("transaction_id", pa.int64()), ("coverage_code", pa.string()),
        ("written_premium", MONEY),
    ] + VERSION_COLUMNS, line_rows)

    vehicles, dwellings = [], []
    ordered = sorted((p for p in book.policies if p.terms), key=lambda p: (p.created_at, p.policy_id))
    for p in ordered:
        for model_year, make, body in p.vehicles:
            vehicles.append((len(vehicles) + 1, p.policy_id, model_year, make, body, p.created_at, p.created_at, False))
        if p.dwelling is not None:
            year_built, construction, square_feet, coverage_a = p.dwelling
            dwellings.append((len(dwellings) + 1, p.policy_id, year_built, construction, square_feet, coverage_a,
                              p.created_at, p.created_at, False))
    tables["vehicles"] = ([
        ("vehicle_id", pa.int64()), ("policy_id", pa.int64()), ("model_year", pa.int32()), ("make", pa.string()),
        ("body_type", pa.string()), ("created_at", TS),
    ] + VERSION_COLUMNS, vehicles)
    tables["dwellings"] = ([
        ("dwelling_id", pa.int64()), ("policy_id", pa.int64()), ("year_built", pa.int32()),
        ("construction_type", pa.string()), ("square_feet", pa.int32()), ("coverage_a_limit", MONEY),
        ("created_at", TS),
    ] + VERSION_COLUMNS, dwellings)
    return tables


def billing_tables(billing: BillingBook) -> dict[str, tuple[list, list]]:
    rows = []
    for i in billing.installments:
        for version_at, due in i.versions:
            rows.append((i.installment_id, i.txn.term.policy.policy_id, i.txn.term.term_id, i.txn.transaction_id,
                         i.number, due, i.amount, i.created_at, version_at, version_at, False))
    installments = ([
        ("installment_id", pa.int64()), ("policy_id", pa.int64()), ("term_id", pa.int64()),
        ("transaction_id", pa.int64()), ("installment_number", pa.int32()), ("due_date", pa.date32()),
        ("amount_cents", pa.int64()), ("created_at", TS), ("updated_at", TS),
    ] + VERSION_COLUMNS, rows)
    rows = []
    for p in billing.payments:
        base = (p.payment_id, p.policy.policy_id, p.received_at, p.amount, p.method)
        rows.append(base + ("SETTLED", None, p.received_at, p.received_at, p.received_at, False))
        if p.returned_at is not None:
            rows.append(base + ("RETURNED", p.returned_at, p.received_at, p.returned_at, p.returned_at, False))
    payments = ([
        ("payment_id", pa.int64()), ("policy_id", pa.int64()), ("received_at", TS), ("amount_cents", pa.int64()),
        ("payment_method", pa.string()), ("payment_status", pa.string()), ("returned_at", TS),
        ("created_at", TS), ("updated_at", TS),
    ] + VERSION_COLUMNS, rows)
    return {"installments": installments, "payments": payments}


def claims_rows(claims_book: ClaimsBook, legacy: dict[str, str], upgrade: dt.datetime) -> dict[str, tuple[list, list]]:
    """CDC version rows before the Rivery metadata is added: {table: (column schema, rows)}."""
    claims = []
    for c in claims_book.claims:
        for updated_at, status, closed_at, deleted in c.versions:
            shown = legacy[status] if updated_at < upgrade else status
            claims.append([c.claim_id, c.claim_number, c.typed_policy_number, c.loss_date, c.reported_at,
                           c.typed_cause, c.typed_state, c.cat_code, shown, closed_at, c.adjuster_id,
                           updated_at, deleted])
    exposures = []
    for c in claims_book.claims:
        for e in c.exposures:
            if e.opened_at is None:
                continue  # opens after the valuation date
            for updated_at, status, closed_at, deleted in e.versions:
                exposures.append([e.exposure_id, c.claim_id, e.coverage, e.claimant_type, status, e.opened_at,
                                  closed_at, updated_at, deleted])
    transactions = []
    for t in claims_book.transactions:
        base = [t.claim_transaction_id, t.claim.claim_id, t.exposure.exposure_id, t.transaction_type,
                t.cost_category, t.expense_type, t.reserve_reason, t.amount, t.transaction_date]
        transactions.append(base + ["POSTED", None, t.created_at, t.created_at, False])
        if t.voided_at is not None:
            transactions.append(base + ["VOIDED", t.voided_at, t.created_at, t.voided_at, False])
    adjusters = []
    for a in claims_book.adjusters:
        for updated_at, team, active in a.versions:
            adjusters.append([a.adjuster_id, a.name, team, active, a.hired_date, updated_at, False])
    return {
        "claims": ([
            ("claim_id", pa.int64()), ("claim_number", pa.string()), ("policy_number", pa.string()),
            ("loss_date", pa.date32()), ("reported_at", TS), ("loss_cause", pa.string()), ("loss_state", pa.string()),
            ("catastrophe_code", pa.string()), ("claim_status", pa.string()), ("closed_at", TS),
            ("adjuster_id", pa.int64()), ("updated_at", TS), ("__deleted", pa.bool_()),
        ], claims),
        "claim_exposures": ([
            ("exposure_id", pa.int64()), ("claim_id", pa.int64()), ("coverage_code", pa.string()),
            ("claimant_type", pa.string()), ("exposure_status", pa.string()), ("opened_at", TS), ("closed_at", TS),
            ("updated_at", TS), ("__deleted", pa.bool_()),
        ], exposures),
        "claim_transactions": ([
            ("claim_transaction_id", pa.int64()), ("claim_id", pa.int64()), ("exposure_id", pa.int64()),
            ("transaction_type", pa.string()), ("cost_category", pa.string()), ("expense_type", pa.string()),
            ("reserve_reason", pa.string()), ("amount", MONEY), ("transaction_date", pa.date32()),
            ("transaction_status", pa.string()), ("voided_at", TS), ("created_at", TS), ("updated_at", TS),
            ("__deleted", pa.bool_()),
        ], transactions),
        "adjusters": ([
            ("adjuster_id", pa.int64()), ("adjuster_name", pa.string()), ("team", pa.string()),
            ("is_active", pa.bool_()), ("hired_date", pa.date32()), ("updated_at", TS), ("__deleted", pa.bool_()),
        ], adjusters),
    }


def with_cdc_metadata(tables: dict, rng: Rng) -> dict[str, tuple[list, list]]:
    out = {}
    for name, (schema, rows) in tables.items():
        updated_index = [n for n, _ in schema].index("updated_at")
        loaded, _ = add_rivery_metadata(rows, updated_index, f"river_claims_{name}", rng)
        out[name] = (schema + CDC_COLUMNS, loaded)
    return out


def check_visibility(cfg: Config, fivetran: dict, cdc: dict) -> None:
    """Every source change made by the valuation date must be visible in the default load."""
    end = cfg.valuation_end
    for name, (schema, rows) in fivetran.items():
        i = [n for n, _ in schema].index("_version_at")
        latest = max((r[i] for r in rows), default=None)
        assert latest is None or latest <= end, f"{name}: a change after the valuation date"
        assert latest is None or next_sync(latest) <= end, f"{name}: a change the last sync would miss"
    for name, (schema, rows) in cdc.items():
        names = [n for n, _ in schema]
        u, last = names.index("updated_at"), names.index("_rivery_last_update")
        for r in rows:
            assert r[u] <= end, f"claims.{name}: a version after the valuation date"
            if r[last] > end:
                # Only planted rerun duplicates may arrive after the as-of; the first copy of
                # every version is loaded within 90 minutes, during the same evening.
                assert r[last] - r[u] > dt.timedelta(minutes=90), f"claims.{name}: late first load"


def write_all(cfg: Config, out_dir: Path, policy_book: PolicyBook, billing: BillingBook, cdc: dict,
              ledger: Ledger, control_rows: list, planted: list, extra_files: dict) -> dict[str, int]:
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    counts = {}
    fivetran = {**policy_admin_tables(policy_book), **billing_tables(billing)}
    check_visibility(cfg, fivetran, cdc)
    for name, (schema, rows) in {**fivetran, **cdc}.items():
        pq.write_table(table_from_rows(schema, rows), out_dir / f"{name}.parquet")
        counts[name] = len(rows)

    write_ledger_files(ledger, out_dir)
    pq.write_table(table_from_rows(
        [("file_name", pa.string()), ("accounting_period", pa.string()), ("modified_at", TS)],
        [(f.file_name, f.accounting_period, f.modified_at) for f in ledger.files],
    ), out_dir / "gl_files.parquet")

    pq.write_table(table_from_rows(
        [("metric", pa.string()), ("grain", pa.string()), ("period", pa.string()),
         ("line_of_business", pa.string()), ("value", "decimal18"), ("as_of", TS)],
        control_rows,
    ), out_dir / "control_totals.parquet")
    pq.write_table(table_from_rows(
        [("issue_code", pa.string()), ("source_table", pa.string()), ("record_count", pa.int64()),
         ("description", pa.string())],
        planted,
    ), out_dir / "planted_issues.parquet")

    for name, text in extra_files.items():
        (out_dir / name).write_text(text, encoding="utf-8", newline="\n")

    metadata = {
        "seed": cfg.seed,
        "scale": cfg.scale,
        "valuation_date": cfg.valuation_date.isoformat(),
        "as_of": cfg.valuation_end.isoformat(),
        "row_versions": counts,
    }
    (out_dir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8", newline="\n")
    return counts
