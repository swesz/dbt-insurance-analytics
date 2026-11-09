-- The incremental fact holds exactly the events a full rebuild would produce.
-- fct_claim_transactions is built incrementally; int_claims__financial_events is the same logic
-- computed in full every time (a view). Any row in one and not the other (a missed late
-- arrival, a stale row whose source changed or disappeared) is returned. A failure is fixed by
-- `dbt build --select fct_claim_transactions --full-refresh`, and is worth investigating first.
{% set columns = [
    'financial_event_id', 'claim_transaction_id', 'event_type', 'is_void_reversal',
    'transaction_type', 'claim_id', 'exposure_id', 'coverage_code', 'line_of_business',
    'cost_category', 'expense_type', 'reserve_reason', 'transaction_date', 'event_date',
    'entered_at', 'accounting_period', 'paid_amount', 'reserve_change_amount', 'loss_date',
    'accident_year', 'source_loaded_at',
] %}

with fact as (
    select {{ columns | join(', ') }} from {{ ref('fct_claim_transactions') }}
),

events as (
    select {{ columns | join(', ') }} from {{ ref('int_claims__financial_events') }}
),

only_in_fact as (
    select 'only in fct_claim_transactions' as difference, * from (
        select * from fact
        except
        select * from events
    )
),

only_in_events as (
    select 'only in int_claims__financial_events' as difference, * from (
        select * from events
        except
        select * from fact
    )
)

select * from only_in_fact
union all
select * from only_in_events
