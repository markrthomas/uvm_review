# =============================================================================
# SystemVerilog UVM runner for apb_mem.
#
# This testbench needs a UVM-capable commercial simulator (VCS, Xcelium, or
# Questa) — none of which is licensed on this host, so `make` here DEGRADES
# GRACEFULLY: it detects an available simulator and, finding none, prints a
# skip and exits 0 (the same policy the root Makefile uses for absent tools).
#
# On a licensed host it runs for real. Select a test with TEST=<name>:
#   apb_write_read_test | apb_random_test | apb_walking_test
# and add WAVES=1 for a dump.
#
# Two equivalent source layouts (pick with SINGLE):
#   SINGLE=0 (default) : multi-file set (apb_if.sv + apb_pkg.sv + classes + top)
#   SINGLE=1           : the single-file variant apb_tb_single.sv
# =============================================================================

TEST   ?= apb_random_test
WAVES  ?=
SINGLE ?= 0

TOP := apb_tb_top
RTL := ../rtl/apb_mem.sv

# Multi-file compile order: interface first (referenced by the package's virtual
# iface), then the DUT, the APB assertion checker (bound to the DUT), the
# package, and the top module.
SV_IF    := apb_if.sv
SVA      := apb_sva.sv
PKG      := apb_pkg.sv
SV_TOP   := apb_tb_top.sv
MULTI_SRC := $(SV_IF) $(RTL) $(SVA) $(PKG) $(SV_TOP)

# Included class files (apb_pkg.sv `include's these; listed for `make clean` /
# dependency clarity only).
CLASSES  := apb_seq_item.sv apb_sequences.sv apb_driver.sv apb_monitor.sv \
            apb_agent.sv apb_scoreboard.sv apb_env.sv apb_test.sv

# Single-file variant: everything (interface + package + top) in one file.
SINGLE_SRC := $(RTL) apb_tb_single.sv

ifeq ($(SINGLE),1)
    SOURCES := $(SINGLE_SRC)
else
    SOURCES := $(MULTI_SRC)
endif

.PHONY: default help test single vcs xcelium questa clean

default: test

help:
	@echo "apb_mem — SystemVerilog UVM runner (license-gated)"
	@echo ""
	@echo "  make test        # auto-detect VCS/Xcelium/Questa; skip cleanly if none"
	@echo "  make single      # same, using the single-file variant (SINGLE=1)"
	@echo "  make vcs         # force Synopsys VCS"
	@echo "  make xcelium     # force Cadence Xcelium (xrun)"
	@echo "  make questa      # force Siemens Questa (qrun)"
	@echo "  make clean"
	@echo ""
	@echo "  TEST=<name>   apb_write_read_test | apb_random_test | apb_walking_test"
	@echo "  WAVES=1       enable a waveform dump"
	@echo "  SINGLE=1      build the single-file TB (apb_tb_single.sv)"

# --- auto-select --------------------------------------------------------------
test:
	@if   command -v vcs  >/dev/null 2>&1; then $(MAKE) vcs; \
	elif command -v xrun >/dev/null 2>&1; then $(MAKE) xcelium; \
	elif command -v qrun >/dev/null 2>&1; then $(MAKE) questa; \
	else \
		echo "[UVM] no UVM simulator (vcs/xrun/qrun) on PATH — skipping"; \
		echo "[UVM] this host has no SystemVerilog/UVM license; TB is a"; \
		echo "[UVM] reference deliverable. Run on a licensed host to execute."; \
	fi

# Convenience: run the auto-select flow against the single-file variant.
single:
	@$(MAKE) test SINGLE=1

# --- Synopsys VCS -------------------------------------------------------------
vcs:
	@echo "[UVM] VCS: $(TEST)"
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps +incdir+. \
		$(if $(WAVES),+define+DUMP,) \
		$(SOURCES) -o simv
	./simv +UVM_TESTNAME=$(TEST)

# --- Cadence Xcelium ----------------------------------------------------------
xcelium:
	@echo "[UVM] Xcelium: $(TEST)"
	xrun -64bit -sv -uvm -timescale 1ns/1ps -incdir . \
		$(if $(WAVES),+define+DUMP,) \
		$(SOURCES) +UVM_TESTNAME=$(TEST)

# --- Siemens Questa -----------------------------------------------------------
questa:
	@echo "[UVM] Questa: $(TEST)"
	qrun -64 -sv -uvm -timescale 1ns/1ps +incdir+. \
		$(if $(WAVES),+define+DUMP,) \
		$(SOURCES) -top $(TOP) +UVM_TESTNAME=$(TEST)

# --- clean --------------------------------------------------------------------
clean:
	rm -rf simv simv.daidir csrc *.log ucli.key \
		xcelium.d xrun.history xrun.log INCA_libs .simvision \
		qrun.out work modelsim.ini transcript vsim.wlf \
		*.vcd *.fsdb *.shm novas.* verdi*
