-- A term whose last covered day is on or before the valuation date has earned all of its
-- written premium, to the cent: earned to date = written to date, per term.
--
-- Every line's window ends by then, and the ITD formula gives exactly written_premium once
-- elapsed = window_days. A cancelled term qualifies too: its cancellation line offsets the
-- unearned part, so earned = the premium for the days covered. A difference means a line
-- stopped earning early (a missing period row) or the rounding drifted.

with terms as (
    select * from {{ ref('dim_policy_terms') }}
),

lines as (
    select * from {{ ref('fct_policy_transaction_lines') }}
),

line_earnings as (
    select * from {{ ref('int_premium__line_earnings_by_period') }}
),

term_totals as (
    select
        lines.term_id,
        sum(line_earnings.written_premium) as written_premium,
        sum(line_earnings.earned_premium) as earned_premium
    from line_earnings
    inner join lines
        on line_earnings.transaction_line_id = lines.transaction_line_id
    group by 1
)

select
    terms.term_id,
    terms.term_expiration_date,
    term_totals.written_premium,
    term_totals.earned_premium,
    term_totals.written_premium - term_totals.earned_premium as unearned_left
from terms
inner join term_totals
    on terms.term_id = term_totals.term_id
where terms.is_expired_at_valuation
    and term_totals.written_premium <> term_totals.earned_premium
