-- Incurred = net paid + outstanding case reserve (docs/source-systems.md 3f), checked two ways:
--   1. on every month-end balance row, the identity itself;
--   2. at the valuation date, per claim and cost category, the month-end balances (a running sum
--      over a period spine) agree with dim_claims (a direct sum over booked events). Two
--      different computations giving the same paid, reserve and incurred is the real check:
--      a gap in the spine or a double-counted period would show here.
-- Returns the rows that break either rule.
with balances as (
    select * from {{ ref('fct_claim_exposure_period_balances') }}
),

claims as (
    select * from {{ ref('dim_claims') }}
),

identity_breaks as (
    select
        'balance row' as check_name,
        exposure_id as claim_or_exposure_id,
        cost_category,
        accounting_period,
        incurred_amount as left_amount,
        itd_paid_amount + case_reserve_amount as right_amount
    from balances
    where incurred_amount <> itd_paid_amount + case_reserve_amount
),

balances_at_valuation as (
    select
        claim_id,
        sum(case when cost_category = 'LOSS' then itd_paid_amount else 0 end) as net_paid_loss_amount,
        sum(case when cost_category = 'LOSS' then case_reserve_amount else 0 end)
            as case_reserve_loss_amount,
        sum(case when cost_category = 'LOSS' then incurred_amount else 0 end) as incurred_loss_amount,
        sum(case when cost_category = 'EXPENSE' then incurred_amount else 0 end)
            as incurred_expense_amount
    from balances
    where accounting_period = {{ claims_valuation_period() }}
    group by claim_id
),

claim_breaks as (
    select
        'claim at valuation' as check_name,
        claims.claim_id as claim_or_exposure_id,
        'LOSS+EXPENSE' as cost_category,
        {{ claims_valuation_period() }} as accounting_period,
        claims.incurred_loss_amount + claims.incurred_expense_amount as left_amount,
        coalesce(balances_at_valuation.incurred_loss_amount, 0)
            + coalesce(balances_at_valuation.incurred_expense_amount, 0) as right_amount
    from claims
    left join balances_at_valuation
        on claims.claim_id = balances_at_valuation.claim_id
    where claims.incurred_loss_amount
            <> claims.net_paid_loss_amount + claims.case_reserve_loss_amount
        or claims.net_paid_loss_amount <> coalesce(balances_at_valuation.net_paid_loss_amount, 0)
        or claims.case_reserve_loss_amount
            <> coalesce(balances_at_valuation.case_reserve_loss_amount, 0)
        or claims.incurred_expense_amount
            <> coalesce(balances_at_valuation.incurred_expense_amount, 0)
)

select * from identity_breaks
union all
select * from claim_breaks
