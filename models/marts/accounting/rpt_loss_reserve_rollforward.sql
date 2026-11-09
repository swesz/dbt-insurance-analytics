-- The case reserve rollforward per accounting period, line of business and cost category
-- (LOSS, EXPENSE), tied to the general ledger's reserve accounts (2200 loss, 2300 LAE).
--
-- How to read a row: the case reserve is what adjusters expect still to pay on reported
-- claims, a liability. Incurred is the period's cost of claims: what was paid plus the change
-- in what is still expected to be paid,
--
--     incurred = paid + (closing - opening),   so   opening + incurred - paid = closing.
--
-- A payment usually erodes the reserve by the same amount, so a payment alone does not change
-- incurred; a reserve increase does, even though no money moved. paid is net paid: payments
-- minus recoveries, with a voided payment reversed in the month of the void
-- (docs/source-systems.md 3f). Incurred here is case-incurred: IBNR is an actuarial estimate
-- and not in the subledger.
--
-- The closing balance is compared with the ledger: account 2200 (LOSS) or 2300 (EXPENSE)
-- holds the running total of the monthly reserve-change postings. Amounts are in their natural
-- sign (a reserve as a positive number). Open periods have null GL columns.
with claim_transactions as (
    select * from {{ ref('fct_claim_transactions') }}
),

gl_balances as (
    select * from {{ ref('int_accounting__gl_balances_by_period') }}
),

accounting_periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

claims_by_period as (
    select
        accounting_period,
        line_of_business,
        cost_category,
        sum(paid_amount) as paid_amount,
        sum(reserve_change_amount) as reserve_change_amount
    from claim_transactions
    group by 1, 2, 3
),

spine as (
    select
        accounting_periods.accounting_period,
        accounting_periods.period_sequence,
        accounting_periods.is_closed_at_valuation,
        lines_of_business.line_of_business,
        cost_categories.cost_category
    from accounting_periods
    cross join (select distinct line_of_business from claims_by_period) as lines_of_business
    cross join (select 'LOSS' as cost_category union all select 'EXPENSE') as cost_categories
    where accounting_periods.accounting_period >= (select min(accounting_period) from claims_by_period)
        and not accounting_periods.is_after_valuation
),

subledger as (
    select
        spine.accounting_period,
        spine.period_sequence,
        spine.is_closed_at_valuation,
        spine.line_of_business,
        spine.cost_category,
        coalesce(claims_by_period.paid_amount, 0) as paid_amount,
        coalesce(claims_by_period.reserve_change_amount, 0) as reserve_change_amount
    from spine
    left join claims_by_period
        on spine.accounting_period = claims_by_period.accounting_period
        and spine.line_of_business = claims_by_period.line_of_business
        and spine.cost_category = claims_by_period.cost_category
),

rolled as (
    select
        subledger.*,
        -- The outstanding case reserve is the running sum of all reserve changes booked so far.
        sum(reserve_change_amount) over (
            partition by line_of_business, cost_category
            order by period_sequence
            rows between unbounded preceding and current row
        ) as closing_case_reserve,
        case cost_category when 'LOSS' then '2200' else '2300' end as reserve_account_number
    from subledger
),

final as (
    select
        cast(rolled.accounting_period || '|' || rolled.line_of_business || '|'
            || rolled.cost_category as varchar) as rollforward_key,
        cast(rolled.accounting_period as varchar) as accounting_period,
        cast(rolled.line_of_business as varchar) as line_of_business,
        cast(rolled.cost_category as varchar) as cost_category,
        cast(rolled.closing_case_reserve - rolled.reserve_change_amount as decimal(18, 2))
            as opening_case_reserve,
        cast(rolled.paid_amount as decimal(18, 2)) as paid_amount,
        cast(rolled.paid_amount + rolled.reserve_change_amount as decimal(18, 2))
            as incurred_amount,
        cast(rolled.closing_case_reserve as decimal(18, 2)) as closing_case_reserve,
        cast(rolled.reserve_account_number as varchar) as reserve_account_number,
        cast(rolled.is_closed_at_valuation as boolean) as is_period_closed,
        -- 2200 and 2300 are credit-normal: flip the signed balance to compare.
        cast(-gl_balances.gl_itd_balance_amount as decimal(18, 2)) as gl_closing_case_reserve,
        cast(-gl_balances.gl_itd_balance_amount - rolled.closing_case_reserve
            as decimal(18, 2)) as gl_difference,
        cast(-gl_balances.documented_items_itd_amount as decimal(18, 2))
            as documented_items_amount,
        cast(
            (-gl_balances.gl_itd_balance_amount - rolled.closing_case_reserve)
            - (-gl_balances.documented_items_itd_amount)
        as decimal(18, 2)) as unexplained_difference
    from rolled
    left join gl_balances
        on rolled.accounting_period = gl_balances.accounting_period
        and rolled.line_of_business = gl_balances.line_of_business
        and rolled.reserve_account_number = gl_balances.account_number
)

select * from final
