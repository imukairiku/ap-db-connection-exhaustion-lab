# ap-db-connection-exhaustion-lab

AP reliability test lab for reproducing PostgreSQL connection exhaustion.

## Phase 0: Killercoda environment probe

Phase 0 selects a real failure-injection method only after PostgreSQL and
`ss` both prove that at least two identical TCP sessions remain established
for 15 seconds. Run it on a fresh Killercoda Ubuntu session from the repository
root:

```bash
sudo bash scripts/probe-env.sh
```

The command builds an isolated `phase0-*` Docker Compose project, tries methods
A through E in priority order, cleans up every mutation, and writes evidence to
`artifacts/phase0/<environment-id>/run-<utc-pid-id>/`. The JSONL `attempt`
continues to represent consecutive TEST-00 failures, while every run directory
has a separate unique collision-safe identity and is never truncated. It removes its probe containers and
network on exit. It never flushes firewall rules, changes the host's existing
qdisc, publishes PostgreSQL ports, or restarts PostgreSQL.

A successful Killercoda run atomically creates `config/selected-method.json`.
Local runs are useful diagnostics but deliberately finish nonzero as
`NOT_QUALIFIED` and cannot create that file.
Killercoda is accepted only when its non-empty `/etc/killercoda/host` marker is
present. The marker value is never logged; only its SHA-256 digest is stored.
The session ID is derived from hostname and kernel boot ID. Environment,
identity, and attempt overrides are rejected. These facts plus kernel, Docker,
and Compose details are stored in `execution-context.json`, and TEST-00
recomputes them. Both the Docker Compose plugin and legacy `docker-compose`
standalone command are supported.

Every writer of `config/selected-method.json` must hold the run-independent
`config/.selected-method.lock` with `flock` for its entire backup, commit,
event-finalization, and rollback sequence. Missing `flock` is a capability
failure. After the new config and all required events are validated, it becomes
authoritative before cleanup of the old backup; a backup deletion failure is
recorded as a warning artifact and does not roll back the validated new config.

The probe prints its current capability, method, observation point, and final
artifact path. Terminal failures are also written to stderr and increment
`artifacts/phase0/test-00-failures.json`; three consecutive failures trigger
the escalation rule and prevent any further mutation. The repository records
the user-provided first failure in `docs/phase0-test-state.json`; if no runtime
counter exists, the next run is attempt 2.

If interrupted, rerun the command: host-owned traps undo pause/STOP, delete only
tagged rules or probe qdiscs, terminate only revalidated probe backends, and
remove the isolated Compose project. See `result.jsonl` for machine-readable
events and `summary.txt` for the result. `scripts/check-connections.sh` may be
used separately while the probe stack is running.
