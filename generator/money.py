"""Money helpers. All amounts in the simulation are integer cents.

Floating point cannot represent most cent amounts exactly (0.1 + 0.2 != 0.3), and the control
totals must equal dbt's figures to the cent. So every amount is an int number of cents, and every
division that the business rules define (proration, earning) is done in integer arithmetic with
the rounding rule from docs/source-systems.md 3d: half away from zero.
"""

from __future__ import annotations

import math
from decimal import Decimal

import numpy as np
import pyarrow as pa


def round_half_away(numerator: int, denominator: int) -> int:
    """numerator / denominator rounded to an integer, halves away from zero (denominator > 0)."""
    q, r = divmod(abs(numerator), denominator)
    if 2 * r >= denominator:
        q += 1
    return q if numerator >= 0 else -q


def round_half_away_np(numerator: np.ndarray, denominator: np.ndarray) -> np.ndarray:
    """Vectorized round_half_away for int64 arrays (denominator > 0)."""
    q = (np.abs(numerator) * 2 + denominator) // (2 * denominator)
    return np.sign(numerator) * q


def dollars_to_cents(amount: float) -> int:
    """Convert a generated (random) dollar amount to cents, halves away from zero."""
    cents = math.floor(abs(amount) * 100 + 0.5)
    return cents if amount >= 0 else -cents


def cents_to_decimal(cents: int) -> Decimal:
    return Decimal(cents).scaleb(-2)


def format_cents(cents: int, thousands: bool = False) -> str:
    """'1234.56', or '1,234.56' with thousands separators."""
    sign = "-" if cents < 0 else ""
    whole, frac = divmod(abs(cents), 100)
    whole_text = f"{whole:,}" if thousands else str(whole)
    return f"{sign}{whole_text}.{frac:02d}"


def cents_to_arrow(cents, precision: int = 12, scale: int = 2) -> pa.Array:
    """Build a pyarrow decimal array directly from integer cents (the unscaled values).

    A decimal128 value is a 16-byte two's complement integer; for cents that fit in 64 bits that
    is the int64 value followed by its sign extension. Building the buffer this way is exact and
    avoids creating a Python Decimal per row.
    """
    values = np.asarray(cents, dtype=np.int64)
    words = np.empty(len(values) * 2, dtype=np.int64)
    words[0::2] = values
    words[1::2] = np.where(values < 0, -1, 0)
    return pa.Array.from_buffers(
        pa.decimal128(precision, scale), len(values), [None, pa.py_buffer(words.tobytes())]
    )
