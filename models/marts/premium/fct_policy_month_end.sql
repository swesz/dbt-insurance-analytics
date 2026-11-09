-- One row per real policy and accounting period in which the policy had coverage on at least
-- one day (through the valuation period): whether it is in force at the period end, the
-- premium in force, and its exposure. The denominator side of actuarial ratios: claim
-- frequency is claims per earned exposure year, and policies in force (PIF) is the book's
-- size.

with terms as (
    select * from {{ ref('dim_policy_terms') }}
),

policies as (
    select * from {{ ref('dim_policies') }}
),

periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

lines as (
    select * from {{ ref('int_premium__transaction_lines_booked') }}
),

vehicles as (
    select * from {{ ref('stg_policy_admin__vehicles') }}
),

dwellings as (
    select * from {{ ref('stg_policy_admin__dwellings') }}
),

-- Each term with every period its coverage [term_effective_date, coverage_end_date) touches.
-- A flat-cancelled term covers no day, so it has no rows.
term_periods as (
    select
        terms.term_id,
        terms.policy_id,
        terms.term_days,
        periods.accounting_period,
        periods.period_start_date,
        periods.period_end_date,
        -- Days of the period inside the coverage window (both ends handled as exclusive ends).
        {{ dbt.datediff(
            'greatest(terms.term_effective_date, periods.period_start_date)',
            'least(terms.coverage_end_date, ' ~ dbt.dateadd('day', 1, 'periods.period_end_date') ~ ')',
            'day'
        ) }} as covered_days,
        -- In force at the period end, docs/source-systems.md 3e: the end date is inside the
        -- term and the term was not cancelled on or before it. Uses the current state of the
        -- term, so a later reinstatement counts as if the cancellation never happened.
        (
            terms.term_effective_date <= periods.period_end_date
            and periods.period_end_date < terms.term_expiration_date
            and (
                terms.cancellation_effective_date is null
                or terms.cancellation_effective_date > periods.period_end_date
            )
        ) as is_in_force_at_period_end
    from terms
    inner join periods
        on terms.term_effective_date <= periods.period_end_date
        and terms.coverage_end_date > periods.period_start_date
    -- A flat cancellation (cancelled on its first day) has coverage_end_date equal to its
    -- effective date. Without this filter, one starting mid-month would still pass the two
    -- overlap conditions above and get a row with zero covered days.
    where terms.covered_days > 0
        -- Month-ends run through the valuation period; later periods have not happened yet.
        and not periods.is_after_valuation
),

policy_periods as (
    select
        policy_id,
        accounting_period,
        period_end_date,
        sum(covered_days) as covered_days,
        bool_or(is_in_force_at_period_end) as is_in_force,
        -- Terms of a policy do not overlap (a renewal starts on the prior expiration date), so
        -- at most one term is in force; max() just picks it.
        max(case when is_in_force_at_period_end then term_id end) as in_force_term_id
    from term_periods
    group by 1, 2, 3
),

-- Premium in force: what the in-force term would cost for its full length at the rates in
-- force at the period end (the "in-force premium" of docs/source-systems.md 3b), from every
-- transaction effective by then (current state, like PIF). A cancellation effective later is
-- not in it yet.
--
-- The source writes an endorsement only for the days left in the term, so summing written
-- premium would mix full-term amounts (new business, renewal) with pro rata ones, and the same
-- rate change would count for less the later in the term it happened. Each line is therefore
-- scaled back to the full term: written x term days / window days. New business and renewal
-- cover the whole term and stay as they are; an endorsement of +87.03 over 132 of 182 days
-- counts +120.00. The source rounds each pro rata amount to the cent, so the rebuilt amount
-- can be off by up to half a cent x term days / window days: a few cents, unless the window
-- is only a few days long. A zero-day window covers no day of the term and is left out.
in_force_premium as (
    select
        policy_periods.policy_id,
        policy_periods.accounting_period,
        sum(
            case
                when lines.window_days > 0
                    then lines.written_premium * lines.term_days / lines.window_days
            end
        ) as in_force_term_premium,
        -- Annualized: the full-term premium per year of term. Auto terms run 6 months and home
        -- terms 12, so auto doubles and home stays (docs/insurance-glossary.md). Calendar
        -- months, not days: a 184-day and a 181-day auto term at the same rate annualize alike.
        sum(
            case
                when lines.window_days > 0
                    then lines.written_premium * lines.term_days / lines.window_days
                        * 12.0 / {{ dbt.datediff('lines.term_effective_date', 'lines.term_expiration_date', 'month') }}
            end
        ) as annualized_in_force_premium
    from policy_periods
    inner join lines
        on policy_periods.in_force_term_id = lines.term_id
        and lines.effective_date <= policy_periods.period_end_date
    group by 1, 2
),

-- Exposure units: the vehicles (AUTO) or the dwelling (HOME) on the policy. The source keeps
-- only the current list, with no dates for adding or removing a unit, and a unit's created_at
-- is when the policy was keyed in (which can be days after coverage started), so it says
-- nothing about when the unit was exposed. The current count is used for every month.
policy_units as (
    select
        policy_id,
        count(*) as exposure_units
    from (
        select policy_id from vehicles
        union all
        select policy_id from dwellings
    ) as units
    group by 1
),

final as (
    select
        {{ dbt_utils.generate_surrogate_key(['policy_periods.policy_id', 'policy_periods.accounting_period']) }}
            as policy_period_key,
        policy_periods.policy_id,
        policies.policy_number,
        policies.line_of_business,
        policies.risk_state,
        policy_periods.accounting_period,
        policy_periods.period_end_date,
        policy_periods.is_in_force,
        policy_periods.in_force_term_id,
        cast(round(coalesce(in_force_premium.in_force_term_premium, 0), 2) as decimal(18, 2))
            as in_force_term_premium,
        cast(round(coalesce(in_force_premium.annualized_in_force_premium, 0), 2) as decimal(18, 2))
            as annualized_in_force_premium,
        cast(coalesce(policy_units.exposure_units, 0) as integer) as exposure_units,
        cast(
            case when policy_periods.is_in_force then coalesce(policy_units.exposure_units, 0) else 0 end
        as integer) as in_force_exposure_units,
        cast(policy_periods.covered_days as integer) as covered_days,
        -- Earned exposure: unit-days of coverage in the month, in years. One vehicle insured
        -- all year is one car-year. 365 days per year is the usual convention.
        cast(
            round(policy_periods.covered_days * coalesce(policy_units.exposure_units, 0) / 365.0, 6)
        as decimal(18, 6)) as earned_exposure_years
    from policy_periods
    inner join policies
        on policy_periods.policy_id = policies.policy_id
    left join in_force_premium
        on policy_periods.policy_id = in_force_premium.policy_id
        and policy_periods.accounting_period = in_force_premium.accounting_period
    left join policy_units
        on policy_periods.policy_id = policy_units.policy_id
)

select * from final
