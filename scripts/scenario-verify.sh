#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/phase7-lab.py verify "${1:-recovery}"
