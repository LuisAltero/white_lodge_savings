{#
  Generic composite-key test.

  It lives here as a local macro rather than pulling in `dbt_utils`, on purpose:
  it's the only thing we'd use from that package, and adding an external
  dependency turns `git clone && run` into `git clone && dbt deps && run` — with
  a network call that can fail on exactly the morning of the live session. Six
  lines of SQL aren't worth that coupling.
#}
{% test unique_combination_of_columns(model, combination_of_columns) %}

    select {{ combination_of_columns | join(', ') }}, count(*) as n_records
    from {{ model }}
    group by {{ combination_of_columns | join(', ') }}
    having count(*) > 1

{% endtest %}
