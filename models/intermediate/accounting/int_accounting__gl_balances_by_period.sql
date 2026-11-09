-- General ledger balances per accounting period x GL account x line of business, through the
-- valuation period, next to the documented reconciling items: what the rollforwards and the
-- receivable report compare their subledger balances with.
--
-- A rollforward compares balances, not one month's activity, so both sides here are
-- inception-to-date sums. A reconciling item is documented for a period's activity (say, a
-- payment the ledger got one month late: -X in that month, +X in the next), so its effect on a
-- balance is the running sum of the items too: -X at the end of the first month, 0 after the
-- second, once the ledger has caught up.
--
-- Signed debit positive, credit negative, like every accounting model here. Reports flip the
-- sign for credit-normal accounts (liabilities) when they present them.
--
-- gl_itd_balance_amount is null for a period with no ledger export yet (still open at the
-- valuation date): an absent ledger is unknown, not zero.
with journal_lines as (
    select * from {{ ref('stg_general_ledger__journal_lines') }}
),

reconciling_items as (
    select * from {{ ref('gl_reconciling_items') }}
),

accounting_periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

gl_accounts as (
    select * from {{ ref('gl_accounts') }}
),

ledger_periods as (
    select distinct accounting_period
    from journal_lines
),

periods as (
    select
        accounting_period,
        is_closed_at_valuation
    from accounting_periods
    where not is_after_valuation
),

lines_of_business as (
    select 'AUTO' as line_of_business
    union all
    select 'HOME'
),

spine as (
    select
        periods.accounting_period,
        periods.is_closed_at_valuation,
        gl_accounts.account_number,
        lines_of_business.line_of_business
    from periods
    cross join gl_accounts
    cross join lines_of_business
),

gl_activity as (
    select
        accounting_period,
        account_number,
        line_of_business,
        sum(net_amount) as gl_net_amount
    from journal_lines
    group by 1, 2, 3
),

documented_activity as (
    select
        accounting_period,
        account_number,
        line_of_business,
        sum(amount) as documented_items_amount
    from reconciling_items
    group by 1, 2, 3
),

joined as (
    select
        spine.accounting_period,
        spine.account_number,
        spine.line_of_business,
        spine.is_closed_at_valuation,
        spine.accounting_period in (select accounting_period from ledger_periods)
            as has_ledger_export,
        coalesce(gl_activity.gl_net_amount, 0) as gl_net_amount,
        coalesce(documented_activity.documented_items_amount, 0) as documented_items_amount
    from spine
    left join gl_activity
        on spine.accounting_period = gl_activity.accounting_period
        and spine.account_number = gl_activity.account_number
        and spine.line_of_business = gl_activity.line_of_business
    left join documented_activity
        on spine.accounting_period = documented_activity.accounting_period
        and spine.account_number = documented_activity.account_number
        and spine.line_of_business = documented_activity.line_of_business
),

final as (
    select
        accounting_period || '|' || account_number || '|' || line_of_business as balance_key,
        accounting_period,
        account_number,
        line_of_business,
        is_closed_at_valuation,
        has_ledger_export,
        cast(case when has_ledger_export then gl_net_amount end as decimal(18, 2))
            as gl_net_amount,
        cast(case
            when has_ledger_export then sum(gl_net_amount) over (
                partition by account_number, line_of_business
                order by accounting_period
                rows between unbounded preceding and current row
            )
        end as decimal(18, 2)) as gl_itd_balance_amount,
        cast(documented_items_amount as decimal(18, 2)) as documented_items_amount,
        cast(sum(documented_items_amount) over (
            partition by account_number, line_of_business
            order by accounting_period
            rows between unbounded preceding and current row
        ) as decimal(18, 2)) as documented_items_itd_amount
    from joined
)

select * from final
