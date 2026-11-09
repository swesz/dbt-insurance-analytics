"""The order of the simulation, from customers to the general ledger."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass

from . import config as C
from .billing import simulate_billing
from .claims import simulate_claims
from .config import Config
from .controls import book_transactions, compute_subledger, control_total_rows
from .defects import count_planted, plant_typing_defects
from .ledger import build_ledger
from .money import format_cents
from .output import claims_rows, with_cdc_metadata, write_all
from .policies import simulate_policies
from .rand import make_rng
from .report import build_summary, format_summary
from .seeds import load_seeds


@dataclass
class Result:
    counts: dict
    planted: list
    summary: dict
    seconds: float


def generate(cfg: Config, verbose: bool = True) -> Result:
    started = time.perf_counter()

    def say(text):
        if verbose:
            print(f"[{time.perf_counter() - started:6.1f}s] {text}", flush=True)

    seeds = load_seeds(cfg.seeds_dir)
    if cfg.valuation_date > seeds.calendar.periods[-1].end:
        raise SystemExit("the valuation date is past the last accounting period in seeds/")

    # 1. Policy administration: customers, policies, terms, premium transactions.
    policy_book = simulate_policies(cfg, seeds, make_rng(cfg.seed, "policies"))
    say(f"policies: {len(policy_book.policies):,} policies, {len(policy_book.terms):,} terms, "
        f"{len(policy_book.transactions):,} transactions")
    # 2. Billing: installments for every transaction, and the payments that settle them.
    billing = simulate_billing(cfg, policy_book, make_rng(cfg.seed, "billing"))
    say(f"billing: {len(billing.installments):,} installments, {len(billing.payments):,} payments")
    # 3. Claims: losses on the in-force terms, catastrophes, and the planted claim defects.
    claims_book = simulate_claims(cfg, seeds, policy_book, make_rng(cfg.seed, "claims"))
    plant_typing_defects(claims_book, make_rng(cfg.seed, "typing"))
    say(f"claims: {len(claims_book.claims):,} claims, {len(claims_book.exposures):,} exposures, "
        f"{len(claims_book.transactions):,} transactions")
    # 4. Subledger and control totals, then the ledger built from the same subledger.
    book_transactions(seeds, policy_book, claims_book)
    sub = compute_subledger(cfg, seeds, policy_book, claims_book, billing)
    ledger = build_ledger(cfg, seeds, sub, claims_book, make_rng(cfg.seed, "ledger"))
    say(f"ledger: {len(ledger.files)} files, {sum(len(f.lines) for f in ledger.files):,} lines")
    # 5. CDC metadata (and duplicate versions), planted counts, files.
    cdc = with_cdc_metadata(claims_rows(claims_book, seeds.legacy_status, C.CLAIMS_SYSTEM_UPGRADE),
                            make_rng(cfg.seed, "cdc"))
    planted = count_planted(policy_book, billing, claims_book, ledger,
                            {name: ([n for n, _ in schema], rows) for name, (schema, rows) in cdc.items()},
                            cfg.valuation_end)
    control_rows = control_total_rows(cfg, sub)
    items = ["accounting_period,account_number,line_of_business,amount,item_type,explanation"]
    for period, account, lob, cents, item_type, why in ledger.reconciling_items:
        items.append(f"{period},{account},{lob},{format_cents(cents)},{item_type},{why}")
    summary = build_summary(policy_book, claims_book, sub, cfg.valuation_date)
    extra = {
        "gl_reconciling_items_expected.csv": "\n".join(items) + "\n",
        "summary.json": json.dumps(summary, indent=2, default=str) + "\n",
    }
    counts = write_all(cfg, cfg.out_dir, policy_book, billing, cdc, ledger, control_rows, planted, extra)
    seconds = time.perf_counter() - started
    say(f"wrote {len(counts)} tables to {cfg.out_dir.as_posix()}")
    if verbose:
        print(format_summary(summary))
        print("Planted issues:")
        for code, table, count, _ in planted:
            print(f"  {code:28} {table:36} {count:>8,}")
        print(f"generated in {seconds:.1f}s")
    return Result(counts, planted, summary, seconds)
