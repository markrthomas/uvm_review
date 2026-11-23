#!/usr/bin/env python3
"""Random-regression driver for axi_apb_mem (Swarm B bootstrap flow).

Drives the existing self-checking PyUVM/cocotb random tests across a sweep of
seeds -- it adds NO new checker: every job runs a test whose scoreboard (or the
shared RefMemModel in the cross-bus test) already scores reads against a byte
reference model. Randomisation is per-seed deterministic via cocotb's
RANDOM_SEED (the same SEED= knob the Makefile exposes), so any failing job
replays exactly.

Subcommands (driven by the Makefile; keep the names -- rr-manager/runner/triage
rely on them):
  build                 compile the sim once (the canonical cocotb build)
  run --n N --jobs J [--seed S]
                        run N jobs with seeds S+i (J in parallel); write
                        runs/<UTC>/results.jsonl + a summary; exit != 0 iff any FAIL
  triage --run DIR      cluster the FAILs in DIR/results.jsonl by signature
  replay                rerun every corpus.json entry; "fixed": true must PASS

results.jsonl is one JSON object per line:
  {"job","seed","config","status","signature","log","repro"}
"""

import argparse
import concurrent.futures
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

RR_DIR = Path(__file__).resolve().parent          # tb/random
REPO = RR_DIR.parents[1]                           # repo root
TB = REPO / "tb"
CANONICAL_BUILD = TB / "sim_build"                 # DUT=axi_apb_mem default build
CORPUS = RR_DIR / "corpus.json"
RUNS = RR_DIR / "runs"

# Knob sets: each job picks one by (seed index % len). Every test is already
# self-checking; the repro uses the Makefile SEED= knob so a human can rerun it.
CONFIGS = [
    ("apb_random",  "random_test",          "make test-random SEED={seed}"),
    ("axi_random",  "axi_random_test",      "make test-axi-random SEED={seed}"),
    ("dual_random", "dual_bus_random_test", "make test-dual-bus-random SEED={seed}"),
]
CONFIG_BY_NAME = {c[0]: c for c in CONFIGS}


def _run_make(testcase, seed, sim_build, results_file, log_file):
    """Run one cocotb test with a pinned seed; return (status, signature)."""
    env = dict(os.environ)
    env["RANDOM_SEED"] = str(seed)
    env["COCOTB_RESULTS_FILE"] = str(results_file)
    cmd = ["make", "-C", "tb", f"TESTCASE={testcase}",
           f"SIM_BUILD={sim_build}", f"RANDOM_SEED={seed}",
           f"COCOTB_RESULTS_FILE={results_file}"]
    with open(log_file, "w") as fh:
        proc = subprocess.run(cmd, cwd=REPO, env=env, stdout=fh,
                              stderr=subprocess.STDOUT)
    status, signature = _parse_result(results_file, log_file)
    # A nonzero make with no parsed failure is itself a failure (build/infra).
    if status == "PASS" and proc.returncode != 0:
        status, signature = "FAIL", "make-returncode-nonzero"
    return status, signature


def _parse_result(results_file, log_file):
    """Return (status, signature) from the cocotb junit XML + log."""
    rf = Path(results_file)
    if not rf.exists():
        return "FAIL", "no-results-xml"
    try:
        root = ET.parse(rf).getroot()
    except ET.ParseError:
        return "FAIL", "unparsable-results-xml"
    failed = False
    raw = ""
    for tc in root.iter("testcase"):
        for tag in ("failure", "error"):
            el = tc.find(tag)
            if el is not None:
                failed = True
                raw = (el.get("message") or el.text or tag)
                break
        if failed:
            break
    if not failed:
        return "PASS", ""
    return "FAIL", _signature(raw, log_file)


# The cocotb junit message is a generic "Test failed with RANDOM_SEED=N", which
# would collapse every failure into one cluster. The actual failing check is in
# the log, so prefer it: the first line mentioning one of these, keyword onward.
_SIG_KEYWORDS = ("MISMATCH", "AssertionError", "Assertion failed",
                 "FATAL", "Timeout", "TimeoutError", "Error:")


def _signature(raw, log_file):
    """Normalise a failure into a stable cluster key (addresses/values stripped).

    Pulls the real failing check from the log (e.g. a scoreboard MISMATCH or an
    AssertionError) rather than cocotb's generic junit wrapper message.
    """
    line = ""
    p = Path(log_file)
    if p.exists():
        text = p.read_text(errors="replace")
        best = None
        for kw in _SIG_KEYWORDS:
            idx = text.find(kw)
            if idx != -1 and (best is None or idx < best[0]):
                end = text.find("\n", idx)
                best = (idx, text[idx:end if end != -1 else len(text)].strip())
        if best:
            line = best[1]
    if not line:
        line = (raw or "").strip().splitlines()[0] if raw else ""
    line = re.sub(r"0x[0-9A-Fa-f]+", "0x#", line)
    line = re.sub(r"\b\d+\b", "#", line)
    line = re.sub(r"\s+", " ", line).strip()
    return line[:120] or "unknown-failure"


def _build(sim_build):
    """Ensure the canonical cocotb sim is built at sim_build."""
    print(f"[rr-build] compiling cocotb sim at tb/{Path(sim_build).name} ...")
    r = subprocess.run(["make", "-C", "tb", f"SIM_BUILD={sim_build}",
                        "TESTCASE=random_test",
                        f"COCOTB_RESULTS_FILE={RR_DIR / 'build-smoke.xml'}"],
                       cwd=REPO)
    (RR_DIR / "build-smoke.xml").unlink(missing_ok=True)
    if r.returncode != 0:
        sys.exit("[rr-build] FAILED: cocotb build did not complete")
    print("[rr-build] ok")


def _prep_job_build(dst):
    """Give a job its own build dir, reusing the canonical one when present."""
    dst = Path(dst)
    if dst.exists():
        shutil.rmtree(dst)
    if (CANONICAL_BUILD / "sim.vvp").exists():
        shutil.copytree(CANONICAL_BUILD, dst)   # copy2 preserves mtime -> no rebuild
    else:
        dst.mkdir(parents=True, exist_ok=True)


def cmd_build(_args):
    _build("sim_build")


def _execute_jobs(jobs, run_dir, parallel):
    """jobs: list of (job_idx, seed, config_name). Returns list of result dicts."""
    results = [None] * len(jobs)

    def work(k):
        job_idx, seed, cfg_name = jobs[k]
        _name, testcase, repro_fmt = CONFIG_BY_NAME[cfg_name]
        sim_build = run_dir / f"sim_{seed}_{cfg_name}"
        _prep_job_build(sim_build)
        log_file = run_dir / f"job_{job_idx:04d}_{seed}.log"
        results_file = run_dir / f"job_{job_idx:04d}_{seed}.xml"
        status, signature = _run_make(testcase, seed, sim_build,
                                      results_file, log_file)
        shutil.rmtree(sim_build, ignore_errors=True)
        rel_log = os.path.relpath(log_file, REPO)
        return {"job": job_idx, "seed": seed, "config": cfg_name,
                "status": status, "signature": signature,
                "log": rel_log, "repro": repro_fmt.format(seed=seed)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, parallel)) as ex:
        for k, res in zip(range(len(jobs)),
                          ex.map(work, range(len(jobs)))):
            results[k] = res
    return results


def cmd_run(args):
    seed_base = args.seed if args.seed is not None else \
        int.from_bytes(os.urandom(3), "big")
    _build("sim_build")  # make sure the canonical build is fresh
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = RUNS / ts
    run_dir.mkdir(parents=True, exist_ok=True)

    jobs = [(i, seed_base + i, CONFIGS[i % len(CONFIGS)][0]) for i in range(args.n)]
    results = _execute_jobs(jobs, run_dir, args.jobs)

    with open(run_dir / "results.jsonl", "w") as fh:
        for r in results:
            fh.write(json.dumps(r) + "\n")
    fails = sum(1 for r in results if r["status"] != "PASS")
    rel = os.path.relpath(run_dir, REPO)
    for r in results:
        if r["status"] != "PASS":
            print(f"  FAIL job={r['job']} seed={r['seed']} cfg={r['config']} "
                  f"sig='{r['signature']}' repro: {r['repro']}")
    print(f"rr run: {rel} seed_base={seed_base} jobs={args.n} fail={fails}")
    sys.exit(1 if fails else 0)


def cmd_triage(args):
    rf = Path(args.run) / "results.jsonl" if Path(args.run).is_dir() else Path(args.run)
    if not rf.exists():
        sys.exit(f"[rr-triage] no results.jsonl at {rf}")
    clusters = {}
    for line in rf.read_text().splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        if r["status"] == "PASS":
            continue
        clusters.setdefault(r["signature"], []).append(r)
    if not clusters:
        print(f"rr triage: {rf.parent} clusters=0 (no failures)")
        return
    print(f"rr triage: {rf.parent} clusters={len(clusters)}")
    for sig, rows in sorted(clusters.items(), key=lambda kv: -len(kv[1])):
        ex = rows[0]
        print(f"  [{len(rows):3d}] {sig}  e.g. seed={ex['seed']} "
              f"cfg={ex['config']}  repro: {ex['repro']}")


def cmd_replay(_args):
    if not CORPUS.exists():
        sys.exit(f"[rr-replay] no corpus at {CORPUS}")
    entries = json.loads(CORPUS.read_text())
    _build("sim_build")
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = RUNS / f"replay-{ts}"
    run_dir.mkdir(parents=True, exist_ok=True)

    jobs = [(i, e["seed"], e["config"]) for i, e in enumerate(entries)]
    results = _execute_jobs(jobs, run_dir, 1)

    gate_fail = 0
    for e, r in zip(entries, results):
        must_pass = e.get("fixed", False)
        mark = "fixed" if must_pass else "open "
        ok = r["status"] == "PASS"
        if must_pass and not ok:
            gate_fail += 1
        flag = "" if (ok or not must_pass) else "  <-- GATE FAIL"
        print(f"  [{mark}] seed={r['seed']} cfg={r['config']} "
              f"-> {r['status']} ({e.get('note', '')}){flag}")
    print(f"rr replay: entries={len(entries)} gate_fail={gate_fail}")
    sys.exit(1 if gate_fail else 0)


def main():
    p = argparse.ArgumentParser(description="axi_apb_mem random regression")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build").set_defaults(fn=cmd_build)
    pr = sub.add_parser("run"); pr.set_defaults(fn=cmd_run)
    pr.add_argument("--n", type=int, default=10)
    pr.add_argument("--jobs", type=int, default=1)
    pr.add_argument("--seed", type=int, default=None)
    pt = sub.add_parser("triage"); pt.set_defaults(fn=cmd_triage)
    pt.add_argument("--run", required=True)
    sub.add_parser("replay").set_defaults(fn=cmd_replay)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
