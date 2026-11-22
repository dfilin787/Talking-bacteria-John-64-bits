#!/usr/bin/env python3

import io
import json
import os
import plistlib
import re
import struct
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = "https://api.github.com"

def remote_slug():
    url = subprocess.run(["git", "remote", "get-url", "origin"],
                         cwd=ROOT, capture_output=True, text=True).stdout.strip()
    match = re.search(r"github\.com[:/]([^/]+)/([^/.]+)", url)
    if not match:
        raise SystemExit("Не удалось разобрать origin")
    return match.group(1), match.group(2)

def token():
    result = subprocess.run(["git", "credential", "fill"], cwd=ROOT,
                            input="protocol=https\nhost=github.com\n\n",
                            capture_output=True, text=True, timeout=60)
    for line in result.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):]
    raise SystemExit("Нет сохранённых credentials")

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def fetch(path, auth, raw=False):
    request = urllib.request.Request(API + path)
    request.add_header("Authorization", "Bearer " + auth)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "talkingjohn-ci")
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=90) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        if raw and error.code in (301, 302, 303, 307, 308):
            location = error.headers.get("Location")
            if location:
                plain = urllib.request.Request(location)
                plain.add_header("User-Agent", "talkingjohn-ci")
                with urllib.request.urlopen(plain, timeout=300) as response:
                    return response.read()
        raise
    return data if raw else json.loads(data)

CPU_NAMES = {12: "armv7/armv7s (32-бит)", 0x0100000C: "arm64", 7: "i386", 0x01000007: "x86_64"}

def describe_macho(data):
    magic = data[:4]
    if magic == bytes.fromhex("cafebabe"):
        count = struct.unpack(">I", data[8:12])[0]
        arches = []
        for i in range(count):
            cpu = struct.unpack(">i", data[8 + 20 * i:12 + 20 * i])[0]
            arches.append(CPU_NAMES.get(cpu, "cputype %d" % cpu))
        return "fat: " + ", ".join(arches), arches
    if magic in (bytes.fromhex("cffaedfe"), bytes.fromhex("cefaedfe")):
        cpu = struct.unpack("<I", data[4:8])[0]
        name = CPU_NAMES.get(cpu, "cputype %d" % cpu)
        return "thin: " + name, [name]
    return "не Mach-O (magic %s)" % magic.hex(), []

def main():
    owner, repo = remote_slug()
    auth = token()

    out_dir = os.path.join(ROOT, "out")
    if "--out" in sys.argv:
        out_dir = sys.argv[sys.argv.index("--out") + 1]
    os.makedirs(out_dir, exist_ok=True)

    runs = fetch("/repos/%s/%s/actions/runs?per_page=10&status=success" % (owner, repo), auth)
    if not runs.get("workflow_runs"):
        raise SystemExit("Успешных сборок пока нет")
    run = runs["workflow_runs"][0]
    print("Сборка #%s, коммит %s" % (run["run_number"], run["head_sha"][:7]))

    artifacts = fetch("/repos/%s/%s/actions/runs/%s/artifacts" % (owner, repo, run["id"]), auth)
    if not artifacts.get("artifacts"):
        raise SystemExit("Артефактов нет")

    problems = []
    for artifact in artifacts["artifacts"]:
        print("\nАртефакт: %s (%.1f МБ)" % (artifact["name"], artifact["size_in_bytes"] / 1048576))
        blob = fetch("/repos/%s/%s/actions/artifacts/%s/zip" % (owner, repo, artifact["id"]),
                     auth, raw=True)
        archive = zipfile.ZipFile(io.BytesIO(blob))
        for name in archive.namelist():
            target = os.path.join(out_dir, os.path.basename(name))
            with open(target, "wb") as fh:
                fh.write(archive.read(name))
            print("  сохранён: %s" % target)

            if not name.endswith(".ipa"):
                continue
            ipa = zipfile.ZipFile(io.BytesIO(archive.read(name)))
            apps = {n.split("/")[1] for n in ipa.namelist() if n.startswith("Payload/") and n.count("/") >= 2}
            app = sorted(apps)[0] if apps else None
            if not app:
                problems.append("в IPA нет Payload/*.app")
                continue
            prefix = "Payload/%s/" % app
            exec_name = app[:-4]
            plist_data = ipa.read(prefix + "Info.plist")
            plist = plistlib.loads(plist_data)
            exec_name = plist.get("CFBundleExecutable", exec_name)
            binary = ipa.read(prefix + exec_name)
            description, arches = describe_macho(binary)
            print("  бандл: %s" % app)
            print("  бинарник: %.1f МБ, %s" % (len(binary) / 1048576, description))
            print("  MinimumOSVersion: %s" % plist.get("MinimumOSVersion"))
            print("  arm64 в требованиях: %s" % plist.get("UIRequiredDeviceCapabilities"))
            if not any("arm64" in a for a in arches):
                problems.append("в бинарнике нет arm64")
            if any("32-бит" in a for a in arches):
                problems.append("остались 32-битные слайсы")

            names = ipa.namelist()
            clips = {n[len(prefix):].split("/")[1] for n in names
                     if n.startswith(prefix + "Animations/") and n.count("/") >= 4}
            frames = [n for n in names if n.startswith(prefix + "Animations/") and n.endswith(".png")]
            sounds = [n for n in names if n.startswith(prefix + "Sounds/") and n.endswith(".wav")]
            ui = [n for n in names if n.startswith(prefix + "UI/") and n.endswith(".png")]
            print("  клипов: %d, кадров: %d, wav: %d, UI: %d" % (len(clips), len(frames), len(sounds), len(ui)))
            for required in ("talk", "laugh", "needle", "eatPinkDonut"):
                if required not in clips:
                    problems.append("нет клипа %s" % required)
            if len(frames) != 504:
                problems.append("кадров %d, ожидалось 504" % len(frames))
            if len(sounds) != 16:
                problems.append("wav %d, ожидалось 16" % len(sounds))
            if not any(n.endswith("Assets.car") for n in names):
                problems.append("нет Assets.car (иконка)")

    print()
    if problems:
        print("ПРОБЛЕМЫ:")
        for problem in problems:
            print("  ✗", problem)
        return 1
    print("IPA проверен: arm64, ассеты на месте.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
