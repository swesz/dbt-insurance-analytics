-- Premium receivable aging at the valuation date, one row per real policy with billing.
--
-- How to read a row: receivable_amount is what the policyholder owes in total (premium written
-- and billed, minus cash collected). It is split by how long the open installments have been
-- past their due date, after settling installments with credits and cash as explained in
-- int_accounting__installment_allocation (credits not refunded settle the latest-due
-- installments first, cash the oldest-due first):
--   current_amount               not past due: due on the valuation date or later. Includes
--                                not_yet_due_amount, installments scheduled after it
--   past_due_1_30_amount ...     open installments 1-30, 31-60, 61-90, over 90 days past due
--   unapplied_credit_amount      cash or credits beyond everything billed (negative): the
--                                policyholder is owed money, typically a refund in transit
-- The buckets add up to receivable_amount. Over 90 days past due matters beyond collections:
-- statutory accounting does not admit premium receivable more than 90 days overdue as an
-- asset.
with allocation as (
    select * from {{ ref('int_accounting__installment_allocation') }}
),

installments as (
    select * from {{ ref('stg_billing__installments') }}
),

transaction_lines as (
    select * from {{ ref('fct_policy_transaction_lines') }}
),

cash_events as (
    select * from {{ ref('int_accounting__billing_cash_events') }}
),

policies as (
    select * from {{ ref('dim_policies') }}
),

accounting_periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

valuation_period as (
    select accounting_period
    from accounting_periods
    where is_valuation_period
),

booked_transactions as (
    select distinct
        transaction_id,
        accounting_period as booked_period
    from transaction_lines
),

-- Everything billed for transactions booked by the valuation period, credits included: the
-- premium the policyholder has been charged, net.
billed_by_policy as (
    select
        installments.policy_id,
        sum(installments.installment_amount) as billed_amount
    from installments
    inner join booked_transactions
        on installments.transaction_id = booked_transactions.transaction_id
    where not installments.is_test_policy
        and booked_transactions.booked_period <= (select accounting_period from valuation_period)
    group by 1
),

collected_by_policy as (
    select
        policy_id,
        sum(cash_amount) as collected_amount
    from cash_events
    group by 1
),

buckets_by_policy as (
    select
        policy_id,
        sum(case when days_past_due <= 0 then open_amount else 0 end) as current_amount,
        sum(case when days_past_due < 0 then open_amount else 0 end) as not_yet_due_amount,
        sum(case when days_past_due between 1 and 30 then open_amount else 0 end)
            as past_due_1_30_amount,
        sum(case when days_past_due between 31 and 60 then open_amount else 0 end)
            as past_due_31_60_amount,
        sum(case when days_past_due between 61 and 90 then open_amount else 0 end)
            as past_due_61_90_amount,
        sum(case when days_past_due > 90 then open_amount else 0 end) as past_due_over_90_amount,
        sum(open_amount) as open_amount,
        min(case when open_amount > 0 and days_past_due > 0 then due_date end)
            as oldest_past_due_date
    from allocation
    group by 1
),

policy_ids as (
    select policy_id from billed_by_policy
    union
    select policy_id from collected_by_policy
),

joined as (
    select
        policy_ids.policy_id,
        coalesce(billed_by_policy.billed_amount, 0) as billed_amount,
        coalesce(collected_by_policy.collected_amount, 0) as collected_amount,
        coalesce(buckets_by_policy.current_amount, 0) as current_amount,
        coalesce(buckets_by_policy.not_yet_due_amount, 0) as not_yet_due_amount,
        coalesce(buckets_by_policy.past_due_1_30_amount, 0) as past_due_1_30_amount,
        coalesce(buckets_by_policy.past_due_31_60_amount, 0) as past_due_31_60_amount,
        coalesce(buckets_by_policy.past_due_61_90_amount, 0) as past_due_61_90_amount,
        coalesce(buckets_by_policy.past_due_over_90_amount, 0) as past_due_over_90_amount,
        coalesce(buckets_by_policy.open_amount, 0) as open_amount,
        buckets_by_policy.oldest_past_due_date
    from policy_ids
    left join billed_by_policy
        on policy_ids.policy_id = billed_by_policy.policy_id
    left join collected_by_policy
        on policy_ids.policy_id = collected_by_policy.policy_id
    left join buckets_by_policy
        on policy_ids.policy_id = buckets_by_policy.policy_id
),

final as (
    select
        joined.policy_id,
        policies.policy_number,
        policies.line_of_business,
        cast('{{ var("valuation_date") }}' as date) as valuation_date,
        cast(joined.billed_amount as decimal(18, 2)) as billed_amount,
        cast(joined.collected_amount as decimal(18, 2)) as collected_amount,
        cast(joined.billed_amount - joined.collected_amount as decimal(18, 2))
            as receivable_amount,
        cast(joined.current_amount as decimal(18, 2)) as current_amount,
        cast(joined.not_yet_due_amount as decimal(18, 2)) as not_yet_due_amount,
        cast(joined.past_due_1_30_amount as decimal(18, 2)) as past_due_1_30_amount,
        cast(joined.past_due_31_60_amount as decimal(18, 2)) as past_due_31_60_amount,
        cast(joined.past_due_61_90_amount as decimal(18, 2)) as past_due_61_90_amount,
        cast(joined.past_due_over_90_amount as decimal(18, 2)) as past_due_over_90_amount,
        -- receivable = open installments + unapplied credit, so the credit is the rest. Each
        -- charge takes at most its own amount from the pool, so this is what the pool held
        -- beyond everything billed. It can only be zero or negative, and only when nothing is
        -- open; the YAML tests both, which is what checks the allocation.
        cast((joined.billed_amount - joined.collected_amount) - joined.open_amount
            as decimal(18, 2)) as unapplied_credit_amount,
        joined.oldest_past_due_date
    from joined
    left join policies
        on joined.policy_id = policies.policy_id
)

select * from final
