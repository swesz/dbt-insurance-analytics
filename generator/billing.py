"""The billing system: installment schedules and the payments that settle them.

Every policy transaction is billed. New business and renewals are billed in one installment
(PAY_IN_FULL) or in monthly installments (6 for auto, 12 for home); endorsements, cancellations
and reinstatements are billed as a single installment. The installments of a transaction always
add up to its written premium to the cent, so billed premium ties to written premium.

Cash follows the schedule: each installment is paid around its due date, except
- after a cancellation is processed, nothing more is collected for that term, and the customer
  is refunded what they paid beyond the premium they owe for the time they were covered;
- in a nonpayment cancellation the missed installment and later ones are never paid, unless the
  term is reinstated, in which case the customer pays the overdue amounts on reinstatement
  (the cancellation credit and the reinstatement debit offset each other without cash);
- a credit endorsement is refunded;
- about 1% of payments are returned by the bank (insufficient funds) a few days later and are
  paid again by card (RETURNED_PAYMENTS). The source overwrites the returned payment's row.

Amounts are integer cents: this is the one system that stores money that way.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field

from . import config as C
from .config import Config
from .policies import PolicyBook, PolicyTransaction
from .rand import Rng
from .timeline import ONE_DAY, add_months

ONE_MINUTE = dt.timedelta(minutes=1)


@dataclass(slots=True, eq=False)
class Installment:
    txn: PolicyTransaction
    number: int
    due_date: dt.date
    amount: int  # cents, signed
    created_at: dt.datetime
    installment_id: int = 0
    versions: list = field(default_factory=list)  # (version_at, due_date)


@dataclass(slots=True, eq=False)
class Payment:
    policy: object
    received_at: dt.datetime
    amount: int  # cents; negative is a refund paid out
    method: str
    returned_at: dt.datetime | None = None
    payment_id: int = 0


@dataclass
class BillingBook:
    installments: list
    payments: list


def split_evenly(total: int, count: int) -> list[int]:
    """Split cents into `count` parts that add up exactly; the remainder goes on the first."""
    base = abs(total) // count * (1 if total >= 0 else -1)  # credits split like debits
    parts = [base] * count
    parts[0] += total - base * count
    return parts


class BillingSimulator:
    def __init__(self, cfg: Config, rng: Rng):
        self.cfg = cfg
        self.rng = rng
        self.valuation = cfg.valuation_date
        self.valuation_end = cfg.valuation_end
        self.installments: list[Installment] = []
        self.payments: list[Payment] = []

    def schedule(self, txn: PolicyTransaction) -> list[Installment]:
        term = txn.term
        policy = term.policy
        if txn.transaction_type in ("NEW_BUSINESS", "RENEWAL"):
            count = C.TERM_MONTHS[policy.lob] if policy.billing_plan == "MONTHLY" else 1
            dues = [add_months(term.start, k) for k in range(count)]
            if txn.transaction_type == "NEW_BUSINESS":
                dues[0] = txn.transaction_date  # the first installment is due at bind
            amounts = split_evenly(txn.written, count)
        else:
            due = txn.transaction_date + dt.timedelta(days=20 if txn.written > 0 else 0)
            dues, amounts = [due], [txn.written]
        result = []
        for number, (due, amount) in enumerate(zip(dues, amounts), start=1):
            inst = Installment(txn, number, due, amount, txn.created_at)
            inst.versions.append((txn.created_at, due))
            self.maybe_reschedule(inst)
            result.append(inst)
        self.installments.extend(result)
        return result

    def maybe_reschedule(self, inst: Installment) -> None:
        """A few customers move a future due date; the source updates the installment row."""
        rng = self.rng
        if inst.number < 2 or not rng.chance(C.INSTALLMENT_RESCHEDULE_RATE):
            return
        first = inst.created_at.date() + ONE_DAY
        last = inst.due_date - dt.timedelta(days=5)
        if last <= first:
            return
        at = rng.office_time(first + dt.timedelta(days=rng.randint(0, (last - first).days)))
        if at > self.valuation_end:
            return
        inst.due_date = inst.due_date + dt.timedelta(days=rng.randint(1, 10))
        inst.versions.append((at, inst.due_date))

    def pay(self, policy, received_at: dt.datetime, amount: int, method: str) -> None:
        if received_at > self.valuation_end or amount == 0:
            return
        payment = Payment(policy, received_at, amount, method)
        self.payments.append(payment)
        rng = self.rng
        if amount > 0 and method in ("ACH", "CHECK") and rng.chance(C.RETURN_RATE_ACH_CHECK):
            returned = rng.office_time(received_at.date() + dt.timedelta(days=rng.randint(2, 7)))
            if returned <= self.valuation_end:
                payment.returned_at = returned
                again = rng.office_time(returned.date() + dt.timedelta(days=rng.randint(2, 10)))
                if again <= self.valuation_end:
                    self.payments.append(Payment(policy, again, amount, "CARD"))

    def run(self, book: PolicyBook) -> BillingBook:
        rng = self.rng
        for term in book.terms:
            policy = term.policy
            plan = term.cancel_plan
            final = plan if plan is not None and plan.reinstated_at is None and term.cancel_date is not None else None
            paid = 0
            for txn in term.transactions:
                for inst in self.schedule(txn):
                    if txn.transaction_type in ("CANCELLATION", "REINSTATEMENT"):
                        continue  # settled through the refund below, or offset by each other
                    if inst.amount < 0:
                        refund_at = rng.office_time(txn.created_at.date() + dt.timedelta(days=rng.randint(7, 20)))
                        if final is not None and refund_at >= final.processed_at:
                            continue  # the final refund on cancellation covers it
                        self.pay(policy, refund_at, inst.amount, policy.payment_method)
                        paid += inst.amount
                        continue
                    due = inst.due_date
                    if final is not None and due > final.processed_at.date():
                        continue  # billing stopped when the cancellation was processed
                    if txn.transaction_type == "NEW_BUSINESS" and inst.number == 1:
                        received = txn.created_at + ONE_MINUTE  # paid at bind
                    else:
                        received = rng.office_time(due + dt.timedelta(days=rng.randint(-5, 3)))
                        if received <= inst.created_at:
                            received = rng.office_time(inst.created_at.date() + ONE_DAY)
                    if plan is not None and plan.reason == "NONPAYMENT" and due >= plan.missed_due:
                        if plan.reinstated_at is None:
                            continue  # never paid: this is why the term was cancelled
                        if due <= plan.reinstated_at.date():
                            received = plan.reinstated_at + ONE_MINUTE  # overdue amounts paid
                    self.pay(policy, received, inst.amount, policy.payment_method)
                    if received <= self.valuation_end:
                        paid += inst.amount
            if final is not None:
                # Refund what was paid beyond the premium owed for the covered period.
                refund = paid - term.written_cents
                if refund > 0:
                    at = rng.office_time(final.processed_at.date() + dt.timedelta(days=rng.randint(7, 20)))
                    self.pay(policy, at, -refund, policy.payment_method)

        installments = sorted(self.installments, key=lambda i: (i.created_at, i.txn.transaction_id, i.number))
        for n, inst in enumerate(installments, start=1):
            inst.installment_id = n
        payments = sorted(self.payments, key=lambda p: (p.received_at, p.policy.policy_id, p.amount))
        for n, payment in enumerate(payments, start=1):
            payment.payment_id = n
        return BillingBook(installments, payments)


def simulate_billing(cfg: Config, book: PolicyBook, rng: Rng) -> BillingBook:
    return BillingSimulator(cfg, rng).run(book)
