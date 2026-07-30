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
UVM_DIR   := uvm

IVERILOG_FLAGS ?= -g2012 -Wall
VERILATOR_LINT_FLAGS ?= --lint-only -Wall -Wno-DECLFILENAME

# Verilator coverage harness (sim/sim_main.cpp -> lcov coverage.info).
VERILATOR_ROOT := $(shell v=$$(command -v verilator 2>/dev/null); [ -n "$$v" ] && realpath "$$(dirname "$$v")/../share/verilator")
VERILATOR_INC  := $(VERILATOR_ROOT)/include
VERILATOR_CPP  := $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_cov.cpp \
                  $(VERILATOR_INC)/verilated_threads.cpp
COV_DIR := sim/obj_dir_cov
# Minimum line-coverage floor enforced by `make coverage`.
COV_MIN ?= 100

.PHONY: default help \
	test test-all test-write-read test-random test-walking \
	waves check regress ci coverage uvm \
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
	@echo "  SystemVerilog UVM (license-gated; skips cleanly if no simulator):"
	@echo "    make uvm               # run the SV/UVM TB under uvm/ (VCS/Xcelium/Questa)"
	@echo ""
	@echo "  Gates:"
	@echo "    make lint              # iverilog -Wall compile check + Verilator RTL lint"
	@echo "    make coverage          # Verilator C++ coverage -> sim/coverage.info (fails below COV_MIN=$(COV_MIN)% lines)"
	@echo "    make check             # lint then test-all"
	@echo "    make regress           # lint + full regression (CI-style pass/fail)"
	@echo "    make ci                # regress + coverage"
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

# SystemVerilog UVM testbench (mirrors the PyUVM TB). Needs a UVM-capable
# commercial simulator; degrades gracefully (skip, exit 0) when none is present.
uvm:
	$(MAKE) -C $(UVM_DIR) $(if $(TEST),TEST=$(TEST),) $(if $(WAVES),WAVES=$(WAVES),)

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

ci: regress coverage
	@echo "[CI] lint + regression + coverage PASSED"

# coverage: Verilator --coverage build + run of the sim/sim_main.cpp harness;
# emits sim/coverage.info (lcov) and enforces the COV_MIN line-coverage floor.
# Degrades gracefully (exit 0) when Verilator is not installed.
coverage:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[COVERAGE] verilator not on PATH; skipping"; exit 0; }; \
	rm -rf $(COV_DIR); \
	$(VERILATOR) --coverage -cc $(RTL) --top-module apb_mem \
		--Mdir $(COV_DIR) -Wall -Wno-DECLFILENAME; \
	$(MAKE) -C $(COV_DIR) -f Vapb_mem.mk; \
	g++ -DVM_COVERAGE=1 -o $(COV_DIR)/sim_cov \
		sim/sim_main.cpp $(COV_DIR)/Vapb_mem__ALL.a \
		-I$(COV_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) -pthread -lm; \
	( cd $(COV_DIR) && ./sim_cov ); \
	if command -v verilator_coverage >/dev/null 2>&1; then \
		verilator_coverage --write-info sim/coverage.info $(COV_DIR)/coverage.dat; \
		echo "[COVERAGE] sim/coverage.info written"; \
		pct=$$(awk -F: '/^DA:/{split($$2,a,","); f++; if(a[2]+0>0) h++} END{printf "%.1f", (f? 100*h/f : 0)}' sim/coverage.info); \
		echo "[COVERAGE] line coverage: $$pct% (floor $(COV_MIN)%)"; \
		awk -v p="$$pct" -v m="$(COV_MIN)" 'BEGIN{exit !(p+0 >= m+0)}' || { \
			echo "[COVERAGE] FAIL: line coverage $$pct% below the $(COV_MIN)% floor"; exit 1; }; \
		echo "[COVERAGE] PASS: meets the $(COV_MIN)% floor"; \
	else \
		echo "[COVERAGE] coverage.dat in $(COV_DIR) (install verilator for lcov export)"; \
	fi

# --- clean -------------------------------------------------------------------

clean:
	$(MAKE) -C $(TB_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(UVM_DIR) clean 2>/dev/null || true
	rm -rf $(TB_DIR)/sim_build $(TB_DIR)/__pycache__ __pycache__ \
		results.xml dump.fst dump.vcd \
		$(COV_DIR) sim/coverage.info sim/coverage.dat sim/annotated
