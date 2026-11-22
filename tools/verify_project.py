#!/usr/bin/env python3

import json
import os
import plistlib
import re
import sys
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "TalkingJohn", "Sources")
ASSETS = os.path.join(ROOT, "Assets")

problems = []
notes = []

def fail(message):
    problems.append(message)

def read_sources():
    texts = {}
    for name in sorted(os.listdir(SRC)):
        if name.endswith(".swift"):
            with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                texts[name] = fh.read()
    return texts

def check_clips(texts):
    joined = "\n".join(texts.values())
    declared = re.search(r"static let all: \[String\] = \[(.*?)\]", joined, re.S)
    if not declared:
        fail("ClipName.all не найден")
        return
    body = declared.group(1)
    names = set(re.findall(r'"([^"]+)"', body))
    for const in re.findall(r"static let (\w+) = \"([^\"]+)\"", joined):
        names.add(const[1])
    for array in re.findall(r"static let (?:laugh|crazy|eat) = \[([^\]]+)\]", joined):
        names.update(re.findall(r'"([^"]+)"', array))

    on_disk = set(os.listdir(os.path.join(ASSETS, "Animations")))
    missing = sorted(names - on_disk)
    unused = sorted(on_disk - names)
    if missing:
        fail("клипы объявлены, но отсутствуют на диске: %s" % ", ".join(missing))
    if unused:
        notes.append("папки не используются кодом: %s" % ", ".join(unused))

    total = 0
    for clip in sorted(on_disk):
        frames = [f for f in os.listdir(os.path.join(ASSETS, "Animations", clip)) if f.endswith(".png")]
        if not frames:
            fail("пустой клип: %s" % clip)
            continue
        expected = ["%04d.png" % i for i in range(len(frames))]
        if sorted(frames) != expected:
            fail("нумерация кадров сбита в %s" % clip)
        total += len(frames)
    notes.append("клипов: %d, кадров: %d" % (len(on_disk), total))

def check_sounds(texts):
    joined = "\n".join(texts.values())
    enum_block = re.search(r"enum Effect: String, CaseIterable \{(.*?)\n    \}", joined, re.S)
    if not enum_block:
        fail("SoundBank.Effect не найден")
        return
    body = enum_block.group(1)
    names = set()
    for line in body.splitlines():
        line = line.strip()
        match = re.match(r"case (\w+)(?: = \"([^\"]+)\")?", line)
        if match:
            names.add(match.group(2) or match.group(1))
    on_disk = {os.path.splitext(f)[0] for f in os.listdir(os.path.join(ASSETS, "Sounds")) if f.endswith(".wav")}
    missing = sorted(names - on_disk)
    if missing:
        fail("звуки объявлены, но файлов нет: %s" % ", ".join(missing))
    unused = sorted(on_disk - names)
    if unused:
        notes.append("неиспользуемые WAV (дубли оригинала): %s" % ", ".join(unused))
    for name in sorted(names & on_disk):
        with wave.open(os.path.join(ASSETS, "Sounds", name + ".wav")) as handle:
            if handle.getnframes() == 0:
                fail("пустой WAV: %s" % name)
    notes.append("звуков задействовано: %d" % len(names & on_disk))

def check_ui_images(texts):
    joined = "\n".join(texts.values())
    referenced = set(re.findall(r'uiImage\("([^"]+)"\)', joined))
    for match in re.finditer(r'\((\d+)\.\.\.(\d+)\)\.compactMap \{ uiImage\("([A-Za-z0-9_-]+)\\\(', joined):
        low, high, prefix = int(match.group(1)), int(match.group(2)), match.group(3)
        referenced.discard(prefix + "\\($0)")
        for i in range(low, high + 1):
            referenced.add("%s%d" % (prefix, i))
    referenced = {n for n in referenced if "\\" not in n}
    table = re.findall(r'configureItem\([^,]+, image: "([^"]+)", action: #selector\((\w+)\)', joined)
    for asset, selector in table:
        referenced.add(asset)
        if "func " + selector not in joined:
            fail("селектор %s из configureItem не реализован" % selector)
    notes.append("кнопок предметов: %d" % len(table))
    on_disk = {os.path.splitext(f)[0] for f in os.listdir(os.path.join(ASSETS, "UI"))}
    on_disk_base = {n.replace("@2x", "") for n in on_disk}
    missing = sorted(n for n in referenced if n not in on_disk and n not in on_disk_base)
    if missing:
        fail("картинки интерфейса не найдены: %s" % ", ".join(missing))
    notes.append("UI-картинок в коде: %d" % len(referenced))

def check_balance(texts):
    for name, text in texts.items():
        stripped = re.sub(r'"(?:[^"\\]|\\.)*"', '""', text)
        stripped = re.sub(r"//[^\n]*", "", stripped)
        for opener, closer in (("{", "}"), ("(", ")"), ("[", "]")):
            if stripped.count(opener) != stripped.count(closer):
                fail("%s: несбалансированные %s%s (%d/%d)" % (
                    name, opener, closer, stripped.count(opener), stripped.count(closer)))

def check_plist():
    path = os.path.join(ROOT, "TalkingJohn", "Info.plist")
    with open(path, "rb") as fh:
        plist = plistlib.load(fh)
    required = ["CFBundleIdentifier", "CFBundleExecutable", "UILaunchScreen",
                "UIApplicationSceneManifest", "NSMicrophoneUsageDescription",
                "UIRequiredDeviceCapabilities"]
    for key in required:
        if key not in plist:
            fail("Info.plist: нет ключа %s" % key)
    if "arm64" not in plist.get("UIRequiredDeviceCapabilities", []):
        fail("Info.plist: не заявлен arm64")
    scene = plist["UIApplicationSceneManifest"]["UISceneConfigurations"]
    delegate = scene["UIWindowSceneSessionRoleApplication"][0]["UISceneDelegateClassName"]
    if "SceneDelegate" not in delegate:
        fail("Info.plist: неверный класс сцены %s" % delegate)
    notes.append("Info.plist корректен, ключей: %d" % len(plist))

def check_bridging():
    header = os.path.join(ROOT, "TalkingJohn", "Support", "SoundTouchProcessor.h")
    impl = os.path.join(ROOT, "TalkingJohn", "Support", "SoundTouchProcessor.mm")
    bridge = os.path.join(ROOT, "TalkingJohn", "Support", "TalkingJohn-Bridging-Header.h")
    for path in (header, impl, bridge):
        if not os.path.exists(path):
            fail("нет файла %s" % os.path.basename(path))
    with open(bridge, encoding="utf-8") as fh:
        if "SoundTouchProcessor.h" not in fh.read():
            fail("bridging header не подключает SoundTouchProcessor.h")

    with open(header, encoding="utf-8") as fh:
        header_text = fh.read()
    with open(impl, encoding="utf-8") as fh:
        impl_text = fh.read()
    declared = set(re.findall(r"^- \([^)]*\)(\w+)", header_text, re.M))
    for selector in declared:
        if selector not in impl_text:
            fail("метод %s объявлен, но не реализован" % selector)

    vendor = os.path.join(ROOT, "Vendor", "SoundTouch")
    for needed in ("SoundTouch.cpp", "SoundTouch.h", "TDStretch.cpp", "RateTransposer.cpp",
                   "FIFOSampleBuffer.cpp", "AAFilter.cpp", "FIRFilter.cpp", "STTypes.h",
                   "soundtouch_config.h", "cpu_detect_x86.cpp", "BPMDetect.cpp",
                   "PeakFinder.cpp", "InterpolateCubic.cpp", "InterpolateLinear.cpp",
                   "InterpolateShannon.cpp"):
        if not os.path.exists(os.path.join(vendor, needed)):
            fail("нет файла SoundTouch: %s" % needed)
    cpp = [f for f in os.listdir(vendor) if f.endswith(".cpp")]
    notes.append("SoundTouch: %d .cpp в сборке" % len(cpp))

def check_manifest():
    path = os.path.join(ASSETS, "manifest.json")
    if not os.path.exists(path):
        fail("нет manifest.json — запусти extract_assets.py")
        return
    with open(path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    for clip, info in manifest["clips"].items():
        directory = os.path.join(ASSETS, "Animations", clip)
        actual = len([f for f in os.listdir(directory) if f.endswith(".png")])
        if actual != info["frames"]:
            fail("%s: в манифесте %d кадров, на диске %d" % (clip, info["frames"], actual))

def main():
    texts = read_sources()
    check_clips(texts)
    check_sounds(texts)
    check_ui_images(texts)
    check_balance(texts)
    check_plist()
    check_bridging()
    check_manifest()

    for note in notes:
        print("  •", note)
    if problems:
        print("\nПРОБЛЕМЫ:")
        for problem in problems:
            print("  ✗", problem)
        return 1
    print("\nВсё сошлось: ассеты, ссылки, plist, SoundTouch.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
