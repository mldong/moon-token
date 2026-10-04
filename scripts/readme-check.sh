#!/usr/bin/env bash
# 把 README「最小用法」那段 moonbit 代码**逐字抽出**灌进一个独立工程，编译 + 跑一次。
# 判的是参赛验收第 4 条"README 可复现"：
# 文档写的形状必须就是用户 `moon add` 之后能直接抄进去编译的东西。
#
# 两种目标代次（DOCS_TARGET，默认 registry），与 scripts/docs-check.sh 同一套理由：
#   registry —— 对注册表已发布件，判"用户今天照 README 敲能不能跑"，发布之后跑才有意义。
#   source  —— 临时 workspace 指向本仓 store/ 与 core/，判"README 与当前这棵树对不对得上"；
#     发版 tag 的检查阶段只能用这一支，否则破坏性变更时它会必然红，而检查红 ⇒ 不发布 ⇒ 死锁。
set -euo pipefail
: "${MOON_HOME:?需要先 export MOON_HOME}"
cd "$(dirname "$0")/.."
REPO=$(pwd -W 2>/dev/null || pwd)
TARGET="${DOCS_TARGET:-registry}"   # 与 docs-check 共用一个旋钮：一个开关同时切两支，免得出现"一半一半"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/moon-token-readme-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [ "$TARGET" = "source" ]; then
  VER=$(sed -nE 's/^version = "([^"]+)".*/\1/p' core/moon.mod | head -1)
  ASYNC=$(sed -nE 's/.*"moonbitlang\/async@([^"]+)".*/\1/p' core/moon.mod | head -1)
  [ -n "$VER" ] && [ -n "$ASYNC" ] || { echo "README CHECK FAIL: 读不到 core/moon.mod 的 version 或 async pin" >&2; exit 1; }
fi

cd "$WORK"
moon new readme_check >/dev/null 2>&1
cd readme_check
if [ "$TARGET" = "registry" ]; then
  moon add mldong/moon-token >/dev/null
  moon add mldong/moon-token-store >/dev/null
  moon add moonbitlang/async >/dev/null
  RUN_DIR="$WORK/readme_check"
  RUN_SEL=""
else
  printf 'members = [\n  "%s/store",\n  "%s/core",\n  "./readme_check",\n]\n' "$REPO" "$REPO" > "$WORK/moon.work"
  printf 'name = "mldong/readme_check"\nversion = "0.0.0"\nimport {\n  "mldong/moon-token@%s",\n  "mldong/moon-token-store@%s",\n  "moonbitlang/async@%s",\n}\n' \
    "$VER" "$VER" "$ASYNC" > "$WORK/readme_check/moon.mod"
  RUN_DIR="$WORK"
  RUN_SEL="./readme_check"
fi

python - "$REPO/README.md" <<'PY'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
code = re.search(r'## 最小用法\s+```moonbit\n(.*?)\n```', src, re.S).group(1)
lines = [l for l in code.split('\n') if l.strip() and not l.strip().startswith('//')]
decl, stmt, depth, in_decl = [], [], 0, False
seen_brace = False
for l in lines:
    st = l.strip()
    # 顶层声明要留在函数体外；其余都是"一次流程里的语句"。
    # 认头一行就够：MoonBit 的这些块都以关键字开头，块内行不可能撞到。
    if not in_decl and (
        st.startswith('pub(all) struct') or st.startswith('struct ')
        or st.startswith('impl ') or st.startswith('pub impl')
        or st.startswith('extend ') or st.startswith('pub extend')
        or st.startswith('fn ') or st.startswith('pub fn ')
    ):
        in_decl, depth, seen_brace = True, 0, False
    if in_decl:
        decl.append(l)
        depth += l.count('{') - l.count('}')
        seen_brace = seen_brace or '{' in l
        # 多行声明的头一行没有 '{'（`pub impl ... with fn name(` 就是这种），
        # 所以必须"见过花括号且闭合"才算块结束，否则声明被拆成语句
        if seen_brace and depth == 0:
            in_decl = False
    else:
        stmt.append('  ' + l)
if 'let route_guard' not in code and 'guard' not in code:
    raise SystemExit('README 段落抽取异常：没抓到守卫示例')
body = '\n'.join(stmt)
with io.open('readme_check_test.mbt', 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(decl) + '\n\n'
            + 'async fn readme_flow() -> String {\n' + body + '\n  login_id\n}\n\n'
            + 'async test "README 最小用法逐字抽出：对注册表已发布件可真编译真跑" {\n'
            + '  assert_eq(readme_flow(), "u1")\n}\n')
with io.open('moon.pkg', 'w', encoding='utf-8', newline='\n') as f:
    # 抽出来的代码全在 *_test.mbt 里，而这个包没有非测试源 ⇒ import 必须挂 `for "test"`。
    # 挂在普通 import 块上，每个别名对"包本身"都是未使用 ⇒ 一片 unused_package 假警告。
    # （docs-check.sh 同一形状，那边已经踩过并写进注释了。）
    # import 表按代码里**真出现过**的 @别名 现算，不写死：多引一个包对包本身就是 unused_package，
    # 而本仓零警告口径下它是错误——写死的那版正是"README 明明没用 style 却一直引它"。
    entries = []
    for alias, path in (
        ('app', 'mldong/moon-token/app'),
        ('style', 'mldong/moon-token/style'),
        ('guard', 'mldong/moon-token/guard'),
        ('port', 'mldong/moon-token-store/port'),
        ('mem', 'mldong/moon-token-store/memory'),
    ):
        if ('@' + alias + '.') in code:
            entries.append('  "%s" @%s,' % (path, alias))
    if not entries:
        raise SystemExit('README 抽取异常：代码块里一个库别名都没用到')
    f.write('import {\n' + '\n'.join(entries) + '\n  "moonbitlang/async",\n} for "test"\n')
PY

cd "$RUN_DIR"
log=$(moon test --target wasm $RUN_SEL 2>&1) || true
printf '%s\n' "$log" | tail -3
# 判据与 scripts/docs-check.sh 完全对齐：**零警告 + 0 failed** 才算过。
# 早先这里只断言 "failed: 0"，理由是"抽出来的代码天然带 unused_package 一类噪音"——
# 那个前提是错的：噪音来自脚本自己写死的 import 表（多引一个包对包本身就是 unused_package），
# 而不是来自 README 的内容。把 import 交给 docs-check 那套"按代码里真出现过的 @别名 现算"之后，
# README 段落的警告就是**真警告**（10-03 实测：`let route_guard = ...` 赋值后没用，
# 这条一直静默通过，门禁却一直在报"零警告"，属于判据用错了档）。
# 本仓对外口径是零警告，README 是用户第一个入口，不该例外。
if printf '%s' "$log" | grep -q "Warning"; then
  printf '%s\n' "$log" | grep -B2 -A8 "Warning" | head -40
  echo "README 代码块有警告（目标代次：$TARGET）——零警告口径下这是错误" >&2
  exit 1
fi
if printf '%s' "$log" | grep -q "failed: 0"; then
  echo "README CHECK PASS（目标代次：$TARGET，零警告）"
else
  echo "README CHECK FAIL（目标代次：$TARGET）" >&2
  exit 1
fi
