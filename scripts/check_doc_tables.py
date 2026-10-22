import re
import sys
from pathlib import Path


def table_errors(text):
    lines = text.splitlines()
    errors = []
    fence = None
    in_table = False
    identifiers = set()
    index = 0
    while index < len(lines):
        line = lines[index]
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
            index += 1
            continue
        if marker:
            fence = marker[1]
            in_table = False
            index += 1
            continue
        if not re.match(r"^ {0,3}\|", line):
            in_table = False
            index += 1
            continue
        following = lines[index + 1].strip() if index + 1 < len(lines) else ""
        cells = following.strip("|").split("|")
        if following.startswith("|") and all(re.fullmatch(r"\s*:?-+:?\s*", cell) for cell in cells):
            in_table = True
            identifiers = set()
            index += 2
            continue
        if not in_table:
            errors.append((index + 1, "table row has no contiguous header and delimiter"))
        else:
            identifier = line.strip().split("|", 2)[1].strip()
            if re.fullmatch(r"\d+(?:\.\d+)*", identifier):
                if identifier in identifiers:
                    errors.append((index + 1, "duplicate row identifier: " + identifier))
                identifiers.add(identifier)
        index += 1
    return errors


def main(paths):
    if not paths:
        print("usage: check_doc_tables.py <markdown> ...", file=sys.stderr)
        return 2
    count = 0
    for path in paths:
        for line, message in table_errors(Path(path).read_text(encoding="utf-8")):
            print("{}:{}: {}".format(path, line, message), file=sys.stderr)
            count += 1
    if count:
        print("DOC TABLE CHECK FAIL: {} errors".format(count), file=sys.stderr)
        return 1
    print("DOC TABLE CHECK PASS: {} files".format(len(paths)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
