#!/usr/bin/env python3

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTENSIONS = {".swift", ".md", ".yml", ".yaml", ".py", ".h", ".mm", ".plist", ".json"}
SKIP_DIRS = {"Vendor", ".git", "Assets", "build", "out", "Payload"}

RANGES = [
    (0x4E00, 0x9FFF, "CJK иероглифы"),
    (0x3040, 0x30FF, "кана"),
    (0xAC00, 0xD7AF, "хангыль"),
    (0x3000, 0x303F, "CJK пунктуация"),
    (0xFF00, 0xFFEF, "полноширинные формы"),
]

def classify(char):
    code = ord(char)
    for low, high, label in RANGES:
        if low <= code <= high:
            return label
    if code in (0x200B, 0x200C, 0x200D, 0xFEFF, 0x00AD):
        return "невидимый символ U+%04X" % code
    if code < 32 and char not in "\n\r\t":
        return "управляющий U+%04X" % code
    return None

def main():
    problems = []
    checked = 0
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if os.path.splitext(name)[1].lower() not in EXTENSIONS:
                continue
            path = os.path.join(base, name)
            checked += 1
            with open(path, encoding="utf-8", errors="replace") as fh:
                for lineno, line in enumerate(fh, 1):
                    for column, char in enumerate(line, 1):
                        label = classify(char)
                        if label:
                            problems.append("%s:%d:%d — %s (%r)" % (
                                os.path.relpath(path, ROOT), lineno, column, label, char))

    print("Проверено файлов: %d" % checked)
    if problems:
        print("Посторонние символы:")
        for problem in problems[:40]:
            print("  ✗", problem)
        return 1
    print("Посторонних символов нет.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
