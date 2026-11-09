"""Planted defects that are not part of the business simulation itself, and their counts.

Most defects in docs/data-issues.md are planted where they happen (late entries in policies and
claims, voids and reopens in claims, soft deletes in policies, the GL issues in ledger). This
module adds the ones that come from people typing into the claims system and from the CDC
connector, and counts every planted issue for raw.generator_audit.planted_issues.
"""

from __future__ import annotations

import datetime as dt

from . import config as C
from .billing import BillingBook
from .claims import ClaimsBook
from .ledger import Ledger
from .policies import PolicyBook
from .rand import Rng
from .timeline import next_sync

POLICY_NUMBER_PATTERN_LENGTH = 10  # 'PA-0001234'


def plant_typing_defects(claims_book: ClaimsBook, rng: Rng) -> None:
    """INCONSISTENT_CODE_CASING and MALFORMED_POLICY_NUMBERS: values as typed at first notice.

    The garbled value is kept on every version of the claim, as it would be in the source.
    """
    for claim in claims_book.claims:
        claim.typed_policy_number = claim.policy_number
        claim.typed_cause = claim.loss_cause
        claim.typed_state = claim.loss_state
        if rng.chance(C.MALFORMED_POLICY_NUMBER_SHARE):
            number = claim.policy_number
            claim.typed_policy_number = rng.choice([
                number.lower(),  # 'pa-0001234'
                number.replace("-", ""),  # 'PA0001234'
                " " + number,
                number + " ",
            ])
        if rng.chance(C.CASING_SHARE):
            r = rng.random()
            if r < 0.8:
                cause = claim.loss_cause
                claim.typed_cause = rng.choice([cause.lower(), cause.title(), " " + cause.title(), cause + " "])
            if r >= 0.5:
                state = claim.loss_state
                claim.typed_state = rng.choice([state.lower(), state.title(), " " + state, state + " "])


def run_id(moment: dt.datetime) -> str:
    return "run_" + moment.strftime("%Y%m%d%H")


def add_rivery_metadata(rows: list[list], updated_at_index: int, river_id: str, rng: Rng) -> tuple[list[list], int]:
    """Append _rivery_last_update, _rivery_run_id and _rivery_river_id to CDC version rows.

    The hourly run writes each version 1-90 minutes after its source change. A rerun loaded a
    few versions a second time (CDC_DUPLICATE_VERSIONS): same key and updated_at, a later
    _rivery_last_update and a different run id. Returns the rows in load order and the number
    of duplicates.
    """
    out = []
    duplicates = 0
    for row in rows:
        loaded = row[updated_at_index] + dt.timedelta(seconds=rng.randint(60, 5400))
        out.append(row + [loaded, run_id(loaded), river_id])
        if rng.chance(C.CDC_DUPLICATE_SHARE):
            again = loaded + dt.timedelta(seconds=rng.randint(3600, 72 * 3600))
            out.append(row + [again, run_id(again), river_id])
            duplicates += 1
    out.sort(key=lambda r: r[-3])
    return out, duplicates


def is_clean_policy_number(text: str) -> bool:
    return (
        len(text) == POLICY_NUMBER_PATTERN_LENGTH and text[:2] in ("PA", "HO") and text[2] == "-"
        and text[3:].isdigit()
    )


def count_planted(policy_book: PolicyBook, billing: BillingBook, claims_book: ClaimsBook, ledger: Ledger,
                  cdc_tables: dict, as_of: dt.datetime) -> list[tuple]:
    """Exact counts for the default (valuation-date) load: (code, table, count, description).

    Row-level CDC defects are counted over the raw rows the default load shows, including
    duplicate versions; entity-level ones count distinct keys.
    """
    out = []
    test_policies = [p for p in policy_book.policies if p.is_test]
    out.append(("TEST_POLICIES", "policy_admin.policies", len(test_policies),
                "QA test policies (policy_id >= 9000000)"))
    out.append(("TEST_POLICIES", "policy_admin.policyholders", sum(1 for h in policy_book.holders if h.is_test),
                "policyholders of test policies (email @test.example.com)"))
    out.append(("SOFT_DELETED_POLICYHOLDERS", "policy_admin.policyholders",
                sum(1 for h in policy_book.holders if h.versions[-1][3]),
                "duplicate customer records with _fivetran_deleted = true"))
    out.append(("SOFT_DELETED_POLICIES", "policy_admin.policies",
                sum(1 for p in policy_book.policies if p.versions[-1][2]),
                "policies created in error, _fivetran_deleted = true, no terms or transactions"))

    for table, (columns, rows) in cdc_tables.items():
        key, updated = columns[0], columns.index("updated_at")
        visible = [r for r in rows if r[-3] <= as_of]
        seen, dupes = set(), 0
        for r in visible:
            k = (r[0], r[updated])
            if k in seen:
                dupes += 1
            seen.add(k)
        out.append(("CDC_DUPLICATE_VERSIONS", f"claims.{table}", dupes,
                    f"extra copies of a ({key}, updated_at) version loaded by a rerun"))

    claims_rows = [r for r in cdc_tables["claims"][1] if r[-3] <= as_of]
    cols = cdc_tables["claims"][0]
    i_status, i_cause, i_state, i_number = (cols.index(c) for c in ("claim_status", "loss_cause", "loss_state", "policy_number"))
    deleted = [c for c in claims_book.claims if c.kind == "DUPLICATE"]
    out.append(("DELETED_CLAIMS", "claims.claims", len(deleted),
                "claims whose latest version has __deleted = true (duplicate first notices)"))
    out.append(("DELETED_CLAIMS", "claims.claim_exposures", sum(len(c.exposures) for c in deleted),
                "exposures of the deleted claims, also deleted"))
    out.append(("LEGACY_STATUS_CODES", "claims.claims", sum(1 for r in claims_rows if r[i_status] in ("O", "C", "R")),
                "claim versions (rows) with status 'O', 'C' or 'R', written before 2023-07-01"))
    out.append(("INCONSISTENT_CODE_CASING", "claims.claims",
                sum(1 for r in claims_rows if r[i_cause] != r[i_cause].strip().upper() or r[i_state] != r[i_state].strip().upper()),
                "claim versions (rows) whose loss_cause or loss_state is not trimmed upper case"))
    out.append(("MALFORMED_POLICY_NUMBERS", "claims.claims",
                sum(1 for r in claims_rows if not is_clean_policy_number(r[i_number])),
                "claim versions (rows) whose policy_number is not 'XX-0000000'"))
    out.append(("ORPHAN_CLAIMS", "claims.claims", sum(1 for c in claims_book.claims if c.kind == "ORPHAN"),
                "claims on policy numbers that never existed; no financial transactions"))
    out.append(("LOSS_OUTSIDE_TERM", "claims.claims", sum(1 for c in claims_book.claims if c.kind == "OUTSIDE_TERM"),
                "claims with a loss date before the policy or after cancellation; closed without payment"))
    out.append(("LATE_ENTERED_TRANSACTIONS", "policy_admin.policy_transactions",
                sum(1 for t in policy_book.transactions if t.created_at.date() > t.transaction_date),
                "transactions entered 1-20 days after their transaction_date"))
    out.append(("LATE_ENTERED_TRANSACTIONS", "claims.claim_transactions",
                sum(1 for t in claims_book.transactions if t.created_at.date() > t.transaction_date),
                "claim transactions entered 1-20 days after their transaction_date"))
    endorsements = [t for t in policy_book.transactions if t.transaction_type == "ENDORSEMENT"]
    out.append(("BACKDATED_ENDORSEMENTS", "policy_admin.policy_transactions",
                sum(1 for t in endorsements if t.effective_date < t.transaction_date),
                f"endorsements effective before their transaction_date (of {len(endorsements)} endorsements)"))
    payments = [t for t in claims_book.transactions if t.transaction_type == "PAYMENT"]
    out.append(("VOIDED_PAYMENTS", "claims.claim_transactions", sum(1 for t in payments if t.voided_at is not None),
                f"payments overwritten with transaction_status = 'VOIDED' (of {len(payments)} payments)"))
    closed = [c for c in claims_book.claims if any(v[1] == "CLOSED" for v in c.versions)]
    reopened = sum(1 for c in closed if any(v[1] == "REOPENED" for v in c.versions))
    out.append(("REOPENED_CLAIMS", "claims.claims", reopened,
                f"claims with a REOPENED version (of {len(closed)} claims that closed)"))
    out.append(("BILLING_AMOUNTS_IN_CENTS", "billing.installments", len(billing.installments),
                "every row: amounts are integer cents"))
    out.append(("BILLING_AMOUNTS_IN_CENTS", "billing.payments", len(billing.payments),
                "every row: amounts are integer cents"))
    out.append(("RETURNED_PAYMENTS", "billing.payments", sum(1 for p in billing.payments if p.returned_at is not None),
                f"payments overwritten with payment_status = 'RETURNED' (of {len(billing.payments)} payments)"))
    visible_files = [f for f in ledger.files if next_sync(f.modified_at) <= as_of]
    reexported = [f for f in visible_files if f.accounting_period == C.GL_REEXPORTED_PERIOD and not f.file_name.endswith("_v2.csv")]
    out.append(("GL_FILE_REEXPORTED", "general_ledger.journal_lines", sum(len(f.lines) for f in reexported),
                "lines of the superseded gl_export_2025_03.csv (gl_export_2025_03_v2.csv replaces it)"))
    out.append(("GL_AMOUNT_FORMAT_CHANGE", "general_ledger.journal_lines",
                sum(1 for f in visible_files for line in f.lines if "," in line[6] or "," in line[7]),
                "journal lines whose debit or credit has a thousands separator"))
    out.append(("GL_MANUAL_RECLASS", "general_ledger.journal_lines", 2,
                f"lines of the 2024-06 MANUAL journal moving {ledger.reclass_cents / 100:,.2f} of written premium from AUTO to HOME"))
    out.append(("GL_CLAIMS_INTERFACE_TIMING", "general_ledger.journal_lines", ledger.timing_payments,
                "claim payments entered on 2025-08-31 and booked in 2025-08 that the GL posted in 2025-09"))
    return out
