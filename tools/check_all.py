#!/usr/bin/env python3

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKS = ["verify_project.py", "check_swift_refs.py", "check_text.py", "test_animation_logic.py"]

def main():
    failed = []
    for script in CHECKS:
        print("=" * 60)
        print(script)
        print("=" * 60)
        result = subprocess.run([sys.executable, os.path.join(HERE, script)])
        if result.returncode != 0:
            failed.append(script)
        print()
    if failed:
        print("Провалены проверки: %s" % ", ".join(failed))
        return 1
    print("Все проверки пройдены.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
