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
TB_RESULTS := $(TB_DIR)/results.xml
FST       := $(TB_DIR)/sim_build/apb_mem.fst
GTKW      := $(TB_DIR)/apb_mem.gtkw
UVM_DIR   := uvm
LP_DIR    := lp
LP_RESULTS := $(LP_DIR)/results.xml

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
	waves wave check regress ci coverage uvm lp \
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
	@echo "    make waves             # dump tb/sim_build/apb_mem.fst (all tests; TEST=<name> for one)"
	@echo "    make wave              # open the dump in GTKWave (add TEST=<name> for a single test)"
	@echo ""
	@echo "  SystemVerilog UVM (license-gated; skips cleanly if no simulator):"
	@echo "    make uvm               # run the SV/UVM TB under uvm/ (VCS/Xcelium/Questa)"
	@echo ""
	@echo "  Low-power / UPF:"
	@echo "    make lp                # UPF-emulated power-cycle test (isolation/retention/corruption)"
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
# run_one_test runs a SINGLE cocotb test in its own simulation and fails the
# build if that test did not pass. Two reasons this is a canned recipe rather
# than a bare `$(MAKE) -C tb`:
#
#   1. Fresh memory per test. cocotb runs every @cocotb.test in ONE simulation,
#      and the RTL only zeroes its array at time 0 — so a later test would read
#      locations an earlier test wrote (a seed-dependent scoreboard flake). One
#      sim per test re-zeroes the memory and mirrors the SV/UVM TB.
#   2. Real pass/fail. cocotb's make flow exits 0 here even when a test fails, so
#      we check results.xml for a <failure>/<error> element and exit non-zero.
define run_one_test
@$(MAKE) -C $(TB_DIR) TESTCASE=$(1)
@test -f $(TB_RESULTS) || { echo "[TEST] $(1): no results.xml (sim did not run)"; exit 1; }
@if grep -Eq "<failure|<error" $(TB_RESULTS); then echo "[TEST] $(1) FAILED (see log above)"; exit 1; fi
@echo "[TEST] $(1) passed"
endef

test: test-all

test-all:
	$(call run_one_test,write_read_test)
	$(call run_one_test,random_test)
	$(call run_one_test,walking_test)
	@echo "[TEST] all three PyUVM tests passed"

test-write-read:
	$(call run_one_test,write_read_test)

test-random:
	$(call run_one_test,random_test)

test-walking:
	$(call run_one_test,walking_test)

# Waveform dump. By default all three tests run in one sim (viewing only, not a
# pass/fail gate); TEST=<name> dumps just one, e.g. `make waves TEST=random_test`.
# cocotb's Icarus dump module is only compiled into a FRESH sim_build, so wipe it
# first — a stale build silently skips the dump and leaves no/empty FST.
WAVE_TESTS := write_read_test random_test walking_test

waves:
	@if [ -n "$(TEST)" ] && ! echo " $(WAVE_TESTS) " | grep -q " $(TEST) "; then \
		echo "[WAVES] unknown TEST='$(TEST)' — choose one of: $(WAVE_TESTS)"; exit 1; fi
	rm -rf $(TB_DIR)/sim_build
	$(MAKE) -C $(TB_DIR) WAVES=1 $(if $(TEST),TESTCASE=$(TEST),)
	@echo "[WAVES] wrote $(FST)$(if $(TEST), (single test: $(TEST)),)"

# Open the dump in GTKWave with the curated signal layout (grouped clock/reset,
# APB request, APB response; buses in hex). ALWAYS regenerates a fresh dump via
# `waves` — a leftover sim_build from a non-WAVES `make test`/`ci` run rewrites
# apb_mem.fst in VCD format (Icarus dumps VCD without +fst), which GTKWave can't
# open. Skips cleanly if GTKWave is not installed. Runs in the foreground —
# closing GTKWave returns the shell.
wave:
	@if ! command -v gtkwave >/dev/null 2>&1; then \
		echo "[WAVE] gtkwave not on PATH — install GTKWave to view waveforms"; \
		exit 0; \
	fi; \
	$(MAKE) --no-print-directory waves $(if $(TEST),TEST=$(TEST),); \
	echo "[WAVE] opening $(FST) in GTKWave (layout: $(GTKW))$(if $(TEST), — single test: $(TEST),)"; \
	exec gtkwave $(FST) $(GTKW)

# SystemVerilog UVM testbench (mirrors the PyUVM TB). Needs a UVM-capable
# commercial simulator; degrades gracefully (skip, exit 0) when none is present.
uvm:
	$(MAKE) -C $(UVM_DIR) $(if $(TEST),TEST=$(TEST),) $(if $(WAVES),WAVES=$(WAVES),) $(if $(SINGLE),SINGLE=$(SINGLE),)

# Low-power (UPF) demo. apb_mem.upf is the golden IEEE-1801 intent; no simulator
# in this repo is UPF-aware, so `make lp` instead runs a hand-modeled emulation
# (lp/apb_mem_lp.sv, lp/apb_mem_array.sv) that reproduces what the UPF flow would
# do — isolation, retention, and power-down corruption — and gates on its
# results.xml like the PyUVM tests. It also compiles the UPF-clean variant (no
# -DLP_EMULATE) so the real-flow sources stay buildable.
lp:
	@echo "[LP] compile-check UPF-clean variant (no emulation)..."
	@$(IVERILOG) $(IVERILOG_FLAGS) -o /dev/null $(LP_DIR)/apb_mem_array.sv $(LP_DIR)/apb_mem_lp.sv
	@echo "[LP] power-cycle test (UPF-emulated isolation/retention/corruption)..."
	@$(MAKE) -C $(LP_DIR)
	@test -f $(LP_RESULTS) || { echo "[LP] no results.xml (sim did not run)"; exit 1; }
	@if grep -Eq "<failure|<error" $(LP_RESULTS); then echo "[LP] FAILED (see log above)"; exit 1; fi
	@echo "[LP] passed"

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

regress: lint test-all lp
	@echo "[REGRESS] lint + PyUVM regression + low-power (UPF) demo PASSED"

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
	$(MAKE) -C $(LP_DIR) clean 2>/dev/null || true
	rm -rf $(LP_DIR)/sim_build $(LP_DIR)/__pycache__ $(LP_RESULTS) \
		$(TB_DIR)/sim_build $(TB_DIR)/__pycache__ __pycache__ \
		results.xml dump.fst dump.vcd \
		$(COV_DIR) sim/coverage.info sim/coverage.dat sim/annotated
