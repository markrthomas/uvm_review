# =============================================================================
# apb_mem — APB byte-wide 32K memory: RTL lint + PyUVM/cocotb regression.
#
# Toolchain (WSL2 host):
#   * Simulator : Icarus Verilog 11  (/usr/bin/iverilog, pinned via ICARUS_BIN_DIR)
#   * Python    : /usr/bin/python3 (3.10) with cocotb 1.9.2 + pyuvm 4.0.1
#   * Lint      : Verilator (optional; degrades gracefully if absent)
#
# The actual cocotb run lives in tb/Makefile; this file provides the standard
# DV gate targets (help / lint / test / check / regress / ci / clean) shared
# with the other RTL repos and delegates to it.
# =============================================================================

IVERILOG  ?= iverilog
VERILATOR ?= verilator

RTL       := rtl/apb_mem.sv
TB_DIR    := tb

IVERILOG_FLAGS ?= -g2012 -Wall
VERILATOR_LINT_FLAGS ?= --lint-only -Wall -Wno-DECLFILENAME

.PHONY: default help \
	test test-all test-write-read test-random test-walking \
	waves check regress ci \
	lint _lint_iverilog _lint_verilator \
	clean

default: help

help:
	@echo "apb_mem — common targets"
	@echo ""
	@echo "  Tests (PyUVM / cocotb):"
	@echo "    make test              # same as test-all (all three cocotb tests)"
	@echo "    make test-all"
	@echo "    make test-write-read   # write-then-read-back sequence"
	@echo "    make test-random       # constrained-random read/write mix"
	@echo "    make test-walking      # directed address/data edge cases"
	@echo "    make waves             # run all tests and dump tb/sim_build/apb_mem.fst"
	@echo ""
	@echo "  Gates:"
	@echo "    make lint              # iverilog -Wall compile check + Verilator RTL lint"
	@echo "    make check             # lint then test-all"
	@echo "    make regress           # lint + full regression (CI-style pass/fail)"
	@echo "    make ci                # alias for regress"
	@echo ""
	@echo "  Other: make clean"

# --- tests -------------------------------------------------------------------

test: test-all

test-all:
	$(MAKE) -C $(TB_DIR)

test-write-read:
	$(MAKE) -C $(TB_DIR) TESTCASE=write_read_test

test-random:
	$(MAKE) -C $(TB_DIR) TESTCASE=random_test

test-walking:
	$(MAKE) -C $(TB_DIR) TESTCASE=walking_test

waves:
	$(MAKE) -C $(TB_DIR) WAVES=1
	@echo "[WAVES] wrote $(TB_DIR)/sim_build/apb_mem.fst"

# --- gates -------------------------------------------------------------------

lint: _lint_iverilog _lint_verilator

_lint_iverilog:
	@echo "[LINT] iverilog -Wall compile check..."
	$(IVERILOG) $(IVERILOG_FLAGS) -o /dev/null $(RTL)

_lint_verilator:
	@if command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[LINT] Verilator RTL lint..."; \
		$(VERILATOR) $(VERILATOR_LINT_FLAGS) $(RTL); \
	else \
		echo "[LINT] verilator not on PATH — skipping RTL lint"; \
	fi

check: lint test-all

regress: lint test-all
	@echo "[REGRESS] lint + PyUVM regression PASSED"

ci: regress

# --- clean -------------------------------------------------------------------

clean:
	$(MAKE) -C $(TB_DIR) clean 2>/dev/null || true
	rm -rf $(TB_DIR)/sim_build $(TB_DIR)/__pycache__ __pycache__ \
		results.xml dump.fst dump.vcd
