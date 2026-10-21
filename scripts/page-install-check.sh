#!/usr/bin/env bash
# 页面安装面闸：每个已发布模块的 README（＝mooncakes 页面正文）自己给的 `moon add` 清单，
# 必须够把它自己给的代码块编译起来。docs-check.sh 会自补全家族依赖，所以"页面少写一条 add"
# 那道闸永远不红——这条专治它。
#
# 用法：
#   bash scripts/page-install-check.sh              # registry（默认）：真按页面清单装 + 真编译
#   PAGE_MODE=source bash scripts/page-install-check.sh   # 发版前：静态差集判这棵树的页面文本
#
# 判据三档：页面没给安装清单＝红；清单缺代码块引用的模块＝红；registry 档真编译有警告/无用例＝红。
set -euo pipefail
export MOON_HOME="${MOON_HOME:-$HOME/.moon}"
export PYTHONIOENCODING=utf-8
REPO=$(cd "$(dirname "$0")/.." && pwd)
MODE="${PAGE_MODE:-registry}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 发布清单现读发布链，不写死模块数
mapfile -t PAIRS < <(grep -oE 'publish-if-absent\.sh +[a-z0-9_-]+ +mldong/[a-z0-9_-]+' \
  "$REPO/.github/workflows/publish.yml" | awk '{print $2 "|" $3}')
[ ${#PAIRS[@]} -gt 0 ] || { echo "PAGE CHECK FAIL: 从 publish.yml 抽不到发布清单" >&2; exit 1; }

fails=0
for pair in "${PAIRS[@]}"; do
  dir="${pair%|*}"; self="${pair#*|}"
  readme="$REPO/$dir/README.md"
  [ -f "$readme" ] || { echo "FAIL $self: 没有 $dir/README.md"; fails=$((fails + 1)); continue; }

  # 页面给的 moon add 清单：取所有**非 moonbit** 围栏里的 `moon add` 行，抽全部 <org>/<mod>
  # （清单既可能写 ```bash 也可能写 ```text，还可能一行并列好几件；```moonbit 里那些是注释，不算）
  # 注释里可能出现 a/b 形状（如 "async test/fn"）：先把 `#` 之后剥掉，别把说明文字当包名。
  # 10-22 0.1.15 的消费者腿就是被这句注释误伤：moon add test/fn 装不到。
  s_add=$(awk '/^```/{ if (inb) { inb = 0 } else { inb = 1; lang = $0 } ; next }
                inb && lang !~ /moonbit/ { print }' "$readme" \
    | grep -E '^[[:space:]]*moon add' | sed -E 's/[[:space:]]+#.*$//' \
    | grep -oE '[a-z0-9_-]+/[a-z0-9_-]+' | sort -u || true)

  if [ -z "$s_add" ]; then
    echo "FAIL $self: 页面没给任何 \`moon add\` 清单（新用户照页面装不起来）"
    fails=$((fails + 1)); continue
  fi

  # 页面代码块实际引用到哪些模块：交给抽块工装生成的 moon.pkg（它按真引用生成，不靠人念）
  slug=$(printf '%s' "$dir-README.md" | tr -cd 'a-z0-9')
  mkdir -p "$WORK/$slug/src"
  python "$REPO/scripts/extract-docs.py" "$readme" "$WORK/$slug/src/${slug}_test.mbt" >/dev/null
  s_pkg=$(grep -oE '"[a-z0-9_-]+/[a-z0-9_-]+' "$WORK/$slug/src/moon.pkg" \
    | tr -d '"' | sort -u || true)
  # 只看真需要 `moon add` 的模块：moonbitlang/core 是标准库，随工具链来，不用装
  need=$(printf '%s\n' "$s_pkg" | grep -vE '^moonbitlang/core$' | sort -u || true)
  missing=$(comm -23 <(printf '%s\n' "$need") <(printf '%s\n' "$s_add" | sort -u))

  if [ -n "$missing" ]; then
    echo "FAIL $self: 代码块引用了页面没让装的模块 ⇒ $(printf '%s' "$missing" | tr '\n' ' ')"
    echo "     页面清单是：$(printf '%s' "$s_add" | tr '\n' ' ')"
    fails=$((fails + 1)); continue
  fi

  if [ "$MODE" = "source" ]; then
    echo "ok $self: 页面清单覆盖代码块引用（$dir，静态档）"
    continue
  fi

  # registry 档：只按页面给的清单装，真编译真跑——这条才是"用户今天照页面敲"的证据
  pkg="$WORK/inst-$slug"
  mkdir -p "$pkg/src"
  printf 'name = "mldong/pageinstall/%s"\nversion = "0.0.0"\n' "$slug" > "$pkg/moon.mod"
  cp "$WORK/$slug/src/"* "$pkg/src/"
  (
    cd "$pkg"
    moon update > /dev/null
    while read -r dep; do
      [ -n "$dep" ] || continue
      # 本家自己就是被装的那件；MoonBit 的传递依赖不自动可见，缺一条就会在 check 阶段报 not imported
      moon add "$dep" > /dev/null || { echo "FAIL $self: moon add $dep 装不到"; exit 1; }
    done <<< "$s_add"
    log=$(moon test --target wasm --no-render 2>&1)
    printf '%s' "$log" | grep -q "Warning" && { printf '%s\n' "$log" | grep -B2 -A6 Warning | head -30; echo "FAIL $self: 页面代码块有警告"; exit 1; }
    printf '%s' "$log" | grep -q "failed: 0" || { printf '%s\n' "$log" | head -40; echo "FAIL $self: 页面代码块跑红"; exit 1; }
    n=$(printf '%s' "$log" | sed -n 's/.*Total tests: \([0-9]*\).*/\1/p')
    [ "${n:-0}" -gt 0 ] || { echo "FAIL $self: 一个用例都没收集到（死格）"; exit 1; }
    echo "ok $self: 照页面清单装成功，代码块真编译真跑（$dir，Total tests: $n）"
  ) || fails=$((fails + 1))
done

# 反向判据自查：清单里装了但代码块没引用的件不作红（那是"按需引"，页面本来就是清单式写法）
if [ "$fails" -gt 0 ]; then
  echo "PAGE INSTALL CHECK FAIL：$fails 个模块的页面安装面不自洽（目标档：$MODE）" >&2
  exit 1
fi
echo "PAGE INSTALL CHECK PASS：${#PAIRS[@]} 个发布模块的页面清单都覆盖自己的代码块（目标档：$MODE）"
