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

port_busy() {
  curl -s -m 2 "$BASE/health" | grep -q '"code":0'
}

if port_busy; then
  echo "GATE FAIL: ${BASE} 已经有服务在跑（多半是手工起的演示站）。先停掉再跑自检——" >&2
  echo "  自检不许把别人的进程当自己的，也不许绕过端口占用假装通过。" >&2
  exit 1
fi

SRV=""
GROUPED=""

stop_server() {
  if [ -z "$SRV" ]; then
    return 0
  fi
  # `moon run` 只是外壳，真在 listen 的是它拉起的 moonrun：只 kill 外壳会留一个游离服务
  # （CI 上就是这么红的）。有 setsid 时把它连同子进程一整组收掉；没有就逐个收 + 轮询端口。
  if [ -n "$GROUPED" ]; then
    kill -TERM "-$SRV" 2>/dev/null || true
  else
    kill -TERM "$SRV" 2>/dev/null || true
    pkill -TERM -P "$SRV" 2>/dev/null || true
  fi
  local waited=0
  while [ "$waited" -lt 6 ]; do
    sleep 1
    waited=$((waited + 1))
    if ! port_busy; then
      SRV=""
      return 0
    fi
    if [ -n "$GROUPED" ]; then
      kill -KILL "-$SRV" 2>/dev/null || true
    else
      kill -KILL "$SRV" 2>/dev/null || true
      pkill -KILL -P "$SRV" 2>/dev/null || true
    fi
  done
  # 最后一道：按命令行特征清掉本仓 serve 的残留 moonrun（模式够具体，不会碰别的进程）
  pkill -KILL -f "cmd/serve" 2>/dev/null || true
  sleep 2
  if port_busy; then
    echo "GATE FAIL: 收尾后 $BASE 仍在应答——有游离服务进程占着端口，请手工确认后再跑" >&2
    return 1
  fi
  SRV=""
  return 0
}

on_exit() {
  stop_server || true
}
trap on_exit EXIT

echo "[site-smoke] 启动 moon run --target wasm examples/cmd/serve（日志：$LOG）"
if command -v setsid >/dev/null 2>&1; then
  setsid moon run --target wasm examples/cmd/serve > "$LOG" 2>&1 &
  GROUPED=yes
else
  moon run --target wasm examples/cmd/serve > "$LOG" 2>&1 &
fi
SRV=$!

ready=""
for _ in $(seq 1 30); do
  sleep 1
  if port_busy; then
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
echo "[site-smoke] 服务已就绪（pid $SRV，进程组收尾=$([ -n "$GROUPED" ] && echo yes || echo no)）"

BASE="$BASE" bash examples/curl.sh

echo "[site-smoke] 收尾：停服务并确认端口已释放"
stop_server
echo "SITE SMOKE PASS：起-测-收全绿（$ROOT）"
