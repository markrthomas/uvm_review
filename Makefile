# =============================================================================
# axi_apb_mem — shared AXI4-Lite/APB3 byte-memory: lint + PyUVM/cocotb regression.
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
RTL_ALL   := rtl/apb_mem.sv rtl/axi_lite_to_apb.sv rtl/axi_apb_mem.sv
# AXI4-Lite protocol assertion checker, bound to axi_lite_to_apb and exercised
# (with --assert) in the Verilator coverage sim. coverage_off internally so it
# does not count toward the line-coverage floor.
AXI_SVA   := uvm/axi_sva.sv
TB_DIR    := tb
TB_RESULTS := $(TB_DIR)/results.xml
FST       := $(TB_DIR)/sim_build/axi_apb_mem.fst
GTKW      := $(TB_DIR)/dual_bus.gtkw
GTKW_APB  := $(TB_DIR)/apb_bus.gtkw
GTKW_AXI  := $(TB_DIR)/axi_bus.gtkw
GTKW_DUAL := $(TB_DIR)/dual_bus.gtkw
UVM_DIR   := uvm
LP_DIR    := lp
LP_RESULTS := $(LP_DIR)/results.xml

# Docker / Railway: license-free UVM on Verilator in a container (see below).
DOCKER         ?= docker
RAILWAY        ?= railway
RAILWAY_PROJECT ?= verilator-uvm
RAILWAY_SERVICE ?= verilator-uvm
RAILWAY_ENVIRONMENT ?= production
UVM_IMAGE      ?= apb-mem-uvm:latest
UVM_DOCKERFILE := Dockerfile
RAILWAY_WATCH  := docker/railway-watch.sh

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
	test-axi-write-read test-axi-random test-axi-walking test-axi-protocol test-dual-bus test-dual-bus-random \
	waves waves-apb waves-axi waves-dual wave wave-apb wave-axi wave-dual \
	check regress ci coverage uvm lp \
	docker-uvm-build docker-uvm-run railway-config railway-deploy railway-logs railway-run check-docker \
	lint _lint_iverilog _lint_verilator \
	clean

default: help

help:
	@echo "apb_mem / axi_apb_mem — common targets"
	@echo ""
	@echo "  Tests (PyUVM / cocotb):"
	@echo "    make test              # same as test-all (APB, AXI, protocol, and dual-bus tests)"
	@echo "    make test-all"
	@echo "    make test-write-read   # APB write-then-read-back sequence"
	@echo "    make test-random       # APB constrained-random read/write mix"
	@echo "    make test-walking      # APB directed address/data edge cases"
	@echo "    make test-axi-write-read # AXI write-then-read-back sequence"
	@echo "    make test-axi-random   # AXI constrained-random read/write mix"
	@echo "    make test-axi-walking  # AXI directed address/data edge cases"
	@echo "    make test-axi-protocol # AXI AW/W skew + WSTRB no-op behavior"
	@echo "    make test-dual-bus     # cross-bus concurrent test (APB WR -> AXI RD, AXI WR -> APB RD)"
	@echo "    make test-dual-bus-random # cross-bus random read/write mix (>=20 transfers, both R&W, ref-model checked)"
	@echo ""
	@echo "  Waveform viewing (GTKWave with curated bus layouts):"
	@echo "    make wave              # open dump in GTKWave (default: BUS=dual -> dual_bus_random_test; override BUS=apb|axi|dual or TEST=<name>)"
	@echo "    make wave-apb          # open GTKWave with dedicated APB bus view (tb/apb_bus.gtkw)"
	@echo "    make wave-axi          # open GTKWave with dedicated AXI bus view (tb/axi_bus.gtkw)"
	@echo "    make wave-dual         # open GTKWave with dual AXI + APB bus view (tb/dual_bus.gtkw)"
	@echo "    make waves             # dump FST trace only (default: dual_bus_random_test; TEST=<name>, BUS=apb|axi|dual)"
	@echo "    SEED=<n>               # pin cocotb's RANDOM_SEED on any test/wave target to replay a random run (e.g. make waves SEED=12345)"
	@echo "    make waves-apb         # dump APB trace only"
	@echo "    make waves-axi         # dump AXI trace only"
	@echo "    make waves-dual        # dump dual-bus trace only"
	@echo ""
	@echo "  SystemVerilog UVM (license-gated; skips cleanly if no simulator):"
	@echo "    make uvm               # run the SV/UVM TB under uvm/ (VCS/Xcelium/Questa)"
	@echo ""
	@echo "  Low-power / UPF:"
	@echo "    make lp                # UPF-emulated power-cycle test (isolation/retention/corruption)"
	@echo ""
	@echo "  Docker / Railway (license-free UVM-on-Verilator in a container):"
	@echo "    make docker-uvm-build            # build the UVM image (Verilator 5.050 from source)"
	@echo "    make docker-uvm-run              # build + run the full UVM gate locally"
	@echo "    make railway-config              # apply .railway/railway.ts project settings"
	@echo "    make railway-run                 # ONE-SHOT: link + apply settings + deploy + wait for PASS/FAIL"
	@echo "    make railway-deploy              # apply settings + deploy (needs: railway login)"
	@echo "    make railway-logs                # tail the Railway deployment logs"
	@echo "    make check-docker                # offline plumbing tests (no Docker build, no network)"
	@echo "    RAILWAY_PROJECT=verilator-uvm RAILWAY_SERVICE=verilator-uvm"
	@echo "    UVM_IMAGE=name:tag  DOCKER=podman  RAILWAY=railway"
	@echo ""
	@echo "  Gates:"
	@echo "    make lint              # iverilog -Wall compile check + Verilator RTL lint"
	@echo "    make coverage          # Verilator C++ coverage -> sim/coverage.info (fails below COV_MIN=$(COV_MIN)% lines)"
	@echo "    make formal            # formal tier (n/a stub if none)"
	@echo "    make stress            # stress / randomized simulation (n/a stub if none)"
	@echo "    make check             # lint then test-all"
	@echo "    make regress           # lint + full regression (CI-style pass/fail)"
	@echo "    make ci                # regress + coverage"
	@echo ""
	@echo "  Other: make clean"
	@echo "  swarm      Swarm A (verification) via Claude Code; swarm-rr = Swarm B (random regression); swarm-dry = show the command"
	@echo "  batch      the Railway batch (docker/entrypoint.sh ci); board = swarm status; heavy T=<t> = one heavy target at a time"
	@echo "  swarm-profile / swarm-kit-check   print .claude/swarm.env / check kit drift (shared kit: markrthomas/dv-swarm-kit)"

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
@$(MAKE) -C $(TB_DIR) TESTCASE=$(1) $(if $(SEED),SEED=$(SEED),)
@test -f $(TB_RESULTS) || { echo "[TEST] $(1): no results.xml (sim did not run)"; exit 1; }
@if grep -Eq "<failure|<error" $(TB_RESULTS); then echo "[TEST] $(1) FAILED (see log above)"; exit 1; fi
@echo "[TEST] $(1) passed"
endef

test: test-all

test-all:
	$(call run_one_test,write_read_test)
	$(call run_one_test,random_test)
	$(call run_one_test,walking_test)
	$(call run_one_test,axi_write_read_test)
	$(call run_one_test,axi_random_test)
	$(call run_one_test,axi_walking_test)
	$(call run_one_test,axi_channel_skew_and_strobe_test)
	$(call run_one_test,dual_bus_test)
	$(call run_one_test,dual_bus_random_test)
	@echo "[TEST] all PyUVM tests (APB + AXI + dual-bus) passed"

test-write-read:
	$(call run_one_test,write_read_test)

test-random:
	$(call run_one_test,random_test)

test-walking:
	$(call run_one_test,walking_test)

test-axi-write-read:
	$(call run_one_test,axi_write_read_test)

test-axi-random:
	$(call run_one_test,axi_random_test)

test-axi-walking:
	$(call run_one_test,axi_walking_test)

test-axi-protocol:
	$(call run_one_test,axi_channel_skew_and_strobe_test)

test-dual-bus:
	$(call run_one_test,dual_bus_test)

test-dual-bus-random:
	$(call run_one_test,dual_bus_random_test)

# Waveform dump. Supports BUS=apb | BUS=axi | BUS=dual (default: dual).
# TEST=<name> overrides the testcase dumped.
WAVE_TESTS := write_read_test random_test walking_test axi_write_read_test axi_random_test axi_walking_test axi_channel_skew_and_strobe_test dual_bus_test dual_bus_random_test

BUS ?= dual
ifeq ($(BUS),apb)
  DEFAULT_WAVE_TEST := random_test
  GTKW_SEL := $(GTKW_APB)
else ifeq ($(BUS),axi)
  DEFAULT_WAVE_TEST := axi_random_test
  GTKW_SEL := $(GTKW_AXI)
else
  DEFAULT_WAVE_TEST := dual_bus_random_test
  GTKW_SEL := $(GTKW_DUAL)
endif

WAVE_TEST := $(if $(TEST),$(TEST),$(DEFAULT_WAVE_TEST))

waves:
	@if [ "$(WAVE_TEST)" != "all" ] && ! echo " $(WAVE_TESTS) " | grep -q " $(WAVE_TEST) "; then \
		echo "[WAVES] unknown TEST='$(WAVE_TEST)' — choose one of: $(WAVE_TESTS) all"; exit 1; fi
	rm -rf $(TB_DIR)/sim_build
	$(MAKE) -C $(TB_DIR) WAVES=1 $(if $(filter all,$(WAVE_TEST)),,TESTCASE=$(WAVE_TEST)) $(if $(SEED),SEED=$(SEED),)
	@echo "[WAVES] wrote $(FST) (test: $(WAVE_TEST)$(if $(SEED), seed: $(SEED),))"

waves-apb:
	@$(MAKE) --no-print-directory waves BUS=apb $(if $(TEST),TEST=$(TEST),)

waves-axi:
	@$(MAKE) --no-print-directory waves BUS=axi $(if $(TEST),TEST=$(TEST),)

waves-dual:
	@$(MAKE) --no-print-directory waves BUS=dual $(if $(TEST),TEST=$(TEST),)

wave:
	@if ! command -v gtkwave >/dev/null 2>&1; then \
		echo "[WAVE] gtkwave not on PATH — install GTKWave to view waveforms"; \
		exit 0; \
	fi; \
	$(MAKE) --no-print-directory waves BUS=$(BUS) $(if $(TEST),TEST=$(TEST),) $(if $(SEED),SEED=$(SEED),); \
	echo "[WAVE] opening $(FST) in GTKWave (layout: $(GTKW_SEL)) — test: $(WAVE_TEST)$(if $(SEED), seed: $(SEED),)"; \
	exec gtkwave -S $(TB_DIR)/zoom_full.tcl $(FST) $(GTKW_SEL)

wave-apb:
	@$(MAKE) wave BUS=apb $(if $(TEST),TEST=$(TEST),)

wave-axi:
	@$(MAKE) wave BUS=axi $(if $(TEST),TEST=$(TEST),)

wave-dual:
	@$(MAKE) wave BUS=dual $(if $(TEST),TEST=$(TEST),)

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

# --- Docker / Railway: license-free UVM on Verilator in a container ----------
# Builds an image with UVM-capable Verilator 5.050 + the bundled UVM library
# (root Dockerfile) whose entrypoint runs the full UVM gate (make -C uvm/vlt ci).
# Useful where the local host lacks the RAM for the --binary build: run it on
# Railway (or any container host) instead. See uvm/vlt/README.md.

docker-uvm-build:
	@command -v $(DOCKER) >/dev/null 2>&1 || { echo "[DOCKER] '$(DOCKER)' not found; install Docker or Podman (or set DOCKER=)"; exit 127; }
	$(DOCKER) build -f $(UVM_DOCKERFILE) -t $(UVM_IMAGE) .

# NOTE: the --binary build is RAM-heavy; on a small (~8 GB) host this can OOM.
# The point of this path is to run it on a RAM-generous host (Railway).
docker-uvm-run: docker-uvm-build
	$(DOCKER) run --rm $(UVM_IMAGE)

railway-config:
	@command -v $(RAILWAY) >/dev/null 2>&1 || { echo "[RAILWAY] '$(RAILWAY)' CLI not found: https://docs.railway.com/guides/cli"; exit 127; }
	@test -d node_modules/railway || { echo "[RAILWAY] Railway IaC SDK is missing; run 'npm install' first."; exit 127; }
	@echo "[RAILWAY] Applying $(RAILWAY_PROJECT)/$(RAILWAY_SERVICE) settings from .railway/railway.ts..."
	@# Railway's TypeScript evaluator interprets Make's exported $_ as its CLI path.
	env -u _ $(RAILWAY) config apply --yes

railway-deploy: railway-config
	@echo "[RAILWAY] Deploying $(UVM_DOCKERFILE) to $(RAILWAY_PROJECT)/$(RAILWAY_SERVICE)..."
	$(RAILWAY) up --service $(RAILWAY_SERVICE) --environment $(RAILWAY_ENVIRONMENT)

railway-logs:
	@command -v $(RAILWAY) >/dev/null 2>&1 || { echo "[RAILWAY] '$(RAILWAY)' CLI not found: https://docs.railway.com/guides/cli"; exit 127; }
	$(RAILWAY) logs --service $(RAILWAY_SERVICE) --environment $(RAILWAY_ENVIRONMENT)

# One command, end to end: authenticate, link the named project/service, apply
# IaC, upload/build the image, and watch the UVM gate to completion. BUILD_JOBS=1
# is baked into the image, so no variables need setting; the ~8 GB RAM floor is a
# one-time dashboard setting (the service's Settings -> Resource Limits) — see
# uvm/vlt/README.md. A green run ends with a `PASS:` line and the container exits
# 0 (Railway: "Completed").
railway-run:
	@command -v $(RAILWAY) >/dev/null 2>&1 || { echo "[RAILWAY] '$(RAILWAY)' CLI not found: https://docs.railway.com/guides/cli"; exit 127; }
	@$(RAILWAY) whoami   >/dev/null 2>&1 || $(RAILWAY) login
	@$(RAILWAY) link --project $(RAILWAY_PROJECT) --service $(RAILWAY_SERVICE) --environment $(RAILWAY_ENVIRONMENT)
	@$(MAKE) railway-config RAILWAY='$(RAILWAY)' RAILWAY_PROJECT='$(RAILWAY_PROJECT)' RAILWAY_SERVICE='$(RAILWAY_SERVICE)' RAILWAY_ENVIRONMENT='$(RAILWAY_ENVIRONMENT)'
	@echo "[RAILWAY] Uploading + building $(UVM_DOCKERFILE), then running the UVM gate (build logs at the URL below)..."
	$(RAILWAY) up --detach --service $(RAILWAY_SERVICE) --environment $(RAILWAY_ENVIRONMENT)
	@echo "[RAILWAY] Deploy queued; watching for completion — returns to your prompt with PASS/FAIL when the run ends."
	@RAILWAY='$(RAILWAY)' bash $(RAILWAY_WATCH)

# Offline tests for the Docker/Railway plumbing (no Docker build, no network):
# script syntax, railway-watch classifier self-test, entrypoint dispatch/preflight
# with a mocked make, and a railway-run parse check.  Run in CI (docker-plumbing.yml).
check-docker:
	bash docker/plumbing-test.sh

# --- gates -------------------------------------------------------------------

lint: _lint_iverilog _lint_verilator

_lint_iverilog:
	@echo "[LINT] iverilog -Wall compile check (AXI + APB subsystem)..."
	$(IVERILOG) $(IVERILOG_FLAGS) -s axi_apb_mem -o /dev/null $(RTL_ALL)

_lint_verilator:
	@if command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[LINT] Verilator RTL lint (AXI + APB subsystem)..."; \
		$(VERILATOR) $(VERILATOR_LINT_FLAGS) --top-module axi_apb_mem $(RTL_ALL); \
	else \
		echo "[LINT] verilator not on PATH — skipping RTL lint"; \
	fi

check: lint test-all

regress: lint test-all lp
	@echo "[REGRESS] lint + PyUVM regression + low-power (UPF) demo PASSED"

ci: regress coverage
	@echo "[CI] lint + regression + coverage PASSED"

# coverage: Verilator --coverage-line build of the FULL axi_apb_mem subsystem
# (memory core + AXI4-Lite front end + arbiter/CDC) + run of the
# sim/sim_main.cpp harness; emits sim/coverage.info (lcov) and enforces the
# COV_MIN line-coverage floor. --coverage-line (not --coverage) keeps the metric
# true line coverage: plain --coverage also flattens per-bit toggle points into
# the lcov DA records, which would impose an unachievable 100%-toggle floor on
# the tied-off AXI PROT inputs and the never-asserted SLVERR path.
# Degrades gracefully (exit 0) when Verilator is not installed.
coverage:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[COVERAGE] verilator not on PATH; skipping"; exit 0; }; \
	rm -rf $(COV_DIR); \
	$(VERILATOR) --coverage-line --assert -cc $(RTL_ALL) $(AXI_SVA) --top-module axi_apb_mem \
		--Mdir $(COV_DIR) -Wall -Wno-DECLFILENAME -Wno-UNOPTFLAT; \
	$(MAKE) -C $(COV_DIR) -f Vaxi_apb_mem.mk; \
	g++ -DVM_COVERAGE=1 -o $(COV_DIR)/sim_cov \
		sim/sim_main.cpp $(COV_DIR)/Vaxi_apb_mem__ALL.a \
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

# Standard DV targets (DV_STANDARDS.md)
.PHONY: stress formal
stress: test-random
formal:
	@echo "[FORMAL] n/a: no formal tier in this repo yet (see DV_STANDARDS.md)"

# Standard DV target (DV_STANDARDS.md)
.PHONY: sim
sim: test

# shared swarm/infra targets (markrthomas/dv-swarm-kit)
include swarm.mk
