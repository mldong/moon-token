#!/usr/bin/env bash
# 本地门禁：与 CI 同判据。断言四件事——零警告、用例条数=33、0 failed、演示站起-测-收全绿。
set -euo pipefail
export MOON_HOME="${MOON_HOME:-$HOME/.moon}"
cd "$(dirname "$0")/.."

check_log=$(moon check --target wasm --no-render 2>&1)
printf '%s\n' "$check_log" | tail -2
if printf '%s' "$check_log" | grep -q "Warning"; then
  echo "GATE FAIL: moon check 有警告（零警告发版口径）" >&2
  exit 1
fi

test_log=$(moon test --target wasm --no-render 2>&1)
printf '%s\n' "$test_log" | tail -3
printf '%s' "$test_log" | grep -q "Total tests: 33" || { echo "GATE FAIL: 用例条数不是 33（矩阵增删要同步这里）" >&2; exit 1; }
printf '%s' "$test_log" | grep -q "failed: 0" || { echo "GATE FAIL: 有失败用例" >&2; exit 1; }
bash scripts/site-smoke.sh
echo "GATE PASS: 零警告 + Total tests: 33 + 0 failed + 演示站自检"
