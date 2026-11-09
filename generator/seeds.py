"""Read the reference data in seeds/ (shared with dbt, so it is never duplicated in Python)."""

from __future__ import annotations

import csv
import datetime as dt
from dataclasses import dataclass
from pathlib import Path

from .timeline import AccountingCalendar, Period


@dataclass(frozen=True)
class CatEvent:
    code: str
    name: str
    peril: str  # a loss cause: HAIL, WIND, FREEZE
    start: dt.date
    end: dt.date
    states: tuple[str, ...]


@dataclass(frozen=True)
class Seeds:
    coverages: dict[str, list[str]]  # line of business -> coverage codes, in seed order
    coverage_lob: dict[str, str]
    states: list[str]
    loss_causes: dict[str, dict[str, bool]]  # cause -> {'AUTO': bool, 'HOME': bool}
    cat_events: list[CatEvent]
    calendar: AccountingCalendar
    gl_accounts: dict[str, str]  # account number -> name
    legacy_status: dict[str, str]  # 'OPEN' -> 'O' (codes used before the claims system upgrade)


def _rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def _bool(text: str) -> bool:
    return text.strip().lower() == "true"


def load_seeds(seeds_dir: Path) -> Seeds:
    coverages: dict[str, list[str]] = {}
    coverage_lob = {}
    for row in _rows(seeds_dir / "coverages.csv"):
        coverages.setdefault(row["line_of_business"], []).append(row["coverage_code"])
        coverage_lob[row["coverage_code"]] = row["line_of_business"]

    states = [row["state_code"] for row in _rows(seeds_dir / "states.csv")]

    loss_causes = {
        row["loss_cause"]: {"AUTO": _bool(row["applies_to_auto"]), "HOME": _bool(row["applies_to_home"])}
        for row in _rows(seeds_dir / "loss_causes.csv")
    }

    cat_events = [
        CatEvent(
            code=row["catastrophe_code"],
            name=row["event_name"],
            peril=row["peril"],
            start=dt.date.fromisoformat(row["start_date"]),
            end=dt.date.fromisoformat(row["end_date"]),
            states=tuple(row["affected_states"].split("|")),
        )
        for row in _rows(seeds_dir / "catastrophe_events.csv")
    ]

    periods = [
        Period(
            index=i,
            code=row["accounting_period"],
            start=dt.date.fromisoformat(row["period_start_date"]),
            end=dt.date.fromisoformat(row["period_end_date"]),
            close=dt.date.fromisoformat(row["close_date"]),
        )
        for i, row in enumerate(_rows(seeds_dir / "accounting_periods.csv"))
    ]

    gl_accounts = {row["account_number"]: row["account_name"] for row in _rows(seeds_dir / "gl_accounts.csv")}

    # Legacy one-letter codes are the source_status values that are not themselves a status.
    legacy_status = {}
    for row in _rows(seeds_dir / "claim_status_map.csv"):
        if row["source_status"] != row["claim_status"]:
            legacy_status[row["claim_status"]] = row["source_status"]

    return Seeds(
        coverages=coverages,
        coverage_lob=coverage_lob,
        states=states,
        loss_causes=loss_causes,
        cat_events=cat_events,
        calendar=AccountingCalendar(periods),
        gl_accounts=gl_accounts,
        legacy_status=legacy_status,
    )
