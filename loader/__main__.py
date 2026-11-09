"""python -m loader [--as-of 2026-09-30T23:59:59] [--input data/generated] [--output warehouse/raw.duckdb]"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

from .load import LoadError, load


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="python -m loader", description=__doc__)
    parser.add_argument("--as-of", type=dt.datetime.fromisoformat, default=None,
                        help="show the sources as of this moment (default: end of the valuation date)")
    parser.add_argument("--input", type=Path, default=Path("data/generated"))
    parser.add_argument("--output", type=Path, default=Path("warehouse/raw.duckdb"))
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)
    try:
        load(args.as_of, args.input, args.output, verbose=not args.quiet)
    except LoadError as exc:
        print(f"loader: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
