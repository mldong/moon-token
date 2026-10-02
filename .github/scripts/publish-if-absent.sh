#!/usr/bin/env bash
# 按模块发布到 mooncakes：**已发过就跳过**，没发过才 publish（整条链可重入）。
#
# 为什么要有这一层（2026-09-26 jeeflow-moon v0.1.13 实发事故，本仓 0.1.1 也撞过同一类）：
#   store 刚 publish 完几秒，core 的"包体校验"要从 registry 解析
#   `mldong/moon-token-store@<新版本>`，而索引还没刷新 ⇒ 报 "no version satisfies" 卡死整条链；
#   此时 store 已在注册表，重跑又撞重复发布。
#   ⇒ 每步前 `moon update` 刷索引，再"已在注册表就跳过"。
#   CLI 退出码不区分"真没发上去"和"上传后环节报错"，故发布后一律回查索引复核。
#
# 索引布局（moon 0.1.x 实测）：$MOON_HOME/registry/index/user/<user>/<mod>.index，
# 每行一个 JSON 对象，name 与 version 同行 ⇒ 可整行匹配。CI 上 MOON_HOME 就是 ~/.moon。
#
# 用法：publish-if-absent.sh <模块目录> <mooncakes 全名> [dry]
#   dry＝只走到"该发"这一支并打印，不真上传（给守卫本身做判据用，CI 不用它）
set -euo pipefail

dir="$1"
full="$2"                        # 例 mldong/moon-token-store
mode="${3:-run}"
user="${full%%/*}"
short="${full##*/}"
: "${MOON_HOME:=$HOME/.moon}"

ver=$(sed -nE 's/^version = "([^"]+)".*/\1/p' "$dir/moon.mod" | head -1)
[ -n "$ver" ] || { echo "!! $dir/moon.mod 读不到 version" >&2; exit 1; }

moon update >/dev/null 2>&1 || echo "   （moon update 失败，用现有索引继续）"
idx="$MOON_HOME/registry/index/user/$user/$short.index"

if [ -f "$idx" ] && grep -q "\"name\":\"$full\".*\"version\":\"$ver\"" "$idx"; then
  echo "跳过：$full@$ver 已在注册表（重入安全）"
  exit 0
fi

echo "该发：$full@$ver 不在注册表"
if [ "$mode" = "dry" ]; then
  echo "DRY：到此为止，不执行 moon publish"
  exit 0
fi

( cd "$dir" && moon publish ) || true

if ! { [ -f "$idx" ] && grep -q "\"name\":\"$full\".*\"version\":\"$ver\"" "$idx"; }; then
  moon update >/dev/null 2>&1 || true
  if [ -f "$idx" ] && grep -q "\"name\":\"$full\".*\"version\":\"$ver\"" "$idx"; then
    echo "  ✅ 回查索引：其实已发上去（CLI 报错发生在上传之后的环节）"
  else
    echo "  ❌ 索引里没有 $full@$ver —— 这次真没发出去，看上面的 moon publish 输出" >&2
    exit 1
  fi
fi
