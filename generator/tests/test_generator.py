"""Tests of the generated data against the business rules in docs/source-systems.md."""

from __future__ import annotations

import datetime as dt
from decimal import Decimal
from pathlib import Path

import duckdb
import pyarrow.parquet as pq

from generator.config import Config
from generator.money import cents_to_arrow, format_cents, round_half_away
from generator.run import generate
from generator.timeline import AccountingCalendar, Period, next_sync

from .conftest import AS_OF, SEEDS_DIR, scalar

SCHEMA_SQL = Path(__file__).resolve().parents[2] / "loader" / "raw_schema.sql"
SYSTEM_SCHEMAS = "('main', 'information_schema', 'pg_catalog', 'temp')"

# Current state of a CDC table: the latest version per key.
CURRENT_TXNS = """
    select * from claims.claim_transactions
    qualify row_number() over (partition by claim_transaction_id order by updated_at desc, _rivery_last_update desc) = 1
"""
CURRENT_CLAIMS = """
    select * from claims.claims
    qualify row_number() over (partition by claim_id order by updated_at desc, _rivery_last_update desc) = 1
"""
CURRENT_EXPOSURES = """
    select * from claims.claim_exposures
    qualify row_number() over (partition by exposure_id order by updated_at desc, _rivery_last_update desc) = 1
"""
# Claims that count: not deleted, not on a test policy (policy_id 9000000 and up).
COUNTED_CLAIMS = f"""
    select claim_id, loss_date, reported_at,
        cast(regexp_replace(upper(trim(policy_number)), '^(PA|HO)-?', '') as bigint) >= 9000000 as is_test
    from ({CURRENT_CLAIMS}) where not __deleted
"""


def booked(date_expr: str, entered_expr: str) -> str:
    return f"""(select min(p.accounting_period) from periods as p
                where p.period_end_date >= cast({date_expr} as date)
                  and {entered_expr} < p.close_date + interval 1 day)"""


# -- unit tests of the helpers -------------------------------------------------------------------

def test_rounding_is_half_away_from_zero():
    assert round_half_away(5, 2) == 3 and round_half_away(-5, 2) == -3
    assert round_half_away(7, 3) == 2 and round_half_away(-7, 3) == -2
    assert format_cents(123456789, thousands=True) == "1,234,567.89"
    assert cents_to_arrow([12345, -1]).to_pylist() == [Decimal("123.45"), Decimal("-0.01")]


def test_booking_rule_and_sync_boundaries():
    cal = AccountingCalendar([
        Period(0, "2025-01", dt.date(2025, 1, 1), dt.date(2025, 1, 31), dt.date(2025, 2, 6)),
        Period(1, "2025-02", dt.date(2025, 2, 1), dt.date(2025, 2, 28), dt.date(2025, 3, 6)),
    ])
    assert cal.booked_index(dt.date(2025, 1, 20), dt.datetime(2025, 2, 6, 16, 0)) == 0  # still open
    assert cal.booked_index(dt.date(2025, 1, 20), dt.datetime(2025, 2, 7, 9, 0)) == 1  # closed: next
    assert next_sync(dt.datetime(2025, 1, 1, 6, 0)) == dt.datetime(2025, 1, 1, 6, 0)
    assert next_sync(dt.datetime(2025, 1, 1, 18, 0, 1)) == dt.datetime(2025, 1, 2, 0, 0)


# -- determinism ---------------------------------------------------------------------------------

def test_same_seed_and_scale_give_identical_data(tmp_path):
    outputs = []
    for name in ("a", "b"):
        cfg = Config(seed=7, scale=0.02, out_dir=tmp_path / name, seeds_dir=SEEDS_DIR)
        generate(cfg, verbose=False)
        outputs.append(cfg.out_dir)
    a, b = outputs
    files = sorted(p.relative_to(a) for p in a.rglob("*") if p.is_file())
    assert files == sorted(p.relative_to(b) for p in b.rglob("*") if p.is_file())
    for rel in files:
        if rel.suffix == ".parquet":
            assert pq.read_table(a / rel).equals(pq.read_table(b / rel)), rel
        else:
            assert (a / rel).read_bytes() == (b / rel).read_bytes(), rel


# -- the raw contract ----------------------------------------------------------------------------

def test_loaded_columns_and_types_equal_the_contract(raw):
    contract = duckdb.connect()
    contract.execute(SCHEMA_SQL.read_text(encoding="utf-8"))
    query = f"""
        select table_schema, table_name, ordinal_position, column_name, data_type
        from information_schema.columns where table_schema not in {SYSTEM_SCHEMAS}
        and table_catalog = current_database()
        order by all
    """
    expected = contract.execute(query).fetchall()
    assert expected, "raw_schema.sql defined no tables"
    assert raw.execute(query).fetchall() == expected


def test_every_table_has_rows(raw):
    tables = raw.execute(f"""
        select table_schema, table_name from information_schema.tables
        where table_schema not in {SYSTEM_SCHEMAS} and table_catalog = current_database()
    """).fetchall()
    for schema, table in tables:
        assert scalar(raw, f"select count(*) from {schema}.{table}") > 0, f"{schema}.{table} is empty"


# -- premium -------------------------------------------------------------------------------------

def test_transaction_lines_sum_to_the_header(raw):
    assert scalar(raw, """
        select count(*) from policy_admin.policy_transactions as t
        left join (select transaction_id, sum(written_premium) as total, count(*) as n
                   from policy_admin.policy_transaction_lines group by 1) as l using (transaction_id)
        where l.n is null or l.total <> t.written_premium
    """) == 0


def test_term_written_premium_equals_its_transactions(raw):
    assert scalar(raw, """
        select count(*) from policy_admin.policy_terms as t
        left join (select term_id, sum(written_premium) as total from policy_admin.policy_transactions group by 1)
            as x using (term_id)
        where coalesce(x.total, 0) <> t.term_written_premium
    """) == 0


def test_installments_sum_to_written_premium_per_term(raw):
    assert scalar(raw, """
        select count(*) from policy_admin.policy_terms as t
        left join (select term_id, sum(amount_cents) as cents from billing.installments group by 1) as i using (term_id)
        where coalesce(i.cents, 0) <> cast(t.term_written_premium * 100 as bigint)
    """) == 0
    # and per transaction
    assert scalar(raw, """
        select count(*) from policy_admin.policy_transactions as t
        join (select transaction_id, sum(amount_cents) as cents from billing.installments group by 1) as i
            using (transaction_id)
        where i.cents <> cast(t.written_premium * 100 as bigint)
    """) == 0


def test_written_premium_and_policies_in_force_match_control_totals(raw):
    """The booking rule (3c) and PIF (3e) in SQL agree with the generator's Python."""
    mismatches = raw.execute(f"""
        with tx as (
            select t.*, p.line_of_business, p.policy_id >= 9000000 as is_test,
                {booked('t.transaction_date', 't.created_at')} as period
            from policy_admin.policy_transactions as t join policy_admin.policies as p using (policy_id)
        ),
        sql_totals as (
            select period, line_of_business, sum(written_premium) as value from tx where not is_test group by all
        )
        select c.period, c.line_of_business, c.value, s.value
        from generator_audit.control_totals as c
        left join sql_totals as s using (period, line_of_business)
        where c.metric = 'written_premium' and c.value <> coalesce(s.value, 0)
    """).fetchall()
    assert mismatches == []
    mismatches = raw.execute("""
        with ends as (select accounting_period as period, period_end_date as d from periods),
        sql_pif as (
            select e.period, p.line_of_business, count(distinct t.policy_id) as value
            from ends as e
            join policy_admin.policy_terms as t
                on t.term_effective_date <= e.d and e.d < t.term_expiration_date
                and (t.cancellation_effective_date is null or t.cancellation_effective_date > e.d)
            join policy_admin.policies as p using (policy_id)
            where p.policy_id < 9000000 and not p._fivetran_deleted
            group by all
        )
        select c.period, c.line_of_business, c.value, s.value
        from generator_audit.control_totals as c left join sql_pif as s using (period, line_of_business)
        where c.metric = 'policies_in_force_end' and c.value <> coalesce(s.value, 0)
    """).fetchall()
    assert mismatches == []


def test_unearned_premium_rolls_forward(raw):
    """UPR(P) = UPR(P-1) + written(P) - earned(P), per line of business (3d)."""
    rows = raw.execute("""
        select period, line_of_business,
            max(value) filter (metric = 'written_premium') as w,
            max(value) filter (metric = 'earned_premium') as e,
            max(value) filter (metric = 'unearned_premium_end') as u
        from generator_audit.control_totals where grain = 'accounting_period' group by all order by 2, 1
    """).fetchall()
    previous = {}
    for period, lob, w, e, u in rows:
        assert u == previous.get(lob, 0) + w - e, (period, lob)
        assert u >= 0
        previous[lob] = u


# -- claims --------------------------------------------------------------------------------------

def test_reserves_never_negative_and_incurred_is_paid_plus_reserve(raw):
    # Running case reserve per exposure and cost category, in entry order.
    assert scalar(raw, f"""
        select count(*) from (
            select sum(amount) over (partition by exposure_id, cost_category
                                     order by created_at, claim_transaction_id) as running
            from ({CURRENT_TXNS}) where transaction_type = 'RESERVE'
        ) where running < 0
    """) == 0
    # Closed exposures carry no reserve.
    assert scalar(raw, f"""
        select count(*) from ({CURRENT_EXPOSURES}) as e
        join (select exposure_id, sum(amount) as reserve from ({CURRENT_TXNS})
              where transaction_type = 'RESERVE' group by 1) as r using (exposure_id)
        where e.exposure_status = 'CLOSED' and r.reserve <> 0
    """) == 0
    # Incurred by accident year from SQL (net paid + outstanding reserve) equals the control total.
    mismatches = raw.execute(f"""
        with tx as (
            select t.*, c.loss_date, cv.line_of_business
            from ({CURRENT_TXNS}) as t
            join ({COUNTED_CLAIMS}) as c using (claim_id)
            join ({CURRENT_EXPOSURES}) as e using (exposure_id)
            join coverages as cv using (coverage_code)
            where not c.is_test and t.cost_category = 'LOSS'
        ),
        sql_ay as (
            select cast(year(loss_date) as varchar) as period, line_of_business,
                sum(case when transaction_type = 'PAYMENT' and transaction_status = 'POSTED' then amount
                         when transaction_type = 'RECOVERY' then -amount else 0 end) as paid,
                sum(case when transaction_type = 'RESERVE' then amount else 0 end) as reserve
            from tx group by all
        )
        select c.metric, c.period, c.line_of_business, c.value, s.paid, s.reserve
        from generator_audit.control_totals as c left join sql_ay as s using (period, line_of_business)
        where c.grain = 'accident_year' and (
            (c.metric = 'incurred_loss' and c.value <> coalesce(s.paid + s.reserve, 0))
            or (c.metric = 'paid_loss_net' and c.value <> coalesce(s.paid, 0)))
    """).fetchall()
    assert mismatches == []


def test_paid_loss_by_period_reverses_voids_at_the_void(raw):
    """Paid loss booked per 3c, with voided payments reversed in the void's period (3f)."""
    mismatches = raw.execute(f"""
        with versions as (
            select t.*, cv.line_of_business from claims.claim_transactions as t
            join ({COUNTED_CLAIMS}) as c using (claim_id)
            join ({CURRENT_EXPOSURES}) as e using (exposure_id)
            join coverages as cv using (coverage_code)
            where not c.is_test and t.cost_category = 'LOSS' and t.transaction_type in ('PAYMENT', 'RECOVERY')
            qualify row_number() over (partition by claim_transaction_id order by t.updated_at desc,
                                       t._rivery_last_update desc) = 1
        ),
        events as (
            select line_of_business, {booked('transaction_date', 'created_at')} as period,
                case when transaction_type = 'PAYMENT' then amount else -amount end as amount
            from versions
            union all
            select line_of_business, {booked('voided_at', 'voided_at')}, -amount
            from versions where transaction_status = 'VOIDED'
        ),
        sql_paid as (select period, line_of_business, sum(amount) as value from events group by all)
        select c.period, c.line_of_business, c.value, s.value
        from generator_audit.control_totals as c left join sql_paid as s using (period, line_of_business)
        where c.metric = 'paid_loss_net' and c.grain = 'accounting_period' and c.value <> coalesce(s.value, 0)
    """).fetchall()
    assert mismatches == []


def test_claims_reported_match_control_totals(raw):
    mismatches = raw.execute(f"""
        with lob as (
            select distinct e.claim_id, cv.line_of_business
            from ({CURRENT_EXPOSURES}) as e join coverages as cv using (coverage_code)
        ),
        sql_counts as (
            select strftime(reported_at, '%Y-%m') as period, line_of_business, count(*) as value
            from ({COUNTED_CLAIMS}) as c join lob using (claim_id) where not is_test group by all
        )
        select c.period, c.line_of_business, c.value, s.value
        from generator_audit.control_totals as c left join sql_counts as s using (period, line_of_business)
        where c.metric = 'claims_reported' and c.value <> coalesce(s.value, 0)
    """).fetchall()
    assert mismatches == []


# -- time ----------------------------------------------------------------------------------------

LOADER_COLUMNS = {"_fivetran_synced", "_rivery_last_update", "_modified", "loaded_at", "as_of"}
DATES_NOT_IN_FUTURE = ("loss_date", "transaction_date", "date_of_birth", "hired_date")


def timestamp_columns(con):
    return con.execute(f"""
        select table_schema, table_name, column_name, data_type from information_schema.columns
        where table_schema not in {SYSTEM_SCHEMAS} and table_schema <> 'generator_audit'
          and table_catalog = current_database()
          and (data_type = 'TIMESTAMP' or (data_type = 'DATE' and column_name in {tuple(DATES_NOT_IN_FUTURE)}))
    """).fetchall()


def test_nothing_is_created_or_updated_after_the_valuation_date(raw, cfg):
    end = cfg.valuation_end
    for schema, table, column, data_type in timestamp_columns(raw):
        if column in LOADER_COLUMNS:
            continue
        latest = scalar(raw, f"select max({column}) from {schema}.{table}")
        if latest is None:
            continue
        if data_type == "DATE":
            assert latest <= end.date(), f"{schema}.{table}.{column} = {latest}"
        else:
            assert latest <= end, f"{schema}.{table}.{column} = {latest}"


def test_an_as_of_load_shows_only_what_existed_then(raw, raw_as_of):
    for schema, table, column, data_type in timestamp_columns(raw_as_of):
        latest = scalar(raw_as_of, f"select max({column}) from {schema}.{table}")
        if latest is not None:
            limit = AS_OF.date() if data_type == "DATE" else AS_OF
            assert latest <= limit, f"{schema}.{table}.{column} = {latest}"
    # The ERP exports a period at 17:30 on its close date, so the last period present is the last
    # one that closed on or before the as-of date (2024-04 here: 2024-05 closes on 2024-06-06).
    last_closed = scalar(raw, f"select max(accounting_period) from periods where close_date <= date '{AS_OF.date()}'")
    assert scalar(raw_as_of, "select max(accounting_period) from general_ledger.journal_lines") == last_closed
    assert scalar(raw_as_of, "select as_of from generator_audit.load_info") == AS_OF
    # Rows created by then are all there, in their state at that moment.
    created_then = scalar(raw, f"select count(*) from policy_admin.policy_terms where created_at <= timestamp '{AS_OF}'")
    assert scalar(raw_as_of, "select count(*) from policy_admin.policy_terms") == created_then
    later_changes = scalar(raw, f"""
        select count(*) from policy_admin.policy_terms
        where created_at <= timestamp '{AS_OF}' and updated_at > timestamp '{AS_OF}'
    """)
    assert later_changes > 0, "expected some terms to change after the as-of"
    assert scalar(raw_as_of, "select count(*) from claims.claims") < scalar(raw, "select count(*) from claims.claims")


# -- planted issues ------------------------------------------------------------------------------

PLANTED_CHECKS = {
    ("TEST_POLICIES", "policy_admin.policies"): "select count(*) from policy_admin.policies where policy_id >= 9000000",
    ("TEST_POLICIES", "policy_admin.policyholders"):
        "select count(*) from policy_admin.policyholders where email like '%@test.example.com'",
    ("SOFT_DELETED_POLICYHOLDERS", "policy_admin.policyholders"):
        "select count(*) from policy_admin.policyholders where _fivetran_deleted",
    ("SOFT_DELETED_POLICIES", "policy_admin.policies"):
        """select count(*) from policy_admin.policies as p where _fivetran_deleted
           and not exists (select 1 from policy_admin.policy_terms as t where t.policy_id = p.policy_id)""",
    ("DELETED_CLAIMS", "claims.claims"): f"select count(*) from ({CURRENT_CLAIMS}) where __deleted",
    ("DELETED_CLAIMS", "claims.claim_exposures"): f"select count(*) from ({CURRENT_EXPOSURES}) where __deleted",
    ("LEGACY_STATUS_CODES", "claims.claims"): "select count(*) from claims.claims where claim_status in ('O', 'C', 'R')",
    ("INCONSISTENT_CODE_CASING", "claims.claims"):
        "select count(*) from claims.claims where loss_cause <> upper(trim(loss_cause)) or loss_state <> upper(trim(loss_state))",
    ("MALFORMED_POLICY_NUMBERS", "claims.claims"):
        "select count(*) from claims.claims where not regexp_full_match(policy_number, '(PA|HO)-[0-9]{7}')",
    ("ORPHAN_CLAIMS", "claims.claims"): """
        select count(distinct claim_id) from claims.claims as c
        where not exists (select 1 from policy_admin.policies as p
                          where p.policy_number = regexp_replace(upper(trim(c.policy_number)), '^(PA|HO)-?', '\\1-'))
    """,
    ("LATE_ENTERED_TRANSACTIONS", "policy_admin.policy_transactions"):
        "select count(*) from policy_admin.policy_transactions where cast(created_at as date) > transaction_date",
    ("LATE_ENTERED_TRANSACTIONS", "claims.claim_transactions"):
        f"select count(*) from ({CURRENT_TXNS}) where cast(created_at as date) > transaction_date",
    ("BACKDATED_ENDORSEMENTS", "policy_admin.policy_transactions"):
        "select count(*) from policy_admin.policy_transactions where transaction_type = 'ENDORSEMENT' and effective_date < transaction_date",
    ("VOIDED_PAYMENTS", "claims.claim_transactions"): f"select count(*) from ({CURRENT_TXNS}) where transaction_status = 'VOIDED'",
    ("REOPENED_CLAIMS", "claims.claims"):
        "select count(distinct claim_id) from claims.claims where claim_status in ('R', 'REOPENED')",
    ("BILLING_AMOUNTS_IN_CENTS", "billing.installments"): "select count(*) from billing.installments",
    ("BILLING_AMOUNTS_IN_CENTS", "billing.payments"): "select count(*) from billing.payments",
    ("RETURNED_PAYMENTS", "billing.payments"): "select count(*) from billing.payments where payment_status = 'RETURNED'",
    ("GL_FILE_REEXPORTED", "general_ledger.journal_lines"):
        "select count(*) from general_ledger.journal_lines where _file = 'gl_export_2025_03.csv'",
    ("GL_AMOUNT_FORMAT_CHANGE", "general_ledger.journal_lines"):
        "select count(*) from general_ledger.journal_lines where debit like '%,%' or credit like '%,%'",
    ("GL_MANUAL_RECLASS", "general_ledger.journal_lines"):
        "select count(*) from general_ledger.journal_lines where source_system = 'MANUAL'",
}
for _table in ("claims", "claim_exposures", "claim_transactions", "adjusters"):
    _key = {"claims": "claim_id", "claim_exposures": "exposure_id", "claim_transactions": "claim_transaction_id",
            "adjusters": "adjuster_id"}[_table]
    PLANTED_CHECKS[("CDC_DUPLICATE_VERSIONS", f"claims.{_table}")] = (
        f"select count(*) - count(distinct ({_key}, updated_at)) from claims.{_table}"
    )


def test_planted_counts_equal_the_data(raw):
    planted = raw.execute("select issue_code, source_table, record_count from generator_audit.planted_issues").fetchall()
    checked = set()
    for code, table, count in planted:
        sql = PLANTED_CHECKS.get((code, table))
        if sql is None:
            continue
        assert scalar(raw, sql) == count, (code, table)
        checked.add((code, table))
    assert checked == set(PLANTED_CHECKS), set(PLANTED_CHECKS) - checked
    # Issues counted from the source records rather than a single column of raw.
    loss_outside = scalar(raw, """
        select count(distinct c.claim_id) from claims.claims as c
        join policy_admin.policies as p
            on p.policy_number = regexp_replace(upper(trim(c.policy_number)), '^(PA|HO)-?', '\\1-')
        where c.loss_date < p.original_effective_date
           or exists (select 1 from policy_admin.policy_terms as t where t.policy_id = p.policy_id
                      and t.cancellation_effective_date is not null
                      and c.loss_date >= t.cancellation_effective_date
                      and not exists (select 1 from policy_admin.policy_terms as later
                                      where later.policy_id = p.policy_id and later.term_number > t.term_number))
    """)
    assert loss_outside == scalar(raw, "select record_count from generator_audit.planted_issues where issue_code = 'LOSS_OUTSIDE_TERM'")


# -- general ledger ------------------------------------------------------------------------------

def test_gl_debits_equal_credits_per_journal(raw):
    assert scalar(raw, """
        select count(*) from (
            select _file, journal_id,
                sum(coalesce(cast(nullif(replace(debit, ',', ''), '') as decimal(18, 2)), 0)) as dr,
                sum(coalesce(cast(nullif(replace(credit, ',', ''), '') as decimal(18, 2)), 0)) as cr
            from general_ledger.journal_lines group by all
        ) where dr <> cr
    """) == 0
    # Every line has exactly one side filled in.
    assert scalar(raw, "select count(*) from general_ledger.journal_lines where (debit = '') = (credit = '')") == 0


def test_gl_premium_ties_to_subledger_except_the_reclass(raw):
    rows = raw.execute("""
        with gl as (
            select accounting_period as period, line_of_business,
                sum(coalesce(cast(nullif(replace(credit, ',', ''), '') as decimal(18, 2)), 0))
                - sum(coalesce(cast(nullif(replace(debit, ',', ''), '') as decimal(18, 2)), 0)) as written
            from general_ledger.journal_lines
            where account_number = '4000' and _file not like 'gl_export_2025_03.csv'
            group by all
        )
        select period, line_of_business, gl.written - c.value as difference
        from gl join generator_audit.control_totals as c using (period, line_of_business)
        where c.metric = 'written_premium' and gl.written <> c.value
    """).fetchall()
    assert {(period, lob) for period, lob, _ in rows} <= {("2024-06", "AUTO"), ("2024-06", "HOME")}
    if rows:
        assert sum(diff for _, _, diff in rows) == 0
