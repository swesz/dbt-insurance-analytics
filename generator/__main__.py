"""python -m generator [--seed 42] [--scale 1.0] [--valuation-date 2026-09-30] [--out data/generated]"""

from __future__ import annotations

import argparse
import datetime as dt
from pathlib import Path

from .config import DEFAULT_SEED, DEFAULT_VALUATION_DATE, Config
from .run import generate


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="python -m generator", description=__doc__)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--scale", type=float, default=1.0, help="1.0 is about 25,000 policies")
    parser.add_argument("--valuation-date", type=dt.date.fromisoformat, default=DEFAULT_VALUATION_DATE)
    parser.add_argument("--out", type=Path, default=Path("data/generated"))
    parser.add_argument("--seeds", type=Path, default=Path("seeds"), help="the dbt seeds directory")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)
    if args.scale <= 0:
        parser.error("--scale must be positive")
    cfg = Config(seed=args.seed, scale=args.scale, valuation_date=args.valuation_date,
                 out_dir=args.out, seeds_dir=args.seeds)
    generate(cfg, verbose=not args.quiet)


if __name__ == "__main__":
    main()
