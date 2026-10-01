#!/usr/bin/env bash
# moon-token 示例服务冒烟：按"正向 / 负向（精确原因）/ 回归"三档各留一次真读数。
# 用法：先起服务  moon run --target wasm examples/cmd/main
#       再跑本脚本 bash examples/curl.sh
#
# 这条链顺带就是文档里的"端对端剧本"：每一步都断言库给出的**精确原因**，
# 而不是只看"有没有报错"——那正是本库的卖点。
set -euo pipefail
BASE="${BASE:-http://127.0.0.1:18890}"

fail() { echo "FAIL: $*" >&2; exit 1; }

get() { curl -s -m 10 "$BASE$1"; }
field() { sed -n "s/.*\"$1\":\"\([a-z0-9]*\)\".*/\1/p"; }

echo "[1] 健康检查"
H=$(get /health); echo "$H"
printf '%s' "$H" | grep -q '"code":0' || fail "健康检查没返回 code=0"

echo
echo "[2] 无 token 访问保护端点 —— 期望精确原因 AbsentToken"
A=$(get /api/user/info); echo "$A"
printf '%s' "$A" | grep -q 'AbsentToken' || fail "期望 AbsentToken，实得：$A"

echo
echo "[3] 豁免端点 —— not_match_pattern(\"/api/public/**\") 应放行（无 token 也要 code=0）"
P=$(get /api/public/ping); echo "$P"
printf '%s' "$P" | grep -q '"code":0' || fail "豁免端点被拦了，守卫的排除臂没生效：$P"

echo
echo "[4] 登录（签发 access + refresh 整对）"
LOGIN=$(curl -s -m 10 -X POST -H 'X-Device: pc' "$BASE/login"); echo "$LOGIN"
T1=$(printf '%s' "$LOGIN" | field token)
R1=$(printf '%s' "$LOGIN" | field refresh_token)
[ "${#T1}" -eq 40 ] || fail "access 长度应为 40，实得 ${#T1}"
[ "${#R1}" -eq 40 ] || fail "refresh 长度应为 40，实得 ${#R1}"

echo
echo "[5] 带 token 访问 —— 期望放行并回 login_id"
B=$(curl -s -m 10 -H "Authorization: $T1" "$BASE/api/user/info"); echo "$B"
printf '%s' "$B" | grep -q 'hello demo-user' || fail "期望放行 demo-user：$B"

echo
echo "[6] 权限 SPI —— 业务只供数，AND 裁决在库里"
W=$(curl -s -m 10 -H "Authorization: $T1" "$BASE/whoami"); echo "$W"
printf '%s' "$W" | grep -q '有 user:info+user:list' || fail "权限裁决不符期望：$W"

echo
echo "[7] 全量轮转 —— 整对换新"
ROT=$(curl -s -m 10 -X POST -H "X-Refresh-Token: $R1" "$BASE/rotate"); echo "$ROT"
T2=$(printf '%s' "$ROT" | field token)
[ "${#T2}" -eq 40 ] || fail "轮转没拿到新 access：$ROT"
[ "$T2" != "$T1" ] || fail "轮转后 access 没换新"

echo
echo "[8] 旧 access 再用 —— 期望 UnknownToken（全量轮转的语义是旧对同废）"
OLD=$(curl -s -m 10 -H "Authorization: $T1" "$BASE/api/user/info"); echo "$OLD"
printf '%s' "$OLD" | grep -q 'UnknownToken' || fail "期望 UnknownToken，实得：$OLD"

echo
echo "[9] 旧 refresh 重放 —— 期望 RefreshInvalid（原子取删，重放必拒）"
REPLAY=$(curl -s -m 10 -X POST -H "X-Refresh-Token: $R1" "$BASE/rotate"); echo "$REPLAY"
printf '%s' "$REPLAY" | grep -q 'RefreshInvalid' || fail "期望 RefreshInvalid，实得：$REPLAY"

echo
echo "[10] 踢下线（落墓碑，不删键）"
K=$(curl -s -m 10 -X POST -H "Authorization: $T2" "$BASE/kick"); echo "$K"
printf '%s' "$K" | grep -q '"code":0' || fail "踢人失败：$K"

echo
echo "[11] 被踢方再用 —— 期望 KickedOut（不是笼统未登录）"
C=$(curl -s -m 10 -H "Authorization: $T2" "$BASE/api/user/info"); echo "$C"
printf '%s' "$C" | grep -q 'KickedOut' || fail "期望 KickedOut，实得：$C"

echo
echo "[12] 同账号另起一枚 —— 默认 Coexist：新登录不受既有墓碑影响"
LOGIN2=$(curl -s -m 10 -X POST -H 'X-Device: mobile' "$BASE/login"); echo "$LOGIN2"
T3=$(printf '%s' "$LOGIN2" | field token)
D=$(curl -s -m 10 -H "Authorization: $T3" "$BASE/api/user/info"); echo "$D"
printf '%s' "$D" | grep -q 'hello demo-user' || fail "共存策略下新 token 应有效：$D"

echo
echo "[13] 注销后再用 —— 期望 UnknownToken（与「被踢」分得开：注销是删键）"
L=$(curl -s -m 10 -X POST -H "Authorization: $T3" "$BASE/logout"); echo "$L"
E=$(curl -s -m 10 -H "Authorization: $T3" "$BASE/api/user/info"); echo "$E"
printf '%s' "$E" | grep -q 'UnknownToken' || fail "期望注销后 UnknownToken，实得：$E"

echo
echo "PASS：三场景全绿——豁免/签发/续用/轮转/重放/被踢/共存/注销 逐条原因对上"
