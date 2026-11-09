-- The unearned premium reserve (UPR) rollforward per accounting period and line of business,
-- tied to the general ledger.
--
-- How to read a row: the UPR is premium already written for coverage still to be provided, a
-- liability. It starts the month at the prior month's closing balance, grows by the premium
-- written in the month, and shrinks by the premium earned (coverage provided) in the month:
--
--     opening + written - earned = closing
--
-- That identity holds by construction of the premium subledger (docs/source-systems.md 3d) and
-- is tested anyway (tests/accounting/assert_unearned_premium_rollforward_ties_to_gl.sql), because
-- a missing period row or a dropped line would break it. The closing balance is then compared
-- with the ledger's account 2100: the ledger only knows the monthly "increase in UPR" postings,
-- so if their running total equals the subledger's closing balance, every month's posting was
-- right.
--
-- Amounts are shown in their natural sign: a liability's credit balance as a positive number.
-- Periods still open at the valuation date have no ledger export yet: their GL columns are null.
with premium as (
    select * from {{ ref('fct_premium_by_policy_period') }}
),

gl_balances as (
    select * from {{ ref('int_accounting__gl_balances_by_period') }}
),

accounting_periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

premium_by_period as (
    select
        accounting_period,
        line_of_business,
        sum(written_premium) as written_premium,
        sum(earned_premium) as earned_premium,
        -- fct_premium_by_policy_period has no row for a policy-coverage outside its earning
        -- range, where the UPR is zero, so the sum over the rows that exist is the total.
        sum(unearned_premium_end) as closing_unearned_premium
    from premium
    group by 1, 2
),

-- A row for every period and line of business from the first premium period to the valuation
-- period, so a month without premium activity still carries the balance forward.
spine as (
    select
        accounting_periods.accounting_period,
        accounting_periods.period_sequence,
        accounting_periods.is_closed_at_valuation,
        lines_of_business.line_of_business
    from accounting_periods
    cross join (select distinct line_of_business from premium_by_period) as lines_of_business
    where accounting_periods.accounting_period >= (select min(accounting_period) from premium_by_period)
        and not accounting_periods.is_after_valuation
),

subledger as (
    select
        spine.accounting_period,
        spine.period_sequence,
        spine.is_closed_at_valuation,
        spine.line_of_business,
        coalesce(premium_by_period.written_premium, 0) as written_premium,
        coalesce(premium_by_period.earned_premium, 0) as earned_premium,
        coalesce(premium_by_period.closing_unearned_premium, 0) as closing_unearned_premium
    from spine
    left join premium_by_period
        on spine.accounting_period = premium_by_period.accounting_period
        and spine.line_of_business = premium_by_period.line_of_business
),

rolled as (
    select
        subledger.*,
        coalesce(lag(closing_unearned_premium) over (
            partition by line_of_business
            order by period_sequence
        ), 0) as opening_unearned_premium
    from subledger
),

final as (
    select
        cast(rolled.accounting_period || '|' || rolled.line_of_business as varchar)
            as rollforward_key,
        cast(rolled.accounting_period as varchar) as accounting_period,
        cast(rolled.line_of_business as varchar) as line_of_business,
        cast(rolled.opening_unearned_premium as decimal(18, 2)) as opening_unearned_premium,
        cast(rolled.written_premium as decimal(18, 2)) as written_premium,
        cast(rolled.earned_premium as decimal(18, 2)) as earned_premium,
        cast(rolled.closing_unearned_premium as decimal(18, 2)) as closing_unearned_premium,
        cast(rolled.is_closed_at_valuation as boolean) as is_period_closed,
        -- 2100 is credit-normal: its signed balance is negative, so flip it to compare.
        cast(-gl_balances.gl_itd_balance_amount as decimal(18, 2)) as gl_closing_unearned_premium,
        cast(-gl_balances.gl_itd_balance_amount - rolled.closing_unearned_premium
            as decimal(18, 2)) as gl_difference,
        -- Documented reconciling items on 2100, to date, in the same natural sign.
        cast(-gl_balances.documented_items_itd_amount as decimal(18, 2))
            as documented_items_amount,
        cast(
            (-gl_balances.gl_itd_balance_amount - rolled.closing_unearned_premium)
            - (-gl_balances.documented_items_itd_amount)
        as decimal(18, 2)) as unexplained_difference
    from rolled
    left join gl_balances
        on rolled.accounting_period = gl_balances.accounting_period
        and rolled.line_of_business = gl_balances.line_of_business
        and gl_balances.account_number = '2100'
)

select * from final
