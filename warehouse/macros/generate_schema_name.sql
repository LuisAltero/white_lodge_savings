{#
  By default dbt prefixes the target schema onto the custom schema, and models
  land in `main_marts`, `main_staging`. That doesn't serve us here: in the live
  sessions we type `from marts.fct_claim` from memory, screen shared.
  `main_marts` is pure friction in a context with no multi-tenancy to protect —
  it's a local DuckDB file with one user.

  The default behaviour exists to stop dev A overwriting dev B's table in a
  shared warehouse. That isn't our situation: everyone has their own .duckdb file.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
