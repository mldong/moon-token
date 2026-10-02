#!/usr/bin/env bash
# 把 docs/*.md 里每个 ```moonbit 代码块**逐字**灌进一个独立工程，真编译真跑。
# 存在理由：使用文档一旦不能编译，它就从"说明书"退化成"装饰"，
# 而且比没文档更糟——读者会以为是自己写错了。
#
# 判据按文件给：一个文件的所有 moonbit 块拼成一个包（块与块之间允许前后引用，
# 所以文档可以渐进式地写）。任一块编不过 / 任一用例失败 / 有警告 / 一个用例都没收集到，即整体红。
#
# 两种目标代次（DOCS_TARGET，默认 registry）：
#   registry —— 只依赖注册表已发布件（`moon add` 不带版本 ⇒ 解析到最新代次）。
#     这是"用户照文档敲能不能跑"的判据，必须在**发布之后**跑才有意义。
#   source —— 临时 workspace 的 members 直接指向本仓 store/ 与 core/，
#     判的是"文档与当前这棵树对不对得上"。发布**之前**只能用它：
#     trait 加方法这类破坏性变更，文档已经按新 API 写、注册表还是旧代次，
#     registry 模式在发版 tag 上必然红，而 CI 的检查阶段又是发布的前置 ⇒ 死锁。
#     （10-02 那道题就是这么撞上的：假绿窗口的反方向。）
set -euo pipefail
: "${MOON_HOME:?需要先 export MOON_HOME}"
cd "$(dirname "$0")/.."
# Windows 上 moon 是原生二进制，吃不进 Git Bash 的 /g/... 形式；pwd -W 给盘符路径，Linux 上没这个参数就退回 pwd
REPO=$(pwd -W 2>/dev/null || pwd)
TARGET="${DOCS_TARGET:-registry}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/moon-token-docs-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# source 模式要用的两个 pin：本仓当前版本号，以及 core 钉的 async 版本（不自己写死，免得漂）
if [ "$TARGET" = "source" ]; then
  VER=$(sed -nE 's/^version = "([^"]+)".*/\1/p' core/moon.mod | head -1)
  ASYNC=$(sed -nE 's/.*"moonbitlang\/async@([^"]+)".*/\1/p' core/moon.mod | head -1)
  [ -n "$VER" ] && [ -n "$ASYNC" ] || { echo "DOCS CHECK FAIL: 读不到 core/moon.mod 的 version 或 async pin" >&2; exit 1; }
  printf 'members = [\n  "%s/store",\n  "%s/core",\n  "%s/store-file",\n' \
    "$REPO" "$REPO" "$REPO" > "$WORK/moon.work"
fi

shopt -s nullglob
# 文档 + 三个**已发布模块**的 README：mooncakes 页面渲染的就是模块目录里那份，
# 它必须是自成一体的说明（包里没有仓库根 README，也没有 docs/）。
files=(docs/*.md core/README.md store/README.md store-file/README.md)
if [ ${#files[@]} -eq 0 ]; then
  echo "DOCS CHECK FAIL: docs/ 下一个文件都没有（要么补文档，要么把这条门禁摘掉，别留死格）" >&2
  exit 1
fi

check_pkg() {
  # $1=运行目录 $2=包选择子（registry 模式留空＝跑当前模块唯一的包；
  #    source 模式给相对目录，因为工作区里还挂着 store/core，不加选择子会把库的 61 条一起跑，
  #    那样"这份文档一个用例都没收到"的死格判据就永远看不见真相）$3=展示名
  local dir="$1" sel="$2" label="$3" test_log tests_n
  (
    cd "$dir"
    # 注意：source 模式下这些包共处一个 workspace，某个包解析不到依赖时会挂到**先跑到的那个**
    # 包名下报出来。红是真的红，归属要按输出里的包名（mldong/doccheck/...）自己核一遍。
    # 判据取 moon test 而不是 moon check：抽出来的是 _test.mbt，`moon check` 只看非测试源，
    # 会把这份 import 全判成 unused_package——那是判据用错了档，不是文档写错。
    # moon test 同时编译包与测试档，警告照样冒出来。
    test_log=$(moon test --target wasm $sel 2>&1)
    if printf '%s' "$test_log" | grep -q "Warning"; then
      printf '%s\n' "$test_log" | grep -B2 -A8 "Warning" | head -40
      echo "文档代码块有警告（$label）" >&2
      exit 1
    fi
    printf '%s\n' "$test_log" | tail -2
    printf '%s' "$test_log" | grep -q "failed: 0" || {
      echo "文档代码块有用例失败（$label）" >&2
      printf '%s\n' "$test_log" | head -60 >&2
      exit 1
    }
    tests_n=$(printf '%s' "$test_log" | sed -n 's/.*Total tests: \([0-9]*\).*/\1/p')
    [ "${tests_n:-0}" -gt 0 ] || {
      echo "文档代码块一个用例都没收集到（$label）——判死格，门禁不认空跑" >&2
      exit 1
    }
  ) || { echo "DOCS CHECK FAIL: $label" >&2; exit 1; }
}

checked=0
pkgs=()
for doc in "${files[@]}"; do
  # slug 取"路径去掉非字母数字"，这样 core/README.md 与 store/README.md 不会撞名
  slug=$(printf '%s' "$doc" | tr -cd 'a-z0-9')
  dir="$WORK/$slug"
  mkdir -p "$dir/src"
  echo "── $doc（目标代次：$TARGET）"
  python "$REPO/scripts/extract-docs.py" "$REPO/$doc" "$dir/src/${slug}_test.mbt"
  if [ "$TARGET" = "registry" ]; then
    printf 'name = "mldong/doccheck/%s"\nversion = "0.0.0"\n' "$slug" > "$dir/moon.mod"
    (
      cd "$dir"
      moon add mldong/moon-token > /dev/null
      moon add mldong/moon-token-store > /dev/null
      moon add mldong/moon-token-store-file > /dev/null
      # 抽出来的代码用了 async 才挂这个依赖：多引一个包对包本身是 unused_package，
      # 而本仓零警告口径下它就是错误（source 模式不用管，async 已在 moon.mod 的 import 里）
      if grep -q 'moonbitlang/async' src/moon.pkg; then
        moon add moonbitlang/async > /dev/null
      fi
    )
  else
    # workspace 成员之间不能用不带版本的 import（moon 会直接拒），所以照 core/moon.mod 写死当前代次
    printf 'name = "mldong/doccheck/%s"\nversion = "0.0.0"\nimport {\n  "mldong/moon-token@%s",\n  "mldong/moon-token-store@%s",\n  "mldong/moon-token-store-file@%s",\n  "moonbitlang/async@%s",\n}\n' \
      "$slug" "$VER" "$VER" "$VER" "$ASYNC" > "$dir/moon.mod"
    printf '  "./%s",\n' "$slug" >> "$WORK/moon.work"
  fi
  if [ "$TARGET" = "source" ]; then
    pkgs+=("$WORK|$slug/src|$doc")
  else
    pkgs+=("$dir||$doc")
  fi
done

if [ "$TARGET" = "source" ]; then
  # moon.work 必须一次写完整再开跑：成员表没收尾就检查，第一个包就会吃到 "unexpected token <EOF>"
  printf ']\n' >> "$WORK/moon.work"
fi

for entry in "${pkgs[@]}"; do
  rest="${entry%|*}"; label="${entry##*|}"; dir="${rest%%|*}"; sel="${rest#*|}"
  check_pkg "$dir" "$sel" "$label"
  checked=$((checked + 1))
done

echo "DOCS CHECK PASS：$checked 个文档文件的 moonbit 块全部真编译真跑（目标代次：$TARGET）"
