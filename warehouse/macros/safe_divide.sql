{#
  Division that returns NULL instead of blowing up on a zero denominator.

  NULL and not zero, deliberately: a partner with zero lookups doesn't have a 0%
  conversion rate — it has no conversion rate. Returning zero puts that row at
  the bottom of an `order by conversion_rate` as if it were measured poor
  performance, when it is actually absence of measurement.
#}
{% macro safe_divide(numerator, denominator) -%}
    case
        when coalesce({{ denominator }}, 0) = 0 then null
        else ({{ numerator }}) * 1.0 / ({{ denominator }})
    end
{%- endmacro %}
