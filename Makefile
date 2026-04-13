# HMTL Ecosystem — top-level Makefile
#
# Targets:
#   make all        — build all firmware + run all tests
#   make build      — build all firmware submodules
#   make test       — run all tests (HMTL + DistributedArt)
#   make <subdir>   — run the default target in that submodule

MAKE ?= make

FIRMWARE_MODULES := HMTL HMTL_Fire_Control CircularController
TEST_MODULES     := HMTL DistributedArt

.PHONY: all build test $(FIRMWARE_MODULES) DistributedArt

all: build test

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

# Convenience: `make HMTL`, `make CircularController`, etc.
$(FIRMWARE_MODULES) DistributedArt:
	$(MAKE) -C $@
