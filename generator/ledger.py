"""The general ledger: monthly journal exports from the ERP (docs/source-systems.md 3h).

At each period close the subledgers post one journal per source system and line of business:

    POLICY_ADMIN  Dr 1200 Premiums receivable  / Cr 4000 Premiums written    written premium
                  Dr 4100 Change in UPR        / Cr 2100 UPR                 increase in UPR
    BILLING       Dr 1000 Cash                 / Cr 1200 Premiums receivable cash received
    CLAIMS        Dr 5000 Losses paid / Cr 1000; Dr 1000 / Cr 5050 recoveries;
                  Dr 5200 LAE paid / Cr 1000; Dr 5100 / Cr 2200 and Dr 5300 / Cr 2300 for the
                  change in loss and LAE case reserves

Debits and credits are never negative: a negative amount (a decrease in UPR, say) swaps the
sides. Every entry is a balanced pair of lines, so each journal balances.

The ERP then writes the period's lines to gl_export_YYYY_MM.csv. Four defects are planted here:
the 2025-03 file is exported again with a correction (GL_FILE_REEXPORTED), amounts have
thousands separators from 2025-01 (GL_AMOUNT_FORMAT_CHANGE), accountants reclassify premium
between the lines in 2024-06 (GL_MANUAL_RECLASS), and the 2025-08 claims interface misses the
payments entered on the last day of the month, which are posted in 2025-09
(GL_CLAIMS_INTERFACE_TIMING).
"""

from __future__ import annotations

import csv
import datetime as dt
from dataclasses import dataclass
from pathlib import Path

from . import config as C
from .claims import ClaimsBook
from .config import Config
from .controls import LOBS, Subledger
from .money import format_cents
from .rand import Rng
from .seeds import Seeds

HEADER = [
    "journal_id", "line_number", "accounting_period", "posting_date", "account_number",
    "line_of_business", "debit", "credit", "source_system", "description",
]


@dataclass
class GLFile:
    file_name: str
    accounting_period: str
    modified_at: dt.datetime
    lines: list  # rows as lists of text, in HEADER order


@dataclass
class Ledger:
    files: list[GLFile]
    reclass_cents: int
    timing_payments: int  # count of payments moved from 2025-08 to 2025-09
    timing_cents: dict  # (lob, account) -> cents moved
    reconciling_items: list  # rows for seeds/gl_reconciling_items.csv


def entry(debit_account: str, credit_account: str, cents: int) -> list[tuple[str, str, int]]:
    """A balanced pair of lines (account, side, cents); a negative amount swaps the sides."""
    if cents >= 0:
        return [(debit_account, "D", cents), (credit_account, "C", cents)]
    return [(debit_account, "C", -cents), (credit_account, "D", -cents)]


def build_ledger(cfg: Config, seeds: Seeds, sub: Subledger, claims_book: ClaimsBook, rng: Rng) -> Ledger:
    accounts = seeds.gl_accounts
    by = sub.by_period
    codes = [p.code for p in sub.periods]

    # GL_CLAIMS_INTERFACE_TIMING: payments entered on the last day of 2025-08 and booked in it.
    timing_index = codes.index(C.GL_CLAIMS_TIMING_PERIOD) if C.GL_CLAIMS_TIMING_PERIOD in codes else None
    moved = {(lob, acct): 0 for lob in LOBS for acct in ("5000", "5200")}
    moved_count = 0
    if timing_index is not None and timing_index + 1 < len(codes):
        last_day = sub.periods[timing_index].end
        for txn in claims_book.transactions:
            if (
                txn.transaction_type == "PAYMENT" and not txn.claim.is_test
                and txn.created_at.date() == last_day and txn.booked == timing_index
            ):
                moved[(txn.claim.lob, "5000" if txn.cost_category == "LOSS" else "5200")] += txn.amount
                moved_count += 1

    reclass = round(rng.uniform(15_000, 40_000)) * 100 + rng.randrange(100)

    files: list[GLFile] = []
    for p, period in enumerate(sub.periods):
        export_at = dt.datetime.combine(period.close, dt.time(17, 30))
        if export_at > cfg.valuation_end:
            break  # not closed yet
        journals = []  # (source, lob or None, [(account, debit, credit, lob)])
        for lob in LOBS:
            lines = entry("1200", "4000", int(by["written_premium"][lob][p]))
            upr_now = int(by["unearned_premium_end"][lob][p])
            upr_before = int(by["unearned_premium_end"][lob][p - 1]) if p else 0
            lines += entry("4100", "2100", upr_now - upr_before)
            journals.append(("POLICY_ADMIN", lob, lines))
        for lob in LOBS:
            journals.append(("BILLING", lob, entry("1000", "1200", int(by["cash_received"][lob][p]))))
        for lob in LOBS:
            loss_paid = int(by["loss_paid_gross"][lob][p])
            expense_paid = int(by["paid_expense"][lob][p])
            if p == timing_index:
                loss_paid -= moved[(lob, "5000")]
                expense_paid -= moved[(lob, "5200")]
            elif timing_index is not None and p == timing_index + 1:
                loss_paid += moved[(lob, "5000")]
                expense_paid += moved[(lob, "5200")]
            lines = entry("5000", "1000", loss_paid)
            lines += entry("1000", "5050", int(by["loss_recoveries"][lob][p]))
            lines += entry("5200", "1000", expense_paid)
            lines += entry("5100", "2200", int(by["loss_reserve_change"][lob][p]))
            lines += entry("5300", "2300", int(by["expense_reserve_change"][lob][p]))
            journals.append(("CLAIMS", lob, lines))
        if period.code == C.GL_MANUAL_RECLASS_PERIOD:
            # Some home policies' premium had been coded to AUTO; accountants move it to HOME.
            journals.append(("MANUAL", None, [("4000", "D", reclass, "AUTO"), ("4000", "C", reclass, "HOME")]))

        thousands = period.code >= C.GL_THOUSANDS_SEPARATOR_FROM
        posting = period.end.strftime("%m/%d/%Y")
        year, month = period.code.split("-")
        rows_by_journal = []
        for j, (source, lob, lines) in enumerate(journals, start=1):
            journal_id = f"JE-{year}-{month}-{j:04d}"
            rows = []
            for n, line in enumerate(lines, start=1):
                account, side, cents = line[:3]
                line_lob = line[3] if len(line) > 3 else lob
                amount = format_cents(cents, thousands)
                if source == "MANUAL":
                    description = f"Manual reclass of written premium from AUTO to HOME {period.code}"
                else:
                    description = f"{source} {period.code} {line_lob}: {accounts[account]}"
                rows.append([
                    journal_id, str(n), period.code, posting, account, line_lob,
                    amount if side == "D" else "",
                    amount if side == "C" else "",
                    source, description,
                ])
            rows_by_journal.append((source, rows))

        file_stub = f"gl_export_{year}_{month}"
        all_rows = [r for _, rows in rows_by_journal for r in rows]
        if period.code == C.GL_REEXPORTED_PERIOD:
            # The first export ran before the billing interface had posted: no BILLING journals.
            first = [r for source, rows in rows_by_journal if source != "BILLING" for r in rows]
            files.append(GLFile(f"{file_stub}.csv", period.code, export_at, first))
            corrected_at = rng.office_time(period.close + dt.timedelta(days=4))
            files.append(GLFile(f"{file_stub}_v2.csv", period.code, corrected_at, all_rows))
        else:
            files.append(GLFile(f"{file_stub}.csv", period.code, export_at, all_rows))

    items = []
    if any(p.code == C.GL_MANUAL_RECLASS_PERIOD for p in sub.periods):
        why = "Manual journal moved written premium of miscoded home policies from AUTO to HOME"
        items.append((C.GL_MANUAL_RECLASS_PERIOD, "4000", "AUTO", reclass, "MANUAL_RECLASS", why))
        items.append((C.GL_MANUAL_RECLASS_PERIOD, "4000", "HOME", -reclass, "MANUAL_RECLASS", why))
    if moved_count:
        nxt = codes[timing_index + 1]
        why = "Claims interface missed payments entered on 2025-08-31; posted in 2025-09"
        for period_code, sign in ((C.GL_CLAIMS_TIMING_PERIOD, -1), (nxt, 1)):
            for lob in LOBS:
                loss, lae = moved[(lob, "5000")], moved[(lob, "5200")]
                items.append((period_code, "5000", lob, sign * loss, "TIMING", why))
                items.append((period_code, "5200", lob, sign * lae, "TIMING", why))
                items.append((period_code, "1000", lob, -sign * (loss + lae), "TIMING", why))
    return Ledger(files, reclass, moved_count, moved, items)


def write_ledger_files(ledger: Ledger, out_dir: Path) -> None:
    gl_dir = out_dir / "gl"
    gl_dir.mkdir(parents=True, exist_ok=True)
    for f in ledger.files:
        with (gl_dir / f.file_name).open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, lineterminator="\n")
            writer.writerow(HEADER)
            writer.writerows(f.lines)
