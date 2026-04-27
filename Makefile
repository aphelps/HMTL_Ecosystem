# HMTL Ecosystem — top-level Makefile
#
# Targets:
#   make all              — build all firmware + run all tests + coverage
#   make build            — build all firmware submodules
#   make test             — run all tests (HMTL + HMTL_Fire_Control)
#   make coverage         — run coverage for all submodules with tests
#   make coverage-python  — Python coverage for all submodules
#   make coverage-native  — C++ native coverage for all submodules
#   make <subdir>         — run the default target in that submodule

MAKE ?= make

FIRMWARE_MODULES  := HMTL HMTL_Fire_Control CircularController
TEST_MODULES      := HMTL HMTL_Fire_Control
COVERAGE_MODULES  := HMTL HMTL_Fire_Control

.PHONY: all build test coverage coverage-python coverage-native $(FIRMWARE_MODULES)

all: build test coverage

build:
	@for m in $(FIRMWARE_MODULES); do \
	    echo ""; \
	    echo "======================================"; \
	    echo "  Building $$m"; \
	    echo "======================================"; \
	    $(MAKE) -C $$m build || exit 1; \
	done

test:
	@for m in $(TEST_MODULES); do \
	    echo ""; \
	    echo "======================================"; \
	    echo "  Testing $$m"; \
	    echo "======================================"; \
	    $(MAKE) -C $$m test || exit 1; \
	done

coverage:
	@for m in $(COVERAGE_MODULES); do \
	    echo ""; \
	    echo "======================================"; \
	    echo "  Coverage $$m"; \
	    echo "======================================"; \
	    $(MAKE) -C $$m coverage || exit 1; \
	done

coverage-python:
	@for m in $(COVERAGE_MODULES); do \
	    echo ""; \
	    echo "======================================"; \
	    echo "  Python Coverage $$m"; \
	    echo "======================================"; \
	    $(MAKE) -C $$m coverage-python || exit 1; \
	done

coverage-native:
	@for m in $(COVERAGE_MODULES); do \
	    echo ""; \
	    echo "======================================"; \
	    echo "  C++ Coverage $$m"; \
	    echo "======================================"; \
	    $(MAKE) -C $$m coverage-native || exit 1; \
	done

# Convenience: `make HMTL`, `make CircularController`, etc.
$(FIRMWARE_MODULES):
	$(MAKE) -C $@
