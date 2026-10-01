#!/usr/bin/env bash
# 把 README「最小用法」那段 moonbit 代码**逐字抽出**灌进一个只依赖注册表已发布件的
# 独立工程，编译 + 跑一次。判的是参赛验收第 4 条"README 可复现"：
# 文档写的形状必须就是用户 `moon add` 之后能直接抄进去编译的东西。
set -euo pipefail
: "${MOON_HOME:?需要先 export MOON_HOME}"
cd "$(dirname "$0")/.."
REPO=$(pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/moon-token-readme-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
moon new readme_check >/dev/null 2>&1
cd readme_check
moon add mldong/moon-token >/dev/null
moon add mldong/moon-token-store >/dev/null
moon add moonbitlang/async >/dev/null

python - "$REPO/README.md" <<'PY'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
code = re.search(r'## 最小用法\s+```moonbit\n(.*?)\n```', src, re.S).group(1)
lines = [l for l in code.split('\n') if l.strip() and not l.strip().startswith('//')]
decl, stmt, depth, in_decl = [], [], 0, False
for l in lines:
    st = l.strip()
    if not in_decl and (st.startswith('pub(all) struct') or st.startswith('impl ')):
        in_decl, depth = True, 0
    if in_decl:
        decl.append(l)
        depth += l.count('{') - l.count('}')
        if depth == 0:
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
    f.write('import {\n'
            '  "mldong/moon-token/app" @app,\n'
            '  "mldong/moon-token/style" @style,\n'
            '  "mldong/moon-token/guard" @guard,\n'
            '  "mldong/moon-token-store/port" @port,\n'
            '  "mldong/moon-token-store/memory" @mem,\n'
            '}\n\n'
            'import {\n  "moonbitlang/async",\n} for "test"\n')
PY

moon test 2>&1 | tail -3 | grep -q "failed: 0" && echo "README CHECK PASS（对注册表已发布件）" || { echo "README CHECK FAIL"; moon test; exit 1; }
