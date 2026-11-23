# Enhancement plan

Verification/infra enhancements for `axi_apb_mem`, from a full repo review on
2026-11-23. Ordered by dependency and value: reproducibility and coverage
scope first (so later work is measurable), then assertions, then the larger
structural and formal items.

> This is a human-readable roadmap, **not** the swarm plan. It is intentionally
> *not* `docs/SWARM_PLAN.md`, so pushing it never triggers `plan-swarm.yml`.

Each item lands as its own focused PR (branch → CI → merge), ticking its box
here as part of that PR.

## Order of work

- [x] **1. Seed reproducibility.** Expose `SEED=` in the cocotb flow
  (`COCOTB_RANDOM_SEED` passthrough in `tb/Makefile`, surfaced by the root
  `waves`/`test-*` targets) so a random run or a random default waveform can be
  replayed deterministically. Document `make waves SEED=…`.

- [x] **2. Coverage covers the AXI bridge + wrapper.** `make coverage` today
  builds only `rtl/apb_mem.sv` (`--top-module apb_mem`) and enforces a 100%
  floor on the trivial memory core, leaving `axi_lite_to_apb.sv` and
  `axi_apb_mem.sv` (the FSM, CDC handshake and arbiter) unmeasured. Extend the
  Verilator coverage harness to drive `axi_apb_mem` at the top so the floor
  means something for the complex logic.

- [x] **3. RTL parameter guard.** The RTL is correct only for `DATA_WIDTH=8`
  (the AXI front end collapses `WSTRB` to a single write-enable, so partial
  multi-byte writes would be wrong). Add an elaboration-time guard / assertion
  (or document the fixed width) so the nominal parameterization can't be
  misused silently. No behaviour change for the supported config.

- [x] **4. AXI4-Lite SVA checker.** Add `axi_sva.sv` bound to
  `axi_lite_to_apb` (mirroring `apb_sva.sv`): VALID stable until READY on every
  channel, no handshake drop, single-outstanding `BVALID`/`RVALID` exclusivity,
  legal `BRESP`/`RRESP`, no-X on active channels, plus cover points for AW/W
  skew and `WSTRB=0`. Scoped to the UVM/Verilator flow (Icarus SVA is weak).

- [x] **5. Testbench refactor.** Factor the ~95% duplicated
  `apb_components.py` / `axi_components.py` onto a shared base
  (scoreboard / agent / env), route the dual-bus tests through a real shared
  scoreboard instead of ad-hoc asserts, drop the redundant scoreboard
  double-drain, and document the monitor's single-outstanding addr/data
  association.

- [x] **6. Error-path (SLVERR) coverage.** The OKAY→SLVERR mapping in the AXI
  front end is currently dead/untested (the memory never errors). Add a
  fault-injecting memory variant (same pattern as `lp/`) and a test that
  exercises `PSLVERR`→`BRESP/RRESP = SLVERR`.

- [x] **7. Formal tier.** Replace the `make formal` stub with a SymbiYosys
  flow proving the properties currently only reasoned in comments: the
  single-outstanding CDC handshake (no lost/duplicated request), arbiter mutual
  exclusion (APB priority, non-preemptive AXI grant), and deadlock-freedom.

- [x] **8. Real stress / soak.** `make stress` is currently just
  `test-random`. Build the scaffolded random-regression flow
  (`tb/random/`, `RR_STATUS=bootstrap`, the `rr-bootstrap` skill) to give a
  genuine seeded soak target with replayable failures.
