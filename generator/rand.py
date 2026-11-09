"""Seeded randomness.

Every module gets its own stream, `make_rng(seed, "claims")`, so that changing how one module
draws numbers does not shift the numbers every other module sees. The streams are
`random.Random` instances seeded with a string, which Python hashes with SHA-512: the same seed
gives the same data on every machine and every run. The global `random` state is never used.
"""

from __future__ import annotations

import bisect
import datetime as dt
import itertools
import math
import random

# Office hours for anything a person keys in. Keeping every user action between 08:00 and 17:00
# means that a load as of the end of a day (the default) sees everything that happened that day:
# the last Fivetran sync at 18:00 and the Rivery runs up to 90 minutes later have picked it up.
WORKDAY_START = dt.time(8, 0)
WORKDAY_SECONDS = 9 * 3600


class Rng(random.Random):
    """random.Random plus the few distributions the simulation needs."""

    def chance(self, p: float) -> bool:
        return self.random() < p

    def lognormal_mean(self, mean: float, sigma: float) -> float:
        """A lognormal draw parameterized by its mean rather than by mu."""
        mu = math.log(mean) - sigma * sigma / 2
        return self.lognormvariate(mu, sigma)

    def poisson(self, lam: float) -> int:
        """Poisson count (Knuth's method for small means, normal approximation for large)."""
        if lam <= 0:
            return 0
        if lam > 40:
            return max(0, round(self.gauss(lam, math.sqrt(lam))))
        limit = math.exp(-lam)
        k, p = 0, self.random()
        while p > limit:
            k += 1
            p *= self.random()
        return k

    def office_time(self, day: dt.date) -> dt.datetime:
        """A random moment during office hours on `day`."""
        return dt.datetime.combine(day, WORKDAY_START) + dt.timedelta(
            seconds=self.randrange(WORKDAY_SECONDS)
        )

    def batch_time(self, day: dt.date, hour: int) -> dt.datetime:
        """A nightly batch job: some time in the half hour after `hour`:00."""
        return dt.datetime.combine(day, dt.time(hour)) + dt.timedelta(seconds=self.randrange(1800))


class WeightedChoice:
    """Fast repeated draws from a fixed discrete distribution."""

    def __init__(self, weights: dict):
        self.items = list(weights)
        self.cum = list(itertools.accumulate(weights.values()))

    def __call__(self, rng: random.Random):
        return self.items[bisect.bisect_right(self.cum, rng.random() * self.cum[-1])]


def make_rng(seed: int, stream: str) -> Rng:
    return Rng(f"{seed}:{stream}")
