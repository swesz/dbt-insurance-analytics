-- At the valuation date, the month-end balances (fct_claim_exposure_period_balances) agree with
-- the claim and exposure dimensions (dim_claims, dim_claim_exposures), per claim and per
-- exposure, measure by measure: net paid loss, paid expense, outstanding loss reserve and
-- outstanding expense reserve.
--
-- The two sides are computed differently from the same booked events. The balances are running
-- sums over a spine of periods; the dimensions are one direct sum of everything booked by the
-- valuation period. A gap in the spine, a period counted twice or an event attached to the wrong
-- exposure shows up here.
--
-- Each measure is compared on its own. Comparing incurred (paid + reserve) instead would let
-- offsetting errors through: an expense payment counted as paid in one model and still held as
-- reserve in the other gives both the same incurred expense. Incurred itself is defined as
-- paid + reserve in every model, so a test of that identity would only restate the definition.
--
-- A claim or exposure missing on one side counts as zero there: claims without financial events
-- (orphans, losses outside the term) have no balance rows. That a balance row's exposure exists
-- in the dimension is the relationships test in _claims__models.yml.
-- Returns one row per level, claim or exposure, and measure that differs.
with balances as (
    select * from {{ ref('fct_claim_exposure_period_balances') }}
),

claims as (
    select * from {{ ref('dim_claims') }}
),

claim_exposures as (
    select * from {{ ref('dim_claim_exposures') }}
),

balances_at_valuation as (
    select
        exposure_id,
        claim_id,
        sum(case when cost_category = 'LOSS' then itd_paid_amount else 0 end)
            as net_paid_loss_amount,
        sum(case when cost_category = 'EXPENSE' then itd_paid_amount else 0 end)
            as paid_expense_amount,
        sum(case when cost_category = 'LOSS' then case_reserve_amount else 0 end)
            as case_reserve_loss_amount,
        sum(case when cost_category = 'EXPENSE' then case_reserve_amount else 0 end)
            as case_reserve_expense_amount
    from balances
    where accounting_period = {{ claims_valuation_period() }}
    group by exposure_id, claim_id
),

-- Long form, one row per key and measure, so that each measure is compared on its own.
balance_amounts_by_exposure as (
    select
        exposure_id,
        claim_id,
        measure,
        amount
    from balances_at_valuation
    unpivot (amount for measure in (
        net_paid_loss_amount, paid_expense_amount,
        case_reserve_loss_amount, case_reserve_expense_amount
    ))
),

balance_amounts as (
    select
        'exposure' as level,
        exposure_id as key_id,
        measure,
        amount
    from balance_amounts_by_exposure

    union all

    select
        'claim' as level,
        claim_id as key_id,
        measure,
        sum(amount) as amount
    from balance_amounts_by_exposure
    group by claim_id, measure
),

dimension_amounts as (
    select
        'exposure' as level,
        exposure_id as key_id,
        measure,
        amount
    from (
        select
            exposure_id,
            net_paid_loss_amount,
            paid_expense_amount,
            case_reserve_loss_amount,
            case_reserve_expense_amount
        from claim_exposures
    ) unpivot (amount for measure in (
        net_paid_loss_amount, paid_expense_amount,
        case_reserve_loss_amount, case_reserve_expense_amount
    ))

    union all

    select
        'claim' as level,
        claim_id as key_id,
        measure,
        amount
    from (
        select
            claim_id,
            net_paid_loss_amount,
            paid_expense_amount,
            case_reserve_loss_amount,
            case_reserve_expense_amount
        from claims
    ) unpivot (amount for measure in (
        net_paid_loss_amount, paid_expense_amount,
        case_reserve_loss_amount, case_reserve_expense_amount
    ))
),

compared as (
    select
        coalesce(dimension_amounts.level, balance_amounts.level) as level,
        coalesce(dimension_amounts.key_id, balance_amounts.key_id) as key_id,
        coalesce(dimension_amounts.measure, balance_amounts.measure) as measure,
        dimension_amounts.amount as dimension_amount,
        balance_amounts.amount as balance_amount
    from dimension_amounts
    full outer join balance_amounts
        on dimension_amounts.level = balance_amounts.level
        and dimension_amounts.key_id = balance_amounts.key_id
        and dimension_amounts.measure = balance_amounts.measure
)

select *
from compared
where coalesce(dimension_amount, 0) <> coalesce(balance_amount, 0)
order by level, key_id, measure
