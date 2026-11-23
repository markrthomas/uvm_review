# Random regression (`tb/random/`)

The seeded random-regression flow for `axi_apb_mem` — Swarm B's entry point.
It adds **no new checker**: every job runs one of the existing self-checking
PyUVM/cocotb random tests, whose scoreboard (APB/AXI) or shared `RefMemModel`
(cross-bus) already scores every read against a byte reference model. The flow
only sweeps seeds and clusters failures.

Per-seed determinism comes from cocotb's `RANDOM_SEED` (the same `SEED=` knob
the top-level Makefile exposes): running a seed twice gives an identical run, so
any failing job replays exactly.

## Targets

| Target | What it does |
|--------|--------------|
| `make rr-build` | Compile the cocotb sim once (the canonical build the jobs reuse). |
| `make rr N=<jobs> JOBS=<parallel> [SEED=<base>]` | Run `N` jobs with seeds `SEED+i` (`JOBS` in parallel). Writes `runs/<UTC>/results.jsonl` (one JSON line per job), prints `rr run: <dir> seed_base=<s> jobs=<N> fail=<F>`, exits non-zero iff `F>0`. `SEED` unset → a random base (logged). |
| `make rr-triage RUN=<dir>` | Cluster the FAILs in `<dir>/results.jsonl` by signature; one line per cluster with count + a repro. |
| `make rr-replay` | Rerun every `corpus.json` entry; entries marked `"fixed": true` **must PASS** (the regression gate). |

`results.jsonl` line schema:
`{"job", "seed", "config", "status", "signature", "log", "repro"}`.

`runs/` is git-ignored. `corpus.json` is the tracked replay corpus.

## Knobs (the `config` field)

Each job picks one knob set by seed index; all three are already self-checking
and randomise only what their scoreboard checks (address, data, read/write mix,
AW/W ordering):

| `config` | test | repro |
|----------|------|-------|
| `apb_random`  | `random_test`          | `make test-random SEED=<s>` |
| `axi_random`  | `axi_random_test`      | `make test-axi-random SEED=<s>` |
| `dual_random` | `dual_bus_random_test` | `make test-dual-bus-random SEED=<s>` |

## Corpus

`corpus.json` is a list of `{seed, config, fixed, note}`. `fixed: true` means
"this scenario must pass" — a regression anchor, or the repro of a bug that was
found and fixed. `make rr-replay` gates on those. When the loop finds a real
bug, add its repro seed here (`fixed: false` until fixed, then flip to `true`).

## Stimulus backlog

The random tests today cover the core read/write datapath. Planned additions,
each driven through the existing scoreboard (never a weaker checker):

- **B1** — randomised inter-transfer gaps (idle cycles) on both buses.
- **B2** — AXI write-channel back-pressure: randomise `BREADY`/`RREADY` delays.
- **B3** — randomised AW/W skew depth (currently only 0/1-beat skew is directed).
- **B4** — concurrent cross-bus traffic with randomised arbitration pressure
  (APB and AXI requests overlapping, to stress the PCLK arbiter + CDC).
- **B5** — `WSTRB=0` no-op writes mixed into the AXI random stream.
- **B6** — reset injected mid-stream (assert `PRESETn`/`ARESETn` at a random
  point) and check clean recovery.

## Status

`RR_STATUS=bootstrap` in `.claude/swarm.env` until this flow lands; then
**set `RR_STATUS=present`** (that file is protected from automated edits).
