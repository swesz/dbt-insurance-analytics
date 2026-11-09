"""Control totals: the figures dbt must reproduce, computed here in Python (docs/source-systems.md 5).

This module is the generator's own *subledger*. It applies the business rules of section 3 to the
in-memory records (never to the written files), in integer cents:

- booking (3c): each premium and claim transaction is booked in the first accounting period on
  or after its transaction date that was still open when it was entered;
- earning (3d): each transaction line earns evenly per day over [effective_date, expiration);
  earned premium of a period is the change in inception-to-date (ITD) earned, where the ITD of
  period P counts only lines booked in P or earlier. Each line's ITD is rounded to the cent,
  half away from zero;
- policies in force (3e) at each period end, from the current state of the terms;
- claim payments, recoveries and reserve changes by booked period, with voided payments reversed
  in the period of the void (3f).

Test policies (and their claims) are excluded everywhere; deleted claims have no transactions.
The ledger (generator.ledger) posts these same subledger figures to the GL.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field

import numpy as np

from .billing import BillingBook
from .claims import ClaimsBook
from .config import Config
from .money import cents_to_decimal, round_half_away_np
from .policies import PolicyBook
from .seeds import Seeds

LOBS = ("AUTO", "HOME")


@dataclass
class Subledger:
    periods: list  # Period objects, 2022-01 through the valuation period
    years: list[int]
    # metric -> lob -> numpy int64 array over periods (cents, or counts)
    by_period: dict = field(default_factory=dict)
    # metric -> lob -> {year: value}
    by_accident_year: dict = field(default_factory=dict)
    # claim payments that the 2025-08 claims interface missed (GL_CLAIMS_INTERFACE_TIMING)
    cash_by_month: dict = field(default_factory=dict)


def book_transactions(seeds: Seeds, policy_book: PolicyBook, claims_book: ClaimsBook) -> None:
    """Set the booked accounting period on every premium and claim transaction (3c)."""
    cal = seeds.calendar
    for txn in policy_book.transactions:
        txn.booked = cal.booked_index(txn.transaction_date, txn.created_at)
    for txn in claims_book.transactions:
        txn.booked = cal.booked_index(txn.transaction_date, txn.created_at)
        if txn.voided_at is not None:
            # A void is booked using its timestamp as both the date and the entry time.
            txn.void_booked = cal.booked_index(txn.voided_at.date(), txn.voided_at)


def compute_subledger(cfg: Config, seeds: Seeds, policy_book: PolicyBook, claims_book: ClaimsBook,
                      billing: BillingBook) -> Subledger:
    cal = seeds.calendar
    last = cal.index_of_date(cfg.valuation_date)
    periods = cal.periods[: last + 1]
    n = len(periods)
    years = list(range(periods[0].start.year, cfg.valuation_date.year + 1))
    sub = Subledger(periods=periods, years=years)

    def zeros():
        return {lob: np.zeros(n, dtype=np.int64) for lob in LOBS}

    # -- premium: written, earned, unearned ---------------------------------------------------
    written_cents, effective, expiration, booked, lob_index = [], [], [], [], []
    for txn in policy_book.transactions:
        term = txn.term
        if term.policy.is_test:
            continue
        assert txn.booked <= last, "a transaction was booked after the valuation period"
        for _coverage, cents in txn.lines:
            written_cents.append(cents)
            effective.append(txn.effective_date.toordinal())
            expiration.append(term.expiration.toordinal())
            booked.append(txn.booked)
            lob_index.append(0 if term.policy.lob == "AUTO" else 1)
    wc = np.array(written_cents, dtype=np.int64)
    eff = np.array(effective, dtype=np.int64)
    window = np.array(expiration, dtype=np.int64) - eff
    bk = np.array(booked, dtype=np.int64)
    lob_arr = np.array(lob_index, dtype=np.int64)

    written, earned, unearned = zeros(), zeros(), zeros()
    previous_itd = {lob: 0 for lob in LOBS}
    for p, period in enumerate(periods):
        elapsed = np.clip(period.end.toordinal() + 1 - eff, 0, window)
        itd = np.where(window > 0, round_half_away_np(wc * elapsed, np.maximum(window, 1)), wc)
        in_books = bk <= p
        for i, lob in enumerate(LOBS):
            mask = in_books & (lob_arr == i)
            itd_total = int(itd[mask].sum())
            written[lob][p] = int(wc[(bk == p) & (lob_arr == i)].sum())
            earned[lob][p] = itd_total - previous_itd[lob]
            unearned[lob][p] = int(wc[mask].sum()) - itd_total
            previous_itd[lob] = itd_total
    sub.by_period.update(written_premium=written, earned_premium=earned, unearned_premium_end=unearned)

    # -- policies in force at each period end (3e), from the current state of the terms --------
    pif = zeros()
    term_rows = [
        (t.start.toordinal(), t.expiration.toordinal(),
         t.cancel_date.toordinal() if t.cancel_date else 10**9, 0 if t.policy.lob == "AUTO" else 1)
        for t in policy_book.terms if not t.policy.is_test
    ]
    ts = np.array(term_rows, dtype=np.int64)
    for p, period in enumerate(periods):
        d = period.end.toordinal()
        in_force = (ts[:, 0] <= d) & (d < ts[:, 1]) & (ts[:, 2] > d)
        for i, lob in enumerate(LOBS):
            pif[lob][p] = int((in_force & (ts[:, 3] == i)).sum())
    sub.by_period["policies_in_force_end"] = pif

    # -- claims -------------------------------------------------------------------------------
    loss_paid, recoveries, expense_paid = zeros(), zeros(), zeros()
    loss_reserve, expense_reserve, reported = zeros(), zeros(), zeros()
    ay = {m: {lob: {y: 0 for y in years} for lob in LOBS} for m in ("incurred_loss", "paid_loss_net", "claim_count")}
    for claim in claims_book.claims:
        if claim.is_test or claim.kind == "DUPLICATE":
            continue
        lob = claim.lob
        reported[lob][cal.index_of_date(claim.reported_at.date())] += 1
        year = claim.loss_date.year
        ay["claim_count"][lob][year] += 1
        for txn in claim.transactions:
            amount = txn.amount
            if txn.transaction_type == "PAYMENT":
                target = loss_paid if txn.cost_category == "LOSS" else expense_paid
                target[lob][txn.booked] += amount
                if txn.voided_at is not None:
                    target[lob][txn.void_booked] -= amount
                elif txn.cost_category == "LOSS":
                    ay["paid_loss_net"][lob][year] += amount
                    ay["incurred_loss"][lob][year] += amount
            elif txn.transaction_type == "RECOVERY":
                recoveries[lob][txn.booked] += amount
                ay["paid_loss_net"][lob][year] -= amount
                ay["incurred_loss"][lob][year] -= amount
            else:  # RESERVE
                target = loss_reserve if txn.cost_category == "LOSS" else expense_reserve
                target[lob][txn.booked] += amount
                if txn.cost_category == "LOSS":
                    ay["incurred_loss"][lob][year] += amount
    sub.by_period.update(
        loss_paid_gross=loss_paid,
        loss_recoveries=recoveries,
        paid_loss_net={lob: loss_paid[lob] - recoveries[lob] for lob in LOBS},
        paid_expense=expense_paid,
        loss_reserve_change=loss_reserve,
        expense_reserve_change=expense_reserve,
        case_reserve_loss_end={lob: np.cumsum(loss_reserve[lob]) for lob in LOBS},
        case_reserve_expense_end={lob: np.cumsum(expense_reserve[lob]) for lob in LOBS},
        claims_reported=reported,
    )
    sub.by_accident_year = ay

    # -- cash: settled payments net of refunds, by month received; returns by month returned ----
    cash = zeros()
    for payment in billing.payments:
        if payment.policy.is_test:
            continue
        lob = payment.policy.lob
        cash[lob][cal.index_of_date(payment.received_at.date())] += payment.amount
        if payment.returned_at is not None:
            cash[lob][cal.index_of_date(payment.returned_at.date())] -= payment.amount
    sub.by_period["cash_received"] = cash
    return sub


PERIOD_METRICS = [
    "written_premium", "earned_premium", "unearned_premium_end", "policies_in_force_end",
    "paid_loss_net", "paid_expense", "case_reserve_loss_end", "case_reserve_expense_end",
    "claims_reported",
]
COUNT_METRICS = {"policies_in_force_end", "claims_reported", "claim_count"}
YEAR_METRICS = ["incurred_loss", "paid_loss_net", "claim_count"]


def control_total_rows(cfg: Config, sub: Subledger) -> list[tuple]:
    """Long-format rows: (metric, grain, period, line_of_business, value, as_of)."""
    from decimal import Decimal

    rows = []
    as_of = cfg.valuation_end

    def value(metric, number):
        return Decimal(int(number)).quantize(Decimal("0.01")) if metric in COUNT_METRICS else cents_to_decimal(int(number))

    for metric in PERIOD_METRICS:
        for p, period in enumerate(sub.periods):
            for lob in LOBS:
                rows.append((metric, "accounting_period", period.code, lob, value(metric, sub.by_period[metric][lob][p]), as_of))
    for metric in YEAR_METRICS:
        for year in sub.years:
            for lob in LOBS:
                rows.append((metric, "accident_year", str(year), lob, value(metric, sub.by_accident_year[metric][lob][year]), as_of))
    return rows


def loss_development(claims_book: ClaimsBook, coverages: set[str], valuations: list[dt.date]) -> dict:
    """Incurred loss by accident year at each valuation date, for a set of coverages.

    Used only for the calibration report: it shows how case-incurred develops as claims mature.
    """
    result: dict[int, list[int]] = {}
    for claim in claims_book.claims:
        if claim.is_test or claim.kind == "DUPLICATE":
            continue
        year = claim.loss_date.year
        row = result.setdefault(year, [0] * len(valuations))
        for txn in claim.transactions:
            if txn.cost_category != "LOSS" or txn.exposure.coverage not in coverages:
                continue
            for i, when in enumerate(valuations):
                end = dt.datetime.combine(when, dt.time(23, 59, 59))
                if txn.created_at > end:
                    continue
                sign = -1 if txn.transaction_type == "RECOVERY" else 1
                amount = txn.amount * sign
                if txn.transaction_type == "PAYMENT" and txn.voided_at is not None and txn.voided_at <= end:
                    amount = 0
                row[i] += amount
    return result
