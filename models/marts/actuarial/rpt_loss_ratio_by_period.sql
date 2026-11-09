-- Calendar-period loss ratio per accounting period and line of business: what this month's
-- income statement says about losses, as opposed to what any one year's accidents will cost.
--
--   calendar-period incurred loss = net paid loss booked in the period
--                                 + change in the case loss reserve booked in the period
--   loss ratio                    = calendar-period incurred loss / earned premium
--
-- Why "change in reserve" and not the reserve itself: incurred to date is paid to date plus the
-- outstanding reserve (docs/source-systems.md 3f). Take that at the end of this period minus the
-- same at the end of the prior period and the result is this period's paid plus this period's
-- reserve change. It is the figure the ledger shows: 5000 Losses paid (gross payments) + 5050
-- Salvage and subrogation (recoveries, a credit, so signed negative) + 5100 Change in loss
-- reserves. Net paid is payments minus recoveries, so leaving out 5050 would overstate it by
-- every recovery. It mixes accident years: a reserve increase on a 2023 bodily injury claim
-- lands in today's calendar period. rpt_loss_ratio_by_accident_year sorts losses by when the
-- accident happened instead.
--
-- Worked example (round numbers, not this data): in a month, AUTO earns $1,000,000, pays $550,000 net of recoveries, and its
-- case reserves rise from $2,100,000 to $2,250,000. Calendar-period incurred is 550,000 +
-- 150,000 = $700,000 and the loss ratio 70%. If a single old claim's reserve is cut by
-- $200,000 in the same month, incurred falls to $500,000 (50%) although this month's
-- accidents cost the same: that is the reserve development a calendar-period ratio absorbs.
--
-- Catastrophe split: claims tied to an event in seeds/catastrophe_events.csv (dim_claims.
-- is_catastrophe). Catastrophes are rare and large, so reports show them apart; the
-- non-catastrophe ratio is the one to compare month to month and with the pricing target.
--
-- LAE (loss adjustment expense) is the EXPENSE cost category: defense and cost containment
-- (DCC) plus adjusting and other (AO). It is reported apart from losses, the way statutory
-- reports do; loss + LAE ratio is the total cost of claims per premium dollar.
--
-- Everything is on booked periods (rule 3c), so closed periods never change and the figures tie
-- to the general ledger; periods stop at the valuation period.
with periods as (
    select * from {{ ref('dim_accounting_periods') }}
    where not is_after_valuation
),

coverages as (
    select * from {{ ref('dim_coverages') }}
),

premium as (
    select * from {{ ref('fct_premium_by_policy_period') }}
),

claim_balances as (
    select * from {{ ref('fct_claim_exposure_period_balances') }}
),

claims as (
    select * from {{ ref('dim_claims') }}
),

lines_of_business as (
    select distinct line_of_business
    from coverages
),

-- Every period and line, so a month with premium but no claims (or the reverse) still has a row.
period_spine as (
    select
        periods.accounting_period,
        periods.period_end_date,
        periods.fiscal_year,
        periods.fiscal_quarter,
        lines_of_business.line_of_business
    from periods
    cross join lines_of_business
),

earned as (
    select
        accounting_period,
        line_of_business,
        sum(earned_premium) as earned_premium
    from premium
    group by all
),

-- The balances fact has the period's flows (paid, reserve change) per exposure and cost
-- category. Inner join to dim_claims for the catastrophe flag: every claim with financial
-- events is in dim_claims (test-policy claims are excluded from both, deleted claims have no
-- transactions), and tests/actuarial/assert_loss_ratio_incurred_matches_claims_mart.sql would
-- catch a claim lost by the join.
claim_activity as (
    select
        claim_balances.accounting_period,
        claim_balances.line_of_business,
        sum(case when claim_balances.cost_category = 'LOSS' then claim_balances.period_paid_amount else 0 end)
            as net_paid_loss_amount,
        sum(case when claim_balances.cost_category = 'LOSS' then claim_balances.period_reserve_change_amount else 0 end)
            as change_in_case_loss_reserve_amount,
        sum(
            case
                when claim_balances.cost_category = 'LOSS' and claims.is_catastrophe
                    then claim_balances.period_paid_amount + claim_balances.period_reserve_change_amount
                else 0
            end
        ) as catastrophe_incurred_loss_amount,
        sum(case when claim_balances.cost_category = 'EXPENSE' then claim_balances.period_paid_amount else 0 end)
            as paid_lae_amount,
        sum(case when claim_balances.cost_category = 'EXPENSE' then claim_balances.period_reserve_change_amount else 0 end)
            as change_in_case_lae_reserve_amount
    from claim_balances
    inner join claims
        on claim_balances.claim_id = claims.claim_id
    group by all
),

combined as (
    select
        period_spine.accounting_period,
        period_spine.period_end_date,
        period_spine.fiscal_year,
        period_spine.fiscal_quarter,
        period_spine.line_of_business,
        coalesce(earned.earned_premium, 0) as earned_premium,
        coalesce(claim_activity.net_paid_loss_amount, 0) as net_paid_loss_amount,
        coalesce(claim_activity.change_in_case_loss_reserve_amount, 0)
            as change_in_case_loss_reserve_amount,
        coalesce(claim_activity.catastrophe_incurred_loss_amount, 0)
            as catastrophe_incurred_loss_amount,
        coalesce(claim_activity.paid_lae_amount, 0) as paid_lae_amount,
        coalesce(claim_activity.change_in_case_lae_reserve_amount, 0)
            as change_in_case_lae_reserve_amount
    from period_spine
    left join earned
        on period_spine.accounting_period = earned.accounting_period
        and period_spine.line_of_business = earned.line_of_business
    left join claim_activity
        on period_spine.accounting_period = claim_activity.accounting_period
        and period_spine.line_of_business = claim_activity.line_of_business
),

amounts as (
    select
        *,
        net_paid_loss_amount + change_in_case_loss_reserve_amount as incurred_loss_amount,
        net_paid_loss_amount + change_in_case_loss_reserve_amount - catastrophe_incurred_loss_amount
            as non_catastrophe_incurred_loss_amount,
        paid_lae_amount + change_in_case_lae_reserve_amount as incurred_lae_amount
    from combined
),

final as (
    select
        accounting_period,
        line_of_business,
        period_end_date,
        fiscal_year,
        fiscal_quarter,
        cast(earned_premium as decimal(18, 2)) as earned_premium,
        cast(net_paid_loss_amount as decimal(18, 2)) as net_paid_loss_amount,
        cast(change_in_case_loss_reserve_amount as decimal(18, 2)) as change_in_case_loss_reserve_amount,
        cast(incurred_loss_amount as decimal(18, 2)) as incurred_loss_amount,
        cast(catastrophe_incurred_loss_amount as decimal(18, 2)) as catastrophe_incurred_loss_amount,
        cast(non_catastrophe_incurred_loss_amount as decimal(18, 2)) as non_catastrophe_incurred_loss_amount,
        {{ actuarial_ratio('incurred_loss_amount', 'earned_premium') }} as loss_ratio,
        {{ actuarial_ratio('non_catastrophe_incurred_loss_amount', 'earned_premium') }}
            as non_catastrophe_loss_ratio,
        {{ actuarial_ratio('catastrophe_incurred_loss_amount', 'earned_premium') }}
            as catastrophe_loss_ratio,
        cast(paid_lae_amount as decimal(18, 2)) as paid_lae_amount,
        cast(change_in_case_lae_reserve_amount as decimal(18, 2)) as change_in_case_lae_reserve_amount,
        cast(incurred_lae_amount as decimal(18, 2)) as incurred_lae_amount,
        -- The LAE ratio on the same basis as the loss ratio (incurred: paid plus the change in
        -- the expense case reserve), and on paid alone, which is what cash-basis expense
        -- reviews look at. They differ while expense reserves build up or run off.
        {{ actuarial_ratio('incurred_lae_amount', 'earned_premium') }} as lae_ratio,
        {{ actuarial_ratio('paid_lae_amount', 'earned_premium') }} as paid_lae_ratio,
        {{ actuarial_ratio('incurred_loss_amount + incurred_lae_amount', 'earned_premium') }}
            as loss_and_lae_ratio
    from amounts
)

select * from final
