#!/usr/bin/env bash
# 本地门禁：与 CI 的 verify job 同判据。断言四件事：零警告、用例条数=73、0 failed、文档与 README 真跑。
set -euo pipefail
export MOON_HOME="${MOON_HOME:-$HOME/.moon}"
cd "$(dirname "$0")/.."

# 文档检查切"对本地源码"那一支：发版前注册表还是旧代次，用 registry 模式判破坏性变更会假绿，
# 而发布之后 CI 还会再以 registry 模式跑一遍当"用户那条腿"的验证，两分工不重叠。
export DOCS_TARGET=source

check_log=$(moon check --target wasm --no-render 2>&1)
printf '%s\n' "$check_log" | tail -2
if printf '%s' "$check_log" | grep -q "Warning"; then
  echo "GATE FAIL: moon check 有警告（零警告发版口径）" >&2
  exit 1
fi

test_log=$(moon test --target wasm --no-render 2>&1)
printf '%s\n' "$test_log" | tail -3
printf '%s' "$test_log" | grep -q "Total tests: 73" || { echo "GATE FAIL: 用例条数不是 73（矩阵增删要同步这里）" >&2; exit 1; }
printf '%s' "$test_log" | grep -q "failed: 0" || { echo "GATE FAIL: 有失败用例" >&2; exit 1; }
bash scripts/docs-check.sh
bash scripts/readme-check.sh
echo "GATE PASS: 零警告 + Total tests: 73 + 0 failed + 文档代码块与 README 对本地源码真跑"
