-- One row per claim exposure (one coverage and one claimant on a claim) in its current state,
-- with its financial position at the valuation date. Exposures of test-policy claims are not
-- here.
with claim_exposures as (
    select * from {{ ref('stg_claims__claim_exposures') }}
),

claims as (
    select * from {{ ref('stg_claims__claims') }}
),

coverages as (
    select * from {{ ref('coverages') }}
),

financial_events as (
    select * from {{ ref('int_claims__financial_events') }}
),

exposure_financials as (
    select
        exposure_id,
        sum(case when cost_category = 'LOSS' then paid_amount else 0 end) as net_paid_loss_amount,
        sum(case when cost_category = 'EXPENSE' then paid_amount else 0 end) as paid_expense_amount,
        sum(case when cost_category = 'LOSS' then reserve_change_amount else 0 end)
            as case_reserve_loss_amount,
        sum(case when cost_category = 'EXPENSE' then reserve_change_amount else 0 end)
            as case_reserve_expense_amount
    from financial_events
    where accounting_period <= {{ claims_valuation_period() }}
    group by exposure_id
),

final as (
    select
        claim_exposures.exposure_id,
        claim_exposures.claim_id,
        claims.claim_number,
        claim_exposures.coverage_code,
        coverages.coverage_name,
        coverages.coverage_group,
        coverages.line_of_business,
        -- Liability coverages pay third parties our insured harmed; they settle slowly and
        -- develop the most, which is why triangles are often split by liability vs. property.
        coverages.is_liability,
        claim_exposures.claimant_type,
        claim_exposures.exposure_status,
        claim_exposures.is_open,
        claim_exposures.opened_at,
        claim_exposures.closed_at,
        claims.loss_date,
        year(claims.loss_date) as accident_year,
        coalesce(exposure_financials.net_paid_loss_amount, 0) as net_paid_loss_amount,
        coalesce(exposure_financials.paid_expense_amount, 0) as paid_expense_amount,
        coalesce(exposure_financials.case_reserve_loss_amount, 0) as case_reserve_loss_amount,
        coalesce(exposure_financials.case_reserve_expense_amount, 0)
            as case_reserve_expense_amount,
        coalesce(exposure_financials.net_paid_loss_amount, 0)
            + coalesce(exposure_financials.case_reserve_loss_amount, 0) as incurred_loss_amount,
        coalesce(exposure_financials.paid_expense_amount, 0)
            + coalesce(exposure_financials.case_reserve_expense_amount, 0)
            as incurred_expense_amount,
        claim_exposures.updated_at
    from claim_exposures
    inner join claims
        on claim_exposures.claim_id = claims.claim_id
    left join coverages
        on claim_exposures.coverage_code = coverages.coverage_code
    left join exposure_financials
        on claim_exposures.exposure_id = exposure_financials.exposure_id
    where not claims.is_test_policy_claim
)

select * from final
