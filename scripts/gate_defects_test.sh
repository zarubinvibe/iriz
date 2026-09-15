#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

decision=$(/usr/bin/tail -n 1 scripts/gate_defects.sh)

run_decision() {
  /bin/bash -c "failed=\$1; no_data=\$2; $decision" gate "$1" "$2"
}

if run_decision 0 1; then
  echo "FAIL: acceptance passed with no_data=1"
  exit 1
fi

if ! run_decision 0 0; then
  echo "FAIL: acceptance failed with complete data"
  exit 1
fi

echo "OK: acceptance requires zero failures and complete data"
