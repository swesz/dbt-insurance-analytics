{#
    Use a model's custom schema name as it is.

    dbt's built-in version joins the target schema and the custom one (main_staging), so that two
    environments or two developers sharing one database never write into the same schema. Here
    every environment is its own database file (profiles.yml), so that protection is not needed,
    and plain names (staging, core, claims, ...) read better in queries.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
