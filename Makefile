# One target per thing somebody needs to do. Nothing beyond that.
#
# On Windows without `make`, every target is a single command — copy the line.

PYTHON ?= .venv/Scripts/python.exe
DB     ?= data/duckdb/warehouse.duckdb

.PHONY: help setup all pipeline test dbt-test notebook query clean rebuild

help:
	@echo "make setup     - create the venv and install dependencies"
	@echo "make all       - full pipeline + executed notebook"
	@echo "make pipeline  - ingestion + dbt build (models and tests)"
	@echo "make test      - pytest + dbt unit tests"
	@echo "make notebook  - execute analysis/analysis.ipynb"
	@echo "make query     - open the DuckDB shell on the warehouse"
	@echo "make rebuild   - drop the database and rebuild from scratch"
	@echo "make clean     - remove build artefacts (keeps the NADAC cache)"

setup:
	python -m venv .venv
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r requirements.txt

# Ingestion + dbt build. `dbt build` interleaves models and tests, so a model
# whose test fails doesn't propagate bad data to whatever depends on it.
pipeline:
	$(PYTHON) -m pipeline.run

all: pipeline notebook

test:
	$(PYTHON) -m pytest tests/ -q
	cd warehouse && ../$(PYTHON) -m dbt.cli.main test --select "test_type:unit"

dbt-test:
	cd warehouse && ../$(PYTHON) -m dbt.cli.main test

# Re-executes the notebook in place, so the delivered .ipynb ships with its
# outputs and reads in a browser. Edit the cells in Jupyter — the notebook is
# the source, there is no generator behind it.
notebook:
	$(PYTHON) -m jupyter nbconvert --to notebook --execute --inplace \
		--ExecutePreprocessor.timeout=300 analysis/analysis.ipynb

# The DuckDB Python package ships no `__main__`, so `python -m duckdb` is not a
# shell. analysis/shell.py is one, on a read-only connection.
query:
	$(PYTHON) analysis/shell.py

rebuild:
	rm -f $(DB)
	$(MAKE) pipeline

# The NADAC CSV (~83 MB) deliberately survives clean: re-downloading takes
# minutes, and it isn't a build artefact — it's a cached input.
clean:
	rm -rf warehouse/target warehouse/logs warehouse/dbt_packages
	rm -rf .pytest_cache
	rm -f $(DB)
