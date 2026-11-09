"""The claims system: claims, exposures, reserves and payments.

A *claim* is one loss occurrence reported by a policyholder (first notice of loss, FNOL). It has
one or more *exposures*: one per coverage and claimant. An at-fault car accident, for example,
can have the other driver's property damage (PD), our insured's own collision damage (COLL) and
one or two injured people (BI).

For each exposure the simulation first draws the *ultimate* loss, the amount that will eventually
be paid, and then plays out how the claims department would discover it:

1. On FNOL the adjuster sets an INITIAL case reserve from an average for the coverage. For bodily
   injury that average is well below what the claims turn out to cost, for property well above,
   which is why BI reserves develop upward over time and property reserves downward.
2. The reserve is revised 1-4 times as the adjuster learns more; each revision estimates the
   remaining loss with a bias that fades as the claim matures.
3. Payments are made (interim payments, then a final one). Each payment *erodes* the reserve by
   the amount paid, but never below zero (a PAYMENT_EROSION reserve row).
4. When the exposure is settled it is closed and any reserve left is released (a CLOSE row).
5. Later there can be recoveries (salvage, subrogation), and a few claims reopen.

Expenses (LAE) follow the same pattern in the EXPENSE cost category.

The claims system is loaded by CDC, so every change to a claim, exposure or transaction row is
kept as a version (`versions` lists).
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field

from . import config as C
from .config import Config
from .money import dollars_to_cents
from .policies import AUTO, HOME, Policy, PolicyBook
from .rand import Rng, WeightedChoice
from .seeds import Seeds

LOSS, EXPENSE = "LOSS", "EXPENSE"
TEAMS = ("AUTO_PHYSICAL_DAMAGE", "AUTO_INJURY", "PROPERTY", "CATASTROPHE")
TEAM_SIZE = {"AUTO_PHYSICAL_DAMAGE": 12, "AUTO_INJURY": 8, "PROPERTY": 10, "CATASTROPHE": 4}


# Actions in an exposure's plan. A plan is a list of groups; a group is a set of actions that
# happen at one moment (for example a final payment, its reserve erosion and the close).
@dataclass(slots=True, eq=False)
class Group:
    day: int  # days after the exposure opened
    actions: list
    seq: int = 0
    exposure: "Exposure" = None
    at: dt.datetime | None = None
    late_date: dt.date | None = None  # transaction_date of a late-entered group


@dataclass(slots=True, eq=False)
class Exposure:
    coverage: str
    claimant_type: str
    open_day: int  # days after the claim was reported
    ultimate: int  # planned ultimate loss, cents
    expense_ultimate: int = 0
    groups: list = field(default_factory=list)
    exposure_id: int = 0
    opened_at: dt.datetime | None = None
    versions: list = field(default_factory=list)  # (updated_at, status, closed_at, is_deleted)


@dataclass(slots=True, eq=False)
class ClaimTransaction:
    claim: "Claim"
    exposure: Exposure
    transaction_type: str
    cost_category: str
    expense_type: str | None
    reserve_reason: str | None
    amount: int  # cents
    transaction_date: dt.date
    created_at: dt.datetime
    seq: int
    voided_at: dt.datetime | None = None
    claim_transaction_id: int = 0
    booked: int = -1
    void_booked: int = -1


@dataclass(slots=True, eq=False)
class Claim:
    kind: str  # NORMAL, OUTSIDE_TERM, ORPHAN, DUPLICATE
    policy: Policy | None
    policy_number: str  # clean form; defects may garble the typed value later
    lob: str
    loss_date: dt.date
    reported_at: dt.datetime
    loss_cause: str
    loss_state: str
    cat_code: str | None
    exposures: list
    is_test: bool = False
    team: str = ""
    claim_id: int = 0
    claim_number: str = ""
    adjuster_id: int = 0
    reopen_planned: bool = False
    versions: list = field(default_factory=list)  # (updated_at, status, closed_at, is_deleted)
    transactions: list = field(default_factory=list)
    typed_policy_number: str = ""
    typed_cause: str = ""
    typed_state: str = ""


@dataclass(slots=True, eq=False)
class Adjuster:
    adjuster_id: int
    name: str
    team: str
    hired_date: dt.date
    versions: list  # (updated_at, team, is_active)

    def active_on(self, day: dt.date) -> bool:
        if day < self.hired_date:
            return False
        active = True
        for at, _, is_active in self.versions:
            if at.date() <= day:
                active = is_active
        return active


@dataclass
class ClaimsBook:
    claims: list  # every claim, including deleted duplicates, orphans and test claims
    exposures: list
    transactions: list
    adjusters: list


def trend_factor(loss_date: dt.date) -> float:
    return (1 + C.SEVERITY_TREND) ** ((loss_date - C.START_DATE).days / 365.25)


def to_hundreds(dollars: float) -> int:
    """Reserves are set in round hundreds of dollars, as adjusters do."""
    return max(1, round(dollars / 100)) * 100 * 100


class ClaimsSimulator:
    def __init__(self, cfg: Config, seeds: Seeds, rng: Rng):
        self.cfg = cfg
        self.seeds = seeds
        self.rng = rng
        self.valuation = cfg.valuation_date
        self.valuation_end = cfg.valuation_end
        self.pick_comp = WeightedChoice(C.COMP_CAUSES)
        self.pick_home = WeightedChoice(C.HOME_PROPERTY_CAUSES)
        self.claims: list[Claim] = []

    # -- severities and lags --------------------------------------------------------------------

    def severity(self, coverage: str, mean: float, loss_date: dt.date, cap: float | None) -> int:
        params = C.COVERAGE_CLAIM_PARAMS[coverage]
        amount = self.rng.lognormal_mean(mean * trend_factor(loss_date), params["sigma"])
        if cap is not None:
            amount = min(amount, cap)
        return dollars_to_cents(max(amount, 100.0))

    def report_lag(self, kind: str) -> int:
        rng = self.rng
        r = rng.random()
        if kind == "auto":
            return int(rng.expovariate(1 / 2)) if r < 0.85 else rng.randint(7, 60)
        if kind == "property":
            if r < 0.85:
                return int(rng.expovariate(1 / 3))
            return rng.randint(14, 90) if r < 0.98 else rng.randint(91, 200)
        if kind == "liability":
            if r < 0.55:
                return int(rng.expovariate(1 / 5))
            return rng.randint(30, 180) if r < 0.88 else rng.randint(181, 540)
        return min(60, int(rng.expovariate(1 / 6)))  # catastrophe

    def bi_open_day(self) -> int:
        """Injured claimants often come forward weeks or months after the accident is reported."""
        rng = self.rng
        r = rng.random()
        if r < 0.55:
            return 0
        if r < 0.85:
            return rng.randint(7, 56)
        return rng.randint(60, 270) if r < 0.97 else rng.randint(271, 600)

    # -- building claims ------------------------------------------------------------------------

    def new_claim(self, kind, policy, lob, loss_date, lag, cause, exposures, cat_code=None) -> Claim | None:
        rng = self.rng
        reported = loss_date + dt.timedelta(days=lag)
        if policy is not None and reported <= policy.created_at.date():
            reported = policy.created_at.date() + dt.timedelta(days=1)
        if reported > self.valuation:
            return None  # not reported yet at the valuation date: IBNR
        claim = Claim(
            kind=kind,
            policy=policy,
            policy_number=policy.policy_number if policy is not None else "",
            lob=lob,
            loss_date=loss_date,
            reported_at=rng.office_time(reported),
            loss_cause=cause,
            loss_state=policy.state if policy is not None else rng.choice(self.seeds.states),
            cat_code=cat_code,
            exposures=exposures,
            is_test=policy.is_test if policy is not None else False,
        )
        if cat_code:
            claim.team = "CATASTROPHE"
        elif any(e.coverage == "BI" for e in exposures):
            claim.team = "AUTO_INJURY"
        else:
            claim.team = "AUTO_PHYSICAL_DAMAGE" if lob == AUTO else "PROPERTY"
        self.claims.append(claim)
        return claim

    def exposure(self, coverage, claimant, ultimate, avg, loss_date, open_day=0, cause="") -> Exposure:
        rng = self.rng
        if rng.chance(C.COVERAGE_CLAIM_PARAMS[coverage]["cwp"]):
            ultimate = 0  # closed without payment: not covered, or below the deductible
        exp = Exposure(coverage, claimant, open_day, ultimate)
        self.plan_exposure(exp, avg, loss_date, cause)
        return exp

    def auto_claims(self, policy: Policy, start: dt.date, days: int, years: float, freq: float) -> None:
        rng = self.rng
        vehicles = policy.units
        p_bi = C.COVERAGE_CLAIM_PARAMS
        # At-fault accidents: third-party PD, maybe our insured's COLL, maybe injuries.
        for _ in range(rng.poisson(C.AUTO_AT_FAULT_RATE * vehicles * years * freq)):
            loss = start + dt.timedelta(days=rng.randrange(days))
            exps = [self.exposure("PD", "THIRD_PARTY", self.severity("PD", 4500, loss, p_bi["PD"]["cap"]), 4500, loss)]
            if policy.has_physical_damage and rng.chance(C.AT_FAULT_COLL_SHARE):
                exps.append(self.exposure("COLL", "FIRST_PARTY", self.severity("COLL", 5000, loss, p_bi["COLL"]["cap"]), 5000, loss))
            if rng.chance(C.AT_FAULT_BI_SHARE):
                for _ in range(2 if rng.chance(C.BI_SECOND_CLAIMANT_SHARE) else 1):
                    ult = self.severity("BI", p_bi["BI"]["mean"], loss, p_bi["BI"]["cap"])
                    exps.append(self.exposure("BI", "THIRD_PARTY", ult, 20000, loss, open_day=self.bi_open_day()))
            self.new_claim("NORMAL", policy, AUTO, loss, self.report_lag("auto"), "COLLISION", exps)
        if not policy.has_physical_damage:
            return
        for _ in range(rng.poisson(C.AUTO_SINGLE_VEHICLE_COLL_RATE * vehicles * years * freq)):
            loss = start + dt.timedelta(days=rng.randrange(days))
            exps = [self.exposure("COLL", "FIRST_PARTY", self.severity("COLL", 5000, loss, p_bi["COLL"]["cap"]), 5000, loss)]
            self.new_claim("NORMAL", policy, AUTO, loss, self.report_lag("auto"), "COLLISION", exps)
        for _ in range(rng.poisson(C.AUTO_COMP_RATE * vehicles * years * freq)):
            loss = start + dt.timedelta(days=rng.randrange(days))
            cause = self.pick_comp(rng)
            mean = C.COMP_CAUSE_SEVERITY[cause]
            exps = [self.exposure("COMP", "FIRST_PARTY", self.severity("COMP", mean, loss, 60000), mean, loss, cause=cause)]
            self.new_claim("NORMAL", policy, AUTO, loss, self.report_lag("auto"), cause, exps)

    def property_exposures(self, policy: Policy, cause: str, mean: float, loss: dt.date) -> list[Exposure]:
        rng = self.rng
        coverage_a = policy.dwelling[3] / 100
        total = rng.lognormal_mean(mean * trend_factor(loss), C.COVERAGE_CLAIM_PARAMS["DWELLING"]["sigma"])
        total = max(150.0, min(total, coverage_a))
        if cause == "THEFT":
            return [self.exposure("CONTENTS", "FIRST_PARTY", dollars_to_cents(total), mean, loss, cause=cause)]
        if rng.chance(C.HOME_CAUSE_CONTENTS_SHARE[cause]):
            dwelling, contents = total * (1 - C.CONTENTS_SPLIT), total * C.CONTENTS_SPLIT
            return [
                self.exposure("DWELLING", "FIRST_PARTY", dollars_to_cents(dwelling), mean * (1 - C.CONTENTS_SPLIT), loss, cause=cause),
                self.exposure("CONTENTS", "FIRST_PARTY", dollars_to_cents(contents), mean * C.CONTENTS_SPLIT, loss, cause=cause),
            ]
        return [self.exposure("DWELLING", "FIRST_PARTY", dollars_to_cents(total), mean, loss, cause=cause)]

    def home_claims(self, policy: Policy, start: dt.date, days: int, years: float, freq: float) -> None:
        rng = self.rng
        for _ in range(rng.poisson(C.HOME_PROPERTY_RATE * years * freq)):
            loss = start + dt.timedelta(days=rng.randrange(days))
            cause = self.pick_home(rng)
            exps = self.property_exposures(policy, cause, C.HOME_CAUSE_SEVERITY[cause], loss)
            self.new_claim("NORMAL", policy, HOME, loss, self.report_lag("property"), cause, exps)
        for _ in range(rng.poisson(C.HOME_LIABILITY_RATE * years * freq)):
            loss = start + dt.timedelta(days=rng.randrange(days))
            params = C.COVERAGE_CLAIM_PARAMS["PERS_LIAB"]
            ult = self.severity("PERS_LIAB", params["mean"], loss, params["cap"])
            exps = [self.exposure("PERS_LIAB", "THIRD_PARTY", ult, params["mean"], loss)]
            self.new_claim("NORMAL", policy, HOME, loss, self.report_lag("liability"), "LIABILITY", exps)

    def catastrophe_claims(self, terms: list) -> None:
        rng = self.rng
        for event in self.seeds.cat_events:
            if event.start > self.valuation:
                continue
            span = (min(event.end, self.valuation) - event.start).days
            for term in terms:
                policy = term.policy
                if policy.state not in event.states:
                    continue
                if not (term.start <= event.start < term.coverage_end):
                    continue
                loss = event.start + dt.timedelta(days=rng.randint(0, span))
                if policy.lob == HOME and rng.chance(C.CAT_HOME_CLAIM_PROB.get(event.code, 0.0)):
                    exps = self.property_exposures(policy, event.peril, C.CAT_SEVERITY[event.peril], loss)
                    self.new_claim("NORMAL", policy, HOME, loss, self.report_lag("cat"), event.peril, exps, event.code)
                elif (
                    policy.lob == AUTO and event.peril == "HAIL" and policy.has_physical_damage
                    and rng.chance(C.CAT_AUTO_HAIL_PROB)
                ):
                    mean = C.CAT_AUTO_HAIL_SEVERITY
                    exps = [self.exposure("COMP", "FIRST_PARTY", self.severity("COMP", mean, loss, 60000), mean, loss, cause="HAIL")]
                    self.new_claim("NORMAL", policy, AUTO, loss, self.report_lag("cat"), "HAIL", exps, event.code)

    # -- the plan of one exposure ---------------------------------------------------------------

    def plan_exposure(self, exp: Exposure, avg: float, loss_date: dt.date, cause: str) -> None:
        rng = self.rng
        p = C.COVERAGE_CLAIM_PARAMS[exp.coverage]
        trend = trend_factor(loss_date)
        groups = exp.groups
        initial = to_hundreds(avg * p["initial"] * trend)
        opening = [("OPEN",), ("RESERVE", LOSS, None, "INITIAL", initial)]
        groups.append(Group(0, opening))
        cwp = exp.ultimate == 0
        settle = rng.randint(15, 75) if cwp else rng.randint(*p["settle"])

        # Expenses: an adjusting fee (AO) for most exposures; defense costs (DCC) when a liability
        # claim is litigated.
        expense_type = None
        if not cwp and exp.coverage in C.DCC_SHARE and rng.chance(C.DCC_SHARE[exp.coverage]):
            expense_type = "DCC"
        elif rng.chance(C.AO_SHARE[exp.coverage]):
            expense_type = "AO"
        if expense_type == "AO":
            mean = C.AO_MEAN[exp.coverage] * trend
            exp.expense_ultimate = dollars_to_cents(rng.lognormal_mean(mean, 0.5))
            opening.append(("RESERVE", EXPENSE, "AO", "INITIAL", to_hundreds(mean)))
            groups.append(Group(rng.randint(max(1, settle // 3), settle), [("PAY", EXPENSE, "AO", exp.expense_ultimate, False)]))
        elif expense_type == "DCC":
            exp.expense_ultimate = dollars_to_cents(max(1500.0, rng.lognormal_mean(0.25 * exp.ultimate / 100, 0.6)))
            first = max(1, int(0.3 * settle))
            groups.append(Group(first, [("RESERVE", EXPENSE, "DCC", "INITIAL", to_hundreds(5000 * trend))]))
            groups.append(Group(max(first + 1, int(0.6 * settle)), [("REVISE", EXPENSE, "DCC", rng.lognormal_mean(1.0, 0.2))]))
            pay_days = sorted(rng.randint(max(first + 2, int(0.5 * settle)), settle) for _ in range(2))
            first_part = round(exp.expense_ultimate * rng.uniform(0.3, 0.6))
            groups.append(Group(pay_days[0], [("PAY", EXPENSE, "DCC", first_part, False)]))
            groups.append(Group(pay_days[1], [("PAY", EXPENSE, "DCC", exp.expense_ultimate - first_part, False)]))

        # Reserve revisions: estimate the remaining loss with a bias that fades over time.
        for _ in range(rng.randint(*p["revisions"])):
            day = rng.randint(1, max(1, settle - 1))
            if cwp:
                groups.append(Group(day, [("REVISE_DOWN", rng.uniform(0.2, 0.9))]))
            else:
                progress = day / settle
                bias = p["bias_early"] + (1 - p["bias_early"]) * progress
                groups.append(Group(day, [("REVISE", LOSS, None, bias * rng.lognormal_mean(1.0, 0.15))]))

        final = [("CLOSE",)]
        if not cwp:
            interim = 0
            if exp.coverage == "BI":
                interim = min(3, rng.poisson(1.0))
            elif exp.coverage in ("DWELLING", "CONTENTS"):
                interim = int(rng.chance(0.5)) + int(rng.chance(0.2))
            elif exp.coverage == "PERS_LIAB":
                interim = int(rng.chance(0.3))
            else:
                interim = int(rng.chance(p["extra_payment"]))
            paid = 0
            if interim:
                share = rng.uniform(0.15, 0.5) / interim
                lo, hi = max(1, int(0.15 * settle)), max(1, int(0.9 * settle))
                for day in sorted(rng.randint(lo, hi) for _ in range(interim)):
                    amount = round(exp.ultimate * share)
                    if amount > 0:
                        groups.append(Group(day, [("PAY", LOSS, None, amount, False)]))
                        paid += amount
            final.insert(0, ("PAY", LOSS, None, exp.ultimate - paid, True))
        groups.append(Group(settle, final))

        if not cwp:
            recovery_share = 0.0
            if exp.coverage == "COLL":
                recovery_share = C.RECOVERY_SHARE["COLL"]
            elif exp.coverage == "COMP" and cause == "THEFT":
                recovery_share = C.RECOVERY_SHARE["COMP_THEFT"]
            if rng.chance(recovery_share):
                amount = round(exp.ultimate * rng.uniform(0.3, 0.9))
                groups.append(Group(settle + rng.randint(30, 240), [("RECOVER", amount)]))

        for seq, group in enumerate(groups):
            group.seq = seq
        groups.sort(key=lambda g: (g.day, g.seq))

    # -- planted claim defects ------------------------------------------------------------------

    def plant_loss_outside_term(self, book: PolicyBook, count: int) -> None:
        """LOSS_OUTSIDE_TERM: a loss before the policy started or after it was cancelled.

        The adjuster opens the claim with an average reserve, finds there was no coverage and
        closes it without payment.
        """
        rng = self.rng
        early = [p for p in book.policies if p.terms and not p.is_test and p.original_effective_date >= dt.date(2022, 3, 1)]
        cancelled = [
            t for t in book.terms
            if t.cancel_date is not None and not t.policy.is_test
            and t.cancel_date + dt.timedelta(days=40) <= self.valuation
        ]
        planted = 0
        while planted < count:
            if rng.chance(0.5) or not cancelled:
                policy = rng.choice(early)
                loss = policy.original_effective_date - dt.timedelta(days=rng.randint(1, 30))
            else:
                term = rng.choice(cancelled)
                policy = term.policy
                loss = term.cancel_date + dt.timedelta(days=rng.randint(1, 30))
            if policy.lob == AUTO:
                coverage, claimant, cause, avg = "PD", "THIRD_PARTY", "COLLISION", 4500
            else:
                coverage, claimant, cause, avg = "DWELLING", "FIRST_PARTY", "WATER_DAMAGE", 12000
            exp = Exposure(coverage, claimant, 0, 0)
            initial = to_hundreds(avg * C.COVERAGE_CLAIM_PARAMS[coverage]["initial"] * trend_factor(loss))
            exp.groups = [
                Group(0, [("OPEN",), ("RESERVE", LOSS, None, "INITIAL", initial)]),
                Group(rng.randint(7, 45), [("CLOSE",)], seq=1),
            ]
            if self.new_claim("OUTSIDE_TERM", policy, policy.lob, loss, rng.randint(1, 10), cause, [exp]):
                planted += 1

    def plant_orphans(self, count: int) -> None:
        """ORPHAN_CLAIMS: claims on policies of a legacy book that was never migrated.

        They are opened and closed in the claims system without any financial transactions.
        """
        rng = self.rng
        first, last = dt.date(2022, 3, 1), self.valuation - dt.timedelta(days=60)
        used = set()
        while len(used) < count:
            lob = rng.choice([AUTO, HOME])
            number = rng.randint(*C.ORPHAN_POLICY_NUMBER_RANGE)
            if number in used:
                continue
            used.add(number)
            loss = first + dt.timedelta(days=rng.randint(0, (last - first).days))
            coverage, claimant, cause = ("PD", "THIRD_PARTY", "COLLISION") if lob == AUTO else ("DWELLING", "FIRST_PARTY", "WIND")
            exp = Exposure(coverage, claimant, 0, 0)
            exp.groups = [Group(0, [("OPEN",)]), Group(rng.randint(10, 60), [("CLOSE",)], seq=1)]
            claim = self.new_claim("ORPHAN", None, lob, loss, rng.randint(1, 20), cause, [exp])
            claim.policy_number = f"{'PA' if lob == AUTO else 'HO'}-{number:07d}"

    def plant_duplicates(self, count: int) -> None:
        """DELETED_CLAIMS: a second FNOL for the same loss, deleted in the source days later."""
        rng = self.rng
        originals = [
            c for c in self.claims
            if c.kind == "NORMAL" and c.reported_at.date() <= self.valuation - dt.timedelta(days=10)
        ]
        for original in rng.sample(originals, min(count, len(originals))):
            main = original.exposures[0]
            exp = Exposure(main.coverage, main.claimant_type, 0, 0)
            exp.groups = [Group(0, [("OPEN",)]), Group(rng.randint(1, 5), [("DELETE",)], seq=1)]
            lag = (original.reported_at.date() - original.loss_date).days + rng.randint(0, 2)
            dup = self.new_claim("DUPLICATE", original.policy, original.lob, original.loss_date, lag,
                                 original.loss_cause, [exp], original.cat_code)
            if dup is not None:
                dup.team = original.team

    # -- simulation -----------------------------------------------------------------------------

    def run(self, book: PolicyBook) -> ClaimsBook:
        rng = self.rng
        horizon = self.valuation + dt.timedelta(days=1)
        for term in book.terms:
            policy = term.policy
            end = min(term.coverage_end, horizon)
            days = (end - term.start).days
            if days <= 0:
                continue
            years = days / 365.25
            freq = policy.risk_factor * C.STATE_FACTOR[policy.lob][policy.state]
            if policy.lob == AUTO:
                self.auto_claims(policy, term.start, days, years, freq)
            else:
                self.home_claims(policy, term.start, days, years, freq)
        self.catastrophe_claims(book.terms)

        regular = sum(1 for c in self.claims if c.kind == "NORMAL")
        for claim in self.claims:
            claim.reopen_planned = rng.chance(C.REOPEN_SHARE)
        self.plant_loss_outside_term(book, max(1, round(regular * C.LOSS_OUTSIDE_TERM_SHARE)))
        self.plant_orphans(self.cfg.scaled(C.ORPHAN_CLAIM_COUNT))
        self.plant_duplicates(max(1, round(regular * C.DELETED_CLAIM_SHARE)))

        claims = sorted(self.claims, key=lambda c: (c.reported_at, c.policy_number, c.loss_date, c.kind))
        per_year: dict[int, int] = {}
        for n, claim in enumerate(claims, start=1):
            claim.claim_id = n
            year = claim.reported_at.year
            per_year[year] = per_year.get(year, 0) + 1
            claim.claim_number = f"CL-{year}-{per_year[year]:06d}"
        adjusters = self.make_adjusters()
        for claim in claims:
            self.assign_adjuster(claim, adjusters)
            self.play_out(claim)

        # Exposures that open at the same moment are ordered by claim, then by plan order.
        index = {id(e): (c.claim_id, i) for c in claims for i, e in enumerate(c.exposures)}
        exposures = sorted(
            (e for c in claims for e in c.exposures if e.opened_at is not None),
            key=lambda e: (e.opened_at, index[id(e)]),
        )
        for n, exp in enumerate(exposures, start=1):
            exp.exposure_id = n
        transactions = sorted(
            (t for c in claims for t in c.transactions),
            key=lambda t: (t.created_at, t.claim.claim_id, t.seq),
        )
        for n, txn in enumerate(transactions, start=1):
            txn.claim_transaction_id = n
        return ClaimsBook(claims, exposures, transactions, adjusters)

    # -- adjusters ------------------------------------------------------------------------------

    def make_adjusters(self) -> list[Adjuster]:
        from .people import random_name

        rng = self.rng
        adjusters = []
        for team in TEAMS:
            size = self.cfg.scaled(TEAM_SIZE[team], minimum=2)
            for i in range(size):
                first, last = random_name(rng)
                if i < size * 0.8:
                    hired = dt.date(2012, 1, 1) + dt.timedelta(days=rng.randint(0, 3600))
                else:
                    hired = dt.date(2022, 3, 1) + dt.timedelta(days=rng.randint(0, (self.valuation - dt.date(2022, 3, 1)).days - 30))
                versions = [(rng.office_time(hired), team, True)]
                if i >= 2 and rng.chance(0.15):
                    left = max(hired, dt.date(2022, 6, 1)) + dt.timedelta(days=rng.randint(30, 900))
                    if left < self.valuation:
                        versions.append((rng.office_time(left), team, False))
                adjusters.append(Adjuster(0, f"{first} {last}", team, hired, versions))
        adjusters.sort(key=lambda a: (a.versions[0][0], a.name))
        for n, adj in enumerate(adjusters, start=1):
            adj.adjuster_id = n
        return adjusters

    def assign_adjuster(self, claim: Claim, adjusters: list[Adjuster]) -> None:
        day = claim.reported_at.date()
        team = [a for a in adjusters if a.team == claim.team]
        active = [a for a in team if a.active_on(day)] or team
        claim.adjuster_id = self.rng.choice(active).adjuster_id

    # -- playing out one claim ------------------------------------------------------------------

    def play_out(self, claim: Claim) -> None:
        """Turn the exposure plans into timestamped transactions and status versions."""
        rng = self.rng
        report_day = claim.reported_at.date()

        # 1. Reopen: a few claims reopen one exposure after the whole claim has closed.
        if claim.kind == "NORMAL" and claim.reopen_planned:
            closed_day = max(
                e.open_day + g.day for e in claim.exposures for g in e.groups if g.actions[-1][0] == "CLOSE"
            )
            main = claim.exposures[0]
            reopen_day = closed_day - main.open_day + rng.randint(30, 180)
            amount = to_hundreds(max(500.0, main.ultimate / 100 * rng.uniform(0.1, 0.4)))
            payment = round(amount * rng.uniform(0.6, 1.3))
            main.groups.append(Group(reopen_day, [("REOPEN", amount)], seq=900))
            main.groups.append(Group(reopen_day + rng.randint(20, 90), [("PAY", LOSS, None, payment, False), ("CLOSE",)], seq=901))
            main.groups.sort(key=lambda g: (g.day, g.seq))

        # 2. Timestamps. The FNOL group happens at reported_at; later groups during office hours,
        # kept in plan order within an exposure.
        for exp in claim.exposures:
            previous = None
            for group in exp.groups:
                group.exposure = exp
                day = report_day + dt.timedelta(days=exp.open_day + group.day)
                if exp.open_day == 0 and group.day == 0:
                    at = claim.reported_at
                else:
                    at = rng.office_time(day)
                if previous is not None and at <= previous:
                    at = previous + dt.timedelta(minutes=rng.randint(1, 5))
                group.at = previous = at

        # 3. Voided payments: an interim payment is voided days later (a lost check, a wrong
        # payee) and reissued before the exposure's next event.
        for exp in claim.exposures:
            inserted = []
            for i, group in enumerate(exp.groups[:-1]):
                action = group.actions[0]
                if action[0] != "PAY" or action[4] or not rng.chance(C.VOID_SHARE_OF_INTERIM_PAYMENTS):
                    continue
                gap = (exp.groups[i + 1].at.date() - group.at.date()).days
                if gap < 10:
                    continue
                void_day = group.at.date() + dt.timedelta(days=rng.randint(3, gap - 5))
                room = (exp.groups[i + 1].at.date() - void_day).days - 1
                reissue_day = void_day + dt.timedelta(days=rng.randint(1, min(3, room)))
                void = Group(0, [("VOID", group)], exposure=exp, at=rng.office_time(void_day))
                reissue = Group(0, [("PAY", action[1], action[2], action[3], False)], exposure=exp,
                                at=rng.office_time(reissue_day))
                inserted += [void, reissue]
            exp.groups.extend(inserted)

        groups = [g for e in claim.exposures for g in e.groups if g.at <= self.valuation_end]
        order = {id(e): i for i, e in enumerate(claim.exposures)}
        groups.sort(key=lambda g: (g.at, order[id(g.exposure)], g.seq))

        # 4. Late entries: a payment, recovery or revision keyed in 1-20 days after its date, but
        # never before the claim's previous event, so entry order and date order agree.
        previous_day = None
        for group in groups:
            day = group.at.date()
            kind = group.actions[0][0]
            if (
                previous_day is not None and kind in ("PAY", "RECOVER", "REVISE", "REVISE_DOWN")
                and rng.chance(C.LATE_CLAIM_TRANSACTION_SHARE)
            ):
                gap = (day - previous_day).days
                if gap >= 2:
                    group.late_date = day - dt.timedelta(days=rng.randint(1, min(C.LATE_MAX_DAYS, gap - 1)))
            previous_day = day

        self.post(claim, groups)

    def post(self, claim: Claim, groups: list[Group]) -> None:
        """Walk the claim's events in order, keeping the running reserves, and write the rows."""
        reserve: dict[tuple, int] = {}
        paid: dict[int, int] = {}
        expense_paid: dict[int, int] = {}
        erosion_of: dict[int, tuple] = {}  # id(pay group) -> (payment row, erosion amount)
        status: dict[int, str] = {}
        expected = {id(e) for e in claim.exposures if e.groups[0].at <= self.valuation_end}
        claim.versions.append((claim.reported_at, "OPEN", None, False))
        seq = 0

        def row(exp, ttype, category, etype, reason, amount, tdate, at):
            nonlocal seq
            seq += 1
            txn = ClaimTransaction(claim, exp, ttype, category, etype, reason, amount, tdate, at, seq)
            claim.transactions.append(txn)
            return txn

        for group in groups:
            exp = group.exposure
            key = id(exp)
            at = group.at
            today = at.date()
            dated = group.late_date or today
            for action in group.actions:
                kind = action[0]
                if kind == "OPEN":
                    exp.opened_at = at
                    exp.versions.append((at, "OPEN", None, False))
                    status[key] = "OPEN"
                    reserve[(key, LOSS)] = reserve[(key, EXPENSE)] = 0
                    paid[key] = expense_paid[key] = 0
                elif kind == "RESERVE":
                    _, category, etype, reason, amount = action
                    reserve[(key, category)] += amount
                    row(exp, "RESERVE", category, etype, reason, amount, today, at)
                elif kind in ("REVISE", "REVISE_DOWN"):
                    if kind == "REVISE_DOWN":
                        category, etype = LOSS, None
                        target = to_hundreds(reserve[(key, LOSS)] / 100 * action[1]) if reserve[(key, LOSS)] else 0
                    else:
                        _, category, etype, multiplier = action
                        if category == LOSS:
                            remaining = exp.ultimate - paid[key]
                        else:
                            remaining = exp.expense_ultimate - expense_paid[key]
                        target = to_hundreds(max(remaining, 0) / 100 * multiplier) if remaining > 0 else 0
                    change = target - reserve[(key, category)]
                    if abs(change) >= 100_00:
                        reserve[(key, category)] += change
                        row(exp, "RESERVE", category, etype, "REVISION", change, dated, at)
                elif kind == "PAY":
                    _, category, etype, amount, _final = action
                    if amount <= 0:
                        continue
                    payment = row(exp, "PAYMENT", category, etype, None, amount, dated, at)
                    erosion = -min(amount, reserve[(key, category)])
                    if erosion:
                        reserve[(key, category)] += erosion
                        row(exp, "RESERVE", category, etype, "PAYMENT_EROSION", erosion, dated, at)
                    erosion_of[id(group)] = (payment, erosion)
                    if category == LOSS:
                        paid[key] += amount
                    else:
                        expense_paid[key] += amount
                elif kind == "VOID":
                    found = erosion_of.get(id(action[1]))
                    if found is None:
                        continue  # the payment itself was after the valuation date
                    payment, erosion = found
                    payment.voided_at = at
                    if erosion:
                        reserve[(key, payment.cost_category)] -= erosion
                        row(exp, "RESERVE", payment.cost_category, payment.expense_type, "VOID_RESTORE", -erosion, today, at)
                    if payment.cost_category == LOSS:
                        paid[key] -= payment.amount
                    else:
                        expense_paid[key] -= payment.amount
                elif kind == "RECOVER":
                    row(exp, "RECOVERY", LOSS, None, None, action[1], dated, at)
                elif kind == "CLOSE":
                    for category, etype in ((LOSS, None), (EXPENSE, self.expense_type_of(claim, exp))):
                        left = reserve[(key, category)]
                        if left > 0:
                            reserve[(key, category)] = 0
                            row(exp, "RESERVE", category, etype, "CLOSE", -left, today, at)
                    exp.versions.append((at, "CLOSED", at, False))
                    status[key] = "CLOSED"
                    if all(status.get(k) == "CLOSED" for k in expected) and claim.versions[-1][1] != "CLOSED":
                        claim.versions.append((at, "CLOSED", at, False))
                elif kind == "REOPEN":
                    amount = action[1]
                    reserve[(key, LOSS)] += amount
                    row(exp, "RESERVE", LOSS, None, "REOPEN", amount, today, at)
                    exp.versions.append((at, "OPEN", None, False))
                    status[key] = "OPEN"
                    if claim.versions[-1][1] == "CLOSED":
                        claim.versions.append((at, "REOPENED", None, False))
                elif kind == "DELETE":
                    exp.versions.append((at, exp.versions[-1][1], exp.versions[-1][2], True))
                    last = claim.versions[-1]
                    claim.versions.append((at, last[1], last[2], True))

    @staticmethod
    def expense_type_of(claim: Claim, exp: Exposure) -> str | None:
        for txn in reversed(claim.transactions):
            if txn.exposure is exp and txn.cost_category == EXPENSE:
                return txn.expense_type
        return None


def simulate_claims(cfg: Config, seeds: Seeds, book: PolicyBook, rng: Rng) -> ClaimsBook:
    return ClaimsSimulator(cfg, seeds, rng).run(book)
