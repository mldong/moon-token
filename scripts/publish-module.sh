#!/usr/bin/env bash
# 按模块发布到 mooncakes：已发过就跳过，没发过才 publish（整条链可重入）。
#
# 为什么要有这一层（jeeflow-moon 2026-09-26 v0.1.13 实发事故的教训）：
#   store 刚 publish 完几秒，core 的"包体校验"要从注册表解析 mldong/moon-token-store@<新版本>，
#   而索引还没刷新 ⇒ 会报 "no version satisfies" 卡死；此时 store 已在注册表，重跑又撞重复发布。
#   ⇒ 每步前 moon update 刷索引，再"已在注册表就跳过"。
#   CLI 退出码不区分"真没发上去"和"上传后环节报错"，故发布后一律回查索引复核。
#
# 索引布局（moon 0.1.x 实测）：$MOON_HOME/registry/index/user/<user>/<mod>.index，
# 每行一个 JSON 对象，name 与 version 同行 ⇒ 可整行匹配。本机工具链是便携目录，故走 MOON_HOME。
#
# 用法：scripts/publish-module.sh <模块目录> <mooncakes 全名> [dry]
set -euo pipefail
dir="$1"; full="$2"; mode="${3:-run}"
user="${full%%/*}"; short="${full##*/}"
: "${MOON_HOME:?需要先 export MOON_HOME}"

ver=$(sed -nE 's/^version = "([^"]+)".*/\1/p' "$dir/moon.mod" | head -1)
[ -n "$ver" ] || { echo "!! $dir/moon.mod 读不到 version" >&2; exit 1; }

moon update >/dev/null 2>&1 || echo "   （moon update 失败，用现有索引继续）"
idx="$MOON_HOME/registry/index/user/$user/$short.index"

if [ "$mode" = "dry" ]; then
  echo "DRY：$full@$ver 索引命中=$([ -f "$idx" ] && grep -q "\"name\":\"$full\".*\"version\":\"$ver\"" "$idx" && echo yes || echo no)"
  exit 0
fi

if [ -f "$idx" ] && grep -q "\"name\":\"$full\".*\"version\":\"$ver\"" "$idx"; then
  echo "跳过：$full@$ver 已在注册表（重入安全）"
  exit 0
fi

echo "publish $full@$ver"
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
