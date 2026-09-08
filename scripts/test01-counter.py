import datetime, hashlib, json, os, sys

path, action = sys.argv[1:3]
if action == "gate":
    if len(sys.argv) != 3:
        raise SystemExit("gate takes no extra arguments")
else:
    if action != "finish" or len(sys.argv) != 7:
        raise SystemExit("finish RUN_ID ARTIFACT {PASS|FAIL} REASON")

if os.path.exists(path):
    with open(path, encoding="utf-8") as stream:
        state = json.load(stream)
    if (state.get("schema_version") != 1 or type(state.get("consecutive_failures")) is not int
            or state["consecutive_failures"] < 0 or not isinstance(state.get("history"), list)
            or state.get("stopped") not in (None, True, False)):
        raise SystemExit("invalid TEST-01 counter")
else:
    state = {"schema_version": 1, "consecutive_failures": 0, "stopped": False, "history": []}

for item in state["history"]:
    if not isinstance(item, dict) or item.get("status") not in ("PASS", "FAIL"):
        raise SystemExit("invalid TEST-01 counter history")

if action == "gate":
    if state.get("stopped") is True or state["consecutive_failures"] >= 3:
        raise SystemExit("TEST-01 blocked after three consecutive failures")
    print(state["consecutive_failures"])
    raise SystemExit()

run_id, artifact, status, reason = sys.argv[3:]
if status == "PASS":
    state["consecutive_failures"] = 0
else:
    state["consecutive_failures"] += 1
state["stopped"] = state["consecutive_failures"] >= 3
row = {"timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "run_id": run_id, "status": status, "artifact_path": artifact,
       "reason": reason, "fingerprint": hashlib.sha256(reason.encode()).hexdigest()}
state["history"] = (state.get("history", []) + [row])[-3:]
state.update(last_run_id=run_id, last_artifact=artifact, last_reason=reason,
             updated_at=row["timestamp"])
os.makedirs(os.path.dirname(path), exist_ok=True)
temporary = path + ".tmp-" + str(os.getpid())
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(state, stream, indent=2)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.replace(temporary, path)
print(state["consecutive_failures"])
