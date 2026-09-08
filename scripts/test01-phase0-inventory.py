import hashlib, json, os, pathlib, stat, sys

action, source_path, output = sys.argv[1:]
source_file = pathlib.Path(source_path).resolve(strict=True)
source = json.loads(source_file.read_text(encoding="utf-8"))
result = pathlib.Path(source["result_jsonl"]).resolve(strict=True)
run_root = result.parent

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

def entry(path, root, root_name):
    info = path.lstat()
    relative = "." if path == root else path.relative_to(root).as_posix()
    row = {"root": root_name, "path": relative}
    if stat.S_ISREG(info.st_mode):
        row.update(type="regular", bytes=info.st_size, sha256=digest(path))
    elif stat.S_ISDIR(info.st_mode): row["type"] = "directory"
    elif stat.S_ISLNK(info.st_mode): row.update(type="symlink", target=os.readlink(path))
    else: row["type"] = "other"
    return row

def inventory():
    rows = [entry(source_file, source_file, "source")]
    rows.append(entry(run_root, run_root, "run"))
    for path in sorted(run_root.rglob("*"), key=lambda p: p.as_posix()):
        rows.append(entry(path, run_root, "run"))
    return rows

if action == "capture":
    rows = [json.loads(line) for line in result.read_text(encoding="utf-8").splitlines() if line]
    for row in rows:
        if (row.get("environment_id") != source["environment_id"] or row.get("run_id") != source["run_id"]
                or row.get("environment") != "killercoda" or row.get("test_id") != "TEST-00"
                or row.get("attempt") != 4):
            raise SystemExit("Phase 0 row identity mismatch")
    terminal = {name: [r for r in rows if r.get("event") == name and r.get("status") == "PASS"]
                for name in ("test_result", "method_qualified", "method_selected")}
    if any(len(value) != 1 for value in terminal.values()): raise SystemExit("Phase 0 terminal evidence invalid")
    if terminal["method_qualified"][0].get("method") != "A" or terminal["method_selected"][0].get("method") != "A":
        raise SystemExit("Phase 0 method mismatch")
    if terminal["method_qualified"][0].get("cleanup_verified") is not True:
        raise SystemExit("Phase 0 cleanup is not verified")
    paths = {result, run_root / "execution-context.json", run_root / "cleanup-ledger.tsv",
             run_root / "cleanup-backend-actions.jsonl"}
    for row in rows:
        if row.get("event") == "observation" or row.get("event") == "method_qualified":
            paths.add(pathlib.Path(row["artifact_path"]).resolve(strict=True))
    required = []
    for path in sorted(paths, key=str):
        if path != run_root and run_root not in path.parents: raise SystemExit("Phase 0 path escapes run root")
        if not path.is_file() or path.is_symlink(): raise SystemExit("Phase 0 required entry is not a regular file")
        required.append(entry(path, run_root, "run"))
    context = json.loads((run_root / "execution-context.json").read_text(encoding="utf-8"))
    if context.get("context_id") != source["environment_id"] or context.get("run_id") != source["run_id"]:
        raise SystemExit("Phase 0 context identity mismatch")
    cleanup = json.loads(pathlib.Path(terminal["method_qualified"][0]["artifact_path"]).read_text(encoding="utf-8"))
    if cleanup.get("pg_backend_pids") or cleanup.get("canonical_tuples"):
        raise SystemExit("Phase 0 cleanup artifact retains resources")
    document = {"schema_version": 1, "source_environment_id": source["environment_id"],
                "source_run_id": source["run_id"], "source_file": str(source_file),
                "run_root": str(run_root), "required": required, "inventory": inventory()}
    pathlib.Path(output).write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
elif action == "verify":
    baseline = json.loads(pathlib.Path(output).read_text(encoding="utf-8"))
    if baseline["source_environment_id"] != source["environment_id"] or baseline["source_run_id"] != source["run_id"]:
        raise SystemExit("Phase 0 identity changed")
    if baseline["inventory"] != inventory(): raise SystemExit("Phase 0 protected inventory changed")
    for expected in baseline["required"]:
        path = run_root / expected["path"]
        if entry(path, run_root, "run") != expected: raise SystemExit("Phase 0 required evidence changed")
else:
    raise SystemExit("action must be capture or verify")
