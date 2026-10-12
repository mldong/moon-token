#!/usr/bin/env bash
# RS 系列真机门禁：要求**真有一台 redis**，并且把任何 SKIP 判成失败。
#
# 存在理由：`moon test` 在无服务端时 RS1–RS8 会响亮打印 SKIP 并计入 passed，
# 于是"109 全绿"完全可以是一台空转的套件（恒 skip 的套件＝没有套件）。
# 这道门专治这一种绿：CI 与 gate.sh 都不需要服务端，只有这里是真跑。
#
# 用法（两台都跑过才算收口）：
#   本机沙箱（Redis 8.0.5，零 root 起法见 hub docs/moon-token-design.md §15.25）：
#     MT_REDIS_HOST=127.0.0.1 bash scripts/redis-gate.sh
#   开发库（Redis 5.0.4，我们一键包实际部署的那一版）：
#     MT_REDIS_HOST=192.168.1.160 MT_REDIS_DB=15 MT_REDIS_PWD="$RD_PWD" bash scripts/redis-gate.sh
set -euo pipefail
export MOON_HOME="${MOON_HOME:-$HOME/.moon}"
cd "$(dirname "$0")/.."

if [ -z "${MT_REDIS_HOST:-}" ]; then
  echo "GATE FAIL: 未给 MT_REDIS_HOST——不指定服务端就是没测" >&2
  exit 1
fi
export MT_REDIS_TEST=1

log=$(mktemp)
if ! moon test --target wasm --no-render >"$log" 2>&1; then
  tail -30 "$log"
  echo "GATE FAIL: RS 真机用例有红（host=${MT_REDIS_HOST} db=${MT_REDIS_DB:-0}）" >&2
  exit 1
fi
if grep -q "SKIP RS" "$log"; then
  grep "SKIP RS" "$log"
  echo "GATE FAIL: 有 RS 用例被跳过，跳过等于没测" >&2
  exit 1
fi
if ! grep -q "Total tests: 109" "$log"; then
  tail -3 "$log"
  echo "GATE FAIL: 条数不是 109" >&2
  exit 1
fi
if ! grep -q "failed: 0" "$log"; then
  tail -3 "$log"
  echo "GATE FAIL: 有失败用例" >&2
  exit 1
fi
tail -2 "$log"
echo "GATE PASS(redis): 109 条全绿、RS1–RS8 真跑无跳过（host=${MT_REDIS_HOST} db=${MT_REDIS_DB:-0}）"
