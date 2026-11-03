#!/usr/bin/env bash
# 数“本仓应负责的告警”。
#
# 背景（2026-11-03）：官方 moonbitlang/async 自 0.22.6 起转发到 core 的实验包 core/async，
# 编译器在 0.10.19 起对这条转发发告警。告警由 async 自己的包发出，消费侧 moon.pkg 的
# allow-experimental-packages 压不掉（旧链 0.10.18 实测 0 条、新链 0.10.19 实测 3 条）。
# 依赖树里的这条不是本仓的账——与本仓 docs-check/readme-check 排除脚本自造噪音同一口径；
# 只剔除“依赖方是 moonbitlang/async*”这一种形状，本仓包自己的告警照常计数。
#
# 用法：
#   bash scripts/own-warn.sh <日志文件>
#   命令 2>&1 | bash scripts/own-warn.sh
#   bash scripts/own-warn.sh --selftest    # 三条依赖告警 + 一条本仓告警 ⇒ 必须只剩 1
set -euo pipefail

count_own() {
  {
    if [ -n "${1:-}" ] && [ -f "$1" ]; then
      grep "Warning" "$1" 2>/dev/null || true
    else
      grep "Warning" || true
    fi
  } | { grep -vE '^Warning: Package `moonbitlang/async(/[^`]*)?` depends on experimental package' || true; } \
    | wc -l | tr -d ' '
}

if [ "${1:-}" = "--selftest" ]; then
  got=$(printf '%s\n' \
    'Warning: Package `moonbitlang/async` depends on experimental package `moonbitlang/core/async`.' \
    'Warning: Package `moonbitlang/async/internal/event_loop` depends on experimental package `moonbitlang/core/async`.' \
    'Warning: Package `moonbitlang/async/external_loop_integration` depends on experimental package `moonbitlang/core/async/external_loop_integration`.' \
    'Warning: [0027] own warning' | count_own)
  if [ "$got" != "1" ]; then
    echo "SELFTEST FAIL: 期望只剩 1 条本仓告警，实得 $got" >&2
    exit 1
  fi
  echo "SELFTEST PASS: 依赖树实验包告警被剔除，本仓告警仍计"
  exit 0
fi

count_own "${1:-}"
