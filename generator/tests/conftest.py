"""Shared fixtures: one small generated dataset, loaded once per test session.

The checks run SQL against the loaded raw database, so they test the generator's Python with an
independent implementation, the way dbt will.
"""

from __future__ import annotations

import datetime as dt
import os
from pathlib import Path

import duckdb
import pytest

from generator.config import Config
from generator.run import generate
from loader.load import load

# Small by default so the suite runs in seconds; GENERATOR_TEST_SCALE=1.0 checks the full book.
SCALE = float(os.environ.get("GENERATOR_TEST_SCALE", "0.05"))
SEEDS_DIR = Path(__file__).resolve().parents[2] / "seeds"


@pytest.fixture(scope="session")
def cfg(tmp_path_factory) -> Config:
    out = tmp_path_factory.mktemp("generated")
    config = Config(seed=42, scale=SCALE, out_dir=out, seeds_dir=SEEDS_DIR)
    generate(config, verbose=False)
    return config


@pytest.fixture(scope="session")
def raw_path(cfg, tmp_path_factory) -> Path:
    path = tmp_path_factory.mktemp("raw") / "raw.duckdb"
    load(None, cfg.out_dir, path, verbose=False)
    return path


@pytest.fixture(scope="session")
def raw(raw_path):
    con = duckdb.connect(str(raw_path), read_only=True)
    con.execute(f"create temp table periods as select * from read_csv('{(SEEDS_DIR / 'accounting_periods.csv').as_posix()}')")
    con.execute(f"create temp table coverages as select * from read_csv('{(SEEDS_DIR / 'coverages.csv').as_posix()}')")
    yield con
    con.close()


AS_OF = dt.datetime(2024, 6, 5, 23, 59, 59)


@pytest.fixture(scope="session")
def raw_as_of(cfg, tmp_path_factory):
    path = tmp_path_factory.mktemp("raw_as_of") / "raw.duckdb"
    load(AS_OF, cfg.out_dir, path, verbose=False)
    con = duckdb.connect(str(path), read_only=True)
    yield con
    con.close()


def scalar(con, sql: str):
    return con.execute(sql).fetchone()[0]
