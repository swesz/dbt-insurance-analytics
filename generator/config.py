"""Run settings and the calibration constants of the simulation.

Everything that shapes the fictional carrier's book (volumes, rates, claim frequencies and
severities) is collected here, so tuning the data means editing one file. Reference data that dbt
also uses (coverages, states, loss causes, catastrophe events, the accounting calendar) is NOT
duplicated here: it is read from seeds/ by generator.seeds.

Money in this file is in dollars for readability; the simulation converts to integer cents.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from pathlib import Path

START_DATE = dt.date(2022, 1, 1)  # first policy effective date: the carrier opens its doors
DEFAULT_VALUATION_DATE = dt.date(2026, 9, 30)
DEFAULT_SEED = 42


@dataclass(frozen=True)
class Config:
    seed: int = DEFAULT_SEED
    scale: float = 1.0
    valuation_date: dt.date = DEFAULT_VALUATION_DATE
    out_dir: Path = Path("data/generated")
    seeds_dir: Path = Path("seeds")

    @property
    def valuation_end(self) -> dt.datetime:
        """The last moment simulated: nothing is created or changed after it."""
        return dt.datetime.combine(self.valuation_date, dt.time(23, 59, 59))

    def scaled(self, count: float, minimum: int = 1) -> int:
        """A count that grows with --scale but never drops below `minimum`."""
        return max(minimum, round(count * self.scale))


# ---------------------------------------------------------------------------------------------
# Book of business
# ---------------------------------------------------------------------------------------------

# New business per month grows linearly from the first to the last month (scale 1.0).
NEW_BUSINESS_FIRST_MONTH = 250
NEW_BUSINESS_LAST_MONTH = 600
AUTO_SHARE = 0.65

STATE_WEIGHTS = {"AZ": 0.11, "CO": 0.11, "GA": 0.15, "IL": 0.14, "NC": 0.13, "TN": 0.10, "TX": 0.26}
CHANNEL_WEIGHTS = {"ONLINE": 0.40, "PHONE": 0.25, "AGENCY": 0.35}
MONTHLY_PLAN_SHARE = 0.60  # the rest pay in full
HOME_EXISTING_CUSTOMER_SHARE = 0.15  # home policies bought by an existing auto customer

TERM_MONTHS = {"AUTO": 6, "HOME": 12}
RETENTION = {"AUTO": 0.88, "HOME": 0.90}
RENEWAL_LEAD_DAYS = 30  # the renewal is processed (and written) this many days before it starts

# Mid-term cancellations: about 6% of terms. Nonpayment needs a monthly plan, so its per-term
# rate is set on monthly terms such that the overall mix is 60/35/5.
CANCEL_INSURED_REQUEST = 0.036
CANCEL_UNDERWRITING = 0.003
CANCEL_NONPAYMENT_MONTHLY = 0.035
FLAT_CANCEL_SHARE = 0.15  # insured-request cancellations effective on the term start
REINSTATEMENT_SHARE = 0.10  # of nonpayment cancellations, within 15 days
NONPAYMENT_NOTICE_DAYS = 20
UNDERWRITING_NOTICE_DAYS = 30

ENDORSEMENT_RATE = {"AUTO": 0.20, "HOME": 0.10}
BACKDATED_SHARE = 0.15

# Rate level by calendar year of the term's effective date: a step change every January 1st.
# A renewal therefore gets about +8% in 2023, +12% in 2024, +6% in 2025 and +4% in 2026.
RATE_CHANGE = {2022: 0.0, 2023: 0.08, 2024: 0.12, 2025: 0.06, 2026: 0.04, 2027: 0.04}

# Full-term premium per exposure unit at the 2022 rate level, before state and risk factors.
# Auto is per vehicle per 6-month term, home per dwelling per year.
BASE_RATE = {
    "BI": 155.0,
    "PD": 100.0,
    "COLL": 158.0,
    "COMP": 65.0,
    "DWELLING": 955.0,
    "CONTENTS": 228.0,
    "PERS_LIAB": 46.0,
}
STATE_FACTOR = {
    "AUTO": {"AZ": 1.00, "CO": 1.05, "GA": 1.08, "IL": 0.95, "NC": 0.85, "TN": 0.90, "TX": 1.10},
    "HOME": {"AZ": 0.90, "CO": 1.15, "GA": 1.00, "IL": 0.95, "NC": 0.95, "TN": 0.90, "TX": 1.20},
}
VEHICLE_COUNT_WEIGHTS = {1: 0.55, 2: 0.35, 3: 0.10}
PHYSICAL_DAMAGE_SHARE = 0.85  # auto policies carrying COLL and COMP

# ---------------------------------------------------------------------------------------------
# Billing
# ---------------------------------------------------------------------------------------------
PAYMENT_METHOD_WEIGHTS = {"ACH": 0.50, "CARD": 0.35, "CHECK": 0.15}
RETURN_RATE_ACH_CHECK = 0.016  # of ACH and check payments: about 1% of all payments
INSTALLMENT_RESCHEDULE_RATE = 0.02

# ---------------------------------------------------------------------------------------------
# Claims
# ---------------------------------------------------------------------------------------------
# Occurrence rates per exposure year (vehicle-year or dwelling-year). An at-fault auto accident
# always has a third-party PD exposure, sometimes the insured's own COLL and sometimes BI.
AUTO_AT_FAULT_RATE = 0.035
AT_FAULT_COLL_SHARE = 0.70
AT_FAULT_BI_SHARE = 0.29
BI_SECOND_CLAIMANT_SHARE = 0.20
AUTO_SINGLE_VEHICLE_COLL_RATE = 0.0255  # gives COLL 0.05 in total
AUTO_COMP_RATE = 0.04
HOME_PROPERTY_RATE = 0.06
HOME_LIABILITY_RATE = 0.003

COMP_CAUSES = {"GLASS": 0.40, "ANIMAL_STRIKE": 0.20, "VANDALISM": 0.15, "THEFT": 0.15, "HAIL": 0.10}
HOME_PROPERTY_CAUSES = {
    "WATER_DAMAGE": 0.30, "WIND": 0.20, "HAIL": 0.15, "THEFT": 0.12, "FREEZE": 0.10,
    "FIRE": 0.07, "VANDALISM": 0.06,
}
# Mean severity of a home property claim by cause (2022 dollars), and the share of claims of that
# cause that also have a CONTENTS exposure. Theft claims are contents only.
HOME_CAUSE_SEVERITY = {
    "WATER_DAMAGE": 12500, "WIND": 12000, "HAIL": 13000, "THEFT": 4500, "FREEZE": 15000,
    "FIRE": 33000, "VANDALISM": 3500,
}
HOME_CAUSE_CONTENTS_SHARE = {
    "WATER_DAMAGE": 0.5, "WIND": 0.15, "HAIL": 0.05, "THEFT": 1.0, "FREEZE": 0.4,
    "FIRE": 0.8, "VANDALISM": 0.3,
}
COMP_CAUSE_SEVERITY = {"GLASS": 750, "ANIMAL_STRIKE": 3600, "VANDALISM": 1900, "THEFT": 6500, "HAIL": 3600}

SEVERITY_TREND = 0.06  # per year, by loss date

# Per coverage: lognormal mean and sigma (2022 dollars), cap (policy limit), share closed without
# payment, days from report to settlement, number of reserve revisions, and the case reserve bias:
# initial = average reserve as a multiple of the mean severity; revisions estimate the remaining
# loss times a bias that moves from `bias_early` to 1.0 as the claim matures.
COVERAGE_CLAIM_PARAMS = {
    "COLL": dict(mean=5000, sigma=0.8, cap=60000, cwp=0.08, settle=(30, 90), revisions=(1, 2),
                 initial=1.05, bias_early=1.10, extra_payment=0.20),
    "COMP": dict(mean=2500, sigma=0.9, cap=60000, cwp=0.10, settle=(30, 90), revisions=(1, 2),
                 initial=1.10, bias_early=1.10, extra_payment=0.15),
    "PD": dict(mean=4500, sigma=0.8, cap=50000, cwp=0.10, settle=(30, 120), revisions=(1, 3),
               initial=1.00, bias_early=1.05, extra_payment=0.20),
    "BI": dict(mean=21500, sigma=1.1, cap=100000, cwp=0.15, settle=(180, 1080), revisions=(1, 4),
               initial=0.55, bias_early=0.60, extra_payment=0.0),
    "DWELLING": dict(mean=None, sigma=1.0, cap=None, cwp=0.12, settle=(60, 240), revisions=(1, 4),
                     initial=1.25, bias_early=1.20, extra_payment=0.0),
    "CONTENTS": dict(mean=None, sigma=1.0, cap=None, cwp=0.12, settle=(60, 240), revisions=(1, 4),
                     initial=1.25, bias_early=1.20, extra_payment=0.0),
    "PERS_LIAB": dict(mean=25000, sigma=1.2, cap=300000, cwp=0.25, settle=(180, 900),
                      revisions=(1, 4), initial=0.70, bias_early=0.70, extra_payment=0.0),
}
CONTENTS_SPLIT = 0.30  # share of a home property loss that is contents, when both are claimed

# Expenses (LAE): adjusting and other (AO) fees, and defense and cost containment (DCC) on
# liability exposures that go to litigation.
AO_SHARE = {"COLL": 0.6, "COMP": 0.5, "PD": 0.6, "BI": 0.5, "DWELLING": 0.7, "CONTENTS": 0.2,
            "PERS_LIAB": 0.5}
AO_MEAN = {"COLL": 350, "COMP": 250, "PD": 400, "BI": 600, "DWELLING": 900, "CONTENTS": 300,
           "PERS_LIAB": 700}
DCC_SHARE = {"BI": 0.30, "PERS_LIAB": 0.35}

RECOVERY_SHARE = {"COLL": 0.25, "COMP_THEFT": 0.30}
REOPEN_SHARE = 0.036
VOID_SHARE_OF_INTERIM_PAYMENTS = 0.028

# Catastrophe events (seeds/catastrophe_events.csv): probability that an in-force home (and, for
# hail, an auto policy with COMP) in an affected state has a claim, and the mean severity.
CAT_HOME_CLAIM_PROB = {
    "CAT2022-01": 0.12, "CAT2023-01": 0.05, "CAT2023-02": 0.06, "CAT2024-01": 0.04,
    "CAT2025-01": 0.025, "CAT2025-02": 0.06, "CAT2026-01": 0.06,
}
CAT_AUTO_HAIL_PROB = 0.05
CAT_SEVERITY = {"HAIL": 12000, "WIND": 14000, "FREEZE": 16000}
CAT_AUTO_HAIL_SEVERITY = 3800

# ---------------------------------------------------------------------------------------------
# Planted defects (docs/data-issues.md). Counts are for scale 1.0 and scale with --scale.
# ---------------------------------------------------------------------------------------------
TEST_POLICY_COUNT = 25
TEST_POLICY_ID_START = 9_000_001
SOFT_DELETED_POLICYHOLDER_COUNT = 40
SOFT_DELETED_POLICY_COUNT = 30
ORPHAN_CLAIM_COUNT = 5
ORPHAN_POLICY_NUMBER_RANGE = (7_000_000, 7_999_999)  # legacy book, never migrated
CDC_DUPLICATE_SHARE = 0.005
DELETED_CLAIM_SHARE = 0.005
CASING_SHARE = 0.03
MALFORMED_POLICY_NUMBER_SHARE = 0.01
LOSS_OUTSIDE_TERM_SHARE = 0.003
LATE_POLICY_TRANSACTION_SHARE = 0.036  # of NB, endorsements and insured cancellations
LATE_CLAIM_TRANSACTION_SHARE = 0.023  # of payments, recoveries and reserve revisions
LATE_MAX_DAYS = 20
CLAIMS_SYSTEM_UPGRADE = dt.datetime(2023, 7, 1)  # before it, statuses were 'O', 'C', 'R'

GL_REEXPORTED_PERIOD = "2025-03"
GL_THOUSANDS_SEPARATOR_FROM = "2025-01"
GL_MANUAL_RECLASS_PERIOD = "2024-06"
GL_CLAIMS_TIMING_PERIOD = "2025-08"
