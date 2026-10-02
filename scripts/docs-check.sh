#!/usr/bin/env bash
# 把 docs/*.md 里每个 ```moonbit 代码块**逐字**灌进一个只依赖注册表已发布件的独立工程，
# 真编译真跑。存在理由：使用文档一旦不能编译，它就从"说明书"退化成"装饰"，
# 而且比没文档更糟——读者会以为是自己写错了。
#
# 判据按文件给：一个文件的所有 moonbit 块拼成一个包（块与块之间允许前后引用，
# 所以文档可以渐进式地写）。任一块编不过 / 任一用例失败 / 有警告 / 一个用例都没收集到，即整体红。
set -euo pipefail
: "${MOON_HOME:?需要先 export MOON_HOME}"
cd "$(dirname "$0")/.."
REPO=$(pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/moon-token-docs-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

shopt -s nullglob
# 文档 + 两个**已发布模块**的 README：mooncakes 页面渲染的就是模块目录里那份，
# 它必须是自成一体的说明（包里没有仓库根 README，也没有 docs/）。
files=(docs/*.md core/README.md store/README.md)
if [ ${#files[@]} -eq 0 ]; then
  echo "DOCS CHECK FAIL: docs/ 下一个文件都没有（要么补文档，要么把这条门禁摘掉，别留死格）" >&2
  exit 1
fi

checked=0
for doc in "${files[@]}"; do
  # slug 取"路径去掉非字母数字"，这样 core/README.md 与 store/README.md 不会撞名
  slug=$(printf '%s' "$doc" | tr -cd 'a-z0-9')
  dir="$WORK/$slug"
  mkdir -p "$dir/src"
  echo "── $doc"
  (
    cd "$dir"
    printf 'name = "mldong/doccheck/%s"\nversion = "0.0.0"\n' "$slug" > moon.mod
    python "$REPO/scripts/extract-docs.py" "$REPO/$doc" "$dir/src/${slug}_test.mbt"
    moon add mldong/moon-token > /dev/null
    moon add mldong/moon-token-store > /dev/null
    if grep -q 'moonbitlang/async' src/moon.pkg; then
      moon add moonbitlang/async > /dev/null
    fi
    # 判据取 moon test 而不是 moon check：抽出来的是 _test.mbt，`moon check` 只看非测试源，
    # 会把这份 import 全判成 unused_package——那是判据用错了档，不是文档写错。
    # moon test 同时编译包与测试档，警告照样冒出来。
    test_log=$(moon test --target wasm 2>&1)
    if printf '%s' "$test_log" | grep -q "Warning"; then
      printf '%s\n' "$test_log" | grep -B2 -A8 "Warning" | head -40
      echo "文档代码块有警告（$doc）" >&2
      exit 1
    fi
    printf '%s\n' "$test_log" | tail -2
    printf '%s' "$test_log" | grep -q "failed: 0" || {
      echo "文档代码块有用例失败（$doc）" >&2
      printf '%s\n' "$test_log" | head -60 >&2
      exit 1
    }
    tests_n=$(printf '%s' "$test_log" | sed -n 's/.*Total tests: \([0-9]*\).*/\1/p')
    [ "${tests_n:-0}" -gt 0 ] || {
      echo "文档代码块一个用例都没收集到（$doc）——判死格，门禁不认空跑" >&2
      exit 1
    }
  ) || { echo "DOCS CHECK FAIL: $doc" >&2; exit 1; }
  checked=$((checked + 1))
done

echo "DOCS CHECK PASS：$checked 个文档文件的 moonbit 块全部真编译真跑（对注册表已发布件）"
