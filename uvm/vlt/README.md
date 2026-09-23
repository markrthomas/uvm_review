# UVM on open-source Verilator (`uvm/vlt`)

Runs the same UVM environment as a commercial simulator, but under open-source
**Verilator 5.050** (the first Verilator that can elaborate/run UVM) with the
Accellera UVM 2020.3.1 library bundled in the Verilator source tree
(`test_regress/t/uvm`). License-free CI path; the repo's `make uvm` (pyuvm)
otherwise self-skips without a licensed UVM simulator.

## Prerequisites
- **Verilator >= 5.050, UVM-capable** (the OSS CAD Suite one is not). Local
  reference: `~/verilator/bin/verilator`.
- **`unset VERILATOR_ROOT`** after sourcing the OSS CAD Suite env (a stale value
  makes `~/verilator` hard-error).
- **`UVM_HOME`** = `~/verilator/test_regress/t/uvm`.
- **In an OSS-off shell** (`OSS_CAD=0` at start, or `oss-cad-off`) `~/.bashrc`
  already puts Verilator 5.050 on `PATH`, unsets `VERILATOR_ROOT`, and exports
  `UVM_HOME` — so the explicit `VERILATOR=`/`UVM_HOME=` and `unset` below are
  optional there.

## Usage
```sh
V=~/verilator/bin/verilator ; U=~/verilator/test_regress/t/uvm
( unset VERILATOR_ROOT; make -C uvm/vlt lint     VERILATOR=$V UVM_HOME=$U )  # RAM-safe (~290 MB)
( unset VERILATOR_ROOT; make -C uvm/vlt random   VERILATOR=$V UVM_HOME=$U )  # build + run
```
Targets: `lint`; `random` (default), `write_read`, `walking`, `all`; `ci`;
`clean`. One `--binary` build serves all three tests (selected via
`+UVM_TESTNAME`). `ci` is the containerized gate — lint + one build + every top,
failing on any `UVM_ERROR`/`UVM_FATAL` (read from the report summary, since the
`--binary` exe exits 0 regardless).

## RAM note — build in CI, not on a small box
`--lint-only` is cheap (~290 MB). The full `--binary` build (large generated
C++) OOMs a RAM-constrained host. Run it in CI
(`.github/workflows/verilator-uvm.yml` builds Verilator 5.050 from source and
runs lint + `write_read` on a GitHub runner), or locally only with
`BUILD_JOBS=1` under a `ulimit -v` guard.

## Container / Railway (off-box, RAM-generous host)
The repo root ships a license-free UVM image (`Dockerfile`) whose entrypoint runs
`make -C uvm/vlt ci`. Use it where the local host lacks the RAM for the
`--binary` build:
```sh
make docker-uvm-build      # build the image (Verilator 5.050 from source)
make docker-uvm-run        # build + run the full UVM gate locally
make railway-config        # apply the batch-service settings in .railway/railway.ts
make railway-run           # one-shot: link verilator-uvm + apply settings + deploy + wait
make check-docker          # offline plumbing tests (no Docker build, no network)
```
`docker/entrypoint.sh` runs a **resource preflight** before the heavy build and
aborts (exit 3) below a **6144 MB** floor — the UVM precompiled-header compile
OOM-kills `cc1plus` under it. On Railway, raise the service's memory to ~8 GB
(Settings → Resource Limits); the service is a run-to-completion **batch job**
(`restartPolicyType: NEVER` in `.railway/railway.ts`), not an always-on service.
`BUILD_JOBS=1` is baked into the image (each PCH compile needs several GB).

The checked-in Railway configuration targets project and service
`verilator-uvm` in the `production` environment. `make railway-run` re-links
those exact names before applying the configuration, so it cannot deploy to an
unrelated locally linked project. Run `npm install` once to install the Railway
IaC SDK used by `railway config apply`.

For Railway-managed deployments, grant the Railway GitHub App access to
`markrthomas/uvm_review` in GitHub, then connect the service to the `main`
branch in **Railway → verilator-uvm → verilator-uvm → Settings → Source**.
Pushes to `main` will then deploy automatically; use `make railway-run` for a
local-source one-shot run.

## `uvm_macros.svh`
A required, tracked empty include-shim: the sources `` `include "uvm_macros.svh" ``
and the monolithic UVM header (first on the command line) already defines the
macros. Do not delete.
