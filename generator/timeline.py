"""Dates, the accounting calendar and the booking rule.

Accounting periods are calendar months. Each closes at the end of the 4th business day of the
following month (seeds/accounting_periods.csv). After the close a period never changes, so a
transaction keyed in late is booked in the next period that is still open
(docs/source-systems.md, 3c).
"""

from __future__ import annotations

import bisect
import calendar
import datetime as dt
from dataclasses import dataclass

ONE_DAY = dt.timedelta(days=1)
SIX_HOURS = dt.timedelta(hours=6)


def add_months(day: dt.date, months: int) -> dt.date:
    """Same day of the month `months` later, clamped to the month's end (Aug 31 + 6 = Feb 28)."""
    month_index = day.month - 1 + months
    year, month = day.year + month_index // 12, month_index % 12 + 1
    return dt.date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


def next_sync(moment: dt.datetime) -> dt.datetime:
    """The first Fivetran sync boundary (00:00, 06:00, 12:00, 18:00) at or after `moment`."""
    floor = moment.replace(hour=moment.hour - moment.hour % 6, minute=0, second=0, microsecond=0)
    return floor if floor == moment else floor + SIX_HOURS


@dataclass(frozen=True)
class Period:
    index: int
    code: str  # 'YYYY-MM'
    start: dt.date
    end: dt.date
    close: dt.date  # last day the period is open; it closes at the end of this day

    @property
    def open_until(self) -> dt.datetime:
        """Entries made before this moment can still be booked in the period."""
        return dt.datetime.combine(self.close + ONE_DAY, dt.time())


class AccountingCalendar:
    def __init__(self, periods: list[Period]):
        self.periods = periods
        self.by_code = {p.code: p for p in periods}
        self._ends = [p.end for p in periods]
        self._open_until = [p.open_until for p in periods]

    def booked_index(self, transaction_date: dt.date, entered_at: dt.datetime) -> int:
        """Index of the period a transaction is booked in (3c).

        The earliest period P with P.end >= transaction_date that was still open when the
        transaction was entered: P.close + 1 day > entered_at.
        """
        i = bisect.bisect_left(self._ends, transaction_date)
        while entered_at >= self._open_until[i]:
            i += 1
        return i

    def index_of_date(self, day: dt.date) -> int:
        """Index of the calendar month containing `day`."""
        return bisect.bisect_left(self._ends, day)
