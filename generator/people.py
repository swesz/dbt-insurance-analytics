"""Fictional people: names, birth dates, e-mail addresses and ZIP codes.

Names are plain common US first and last names; e-mail addresses use the reserved example.com
domain (test.example.com for QA test records), so no real person or mailbox is ever referenced.
"""

from __future__ import annotations

import datetime as dt

from .rand import Rng

FIRST_NAMES = [
    "James", "Mary", "John", "Patricia", "Robert", "Jennifer", "Michael", "Linda", "William",
    "Elizabeth", "David", "Barbara", "Richard", "Susan", "Joseph", "Jessica", "Thomas", "Sarah",
    "Charles", "Karen", "Daniel", "Nancy", "Matthew", "Lisa", "Anthony", "Betty", "Mark", "Sandra",
    "Donald", "Ashley", "Steven", "Emily", "Paul", "Donna", "Andrew", "Michelle", "Joshua", "Carol",
    "Kevin", "Amanda", "Brian", "Melissa", "George", "Deborah", "Timothy", "Laura", "Ronald",
    "Rebecca", "Jason", "Sharon", "Ryan", "Cynthia", "Jacob", "Amy", "Gary", "Anna", "Eric",
    "Angela", "Stephen", "Brenda",
]
LAST_NAMES = [
    "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez",
    "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson", "Thomas", "Taylor",
    "Moore", "Jackson", "Martin", "Lee", "Perez", "Thompson", "White", "Harris", "Sanchez",
    "Clark", "Ramirez", "Lewis", "Robinson", "Walker", "Young", "Allen", "King", "Wright", "Scott",
    "Torres", "Nguyen", "Hill", "Flores", "Green", "Adams", "Nelson", "Baker", "Hall", "Rivera",
    "Campbell", "Mitchell", "Carter", "Roberts", "Phillips", "Evans", "Turner", "Parker",
    "Collins", "Edwards", "Stewart", "Morris", "Murphy", "Cook",
]

ZIP_PREFIXES = {
    "AZ": ["850", "852", "853", "857"],
    "CO": ["800", "801", "802", "809"],
    "GA": ["300", "301", "303", "310"],
    "IL": ["600", "601", "606", "617"],
    "NC": ["275", "276", "282", "284"],
    "TN": ["370", "372", "379", "381"],
    "TX": ["750", "752", "770", "782", "787"],
}


def random_name(rng: Rng) -> tuple[str, str]:
    return rng.choice(FIRST_NAMES), rng.choice(LAST_NAMES)


def random_zip(rng: Rng, state: str) -> str:
    return rng.choice(ZIP_PREFIXES[state]) + f"{rng.randrange(100):02d}"


def random_birth_date(rng: Rng, on: dt.date) -> dt.date:
    age_days = rng.randint(18 * 365 + 5, 85 * 365)
    return on - dt.timedelta(days=age_days)


def email_for(first: str, last: str, sequence: int, is_test: bool) -> str:
    domain = "test.example.com" if is_test else "example.com"
    return f"{first}.{last}{sequence}@{domain}".lower()
