"""The policy administration system: customers, policies, terms and premium transactions.

How a policy lives (docs/source-systems.md, 3a and 3b):

1. A customer buys a policy (it is *bound*). The NEW_BUSINESS transaction writes the full term
   premium, dated the bind date and effective on the term start, which can be up to 30 days later.
2. During the term, some policies are *endorsed* (a driver added, a vehicle garaged elsewhere):
   the premium change for the rest of the term is written. Some endorsements are backdated: they
   take effect before the day they are processed.
3. Some terms are *cancelled* mid-term: at the insured's request, for nonpayment (monthly plans
   only) or by underwriting. The cancellation returns the unearned premium pro rata. A few
   nonpayment cancellations are *reinstated* within 15 days, which reverses the cancellation.
4. Thirty days before a term expires, the renewal batch decides whether the policy renews
   (about 88% of auto and 90% of home terms do). A RENEWAL transaction writes the next term's
   premium at the new rate level, so premium is written before the term starts.
5. At expiration a nightly batch marks the term EXPIRED; the policy is EXPIRED if it did not renew.

Every change to a policy or term row is recorded as a version (`versions` lists), because the
source system overwrites rows and the loader must be able to show any point in time.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field

from . import config as C
from .config import Config
from .money import dollars_to_cents, round_half_away
from .people import email_for, random_birth_date, random_name, random_zip
from .rand import Rng, WeightedChoice
from .seeds import Seeds
from .timeline import ONE_DAY, add_months

AUTO, HOME = "AUTO", "HOME"
MAKES = ["Aurelo", "Brisken", "Calvara", "Drevon", "Elsby", "Fenrow", "Graylin", "Halvex"]
BODY_TYPES = {"SEDAN": 0.38, "SUV": 0.34, "PICKUP": 0.14, "MINIVAN": 0.07, "COUPE": 0.07}
CONSTRUCTION = {"FRAME": 0.60, "MASONRY": 0.30, "SUPERIOR": 0.10}


@dataclass(slots=True, eq=False)
class Policyholder:
    first_name: str
    last_name: str
    date_of_birth: dt.date
    email: str
    state: str
    zip: str
    created_at: dt.datetime
    is_test: bool
    policyholder_id: int = 0
    # (version_at, updated_at, zip, is_deleted): one entry per change of the source row
    versions: list = field(default_factory=list)


@dataclass(slots=True, eq=False)
class PolicyTransaction:
    term: "Term"
    transaction_type: str
    transaction_date: dt.date
    effective_date: dt.date
    created_at: dt.datetime
    lines: list  # [(coverage_code, written_cents)]
    transaction_id: int = 0
    booked: int = -1  # index of the accounting period it is booked in (set by controls)

    @property
    def written(self) -> int:
        return sum(cents for _, cents in self.lines)


@dataclass(slots=True, eq=False)
class CancelPlan:
    reason: str
    effective: dt.date
    processed_at: dt.datetime
    is_flat: bool
    missed_due: dt.date | None = None  # nonpayment: the first installment that was not paid
    reinstated_at: dt.datetime | None = None


@dataclass(slots=True, eq=False)
class Term:
    policy: "Policy"
    term_number: int
    start: dt.date
    expiration: dt.date
    created_at: dt.datetime
    term_id: int = 0
    status: str = "ACTIVE"
    cancel_date: dt.date | None = None
    cancel_reason: str | None = None
    written_cents: int = 0
    cancel_plan: CancelPlan | None = None  # what happened, for billing; None if never cancelled
    transactions: list = field(default_factory=list)
    # (version_at, status, cancel_date, cancel_reason, written_cents)
    versions: list = field(default_factory=list)

    @property
    def days(self) -> int:
        return (self.expiration - self.start).days

    @property
    def coverage_end(self) -> dt.date:
        """Exclusive end of coverage in the current state: the cancellation date or expiration."""
        return self.cancel_date if self.cancel_date is not None else self.expiration

    def record(self, txn: PolicyTransaction) -> None:
        self.transactions.append(txn)
        self.written_cents += txn.written
        self.snapshot(txn.created_at)

    def snapshot(self, at: dt.datetime) -> None:
        self.versions.append((at, self.status, self.cancel_date, self.cancel_reason, self.written_cents))


@dataclass(slots=True, eq=False)
class Policy:
    lob: str
    state: str
    channel: str
    holder: Policyholder
    bind_date: dt.date
    original_effective_date: dt.date
    is_test: bool
    billing_plan: str
    payment_method: str
    rating_factor: float  # premium relativity; endorsements change it
    risk_factor: float  # true claim frequency relativity
    coverages: list
    units: int  # vehicles, or 1 dwelling
    vehicles: list = field(default_factory=list)  # (model_year, make, body_type)
    dwelling: tuple | None = None  # (year_built, construction, square_feet, coverage_a_cents)
    created_at: dt.datetime | None = None
    policy_id: int = 0
    terms: list = field(default_factory=list)
    versions: list = field(default_factory=list)  # (version_at, status, is_deleted)
    has_physical_damage: bool = False

    @property
    def policy_number(self) -> str:
        return f"{'PA' if self.lob == AUTO else 'HO'}-{self.policy_id:07d}"

    @property
    def status(self) -> str:
        return self.versions[-1][1]

    def set_status(self, at: dt.datetime, status: str) -> None:
        if status != self.status:
            self.versions.append((at, status, False))


@dataclass
class PolicyBook:
    holders: list
    policies: list  # every policy, including test and soft-deleted ones
    terms: list
    transactions: list


class PolicySimulator:
    def __init__(self, cfg: Config, seeds: Seeds, rng: Rng):
        self.cfg = cfg
        self.seeds = seeds
        self.rng = rng
        self.valuation = cfg.valuation_date
        self.valuation_end = cfg.valuation_end
        self.pick_state = WeightedChoice(C.STATE_WEIGHTS)
        self.pick_channel = WeightedChoice(C.CHANNEL_WEIGHTS)
        self.pick_method = WeightedChoice(C.PAYMENT_METHOD_WEIGHTS)
        self.pick_vehicles = WeightedChoice(C.VEHICLE_COUNT_WEIGHTS)
        self.pick_body = WeightedChoice(BODY_TYPES)
        self.pick_construction = WeightedChoice(CONSTRUCTION)
        self.rate_level = {}
        level = 1.0
        for year in sorted(C.RATE_CHANGE):
            level *= 1 + C.RATE_CHANGE[year]
            self.rate_level[year] = level
        self.holders: list[Policyholder] = []
        self.policies: list[Policy] = []
        self.email_sequence = 0

    # -- customers ------------------------------------------------------------------------------

    def new_holder(self, state: str, created_at: dt.datetime, is_test: bool) -> Policyholder:
        rng = self.rng
        first, last = random_name(rng)
        self.email_sequence += 1
        holder = Policyholder(
            first_name=first,
            last_name=last,
            date_of_birth=random_birth_date(rng, created_at.date()),
            email=email_for(first, last, self.email_sequence, is_test),
            state=state,
            zip=random_zip(rng, state),
            created_at=created_at,
            is_test=is_test,
        )
        self.holders.append(holder)
        return holder

    # -- new business ---------------------------------------------------------------------------

    def run(self) -> PolicyBook:
        rng = self.rng
        cfg = self.cfg
        applications = []  # (bind_date, is_test)
        months = []
        day = C.START_DATE
        while day <= self.valuation:
            months.append(day)
            day = add_months(day, 1)
        for i, month_start in enumerate(months):
            share = i / max(1, len(months) - 1)
            target = C.NEW_BUSINESS_FIRST_MONTH + (C.NEW_BUSINESS_LAST_MONTH - C.NEW_BUSINESS_FIRST_MONTH) * share
            month_end = min(add_months(month_start, 1) - ONE_DAY, self.valuation)
            span = (month_end - month_start).days
            for _ in range(rng.poisson(target * cfg.scale)):
                applications.append((month_start + dt.timedelta(days=rng.randint(0, span)), False))
        first_test, last_test = dt.date(2022, 2, 1), self.valuation - dt.timedelta(days=30)
        for _ in range(cfg.scaled(C.TEST_POLICY_COUNT, minimum=2)):
            applications.append((first_test + dt.timedelta(days=rng.randint(0, (last_test - first_test).days)), True))
        applications.sort(key=lambda a: a[0])

        auto_holders_by_state: dict[str, list[Policyholder]] = {}
        for n, (bind_date, is_test) in enumerate(applications):
            lob = AUTO if rng.chance(C.AUTO_SHARE) else HOME
            state = self.pick_state(rng)
            lead = 0 if rng.chance(0.4) else rng.randint(1, 30)
            effective = bind_date + dt.timedelta(days=lead)
            if n == 0 and not is_test:
                bind_date = effective = C.START_DATE  # the very first policy starts the book
            holder = None
            if lob == HOME and not is_test and rng.chance(C.HOME_EXISTING_CUSTOMER_SHARE):
                candidates = auto_holders_by_state.get(state, [])
                if candidates:
                    candidate = rng.choice(candidates)
                    if candidate.created_at.date() < bind_date:
                        holder = candidate
            policy = self.new_policy(lob, state, bind_date, effective, is_test, holder)
            if lob == AUTO and not is_test:
                auto_holders_by_state.setdefault(state, []).append(policy.holder)

        self.plant_soft_deleted_policyholders()
        self.plant_soft_deleted_policies()
        self.change_addresses()
        return self.assign_ids()

    def new_policy(self, lob, state, bind_date, effective, is_test, holder) -> Policy:
        rng = self.rng
        risk = rng.lognormal_mean(1.0, 0.25)
        has_pd = lob == AUTO and rng.chance(C.PHYSICAL_DAMAGE_SHARE)
        if lob == AUTO:
            coverages = ["BI", "PD"] + (["COLL", "COMP"] if has_pd else [])
            units = self.pick_vehicles(rng)
        else:
            coverages = list(self.seeds.coverages[HOME])
            units = 1
        policy = Policy(
            lob=lob,
            state=state,
            channel=self.pick_channel(rng),
            holder=holder,  # filled in below once the entry time is known, if new
            bind_date=bind_date,
            original_effective_date=effective,
            is_test=is_test,
            billing_plan="MONTHLY" if rng.chance(C.MONTHLY_PLAN_SHARE) else "PAY_IN_FULL",
            payment_method=self.pick_method(rng),
            # Pricing is good but not perfect: the premium relativity tracks the true risk with
            # some noise, so the loss ratio varies by policy as it would in a real book.
            rating_factor=risk * rng.lognormal_mean(1.0, 0.10),
            risk_factor=risk,
            coverages=coverages,
            units=units,
            has_physical_damage=has_pd,
        )
        if lob == AUTO:
            for _ in range(units):
                policy.vehicles.append(
                    (bind_date.year - rng.randint(0, 14), rng.choice(MAKES), self.pick_body(rng))
                )
        else:
            square_feet = rng.randint(10, 40) * 100
            coverage_a = round(square_feet * rng.uniform(120, 210), -3)
            policy.dwelling = (
                rng.randint(1955, bind_date.year - 1),
                self.pick_construction(rng),
                square_feet,
                dollars_to_cents(coverage_a),
            )
        self.simulate_terms(policy)
        if policy.holder is None:
            policy.holder = self.new_holder(state, policy.created_at, is_test)
        self.policies.append(policy)
        return policy

    # -- premium --------------------------------------------------------------------------------

    def term_premium(self, policy: Policy, start: dt.date) -> dict[str, int]:
        """Full-term premium per coverage, in cents, at the rate level of the term's start."""
        level = self.rate_level[start.year]
        noise = self.rng.uniform(0.98, 1.02)
        state_factor = C.STATE_FACTOR[policy.lob][policy.state]
        return {
            cov: dollars_to_cents(C.BASE_RATE[cov] * state_factor * policy.rating_factor * policy.units * level * noise)
            for cov in policy.coverages
        }

    # -- the life of a policy -------------------------------------------------------------------

    def entry_time(self, dated: dt.date, next_event: dt.date | None) -> dt.datetime:
        """When a transaction dated `dated` was keyed in.

        Usually the same day. A few (LATE_ENTERED_TRANSACTIONS) are entered 1-20 days later, but
        never after the next event on the same term, so the order of entry and the order of
        transaction dates agree, and never after the valuation date.
        """
        rng = self.rng
        if rng.chance(C.LATE_POLICY_TRANSACTION_SHARE):
            limit = min(C.LATE_MAX_DAYS, (self.valuation - dated).days)
            if next_event is not None:
                limit = min(limit, (next_event - dated).days - 1)
            if limit >= 1:
                return rng.office_time(dated + dt.timedelta(days=rng.randint(1, limit)))
        return rng.office_time(dated)

    def plan_cancellation(self, policy: Policy, term: Term) -> CancelPlan | None:
        rng = self.rng
        r = rng.random()
        p_insured, p_uw = C.CANCEL_INSURED_REQUEST, C.CANCEL_UNDERWRITING
        p_nonpay = C.CANCEL_NONPAYMENT_MONTHLY if policy.billing_plan == "MONTHLY" else 0.0
        start, days = term.start, term.days
        earliest = term.created_at.date() + ONE_DAY
        if r < p_insured:
            if rng.chance(C.FLAT_CANCEL_SHARE):
                processed = max(start + dt.timedelta(days=rng.randint(1, 10)), earliest)
                return CancelPlan("INSURED_REQUEST", start, rng.office_time(processed), True)
            effective = start + dt.timedelta(days=rng.randint(10, days - 50))
            processed = max(effective - dt.timedelta(days=rng.randint(0, 5)), earliest)
            return CancelPlan("INSURED_REQUEST", effective, rng.office_time(processed), False)
        if r < p_insured + p_uw:
            effective = start + dt.timedelta(days=rng.randint(60, days - 50))
            processed = effective - dt.timedelta(days=C.UNDERWRITING_NOTICE_DAYS)
            return CancelPlan("UNDERWRITING", effective, rng.office_time(processed), False)
        if r < p_insured + p_uw + p_nonpay:
            # The insured stops paying: installment k is missed and, after the notice period, a
            # nightly batch cancels the term. The first new business installment is paid at bind.
            first = 2 if term.term_number == 1 else 1
            installments = C.TERM_MONTHS[policy.lob]
            choices = []
            for k in range(first, installments + 1):
                due = add_months(start, k - 1)
                if due + dt.timedelta(days=C.NONPAYMENT_NOTICE_DAYS) <= term.expiration - dt.timedelta(days=50):
                    choices.append(due)
            if not choices:
                return None
            due = rng.choice(choices)
            effective = due + dt.timedelta(days=C.NONPAYMENT_NOTICE_DAYS)
            plan = CancelPlan("NONPAYMENT", effective, rng.batch_time(effective, 1), False, missed_due=due)
            if rng.chance(C.REINSTATEMENT_SHARE):
                plan.reinstated_at = rng.office_time(effective + dt.timedelta(days=rng.randint(1, 15)))
            return plan
        return None

    def simulate_terms(self, policy: Policy) -> None:
        rng = self.rng
        lob = policy.lob
        start = policy.original_effective_date
        bind_date = policy.bind_date
        renewal_created: dt.datetime | None = None
        term_number = 1
        while True:
            expiration = add_months(start, C.TERM_MONTHS[lob])
            days = (expiration - start).days
            renewal_date = expiration - dt.timedelta(days=C.RENEWAL_LEAD_DAYS)
            # Placeholder creation time: for new business it is fixed below, once we know
            # whether the entry was late.
            term = Term(policy, term_number, start, expiration, renewal_created or rng.office_time(bind_date))
            cancel = self.plan_cancellation(policy, term)

            endorsement = None
            if rng.chance(C.ENDORSEMENT_RATE[lob]):
                processed = start + dt.timedelta(days=rng.randint(5, days - 35))
                if cancel is None or (not cancel.is_flat and processed < cancel.processed_at.date()):
                    effective = processed
                    if rng.chance(C.BACKDATED_SHARE):
                        effective = max(start, processed - dt.timedelta(days=rng.randint(1, 30)))
                    up = rng.chance(0.65)
                    change_bp = rng.randint(500, 2500) if up else -rng.randint(500, 2000)
                    endorsement = (processed, effective, change_bp)

            next_event_dates = [renewal_date]
            if endorsement:
                next_event_dates.append(endorsement[0])
            if cancel:
                next_event_dates.append(cancel.processed_at.date())
            first_next = min(next_event_dates)

            premium = self.term_premium(policy, start)
            if term_number == 1:
                created = self.entry_time(bind_date, first_next)
                term.created_at = created
                policy.created_at = created
                policy.versions.append((created, "ACTIVE", False))
                txn = PolicyTransaction(term, "NEW_BUSINESS", bind_date, start, created, list(premium.items()))
            else:
                txn = PolicyTransaction(term, "RENEWAL", renewal_created.date(), start, renewal_created, list(premium.items()))
            term.record(txn)
            policy.terms.append(term)
            inforce = dict(premium)

            # Endorsement: the full-term premium of each coverage changes by change_bp basis
            # points; the transaction writes that change times the remaining fraction of the term.
            if endorsement:
                processed, effective, change_bp = endorsement
                next_after = cancel.processed_at.date() if cancel else renewal_date
                created = self.entry_time(processed, next_after)
                if created <= self.valuation_end:
                    lines = []
                    for cov in policy.coverages:
                        delta_full = round_half_away(inforce[cov] * change_bp, 10_000)
                        inforce[cov] += delta_full
                        lines.append((cov, round_half_away(delta_full * (expiration - effective).days, days)))
                    term.record(PolicyTransaction(term, "ENDORSEMENT", processed, effective, created, lines))
                    # The change in exposure (a driver added, say) changes risk and price alike.
                    policy.rating_factor *= 1 + change_bp / 10_000
                    policy.risk_factor *= 1 + change_bp / 10_000

            if cancel and cancel.processed_at <= self.valuation_end:
                created = cancel.processed_at
                if cancel.reason == "INSURED_REQUEST":
                    created = self.entry_time(cancel.processed_at.date(), None)
                cancel.processed_at = created
                # Return the unearned part of each coverage's in-force (full-term) premium.
                remaining = (expiration - cancel.effective).days
                lines = [(cov, -round_half_away(inforce[cov] * remaining, days)) for cov in policy.coverages]
                term.status, term.cancel_date, term.cancel_reason = "CANCELLED", cancel.effective, cancel.reason
                term.cancel_plan = cancel
                term.record(PolicyTransaction(term, "CANCELLATION", created.date(), cancel.effective, created, lines))
                policy.set_status(created, "CANCELLED")
                if cancel.reinstated_at is not None and cancel.reinstated_at <= self.valuation_end:
                    # Reinstatement reverses the cancellation exactly, effective on its date.
                    at = cancel.reinstated_at
                    term.status, term.cancel_date, term.cancel_reason = "ACTIVE", None, None
                    reverse = [(cov, -cents) for cov, cents in lines]
                    term.record(PolicyTransaction(term, "REINSTATEMENT", at.date(), cancel.effective, at, reverse))
                    policy.set_status(at, "ACTIVE")
                else:
                    cancel.reinstated_at = None
                    return  # a cancelled policy does not renew

            if renewal_date > self.valuation:
                return  # the renewal decision has not been made yet
            if not rng.chance(C.RETENTION[lob]):
                if expiration <= self.valuation:
                    at = rng.batch_time(expiration, 1)
                    term.status = "EXPIRED"
                    term.snapshot(at)
                    policy.set_status(at, "EXPIRED")
                return
            renewal_created = rng.batch_time(renewal_date, 2)
            if expiration <= self.valuation:
                term.status = "EXPIRED"
                term.snapshot(rng.batch_time(expiration, 1))
            start = expiration
            term_number += 1

    # -- planted defects on customers and policies ----------------------------------------------

    def plant_soft_deleted_policyholders(self) -> None:
        """SOFT_DELETED_POLICYHOLDERS: duplicate customer records, removed in the source."""
        rng = self.rng
        originals = [h for h in self.holders if not h.is_test]
        planted = 0
        target = self.cfg.scaled(C.SOFT_DELETED_POLICYHOLDER_COUNT)
        while planted < target:
            original = rng.choice(originals)
            created = rng.office_time(original.created_at.date() + dt.timedelta(days=rng.randint(0, 3)))
            deleted = rng.office_time(created.date() + dt.timedelta(days=rng.randint(1, 30)))
            if deleted > self.valuation_end:
                continue
            dup = Policyholder(
                original.first_name, original.last_name, original.date_of_birth, original.email,
                original.state, original.zip, created, False,
            )
            dup.versions = [(created, created, dup.zip, False), (deleted, created, dup.zip, True)]
            self.holders.append(dup)
            planted += 1

    def plant_soft_deleted_policies(self) -> None:
        """SOFT_DELETED_POLICIES: policies created in error and deleted, with no transactions."""
        rng = self.rng
        holders = [h for h in self.holders if not h.is_test and not h.versions]
        planted = 0
        target = self.cfg.scaled(C.SOFT_DELETED_POLICY_COUNT)
        while planted < target:
            holder = rng.choice(holders)
            first = holder.created_at.date() + ONE_DAY
            if first >= self.valuation - dt.timedelta(days=10):
                continue
            created = rng.office_time(first + dt.timedelta(days=rng.randint(0, (self.valuation - first).days - 10)))
            deleted = rng.office_time(created.date() + dt.timedelta(days=rng.randint(1, 5)))
            lob = rng.choice([AUTO, HOME])
            effective = created.date() + dt.timedelta(days=rng.randint(0, 20))
            policy = Policy(
                lob=lob, state=holder.state, channel=self.pick_channel(rng), holder=holder,
                bind_date=created.date(), original_effective_date=effective, is_test=False,
                billing_plan="PAY_IN_FULL", payment_method="CARD", rating_factor=1.0,
                risk_factor=1.0, coverages=[], units=0, created_at=created,
            )
            policy.versions = [(created, "ACTIVE", False), (deleted, "ACTIVE", True)]
            self.policies.append(policy)
            planted += 1

    def change_addresses(self) -> None:
        """About 5% of customers move within their state; updated_at changes with the address."""
        rng = self.rng
        for holder in self.holders:
            if holder.versions:
                continue  # soft-deleted duplicates keep their two versions
            holder.versions.append((holder.created_at, holder.created_at, holder.zip, False))
            first = holder.created_at.date() + dt.timedelta(days=30)
            if first < self.valuation and rng.chance(0.05):
                moved = rng.office_time(first + dt.timedelta(days=rng.randint(0, (self.valuation - first).days)))
                holder.versions.append((moved, moved, random_zip(rng, holder.state), False))

    # -- identifiers ----------------------------------------------------------------------------

    def assign_ids(self) -> PolicyBook:
        """Source systems hand out ids in the order rows are entered."""
        holders = sorted(self.holders, key=lambda h: (h.created_at, h.email))
        for i, holder in enumerate(holders, start=1):
            holder.policyholder_id = i
        policies = sorted(self.policies, key=lambda p: (p.created_at, p.holder.policyholder_id, p.lob))
        regular_id, test_id = 1, C.TEST_POLICY_ID_START
        for policy in policies:
            if policy.is_test:
                policy.policy_id, test_id = test_id, test_id + 1
            else:
                policy.policy_id, regular_id = regular_id, regular_id + 1
        terms = sorted((t for p in policies for t in p.terms), key=lambda t: (t.created_at, t.policy.policy_id))
        for i, term in enumerate(terms, start=1):
            term.term_id = i
        transactions = sorted(
            (x for t in terms for x in t.transactions),
            key=lambda x: (x.created_at, x.term.term_id, x.transaction_date),
        )
        for i, txn in enumerate(transactions, start=1):
            txn.transaction_id = i
        return PolicyBook(holders, policies, terms, transactions)


def simulate_policies(cfg: Config, seeds: Seeds, rng: Rng) -> PolicyBook:
    return PolicySimulator(cfg, seeds, rng).run()
