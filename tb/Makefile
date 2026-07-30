# cocotb / pyuvm runner for apb_mem (invoked by the repo-root Makefile).
# Select a single test with TESTCASE=<name>; dump waves with WAVES=1.

TOPLEVEL_LANG = verilog
SIM          ?= icarus

VERILOG_SOURCES = $(PWD)/../rtl/apb_mem.sv
TOPLEVEL        = apb_mem
MODULE          = apb_test

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
