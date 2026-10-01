#!/usr/bin/env bash
# moon-token 演示服务冒烟：正向 / 负向（精确原因）/ 被踢 三场景各留一次真读数
# 用法：先起服务  moon run --target wasm examples/cmd/main
#       再跑本脚本 bash examples/curl.sh
set -euo pipefail
BASE="${BASE:-http://127.0.0.1:18890}"

echo "[1] 健康检查"
curl -s "$BASE/health"; echo

echo "[2] 无 token 访问保护端点 —— 期望 msg 含 AbsentToken"
curl -s "$BASE/api/user/info"; echo

echo "[3] 登录"
LOGIN=$(curl -s -X POST "$BASE/login"); echo "$LOGIN"
TOKEN=$(printf '%s' "$LOGIN" | sed 's/.*token=\([a-z0-9]*\).*/\1/')
if [ "${#TOKEN}" -ne 40 ]; then
  echo "FAIL: token 长度应为 40，实得 ${#TOKEN}" >&2
  exit 1
fi

echo "[4] 带 token 访问 —— 期望 code=0 且 data 含 demo-user"
curl -s -H "Authorization: $TOKEN" "$BASE/api/user/info"; echo

echo "[5] 踢下线"
curl -s -X POST -H "Authorization: $TOKEN" "$BASE/kick"; echo

echo "[6] 同一个 token 再用 —— 期望 msg 含 KickedOut（不是笼统未登录）"
AFTER=$(curl -s -H "Authorization: $TOKEN" "$BASE/api/user/info"); echo "$AFTER"
case "$AFTER" in
  *KickedOut*) echo "PASS：被踢方拿到精确原因" ;;
  *) echo "FAIL：期望 KickedOut，实得 $AFTER" >&2; exit 1 ;;
esac
