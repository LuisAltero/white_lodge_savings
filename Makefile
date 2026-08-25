# One target per thing somebody needs to do. Nothing beyond that.
#
# On Windows: `winget install ezwinports.make`. Without make, every target is a
# single command — copy the line.

# The venv puts the interpreter in a different place per platform, and macOS
# ships no bare `python` - only `python3`. Both are `?=`, so either can still be
# overridden on the command line.
ifeq ($(OS),Windows_NT)
PYTHON    ?= .venv/Scripts/python.exe
BOOTSTRAP ?= python
else
PYTHON    ?= .venv/bin/python
BOOTSTRAP ?= python3
endif

DB     ?= data/duckdb/warehouse.duckdb

# `cd warehouse && ...` would put a `&&` in the recipe, and a `&&` is what makes
# make hand the line to a shell — cmd.exe on Windows, which reads `/` as a switch
# and fails with `'..' is not recognized`. These flags do the same job with no
# shell, so every target behaves the same on all three systems.
#
# --project-dir does *not* chdir, so profiles.yml's relative `../data/...` would
# resolve against the repo root. Hence the absolute export below.
DBT     = $(PYTHON) -m dbt.cli.main
DBT_DIR = --project-dir warehouse --profiles-dir warehouse
export WLS_DUCKDB_PATH := $(abspath $(DB))

# `rm` doesn't exist on Windows. Python does, and it's already required here.
RM_DB   = $(PYTHON) -c "import pathlib; pathlib.Path('$(DB)').unlink(missing_ok=True)"
RM_TREE = $(PYTHON) -c "import shutil,sys; [shutil.rmtree(p, ignore_errors=True) for p in sys.argv[1:]]"

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
	$(BOOTSTRAP) -m venv .venv
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r requirements.txt

# Ingestion + dbt build. `dbt build` interleaves models and tests, so a model
# whose test fails doesn't propagate bad data to whatever depends on it.
pipeline:
	$(PYTHON) -m pipeline.run

all: pipeline notebook

test:
	$(PYTHON) -m pytest tests/ -q
	$(DBT) test $(DBT_DIR) --select "test_type:unit"

dbt-test:
	$(DBT) test $(DBT_DIR)

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
	$(RM_DB)
	$(MAKE) pipeline

# The NADAC CSV (~83 MB) deliberately survives clean: re-downloading takes
# minutes, and it isn't a build artefact — it's a cached input.
clean:
	$(RM_TREE) warehouse/target warehouse/logs warehouse/dbt_packages .pytest_cache
	$(RM_DB)
