#!/usr/bin/env python3

import os
import re
import struct
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREFIX = "Payload/TalkingJohn.app/"

TYPES = ["GameViewController", "BacteriaView", "BundleLocator", "VoiceRecorder",
         "SampleCollector", "PermutationPicker", "ReactionPool", "SoundBank",
         "EffectPlayer", "ClipLibrary", "SoundTouchProcessor", "SceneDelegate",
         "AppDelegate", "AnimationClip"]

SOUNDTOUCH_MARKERS = ["TDStretch", "RateTransposer", "FIRFilter", "AAFilter",
                      "detectCPUextensions", "SoundTouch"]

CLIPS = ["talk", "listen", "blink", "sway", "lookLeftRight", "bumpLeftRight",
         "bumpUpDown", "laugh", "laughGiggle", "laughGuffaw", "crazy1", "crazy2",
         "eatBrownDonut", "eatOrangeDonut", "eatPinkDonut", "explode", "multiply", "needle"]

def cstring_section(data):
    magic = struct.unpack("<I", data[:4])[0]
    if magic != 0xFEEDFACF:
        return b""
    ncmds = struct.unpack("<I", data[16:20])[0]
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[offset:offset + 8])
        if cmd == 0x19:
            nsects = struct.unpack("<I", data[offset + 64:offset + 68])[0]
            sect_offset = offset + 72
            for _ in range(nsects):
                name = data[sect_offset:sect_offset + 16].split(b"\0")[0].decode()
                length = struct.unpack("<Q", data[sect_offset + 40:sect_offset + 48])[0]
                file_offset = struct.unpack("<I", data[sect_offset + 48:sect_offset + 52])[0]
                if name == "__cstring":
                    return data[file_offset:file_offset + length]
                sect_offset += 80
        offset += size
    return b""

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "out", "TalkingJohn-unsigned.ipa")
    if not os.path.exists(path):
        print("IPA не найден: %s" % path)
        return 1

    archive = zipfile.ZipFile(path)
    names = archive.namelist()
    binary = archive.read(PREFIX + "TalkingJohn")
    problems = []

    print("IPA: %s (%.1f МБ), файлов: %d"
          % (os.path.basename(path), os.path.getsize(path) / 1048576, len(names)))
    print("бинарник: %.2f МБ" % (len(binary) / 1048576))

    print("\nТипы Swift в бинарнике:")
    for name in TYPES:
        count = binary.count(name.encode())
        if count == 0:
            problems.append("нет метаданных типа %s" % name)
    print("   найдено %d из %d" % (sum(1 for t in TYPES if binary.count(t.encode())), len(TYPES)))

    mangled = binary.count(b"11TalkingJohn")
    print("   манглинг модуля TalkingJohn: %d вхождений" % mangled)
    if mangled == 0:
        problems.append("нет манглинга модуля — Swift-код не слинкован")

    print("\nSoundTouch:")
    for marker in SOUNDTOUCH_MARKERS:
        count = binary.count(marker.encode())
        if count == 0:
            problems.append("нет символа SoundTouch: %s" % marker)
    print("   маркеров найдено: %d из %d"
          % (sum(1 for m in SOUNDTOUCH_MARKERS if binary.count(m.encode())), len(SOUNDTOUCH_MARKERS)))

    strings = [s.decode("utf-8", errors="replace") for s in cstring_section(binary).split(b"\0") if s]
    russian = [s for s in strings if re.search(r"[А-Яа-яЁё]", s)]
    print("\nСтрок интерфейса в __cstring: %d" % len(russian))
    for text in russian[:6]:
        print("   ", text[:70])
    if len(russian) < 5:
        problems.append("подозрительно мало строк интерфейса: %d" % len(russian))

    print("\nАссеты:")
    clips = {n[len(PREFIX):].split("/")[1] for n in names
             if n.startswith(PREFIX + "Animations/") and n.count("/") >= 4}
    frames = [n for n in names if n.startswith(PREFIX + "Animations/") and n.endswith(".png")]
    sounds = [n for n in names if n.startswith(PREFIX + "Sounds/") and n.endswith(".wav")]
    ui = [n for n in names if n.startswith(PREFIX + "UI/") and n.endswith(".png")]
    print("   клипов: %d, кадров: %d, wav: %d, UI: %d" % (len(clips), len(frames), len(sounds), len(ui)))
    for clip in CLIPS:
        if clip not in clips:
            problems.append("нет клипа %s" % clip)
    if len(frames) != 504:
        problems.append("кадров %d, ожидалось 504" % len(frames))
    if len(sounds) != 16:
        problems.append("wav %d, ожидалось 16" % len(sounds))
    if not any(n.endswith("Assets.car") for n in names):
        problems.append("нет Assets.car — иконка не собралась")

    print()
    if problems:
        print("ПРОБЛЕМЫ:")
        for problem in problems:
            print("  ✗", problem)
        return 1
    print("IPA в порядке: arm64-код игры, SoundTouch и все ассеты на месте.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
