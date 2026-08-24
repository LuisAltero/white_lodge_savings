{#
  Money becomes an integer number of cents as soon as it leaves staging.

  Why: `price`, `pbm_fee` and the NADAC cost all arrive as floats, and the
  partner split multiplies a float by a percentage. Summing 41k claims in DOUBLE,
  the rounding error shows up in the third decimal, and two people running the
  same question with different GROUP BYs get different totals. Integer cents make
  the sum exact and associative.

  DECIMAL(18,2) would work too, but cents make the unit explicit in the column
  name (`price_cents`) — nobody divides by 100 by accident.
#}
{% macro to_cents(column) -%}
    cast(round(({{ column }}) * 100) as bigint)
{%- endmacro %}
