# -*- coding: utf-8 -*-
"""把一份 markdown 里的 ```moonbit 块逐字抽成一个源文件，并按实际引用生成 moon.pkg。

被 scripts/docs-check.sh 调用。多引一个包就会吃 unused_package 警告，而本仓口径是零警告，
所以 import 表按代码里真出现过的 `@别名.` 现算，不写死。
"""
import io
import re
import sys

# (别名, moon.pkg 里的路径, 是否需要显式别名)
PACKAGES = [
    ("app", "mldong/moon-token/app", None),
    ("domain", "mldong/moon-token/domain", None),
    ("style", "mldong/moon-token/style", None),
    ("guard", "mldong/moon-token/guard", None),
    ("event", "mldong/moon-token/event", None),
    ("port", "mldong/moon-token-store/port", None),
    ("mem", "mldong/moon-token-store/memory", "@mem"),
    ("file", "mldong/moon-token-store-file/file", None),
    ("fs", "moonbitlang/async/fs", None),
    ("mbguard", "mldong/moon-token-moonback/guard", "@mbguard"),
    ("mb", "moonbitlang/moonback", "@mb"),
]


def extract(md_path, out_path):
    src = io.open(md_path, encoding="utf-8").read()
    blocks = re.findall(r"```moonbit\n(.*?)\n```", src, re.S)
    if not blocks:
        raise SystemExit("no moonbit block in " + md_path)

    with io.open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("// 本文件由 scripts/docs-check.sh 从文档逐字抽出，只为验证“照着敲就能跑”\n")
        for index, block in enumerate(blocks):
            f.write("\n// ---- block %d ----\n" % (index + 1))
            f.write(block.rstrip("\n") + "\n")

    code = "\n".join(blocks)
    # 抽出来的代码全在 *_test.mbt 里，而这个包没有非测试源 ⇒ import 必须挂 `for "test"`，
    # 否则普通 import 块对包本身是"未使用"，会吃一片 unused_package 假警告。
    entries = []
    used = 0
    for alias, path, explicit in PACKAGES:
        if ("@" + alias + ".") in code:
            entry = '  "' + path + '"'
            if explicit:
                entry += " " + explicit
            entries.append(entry + ",")
            used += 1
    if "async" in code:
        entries.append('  "moonbitlang/async",')
    lines = ["import {"] + entries + ['} for "test"']
    pkg = out_path.rsplit("/", 1)[0] + "/moon.pkg"
    with io.open(pkg, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("blocks=%d imports=%d async=%s" % (len(blocks), used, "async" in code))


if __name__ == "__main__":
    extract(sys.argv[1], sys.argv[2])
