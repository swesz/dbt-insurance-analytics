-- The trial balance: for every period the ledger covers, each GL account and line of business
-- with its debits, credits and net activity in the period, and the balance to date.
--
-- Double-entry bookkeeping posts every entry as equal debits and credits, so in every period
-- total debits equal total credits (tests/accounting/assert_trial_balance_balances.sql). A
-- trial balance that does not balance means a file was cut short, a line was lost, or an
-- amount was parsed wrongly, before anyone looks at what the amounts mean.
--
-- Balances:
--   balance sheet accounts (cash, receivable, reserves) carry their balance forever, so
--   itd_balance is the inception-to-date sum of net activity: the account's balance at the
--   period end.
--   income statement accounts (premium, losses) measure a year's performance and are closed to
--   retained earnings at each fiscal year end, so their running figure is ytd_net_activity, and
--   itd_balance is null for them. (The chart in seeds/gl_accounts.csv has no retained earnings
--   account, so the year-end closing entry is not in the export.)
-- Both are signed debit positive: a liability's or revenue's normal (credit) balance is
-- negative. Every account and line of business that ever had activity gets a row in every
-- period from the ledger's first period to its last, so a balance shows in months without
-- activity too.
with journal_lines as (
    select * from {{ ref('stg_general_ledger__journal_lines') }}
),

gl_accounts as (
    select * from {{ ref('gl_accounts') }}
),

accounting_periods as (
    select * from {{ ref('dim_accounting_periods') }}
),

ledger_periods as (
    select accounting_periods.*
    from accounting_periods
    where accounting_periods.accounting_period between
        (select min(accounting_period) from journal_lines)
        and (select max(accounting_period) from journal_lines)
),

account_lines as (
    select distinct
        account_number,
        line_of_business
    from journal_lines
),

activity as (
    select
        accounting_period,
        account_number,
        line_of_business,
        sum(debit_amount) as debit_amount,
        sum(credit_amount) as credit_amount
    from journal_lines
    group by 1, 2, 3
),

spine as (
    select
        ledger_periods.accounting_period,
        ledger_periods.fiscal_year,
        account_lines.account_number,
        account_lines.line_of_business
    from ledger_periods
    cross join account_lines
),

with_activity as (
    select
        spine.accounting_period,
        spine.fiscal_year,
        spine.account_number,
        spine.line_of_business,
        coalesce(activity.debit_amount, 0) as debit_amount,
        coalesce(activity.credit_amount, 0) as credit_amount,
        coalesce(activity.debit_amount, 0) - coalesce(activity.credit_amount, 0)
            as net_activity_amount
    from spine
    left join activity
        on spine.accounting_period = activity.accounting_period
        and spine.account_number = activity.account_number
        and spine.line_of_business = activity.line_of_business
),

balances as (
    select
        with_activity.*,
        sum(net_activity_amount) over (
            partition by account_number, line_of_business
            order by accounting_period
            rows between unbounded preceding and current row
        ) as running_net_amount,
        sum(net_activity_amount) over (
            partition by account_number, line_of_business, fiscal_year
            order by accounting_period
            rows between unbounded preceding and current row
        ) as ytd_net_activity_amount
    from with_activity
),

final as (
    select
        cast(balances.accounting_period || '|' || balances.account_number || '|'
            || balances.line_of_business as varchar) as trial_balance_key,
        cast(balances.accounting_period as varchar) as accounting_period,
        cast(balances.account_number as varchar) as account_number,
        cast(gl_accounts.account_name as varchar) as account_name,
        cast(gl_accounts.account_type as varchar) as account_type,
        cast(gl_accounts.normal_balance as varchar) as normal_balance,
        cast(gl_accounts.statement as varchar) as statement,
        cast(balances.line_of_business as varchar) as line_of_business,
        cast(balances.debit_amount as decimal(18, 2)) as debit_amount,
        cast(balances.credit_amount as decimal(18, 2)) as credit_amount,
        cast(balances.net_activity_amount as decimal(18, 2)) as net_activity_amount,
        cast(balances.ytd_net_activity_amount as decimal(18, 2)) as ytd_net_activity_amount,
        cast(case
            when gl_accounts.statement = 'BALANCE_SHEET' then balances.running_net_amount
        end as decimal(18, 2)) as itd_balance_amount
    from balances
    left join gl_accounts
        on balances.account_number = gl_accounts.account_number
)

select * from final
