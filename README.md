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
`artifacts/phase0/<environment-id>/`. It removes its probe containers and
network on exit. It never flushes firewall rules, changes the host's existing
qdisc, publishes PostgreSQL ports, or restarts PostgreSQL.

A successful Killercoda run atomically creates `config/selected-method.json`.
Local runs are useful diagnostics but deliberately finish nonzero as
`NOT_QUALIFIED` and cannot create that file.
Environment overrides that disagree with automatic detection are rejected so
local evidence cannot be labelled as Killercoda evidence.

If interrupted, rerun the command: host-owned traps undo pause/STOP, delete only
tagged rules or probe qdiscs, terminate only revalidated probe backends, and
remove the isolated Compose project. See `result.jsonl` for machine-readable
events and `summary.txt` for the result. `scripts/check-connections.sh` may be
used separately while the probe stack is running.
