#!/usr/bin/env bash
set -euo pipefail
result=${1:?usage: tests/test-00.sh result.jsonl cleanup-ledger.tsv}
ledger=${2:?cleanup ledger is required}
python3 - "$result" "$ledger" <<'PY'
import hashlib, json, os, platform, sys

result, ledger = sys.argv[1:]
rows = [json.loads(x) for x in open(result, encoding="utf-8") if x.strip()]
common = {"ts", "phase", "test_id", "event", "status", "rc", "environment",
          "environment_id", "hostname", "kernel", "docker_version", "compose_version",
          "attempt", "command_id", "artifact_path"}
assert rows and all(common <= set(r) for r in rows), "JSONL common contract incomplete"
assert all(r["environment"] == "killercoda" for r in rows), "not Killercoda evidence"
env_ids = {r["environment_id"] for r in rows}
assert len(env_ids) == 1 and next(iter(env_ids)), "environment_id mismatch"
run_ids = {r.get("run_id") for r in rows}
assert len(run_ids) == 1 and next(iter(run_ids)), "run_id mismatch"
assert len({r["command_id"] for r in rows}) == len(rows), "duplicate command_id"
assert all(isinstance(r["attempt"], int) and r["attempt"] >= 1 for r in rows)
context_path = os.path.join(os.path.dirname(result), "execution-context.json")
assert os.path.isfile(context_path), "execution context marker missing"
context = json.load(open(context_path, encoding="utf-8"))
assert context.get("schema_version") == 1
assert context.get("context") == "killercoda"
assert context.get("context_id") == next(iter(env_ids))
assert context.get("run_id") == next(iter(run_ids))
assert context.get("hostname") == rows[0]["hostname"]
host_marker = "/etc/killercoda/host"
assert os.path.isfile(host_marker) and os.path.getsize(host_marker) > 0, "Killercoda host marker missing"
marker_hash = hashlib.sha256(open(host_marker, "rb").read()).hexdigest()
assert context.get("context_source") == host_marker
assert context.get("killercoda_host_sha256") == marker_hash
boot_id = open("/proc/sys/kernel/random/boot_id", encoding="utf-8").read().strip()
assert context.get("boot_id") == boot_id
assert context.get("context_id") == f"{platform.node()}-{boot_id}"
assert context.get("docker_version") == rows[0]["docker_version"]
assert context.get("compose_kind") in {"plugin", "standalone"}
assert context.get("compose_version") == rows[0]["compose_version"]

qualified = [r for r in rows if r["event"] == "method_qualified" and r["status"] == "PASS"]
assert len(qualified) == 1, "exactly one qualified method required"
selected = qualified[0]
method = selected["method"]
order = "ABCDE"
assert method in order
for earlier in order[:order.index(method)]:
    terminal = [r for r in rows if r.get("method") == earlier and
                r.get("method_state") in {"CAPABILITY_FAILED", "TRIAL_FAILED"}]
    assert terminal and terminal[-1]["status"] == "FAIL", "priority order not proven"

observations = [r for r in rows if r["event"] == "observation" and r.get("method") == method]
by_point = {r["point"]: r for r in observations}
required_points = {"before", "immediate_after", "after_5s", "after_15s"}
assert required_points <= set(by_point), "required observation point missing"
for row in observations:
    assert os.path.isfile(row["artifact_path"]), "observation artifact missing"
    assert row["ap_stop_state"] == row["ap_stop_state_expected"], "AP stop state mismatch"
    assert row["ap_stop_state_source"], "AP state source missing"

before = by_point["before"]
assert before["ap_stop_state"] == "RUNNING"
artifact_dir = os.path.dirname(before["artifact_path"])
inspect_path = os.path.join(artifact_dir, f"method-{method}-before-inspect.json")
ps_path = os.path.join(artifact_dir, f"method-{method}-before-ps.txt")
assert os.path.isfile(inspect_path) and os.path.isfile(ps_path), "raw before state artifacts missing"
inspect_state = json.load(open(inspect_path, encoding="utf-8"))[0]["State"]
ps_rows = [x.split() for x in open(ps_path, encoding="utf-8").read().splitlines()[1:] if x.split()]
assert inspect_state.get("Running") is True and inspect_state.get("Paused") is False
assert ps_rows and all(not r[1].startswith(("T", "Z", "X")) for r in ps_rows)
before_rows = {r["pid"]: r for r in before["pg_rows"]}
before_tuples = {tuple(t) for t in before["matched_tuples"]}
assert len(before_rows) >= 2 and len(before_tuples) >= 2
postmaster = before["pg_postmaster_start_time"]
restart_count = before["db_restart_count"]
for point in ("immediate_after", "after_5s", "after_15s"):
    row = by_point[point]
    current = {r["pid"]: r for r in row["pg_rows"]}
    tuples = {tuple(t) for t in row["matched_tuples"]}
    matched = 0
    for pid, old in before_rows.items():
        new = current.get(pid)
        same_row = new and all(new[k] == old[k] for k in
                               ("backend_start", "client_addr", "client_port"))
        same_tuple = any(t in tuples and t[2] == old["client_addr"] and
                         t[3] == old["client_port"] for t in before_tuples)
        matched += bool(same_row and same_tuple)
    assert matched >= 2 and row["matched_count"] == matched, f"identity mismatch at {point}"
    assert row["pg_postmaster_start_time"] == postmaster, "postmaster restarted"
    assert row["db_restart_count"] == restart_count, "DB restart count changed"

cleanup_path = selected["artifact_path"]
assert os.path.isfile(cleanup_path), "cleanup artifact missing"
cleanup = json.load(open(cleanup_path, encoding="utf-8"))
assert not (set(before_rows) & set(cleanup["pg_backend_pids"])), "backend remains after cleanup"
assert not (before_tuples & {tuple(t) for t in cleanup["canonical_tuples"]}), "tuple remains after cleanup"
assert cleanup["pg_postmaster_start_time"] == postmaster
assert cleanup["db_restart_count"] == restart_count
assert selected.get("cleanup_verified") is True

assert os.path.isfile(ledger), "cleanup ledger missing"
entries = [line.rstrip("\n").split("\t") for line in open(ledger, encoding="utf-8") if line.strip()]
adds = [e for e in entries if len(e) == 7 and e[1] == "add_mutation"]
removes = [e for e in entries if len(e) == 7 and e[1] == "remove_mutation"]
assert adds and removes and removes[-1][6] == "VERIFIED", "cleanup ledger not verified"
assert adds[-1][2:6] == removes[-1][2:6], "cleanup ledger target mismatch"
if method in {"D", "E"}:
    original = adds[-1][5]
    suffix = "link" if method == "D" else "qdisc"
    restored = os.path.join(artifact_dir, f"method-{method}-{suffix}-after.txt")
    assert os.path.isfile(original) and os.path.isfile(restored), "network original/restored artifact missing"
    assert open(original, "rb").read() == open(restored, "rb").read(), "network state not restored"
print(f"TEST-00 PASS method={method} environment_id={next(iter(env_ids))}")
PY
