#!/usr/bin/env bash
set -euo pipefail
cd /root
if [ ! -d ap-db-connection-exhaustion-lab/.git ]; then
  git clone --depth 1 https://github.com/imukairiku/ap-db-connection-exhaustion-lab.git
else
  git -C ap-db-connection-exhaustion-lab pull --ff-only
fi
cd ap-db-connection-exhaustion-lab
bash scripts/scenario-reset.sh
bash scripts/scenario-inject.sh
