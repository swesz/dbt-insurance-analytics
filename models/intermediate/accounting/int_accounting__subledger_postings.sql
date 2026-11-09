{{ config(materialized='table') }}

-- The general ledger postings the subledgers imply: what the ledger should contain, per
-- accounting period x line of business x GL account x source system, built from the premium,
-- billing and claims subledgers exactly as docs/source-systems.md 3h describes the close.
--
-- Amounts are signed, debit positive and credit negative. Each entry below is written as two
-- legs of opposite sign, so every entry, and therefore every period and line of business, sums
-- to zero (tests/accounting/assert_subledger_postings_balance.sql). That one convention lets the
-- reconciliation compare subledger and ledger with a subtraction, whatever the account type.
--
--   source        entry                     debit                    credit
--   POLICY_ADMIN  written premium           1200 Premiums receivable 4000 Premiums written
--   POLICY_ADMIN  increase in UPR           4100 Change in UPR       2100 Unearned premium
--   BILLING       cash, net of refunds      1000 Cash                1200 Premiums receivable
--                 and returns
--   CLAIMS        gross loss payments       5000 Losses paid         1000 Cash
--   CLAIMS        loss recoveries           1000 Cash                5050 Salvage and subrogation
--   CLAIMS        LAE payments              5200 LAE paid            1000 Cash
--   CLAIMS        loss reserve change       5100 Change in reserves  2200 Case reserves - loss
--   CLAIMS        LAE reserve change        5300 Change in reserves  2300 Case reserves - LAE
--
-- A negative amount swaps the sides: a cancellation (negative written premium) credits 1200 and
-- debits 4000; a month in which more premium is earned than written decreases the UPR, which
-- debits 2100 and credits 4100. The signed convention handles that without a case statement.
--
-- Every input is booked by the booking rule (3c) upstream, which is what makes these figures
-- stable: an amount booked in a closed period was entered before that period closed, so it was
-- in the ledger export, and nothing entered later can land in a closed period.
with premium as (
    select * from {{ ref('fct_premium_by_policy_period') }}
),

cash_events as (
    select * from {{ ref('int_accounting__billing_cash_events') }}
),

claim_transactions as (
    select * from {{ ref('fct_claim_transactions') }}
),

premium_by_period as (
    select
        accounting_period,
        line_of_business,
        sum(written_premium) as written_premium,
        -- UPR(P) - UPR(P-1) = written(P) - earned(P), line by line (docs/source-systems.md 3d),
        -- so the increase in UPR needs no lag over a sparse table: lines whose window ended have
        -- no row in later periods, and their UPR is zero there.
        sum(written_premium - earned_premium) as unearned_premium_increase
    from premium
    group by 1, 2
),

cash_by_period as (
    select
        accounting_period,
        line_of_business,
        sum(cash_amount) as cash_amount
    from cash_events
    group by 1, 2
),

claims_by_period as (
    select
        accounting_period,
        line_of_business,
        -- Gross payments, by cost category, including the reversals of voided payments
        -- (PAYMENT_VOID events, negative), booked in the month of the void. paid_amount is
        -- signed for net paid: + for a payment, - for its reversal.
        sum(case
            when transaction_type = 'PAYMENT' and cost_category = 'LOSS' then paid_amount
            else 0
        end) as loss_paid_amount,
        sum(case
            when transaction_type = 'PAYMENT' and cost_category = 'EXPENSE' then paid_amount
            else 0
        end) as expense_paid_amount,
        -- Recoveries are money coming back, so their paid_amount is negative (net paid =
        -- payments - recoveries). The ledger books the money received as a positive debit to
        -- cash, hence the minus sign.
        -- Known limitation: every RECOVERY goes to 5050 Salvage and subrogation, whatever its
        -- cost category. That is right for loss recoveries, and today all recoveries are LOSS.
        -- An EXPENSE recovery (recovered defense costs, say) belongs against LAE (5200) and
        -- would be misposted. The reconciliation would not notice, because the generator's
        -- ledger also posts every recovery to 5050; the claims control-total tests would, since
        -- dbt nets a recovery against its own cost category and the generator against loss.
        -- Split this by cost_category before expense recoveries appear.
        -sum(case
            when transaction_type = 'RECOVERY' then paid_amount
            else 0
        end) as recovery_amount,
        sum(case
            when cost_category = 'LOSS' then reserve_change_amount
            else 0
        end) as loss_reserve_change_amount,
        sum(case
            when cost_category = 'EXPENSE' then reserve_change_amount
            else 0
        end) as expense_reserve_change_amount
    from claim_transactions
    group by 1, 2
),

posting_legs as (
    -- POLICY_ADMIN: written premium.
    select accounting_period, line_of_business, 'POLICY_ADMIN' as source_system,
        '1200' as account_number, written_premium as amount
    from premium_by_period
    union all
    select accounting_period, line_of_business, 'POLICY_ADMIN', '4000', -written_premium
    from premium_by_period

    -- POLICY_ADMIN: change in the unearned premium reserve.
    union all
    select accounting_period, line_of_business, 'POLICY_ADMIN', '4100', unearned_premium_increase
    from premium_by_period
    union all
    select accounting_period, line_of_business, 'POLICY_ADMIN', '2100', -unearned_premium_increase
    from premium_by_period

    -- BILLING: cash collected reduces the receivable.
    union all
    select accounting_period, line_of_business, 'BILLING', '1000', cash_amount
    from cash_by_period
    union all
    select accounting_period, line_of_business, 'BILLING', '1200', -cash_amount
    from cash_by_period

    -- CLAIMS: loss payments, recoveries and LAE payments move cash.
    union all
    select accounting_period, line_of_business, 'CLAIMS', '5000', loss_paid_amount
    from claims_by_period
    union all
    select accounting_period, line_of_business, 'CLAIMS', '1000', -loss_paid_amount
    from claims_by_period
    union all
    select accounting_period, line_of_business, 'CLAIMS', '1000', recovery_amount
    from claims_by_period
    union all
    select accounting_period, line_of_business, 'CLAIMS', '5050', -recovery_amount
    from claims_by_period
    union all
    select accounting_period, line_of_business, 'CLAIMS', '5200', expense_paid_amount
    from claims_by_period
    union all
    select accounting_period, line_of_business, 'CLAIMS', '1000', -expense_paid_amount
    from claims_by_period

    -- CLAIMS: changes in the case reserves (an increase is an expense and a liability).
    union all
    select accounting_period, line_of_business, 'CLAIMS', '5100', loss_reserve_change_amount
    from claims_by_period
    union all
    select accounting_period, line_of_business, 'CLAIMS', '2200', -loss_reserve_change_amount
    from claims_by_period
    union all
    select accounting_period, line_of_business, 'CLAIMS', '5300', expense_reserve_change_amount
    from claims_by_period
    union all
    select accounting_period, line_of_business, 'CLAIMS', '2300', -expense_reserve_change_amount
    from claims_by_period
),

-- One row per source system, too, not only per account. Two accounts are fed by two systems:
-- 1000 Cash by billing (customer cash) and claims (payments, recoveries), 1200 Receivable by
-- policy admin (written premium) and billing (cash collected). The ledger records the source
-- system on every journal line, so the reconciliation can compare system by system. Summed per
-- account only, an error in one system and an opposite error in the other within the same
-- month would cancel out and look MATCHED.
aggregated as (
    select
        accounting_period,
        line_of_business,
        account_number,
        source_system,
        sum(amount) as subledger_amount
    from posting_legs
    group by 1, 2, 3, 4
),

final as (
    select
        accounting_period || '|' || line_of_business || '|' || account_number || '|'
            || source_system as posting_key,
        accounting_period,
        line_of_business,
        account_number,
        source_system,
        cast(subledger_amount as decimal(18, 2)) as subledger_amount
    from aggregated
)

select * from final
