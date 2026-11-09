{#
    The distinct versions of a CDC table loaded in append mode (docs/source-systems.md 2c, 2e).

    The claims connector appends one row per source change, so a key has one row per version,
    ordered by the source's updated_at. A loader rerun sometimes wrote a version a second time
    (CDC_DUPLICATE_VERSIONS): same key and updated_at, a different _rivery_run_id. Those copies
    describe one version, so this keeps one row per (key, updated_at). Which copy survives does
    not matter for the business columns (tests/claims/assert_cdc_duplicate_versions_are_exact.sql
    checks they are identical), but it must be deterministic, so the tiebreak is the latest
    write: _rivery_last_update, then _rivery_run_id.

    Adds three columns:
        version_number      1 for the key's first version, then 2, 3, ...
        is_latest_version   true on the version that is the key's current state. That version
                            can be a delete (__deleted = true): callers drop the key then, and
                            must filter on is_latest_version BEFORE removing deletes, or the
                            version before the delete would wrongly come back as current.
        valid_to            the next version's updated_at; null on the latest version. A version
                            is the state of the row during [updated_at, valid_to).

    Usage, as a CTE body over an import CTE or relation that has the raw loader columns:
        distinct_versions as (
            {{ claims_cdc_versions('claims_source', 'claim_id') }}
        ),
#}
{% macro claims_cdc_versions(relation, primary_key) -%}
    select
        _deduplicated.*,
        row_number() over (
            partition by {{ primary_key }}
            order by updated_at, _rivery_last_update, _rivery_run_id
        ) as version_number,
        row_number() over (
            partition by {{ primary_key }}
            order by updated_at desc, _rivery_last_update desc, _rivery_run_id desc
        ) = 1 as is_latest_version,
        lead(updated_at) over (
            partition by {{ primary_key }}
            order by updated_at, _rivery_last_update, _rivery_run_id
        ) as valid_to
    from (
        select *
        from {{ relation }}
        qualify row_number() over (
            partition by {{ primary_key }}, updated_at
            order by _rivery_last_update desc, _rivery_run_id desc
        ) = 1
    ) as _deduplicated
{%- endmacro %}
