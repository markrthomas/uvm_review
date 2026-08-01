# cocotb runner for the low-power (UPF-emulated) APB memory demo.
# Invoked by the repo-root Makefile via `make lp`. Dump waves with WAVES=1.

TOPLEVEL_LANG = verilog
SIM          ?= icarus

VERILOG_SOURCES = $(PWD)/apb_mem_array.sv $(PWD)/apb_mem_lp.sv
TOPLEVEL        = apb_mem_lp
MODULE          = test_lp

# Pin the apt Icarus + the cocotb-bound interpreter (same rationale as tb/).
ICARUS_BIN_DIR    ?= /usr/bin
export ICARUS_BIN_DIR
SIM_CMD_PREFIX    := env -u VIRTUAL_ENV -u PYTHONHOME
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
export PYTHON_BIN       := $(shell cocotb-config --python-bin)

export PYTHONPATH := $(PWD):$(PYTHONPATH)

# SystemVerilog on; LP_EMULATE turns on the pure-Verilog stand-in for UPF
# corruption/isolation/retention. A real IEEE-1801 flow drops this define and
# passes apb_mem.upf to a UPF-aware tool instead.
COMPILE_ARGS += -g2012 -DLP_EMULATE

ifeq ($(WAVES),1)
    PLUSARGS += -fst
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
