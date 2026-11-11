#!/usr/bin/env python
"""公开面痕迹闸：三类"读文档时看不见、装到用户手上才成立"的痕迹，命中即红并报 文件:行号。

存在理由：这三类缺陷靠人读文档抓不到，而它们的代价落在公开面与发布物上——
  1) 本机路径：`G:\\...`、`/g/...`、内网 IP 这类只在本机成立的地址，写进注释就等于
     指认一个用户中没有的东西（它会随模块源文件进发布包）。
  2) 赛事语境：申报／验收／组委会这类内部口径写进公开仓，读起来像给评审看的，不像给用户看的。
     注意"后端验收清单／验收项"是工程语义（换后端的最小清单），不在此列，所以判的是
     `黑客松`、`参赛`、`申报书`、`组委会`、`hackathon`、`验收第 N 条`、`验收实测` 这几个具体形状。
  3) 指认不存在的文件：文档里用反引号点出一个仓库里根本没有的文件（接口文件、示例文件名、
     跨仓路径），用户照抄就撞空。判据只收到"带扩展名的反引号 token"这一档：
     含 `*`/`?` 的形状写法跳过，纯 `xxx.mbt` 这种（既可能是后缀记法，也可能是依赖里的文件）跳过，
     带目录的 `a/b.mbt` 与 `md/sh/py/yml/mbti/json` 五类扩展名要求 basename 在仓内存在。

用法：
  python scripts/check_traces.py              # 扫整棵树（git 索引：已跟踪 + 未跟踪非 ignore）
  python scripts/check_traces.py --root DIR   # 扫指定目录（自检用，不依赖 git）
  python scripts/check_traces.py --selftest   # 正向（干净样本必须 0 命中）+ 负向（三类坏样本各必须红）

某行确实要留下这些字样（例如本脚本自己的判据表）：行尾加 `trace-check:allow`。
"""
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

SKIP_DIRS = {".git", ".mooncakes", "_build", "target", "__pycache__", ".github_tmp"}
SCAN_EXT = {".md", ".mbt", ".py", ".sh", ".yml", ".yaml"}
SCAN_NAMES = {"moon.mod", "moon.pkg", "moon.work"}
ALLOW = "trace-check:allow"
SELF = os.path.realpath(__file__)

LOCAL_PATH = re.compile(
    r"[A-Za-z]:[\\/](?:dev-tools|Users|mldong-bot)"
    r"|/[a-z]/dev-tools/"
    r"|\b192\.168\.\d{1,3}\.\d{1,3}\b"
)
COMPETITION = re.compile(r"黑客松|参赛|申报书|组委会|hackathon|验收第\s*\d+\s*条|验收实测")
FILE_REF = re.compile(r"`([A-Za-z0-9_.\-/*?/]+\.(?:md|sh|py|yml|yaml|mbti|json|mbt))`")


def inventory(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SCAN_NAMES or os.path.splitext(name)[1] in SCAN_EXT:
                out.append(os.path.join(dirpath, name))
    return out


def git_inventory(root):
    r = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=root, capture_output=True, text=True, encoding="utf-8",
    )
    if r.returncode != 0:
        return None
    files = [f.replace("\\", "/") for f in r.stdout.splitlines() if f]
    picked = []
    for f in files:
        parts = f.split("/")
        if any(p in SKIP_DIRS for p in parts[:-1]):
            continue
        if os.path.splitext(f)[1] in SCAN_EXT or os.path.basename(f) in SCAN_NAMES:
            picked.append(os.path.join(root, *parts))
    return picked


def scan(root, files):
    """返回 [(相对路径, 行号, 类别, 命中内容)]。第三类要全树 basename，所以先收一遍。"""
    pairs = [(f, os.path.relpath(f, root).replace("\\", "/")) for f in files]
    # 本脚本自己不扫（它带着判据里的字样），但它的名字要留在"仓内真实文件"集合里。
    basenames = {os.path.basename(r) for _, r in pairs}
    pairs = [(f, r) for f, r in pairs if os.path.realpath(f) != SELF]
    hits = []
    for path, r in pairs:
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(lines, 1):
            if ALLOW in line:
                continue
            for pat, label in ((LOCAL_PATH, "本机路径"), (COMPETITION, "赛事语境")):
                m = pat.search(line)
                if m:
                    hits.append((r, n, label, m.group(0)))
            for m in FILE_REF.finditer(line):
                tok = m.group(1)
                # 形状写法（`*_test.mbt`）与不带目录的 `xxx.mbt`（后缀记法／依赖里的文件）不判
                if "*" in tok or "?" in tok or ("/" not in tok and tok.endswith(".mbt")):
                    continue
                if os.path.basename(tok) not in basenames:
                    hits.append((r, n, "指认不存在文件", tok))
    return hits


def report(hits, limit=None):
    for r, n, label, token in (hits[:limit] if limit else hits):
        print("TRACE HIT %s:%d  %s  →  %s" % (r, n, label, token))
    if hits:
        print("TRACE CHECK FAIL: %d 处公开面痕迹（去掉痕迹，或在该行尾加 %s）" % (len(hits), ALLOW))


def main(argv):
    if "--selftest" in argv:
        return selftest()
    root = os.path.realpath(argv[argv.index("--root") + 1]) if "--root" in argv \
        else os.path.realpath(os.path.join(os.path.dirname(SELF), ".."))
    files = git_inventory(root) if "--root" not in argv else None
    files = files if files is not None else inventory(root)
    if not files:
        print("TRACE CHECK FAIL: 收到 0 个待扫文件（判据用错了档，不是树干净）")
        return 1
    hits = scan(root, files)
    report(hits)
    if hits:
        return 1
    print("TRACE CHECK PASS: %d 个公开面文件零痕迹（本机路径／赛事语境／指认不存在文件）" % len(files))
    return 0


def selftest():
    import tempfile
    bad = [
        ("docs/a.md", "判据来源是探针（`G:\\dev-tools\\tmp\\probe`，可复跑）\n"),
        ("docs/b.md", "参赛验收第 4 条要求的 README 可复现\n"),
        ("docs/c.md", "完整清单以包内的 `pkg.generated.mbti` 为准\n"),
        ("core/d.md", "见隔壁仓的 `../other/x.md`\n"),
    ]
    good = [
        ("docs/ok.md", "后端验收清单第 12 条只许一个时间源；形状写法是 `*_test.mbt`，"
                       "工装见 `scripts/gate.sh`，白盒档是 `_wbtest.mbt` 后缀\n"),
        ("core/ok2.md", "探针实测 8 路并发登录报 7 错（口径见 `docs/ok.md`）\n"),
        ("scripts/gate.sh", "# 跑一遍门禁；本仓文档引用它写作 `scripts/gate.sh`\n"),
    ]
    rc = 0
    with tempfile.TemporaryDirectory() as tmp:
        for rel, text in bad + good:
            p = os.path.join(tmp, rel.replace("/", os.sep))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w", encoding="utf-8").write(text)
        hits = {t: [h for h in scan(tmp, inventory(tmp)) if h[0] == t] for t, _ in bad}
        for t, _ in bad:
            if not hits[t]:
                print("SELFTEST FAIL: 坏样本 %s 没被报红" % t)
                rc = 1
            else:
                print("  负向 %s → %s（%s）" % (t, hits[t][0][2], hits[t][0][3]))
        clean = [h for h in scan(tmp, inventory(tmp)) if h[0] not in {t for t, _ in bad}]
        if clean:
            print("SELFTEST FAIL: 干净样本被误报 %s" % clean)
            rc = 1
        else:
            print("  正向：干净样本零命中")
    if rc == 0:
        print("SELFTEST PASS: 三类痕迹敢报红，工程语义（后端验收清单／`*_test.mbt`／仓内真实文件）不误报")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
