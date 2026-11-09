-- Written, earned and unearned premium per policy, coverage and accounting period: the
-- premium subledger. Summed over policies, the columns are the period's written premium,
-- earned premium and unearned premium reserve (UPR) that the general ledger should show.
--
-- A policy-coverage has a row in every period from its first booked line to the end of its
-- last earning window (capped at the valuation period). Before and after that range all three
-- amounts are zero, so a missing row means zero, not unknown.

with line_earnings as (
    select * from {{ ref('int_premium__line_earnings_by_period') }}
),

lines as (
    select * from {{ ref('int_premium__transaction_lines_booked') }}
),

aggregated as (
    select
        lines.policy_id,
        lines.policy_number,
        lines.line_of_business,
        lines.risk_state,
        lines.coverage_code,
        line_earnings.accounting_period,
        sum(line_earnings.written_premium) as written_premium,
        sum(line_earnings.earned_premium) as earned_premium,
        sum(line_earnings.unearned_premium_end) as unearned_premium_end
    from line_earnings
    inner join lines
        on line_earnings.transaction_line_id = lines.transaction_line_id
    group by 1, 2, 3, 4, 5, 6
),

final as (
    select
        cast({{ dbt_utils.generate_surrogate_key(['policy_id', 'coverage_code', 'accounting_period']) }}
            as varchar) as policy_coverage_period_key,
        cast(policy_id as bigint) as policy_id,
        cast(policy_number as varchar) as policy_number,
        cast(coverage_code as varchar) as coverage_code,
        cast(accounting_period as varchar) as accounting_period,
        cast(line_of_business as varchar) as line_of_business,
        cast(risk_state as varchar) as risk_state,
        cast(written_premium as decimal(18, 2)) as written_premium,
        cast(earned_premium as decimal(18, 2)) as earned_premium,
        cast(unearned_premium_end as decimal(18, 2)) as unearned_premium_end
    from aggregated
)

select * from final
