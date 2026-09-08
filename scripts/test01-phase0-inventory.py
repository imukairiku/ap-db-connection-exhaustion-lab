import hashlib
import json
import pathlib
import sys

action, source_path, output_path = sys.argv[1:]
repo_root = pathlib.Path(__file__).resolve().parents[1]

def regular_file_within_repo(value):
    path = (repo_root / value).resolve(strict=True)
    if repo_root not in path.parents or not path.is_file() or path.is_symlink():
        raise SystemExit("Phase 0 prerequisite path is not a regular repository file")
    return path

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

source_file = regular_file_within_repo(source_path)
source = json.loads(source_file.read_text(encoding="utf-8"))
expected = {
    "schema_version": 1, "test_id": "TEST-00", "status": "PASS", "attempt": 4,
    "method": "A", "environment_id": "ubuntu-01747e9d-d5c2-494b-bc03-e68deae7aac4",
    "run_id": "20260903T155321-1728", "cleanup_verified": True,
    "matched_counts": {"immediate_after": 3, "after_5s": 3, "after_15s": 3},
    "source_report": "docs/phase0-report.md",
}
if source != expected:
    raise SystemExit("Phase 0 persistent prerequisite does not match the approved TEST-00 result")

report_file = regular_file_within_repo(source["source_report"])
report = report_file.read_text(encoding="utf-8")
required_report_values = (
    "TEST-00", "PASS", source["environment_id"], source["run_id"],
    "immediate_after", "after_5s", "after_15s", "通信DROP", "pause",
)
if any(value not in report for value in required_report_values):
    raise SystemExit("Phase 0 report does not substantiate the persistent prerequisite")

def inventory():
    return [
        {"path": path.relative_to(repo_root).as_posix(), "bytes": path.stat().st_size,
         "sha256": digest(path)}
        for path in (source_file, report_file)
    ]

output = pathlib.Path(output_path)
if action == "capture":
    document = {
        "schema_version": 2,
        "prerequisite": {key: source[key] for key in (
            "test_id", "status", "attempt", "method", "environment_id", "run_id")},
        "inventory": inventory(),
    }
    output.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
elif action == "verify":
    baseline = json.loads(output.read_text(encoding="utf-8"))
    if baseline.get("schema_version") != 2 or baseline.get("inventory") != inventory():
        raise SystemExit("Phase 0 persistent prerequisite changed during TEST-01")
else:
    raise SystemExit("action must be capture or verify")
