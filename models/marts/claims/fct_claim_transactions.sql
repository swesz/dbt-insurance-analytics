{#
    Incremental strategy

    The fact is the largest claims table and grows every day, so it is built incrementally: each
    run rebuilds only the events whose source rows changed since the last run.

    Unique key: financial_event_id (claim_transaction_id + event type). Every source transaction
    gives one original event, and a voided payment gives one reversal more, so the key is stable
    across runs: the same event always has the same id.

    Strategy: delete+insert. dbt-duckdb 1.11 offers append, delete+insert, merge and microbatch
    (merge and microbatch because DuckDB is 1.4 or later).
      - append would insert the overlap of the lookback window a second time: duplicates.
      - delete+insert removes every target row whose key is in the new batch and inserts the
        batch. Rows are replaced whole, so a changed event (say, a payment whose claim got a new
        loss date) is simply rewritten, and re-running the same batch is idempotent.
      - merge does the same with an UPDATE and an INSERT and needs the update columns spelled
        out; it pays off when the target is large and partitioned or rows are updated in place
        with few columns. Neither is the case here, so it adds configuration and no benefit.
      - microbatch splits the work into time batches by an event_time column and needs every
        upstream model to declare one. It suits immutable event streams with a reliable event
        time. Here an event's row can change long after its event time (a void rewrites the
        payment), so batching by event time would not find the changes.

    Which rows a run rebuilds: the ones whose source_loaded_at (the latest loader write among
    the transaction, exposure and claim rows the event is built from) is no older than the
    newest one already in the target, minus a lookback window. The window exists because the
    loader timestamp is not a perfect high-water mark: _rivery_last_update is the source change
    time plus 1-90 minutes, runs are hourly, and a rerun can write a version whose timestamp is
    older than rows already loaded (CDC_DUPLICATE_VERSIONS came from such a rerun). A version
    that arrives late with an older timestamp would be skipped by a strict "newer than the max"
    filter. Re-processing a few days of events costs little, and delete+insert makes the overlap
    harmless. Override the window with --vars '{claims_incremental_lookback_days: 7}'.

    What incremental runs cannot do: remove an event whose source disappeared (a hard-deleted
    transaction, or a claim later found to be a test claim). delete+insert only replaces keys
    present in the new batch. The source does not do this today (deleted claims never had
    transactions), and tests/claims/assert_fct_claim_transactions_matches_events.sql compares the
    fact with the full set of events, so drift would fail the build. A load at an earlier as-of
    than the last one also needs --full-refresh.
#}
{{
    config(
        materialized='incremental',
        incremental_strategy='delete+insert',
        unique_key='financial_event_id',
        on_schema_change='fail',
    )
}}

{%- set lookback_days = var('claims_incremental_lookback_days', 3) %}

with financial_events as (
    select * from {{ ref('int_claims__financial_events') }}
),

final as (
    select
        financial_event_id,
        claim_transaction_id,
        event_type,
        is_void_reversal,
        transaction_type,
        claim_id,
        exposure_id,
        coverage_code,
        line_of_business,
        cost_category,
        expense_type,
        reserve_reason,
        transaction_date,
        event_date,
        entered_at,
        accounting_period,
        paid_amount,
        reserve_change_amount,
        loss_date,
        accident_year,
        source_loaded_at
    from financial_events
    {% if is_incremental() %}
    -- coalesce: if the target is empty (say, the first run was against an empty raw database),
    -- the max is null, and a comparison with null would select nothing, forever.
    where source_loaded_at >= (
        select coalesce(max(source_loaded_at), timestamp '1900-01-01')
            - interval '{{ lookback_days }} days'
        from {{ this }}
    )
    {% endif %}
)

select * from final
