import hashlib, json, os, pathlib, socket, sys

artifact = pathlib.Path(sys.argv[1])
required = ["execution-context.json", "result.jsonl", "ownership-ledger.tsv",
            "compose-version.txt", "compose-config.yaml", "compose-services.txt",
            "build.log", "up.log", "health-polls.jsonl", "compose-ps.raw", "compose-ps.json",
            "db-inspect.json", "ap-inspect.json", "postgres-settings.json",
            "postgres-settings.raw", "ap-readiness.json", "ap-db-tcp.json",
            "cleanup.log", "cleanup-verification.json", "phase0-protection.json", "summary.json"]
for name in required:
    if not (artifact / name).is_file(): raise SystemExit("missing artifact: " + name)
context = json.loads((artifact / "execution-context.json").read_text())
settings = json.loads((artifact / "postgres-settings.json").read_text())
readiness = json.loads((artifact / "ap-readiness.json").read_text())
tcp = json.loads((artifact / "ap-db-tcp.json").read_text())
cleanup = json.loads((artifact / "cleanup-verification.json").read_text())
summary = json.loads((artifact / "summary.json").read_text())
assert context["environment"] == "killercoda" and context["environment_id"] == context["hostname"] + "-" + context["boot_id"]
assert pathlib.Path("/etc/killercoda/host").is_file()
assert hashlib.sha256(pathlib.Path("/etc/killercoda/host").read_bytes()).hexdigest() == context["marker_sha256"]
assert socket.gethostname() == context["hostname"]
assert pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip() == context["boot_id"]
assert settings["max_connections"] == 20 and settings["pg_postmaster_start_time"]
assert type(settings["db_restart_count"]) is int
assert readiness["http_status"] == 200 and readiness["ready"] is True
assert tcp["status"] == "CONNECTED" and tcp["port"] == 5432
assert cleanup["containers"] == cleanup["networks"] == cleanup["volumes"] == 0
assert summary["test_id"] == "TEST-01" and summary["status"] == "PASS" and summary["cleanup"]["verified"] is True
compose = json.loads((artifact / "compose-ps.json").read_text())
assert set(compose) == {"db-server", "ap-server-1"}
for service, expected_id in (("db-server", settings["db_container_id"]), ("ap-server-1", summary["ap_container_id"])):
    assert compose[service]["id"] == expected_id and compose[service]["service"] == service
    assert compose[service]["project"] == summary["compose_project"] and compose[service]["running"] is True and compose[service]["health"] == "healthy"
rows = [json.loads(line) for line in (artifact / "result.jsonl").read_text().splitlines() if line]
assert rows and all(row["test_id"] == "TEST-01" and row["environment_id"] == context["environment_id"] and row["run_id"] == context["run_id"] for row in rows)
if len(sys.argv) > 2:
    state = json.loads(pathlib.Path(sys.argv[2]).read_text())
    terminal = [row for row in rows if row["event"] == "test_result"]
    assert len(terminal) == 1 and terminal[0]["failure_count_at_end"] == state["consecutive_failures"]
    assert terminal[0]["cleanup"]["verified"] is True
print(json.dumps({"validated": True, "artifact_path": str(artifact)}))
