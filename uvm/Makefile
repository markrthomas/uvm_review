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
# =============================================================================

TEST  ?= apb_write_read_test
WAVES ?=

# Compile order: interface first (referenced by the package's virtual iface),
# then the DUT, the package, and the top module.
RTL      := ../rtl/apb_mem.sv
SV_TOP   := apb_tb_top.sv
SV_IF    := apb_if.sv
PKG      := apb_pkg.sv
SOURCES  := $(SV_IF) $(RTL) $(PKG) $(SV_TOP)
TOP      := apb_tb_top

# Included class files (apb_pkg.sv `include's these; listed for `make clean` /
# dependency clarity only).
CLASSES  := apb_seq_item.sv apb_sequences.sv apb_driver.sv apb_monitor.sv \
            apb_agent.sv apb_scoreboard.sv apb_env.sv apb_test.sv

.PHONY: default help test vcs xcelium questa clean

default: test

help:
	@echo "apb_mem — SystemVerilog UVM runner (license-gated)"
	@echo ""
	@echo "  make test        # auto-detect VCS/Xcelium/Questa; skip cleanly if none"
	@echo "  make vcs         # force Synopsys VCS"
	@echo "  make xcelium     # force Cadence Xcelium (xrun)"
	@echo "  make questa      # force Siemens Questa (qrun)"
	@echo "  make clean"
	@echo ""
	@echo "  TEST=<name>   apb_write_read_test | apb_random_test | apb_walking_test"
	@echo "  WAVES=1       enable a waveform dump"

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
