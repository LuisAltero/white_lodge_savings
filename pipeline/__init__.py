"""Ingestion layer for the White Lodge Savings mini-warehouse.

Python only does the *landing*: fetch NADAC, and drop each raw file into a
`raw.*` DuckDB table without interpreting anything. Every transformation lives
in dbt.
"""
