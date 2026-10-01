#!/usr/bin/env bash
# moon-token 演示站冒烟：JSON 门面 + HTML 门面，三场景各留一次真读数
#   正向 / 负向（精确原因）/ 回归（已有页面不被改坏）
# 用法：先起服务  moon run --target wasm examples/cmd/serve
#       再跑本脚本 bash examples/curl.sh
#       （或一把梭：bash scripts/site-smoke.sh —— 自己起、自己测、自己收）
set -euo pipefail
BASE="${BASE:-http://127.0.0.1:18891}"

fail() { echo "FAIL: $*" >&2; exit 1; }

get() { curl -s -m 10 "$BASE$1"; }

echo "[1] 健康检查 —— 期望 code=0"
H=$(get /health)
echo "$H"
printf '%s' "$H" | grep -q '"code":0' || fail "健康检查没返回 code=0：$H"

echo
echo "[2] 无 token 访问保护端点 —— 期望精确原因 AbsentToken"
A=$(get /api/user/info)
echo "$A"
printf '%s' "$A" | grep -q 'AbsentToken' || fail "期望 AbsentToken，实得：$A"

echo
echo "[3] 登录（拿 access + refresh 整对）"
LOGIN=$(curl -s -m 10 -X POST "$BASE/login?user=demo-user&device=cli")
echo "$LOGIN"
printf '%s' "$LOGIN" | grep -q '"code":0' || fail "登录失败：$LOGIN"
TOKEN=$(printf '%s' "$LOGIN" | sed -n 's/.*"data":{"token":"\([a-z0-9]*\)".*/\1/p')
REFRESH=$(printf '%s' "$LOGIN" | sed -n 's/.*"refresh_token":"\([a-z0-9]*\)".*/\1/p')
[ "${#TOKEN}" -eq 40 ] || fail "token 长度应为 40，实得 ${#TOKEN}"
[ "${#REFRESH}" -eq 40 ] || fail "refresh_token 长度应为 40，实得 ${#REFRESH}"
echo "PASS：拿到 40 字符 access 与 refresh 各一枚"

echo
echo "[4] 带 token 访问 —— 期望 code=0 且 login_id=demo-user"
B=$(get "/api/user/info?token=$TOKEN")
echo "$B"
printf '%s' "$B" | grep -q '"login_id":"demo-user"' || fail "期望放行 demo-user，实得：$B"

echo
echo "[5] 踢下线"
K=$(curl -s -m 10 -X POST -H "Authorization: $TOKEN" "$BASE/kick?user=demo-user")
echo "$K"
printf '%s' "$K" | grep -q '"code":0' || fail "踢人失败：$K"

echo
echo "[6] 同一枚 token 再用 —— 期望 KickedOut（不是笼统未登录）"
C=$(get "/api/user/info?token=$TOKEN")
echo "$C"
printf '%s' "$C" | grep -q 'KickedOut' || fail "期望 KickedOut，实得：$C"

echo
echo "[7] 页面门面：五个主页面都要真渲染出来（演的是同一份站点状态）"
for path in / /sessions /login /events /guard; do
  PAGE=$(get "$path")
  if printf '%s' "$PAGE" | grep -q '出错了'; then
    fail "$path 渲染失败"
  fi
  if ! printf '%s' "$PAGE" | grep -q 'moon-token'; then
    fail "$path 没返回页面"
  fi
  echo "  $path OK（$(printf '%s' "$PAGE" | wc -c) 字节）"
done

echo
echo "[8] 剧本页回归：kick 剧本必须同时演出 KickedOut 与墓碑回收后的 UnknownToken"
SCRIPT=$(get "/play?run=kick")
printf '%s' "$SCRIPT" | grep -q 'KickedOut' || fail "kick 剧本没演到 KickedOut"
printf '%s' "$SCRIPT" | grep -q 'UnknownToken' || fail "kick 剧本没演到墓碑回收（UnknownToken）"
printf '%s' "$SCRIPT" | grep -q 'apply MarkStatus' || fail "kick 剧本没给出落库流水"
echo "PASS：剧本页把「调用 → 精确原因 → 落库写了什么」三段都画出来了"

echo
echo "PASS：JSON 门面与 HTML 门面三场景全绿"
