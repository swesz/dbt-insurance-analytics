"""Write seeds/accounting_periods.csv: one row per monthly accounting period.

The close rule is in docs/source-systems.md (section 1): a period closes at the end of the 4th
business day (Monday to Friday, no holiday calendar) of the following month. Run this only to
regenerate the seed; the CSV is committed so dbt and the generator read the same calendar.

    python scripts/make_accounting_calendar.py
"""

import csv
import datetime as dt
from pathlib import Path

FIRST_PERIOD = (2022, 1)
LAST_PERIOD = (2027, 12)  # past the valuation date: late entries must still find a period
CLOSE_BUSINESS_DAY = 4

SEED_PATH = Path(__file__).resolve().parent.parent / "seeds" / "accounting_periods.csv"


def month_start(year: int, month: int) -> dt.date:
    return dt.date(year, month, 1)


def next_month(year: int, month: int) -> tuple[int, int]:
    return (year + 1, 1) if month == 12 else (year, month + 1)


def nth_business_day(start: dt.date, n: int) -> dt.date:
    """The n-th Monday-to-Friday day on or after `start`."""
    day = start
    count = 0
    while True:
        if day.weekday() < 5:
            count += 1
            if count == n:
                return day
        day += dt.timedelta(days=1)


def main() -> None:
    rows = []
    year, month = FIRST_PERIOD
    while (year, month) <= LAST_PERIOD:
        ny, nm = next_month(year, month)
        start = month_start(year, month)
        end = month_start(ny, nm) - dt.timedelta(days=1)
        close = nth_business_day(month_start(ny, nm), CLOSE_BUSINESS_DAY)
        rows.append(
            {
                "accounting_period": f"{year:04d}-{month:02d}",
                "period_start_date": start.isoformat(),
                "period_end_date": end.isoformat(),
                "close_date": close.isoformat(),
                "fiscal_year": year,
                "fiscal_quarter": (month - 1) // 3 + 1,
            }
        )
        year, month = ny, nm

    with SEED_PATH.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} periods to {SEED_PATH.name}")


if __name__ == "__main__":
    main()
