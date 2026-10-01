#!/usr/bin/env bash
# 演示站自检：自己起服务 → 跑 examples/curl.sh → 自己收尾。
# 存在理由：示例站最容易被改坏而无人察觉（编译通过 ≠ 页面渲染得出来）。
# CI 里是一条独立步骤；本地想单跑就直接 bash scripts/site-smoke.sh。
set -euo pipefail
export MOON_HOME="${MOON_HOME:-$HOME/.moon}"
cd "$(dirname "$0")/.."
ROOT=$(pwd)
PORT="${PORT:-18891}"
BASE="http://127.0.0.1:${PORT}"
LOG="${TMPDIR:-/tmp}/mldong-moon-token-site.log"

if curl -s -m 2 "$BASE/health" > /dev/null 2>&1; then
  echo "GATE FAIL: ${BASE} 已经有服务在跑（多半是手工起的演示站）。先停掉再跑自检——" >&2
  echo "  自检不许把别人的进程当自己的，也不许绕过端口占用假装通过。" >&2
  exit 1
fi

SRV=""
cleanup() {
  if [ -n "$SRV" ] && kill -0 "$SRV" 2>/dev/null; then
    kill "$SRV" 2>/dev/null || true
    sleep 1
    kill -9 "$SRV" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[site-smoke] 启动 moon run --target wasm examples/cmd/serve（日志：$LOG）"
moon run --target wasm examples/cmd/serve > "$LOG" 2>&1 &
SRV=$!

ready=""
for _ in $(seq 1 30); do
  sleep 1
  if curl -s -m 2 "$BASE/health" | grep -q '"code":0'; then
    ready=yes
    break
  fi
  if ! kill -0 "$SRV" 2>/dev/null; then
    break
  fi
done
if [ -z "$ready" ]; then
  echo "GATE FAIL: 服务 30 秒内没起来（$BASE）。启动日志：" >&2
  tail -20 "$LOG" >&2 || true
  exit 1
fi
echo "[site-smoke] 服务已就绪（pid $SRV）"

BASE="$BASE" bash examples/curl.sh

echo "[site-smoke] 收尾：停服务并确认端口已释放"
kill "$SRV" 2>/dev/null || true
SRV=""
sleep 1
if curl -s -m 2 "$BASE/health" | grep -q '"code":0'; then
  echo "GATE FAIL: 已经 kill 但 $BASE 仍应答——有游离的服务进程占着端口，请手工确认后再跑" >&2
  exit 1
fi
echo "SITE SMOKE PASS：起-测-收全绿（$ROOT）"
