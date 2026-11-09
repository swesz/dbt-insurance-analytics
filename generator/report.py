"""A calibration summary of the generated book, printed after each run.

It reads the in-memory records and the subledger, so it can be compared with what dbt computes.
Loss ratios here are accident-year case-incurred loss at the valuation date divided by calendar
year earned premium; recent years are still immature (unreported claims, BI reserves that will
develop upward), so they read lower than their ultimate.
"""

from __future__ import annotations

import datetime as dt

from .claims import ClaimsBook
from .controls import LOBS, Subledger, loss_development
from .policies import PolicyBook


def build_summary(policy_book: PolicyBook, claims_book: ClaimsBook, sub: Subledger, valuation: dt.date) -> dict:
    years = sub.years
    summary: dict = {}
    regular = [p for p in policy_book.policies if p.terms and not p.is_test]
    summary["new_business_by_year"] = {
        y: {lob: sum(1 for p in regular if p.lob == lob and p.bind_date.year == y) for lob in LOBS} for y in years
    }
    summary["terms_by_start_year"] = {
        y: {lob: sum(1 for t in policy_book.terms if not t.policy.is_test and t.policy.lob == lob and t.start.year == y)
            for lob in LOBS}
        for y in years
    }
    claims = [c for c in claims_book.claims if not c.is_test and c.kind != "DUPLICATE"]
    summary["claims_by_accident_year"] = {
        y: {lob: sum(1 for c in claims if c.lob == lob and c.loss_date.year == y) for lob in LOBS} for y in years
    }

    def by_year(metric):
        out = {y: {lob: 0 for lob in LOBS} for y in years}
        for p, period in enumerate(sub.periods):
            for lob in LOBS:
                out[period.start.year][lob] += int(sub.by_period[metric][lob][p])
        return out

    written, earned = by_year("written_premium"), by_year("earned_premium")
    summary["written_premium_by_year"] = {y: {lob: written[y][lob] / 100 for lob in LOBS} for y in years}
    summary["earned_premium_by_year"] = {y: {lob: earned[y][lob] / 100 for lob in LOBS} for y in years}

    cat_incurred = {y: {lob: 0 for lob in LOBS} for y in years}
    for c in claims:
        if c.cat_code:
            for t in c.transactions:
                if t.cost_category != "LOSS":
                    continue
                sign = -1 if t.transaction_type == "RECOVERY" else 1
                if t.transaction_type == "PAYMENT" and t.voided_at is not None:
                    continue
                cat_incurred[c.loss_date.year][c.lob] += sign * t.amount
    incurred = sub.by_accident_year["incurred_loss"]
    summary["loss_ratio"] = {
        y: {lob: round(100 * incurred[lob][y] / earned[y][lob], 1) if earned[y][lob] else None for lob in LOBS}
        for y in years
    }
    summary["loss_ratio_ex_cat"] = {
        y: {lob: round(100 * (incurred[lob][y] - cat_incurred[y][lob]) / earned[y][lob], 1) if earned[y][lob] else None
            for lob in LOBS}
        for y in years
    }
    pif_index = {p.code: i for i, p in enumerate(sub.periods)}
    summary["pif_year_end"] = {}
    for y in years:
        code = f"{y}-12" if f"{y}-12" in pif_index else sub.periods[-1].code
        summary["pif_year_end"][code] = {lob: int(sub.by_period["policies_in_force_end"][lob][pif_index[code]]) for lob in LOBS}

    valuations = [dt.date(y, 12, 31) for y in years if dt.date(y, 12, 31) < valuation] + [valuation]
    labels = [v.isoformat() for v in valuations]
    for name, coverages in (("development_bi", {"BI"}), ("development_home_property", {"DWELLING", "CONTENTS"})):
        dev = loss_development(claims_book, coverages, valuations)
        summary[name] = {
            "valuations": labels,
            "accident_years": {y: [round(v / 100) for v in dev.get(y, [0] * len(valuations))] for y in years},
        }
    return summary


def format_summary(summary: dict) -> str:
    lines = []

    def table(title, data, fmt="{:>12,}"):
        lines.append(title)
        lines.append(f"  {'':8}" + "".join(f"{lob:>14}" for lob in LOBS))
        for key, row in data.items():
            cells = "".join(f"{'-':>14}" if row[lob] is None else f"{fmt.format(row[lob]):>14}" for lob in LOBS)
            lines.append(f"  {str(key):8}{cells}")

    table("New business policies by bind year", summary["new_business_by_year"])
    table("Terms by start year", summary["terms_by_start_year"])
    table("Claims by accident year", summary["claims_by_accident_year"])
    table("Written premium by year ($)", summary["written_premium_by_year"], "{:>12,.0f}")
    table("Earned premium by year ($)", summary["earned_premium_by_year"], "{:>12,.0f}")
    table("Loss ratio, AY incurred / CY earned (%)", summary["loss_ratio"], "{:>8.1f}")
    table("Loss ratio excluding catastrophes (%)", summary["loss_ratio_ex_cat"], "{:>8.1f}")
    table("Policies in force at year end", summary["pif_year_end"])
    for name in ("development_bi", "development_home_property"):
        dev = summary[name]
        lines.append(f"{name}: case incurred ($) by accident year at " + ", ".join(dev["valuations"]))
        for year, values in dev["accident_years"].items():
            lines.append(f"  {year}: " + "  ".join(f"{v:>12,}" for v in values))
    return "\n".join(lines)
