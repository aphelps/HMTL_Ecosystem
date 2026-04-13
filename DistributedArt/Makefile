# DistributedArt Makefile
#
# Targets:
#   make all  — run tests
#   make test — run Flask unit tests

PYTEST ?= pytest

FLASK_DIR := DistributedArtFlask

.PHONY: all test

all: test

test:
	@echo "=== DistributedArt Flask tests ==="
	cd $(FLASK_DIR) && $(PYTEST) tests/ -v
