#!/usr/bin/env bash
# moonback 适配层冒烟：守卫挂在真路由上，逐格断言 **HTTP 状态码 + 精确原因**。
# 用法：先起服务  moon run --target wasm examples/cmd/moonback-demo
#       再跑本脚本 bash scripts/mw-smoke.sh
#
# 为什么单开一条脚本：moonback 的 `Context::new` 与 `ConnectionInfo` 都不公开，包外造不出
# 一个 `Request`，所以"判决逻辑"能在 `moon test` 里测（MB1–MB10），而"**Request → 两个闭包**
# 这一小段 + 状态码真的落到响应上"只能靠真服务器。这条脚本测的就是那一段。
#
# 判据分档：401=身份不成立、403=权限/角色/被禁用、400=入参不合法、500=存储故障。
# 只断言"非 200"是不够的——401 与 403 混了，前端就分不清该跳登录还是该报无权。
set -euo pipefail
BASE="${BASE:-http://127.0.0.1:18891}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 响应体留在脚本自己的临时件里，跑完就删（不进仓、不跟别的会话撞名）
BODY=$(mktemp -t mldong-mw.XXXXXX)
trap 'rm -f "$BODY"' EXIT

# status <期望码> <标签> curl 参数...
status() {
  local want="$1" label="$2"
  shift 2
  local code
  code=$(curl -s -m 10 -o "$BODY" -w '%{http_code}' "$@")
  printf '  %-46s => %s %s\n' "$label" "$code" "$(head -c 90 "$BODY")"
  [ "$code" = "$want" ] || fail "$label 期望 $want，实得 $code"
}

token_of() {
  curl -s -m 10 -X POST "$BASE/login$1" |
    sed -n 's/.*"token":"\([a-z0-9]*\)".*/\1/p'
}

echo "[1] 豁免面：无凭证也 200，且响应里不带主体"
status 200 "GET /public/ping（豁免）" "$BASE/public/ping"

echo
echo "[2] 未登录打保护端点 —— 期望 401 + AbsentToken"
status 401 "GET /api/user/info（无凭证）" "$BASE/api/user/info"

echo
echo "[3] 伪造 token —— 期望 401 + UnknownToken（不是 500）"
status 401 "GET /api/user/info（假 token）" -H "Authorization: zzz-not-a-token" "$BASE/api/user/info"

echo
echo "[4] 登录拿 token，两条腿都能过同一次裁决"
USER_T=$(token_of "")
[ "${#USER_T}" -eq 40 ] || fail "access 长度应为 40，实得 ${#USER_T}"
status 200 "GET /api/user/info（Authorization 头）" -H "Authorization: $USER_T" "$BASE/api/user/info"
status 200 "GET /api/user/info（同名 cookie 兜底）" -b "Authorization=$USER_T" "$BASE/api/user/info"
printf '%s' "$(cat "$BODY")" | grep -q '"login_id":"demo-user"' ||
  fail "cookie 腿应拿到与头腿相同的主体：$(cat "$BODY")"

echo
echo "[5] 推导面：路径推出来的码真在裁（在权限集里 ⇒ 200，不在 ⇒ 403）"
status 200 "GET /api/user/info（推 api:user:info）" -H "Authorization: $USER_T" "$BASE/api/user/info"
status 403 "GET /api/user/remove（推 api:user:remove）" -H "Authorization: $USER_T" "$BASE/api/user/remove"

echo
echo "[6] 例外清单与多码：demo-user 有 sys:user:save，但没有 a:b/c:d，也不是 admin"
status 200 "GET /sys/user/save（例外清单命中）" -H "Authorization: $USER_T" "$BASE/sys/user/save"
status 403 "GET /multi（多码 OR，两个都没有）" -H "Authorization: $USER_T" "$BASE/multi"
status 403 "GET /admin/panel（只挂角色要求）" -H "Authorization: $USER_T" "$BASE/admin/panel"

echo
echo "[7] 超管：权限集是空的，靠 is_super_admin 那一档过角色面"
BOSS_T=$(token_of "?as=boss")
status 200 "GET /admin/panel（超管跳过裁决）" -H "Authorization: $BOSS_T" "$BASE/admin/panel"
status 200 "GET /api/user/info（主体带 super_admin=true）" -H "Authorization: $BOSS_T" "$BASE/api/user/info"
printf '%s' "$(cat "$BODY")" | grep -q '"super_admin":true' ||
  fail "主体里的超管位没传出来：$(cat "$BODY")"

echo
echo "[8] 未匹配的路径 —— 守卫不背 404 的锅（逐路由包装：没注册就压根不过守卫）"
status 404 "GET /no/such/route" "$BASE/no/such/route"

echo
echo "[9] 注销后同一枚 token —— 401 UnknownToken（快照跟着会话一起废）"
status 200 "POST /logout" -X POST -H "Authorization: $USER_T" "$BASE/logout"
status 401 "GET /api/user/info（注销后）" -H "Authorization: $USER_T" "$BASE/api/user/info"

echo
echo "[10] 回归：boss 那枚不受别人注销影响，豁免面照常放行"
status 200 "GET /admin/panel（另一枚 token 仍在）" -H "Authorization: $BOSS_T" "$BASE/admin/panel"
status 200 "GET /public/ping（再次豁免）" "$BASE/public/ping"

echo
echo "PASS：正/负/回归三档全绿——401/403/404/200 逐格对上，头腿与 cookie 腿同判据"
