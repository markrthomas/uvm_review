# cocotb / PyUVM runner for axi_apb_mem (invoked by the repo-root Makefile).
# Select a single test with TESTCASE=<name>; dump waves with WAVES=1. Set
# DUT=apb_mem to run the original standalone APB3 core instead.

TOPLEVEL_LANG = verilog
SIM          ?= icarus

DUT             ?= axi_apb_mem

ifeq ($(DUT),apb_mem)
    VERILOG_SOURCES = $(PWD)/../rtl/apb_mem.sv
    TOPLEVEL        = apb_mem
    MODULE          = apb_test
    # Keep the legacy standalone build separate from the integrated build.
    # Cocotb's simulator make rules otherwise reuse sim_build/sim.vvp when DUT
    # is switched on the command line, leaving the wrong top-level elaborated.
    SIM_BUILD      ?= sim_build/apb_mem
else
    VERILOG_SOURCES = $(PWD)/../rtl/apb_mem.sv $(PWD)/../rtl/axi_lite_to_apb.sv $(PWD)/../rtl/axi_apb_mem.sv
    TOPLEVEL        = axi_apb_mem
    MODULE          = apb_test,axi_test
    COMPILE_ARGS   += -I$(PWD)/../rtl
endif

# Pin the apt Icarus + the cocotb-bound interpreter so the VPI is built against
# the same Python that imports the testbench (avoids the OSS-CAD-Suite mismatch).
ICARUS_BIN_DIR    ?= /usr/bin
export ICARUS_BIN_DIR
SIM_CMD_PREFIX    := env -u VIRTUAL_ENV -u PYTHONHOME
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
export PYTHON_BIN       := $(shell cocotb-config --python-bin)

export PYTHONPATH := $(PWD):$(PYTHONPATH)

# Icarus needs SystemVerilog turned on explicitly.
COMPILE_ARGS += -g2012

# make WAVES=1  -> dump.fst
ifeq ($(WAVES),1)
    PLUSARGS += -fst
endif

ifdef TESTCASE
export TESTCASE
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
