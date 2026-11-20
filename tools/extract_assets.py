#!/usr/bin/env python3
"""Извлекает игровые ассеты из оригинального .ipa в структуру проекта.

- 515 обычных PNG копируются как есть, кадры анимаций нормализуются в 0000.png…
- 37 PNG в формате Apple CgBI (BGRA, premultiplied alpha, zlib без заголовка)
  конвертируются обратно в стандартный RGBA PNG.
- WAV копируются без изменений.

Запуск:  python tools/extract_assets.py "путь к .ipa"
"""

import io
import json
import os
import posixpath
import re
import struct
import sys
import zipfile
import zlib

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "Assets")
APP_PREFIX = "Payload/TalkingJohn.app/"

# Что оригинал тащил для соцсетей/рекламы — в новой сборке не нужно.
SKIP_NAMES = {
    "facebook.png", "youtube.png", "mail.png", "mail@2x.png",
    "gift.png", "gift@2x.png", "wealth-splash-new.png",
    "Check18.png", "check25.png", "check25@2x.png",
    "aboutBack.png", "close.png", "X.png", "X@2x.png",
}


def cgbi_to_png(data: bytes) -> Image.Image:
    """Разворачивает Apple CgBI PNG в обычный RGBA."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    width = height = depth = ctype = None
    idat = bytearray()
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break

    if depth != 8 or ctype not in (2, 6):
        raise ValueError("unsupported CgBI: depth=%s ctype=%s" % (depth, ctype))

    # CgBI хранит поток zlib без 2-байтового заголовка и без adler32.
    try:
        raw = zlib.decompress(bytes(idat), -15)
    except zlib.error:
        raw = zlib.decompress(bytes(idat))

    channels = 4 if ctype == 6 else 3
    stride = width * channels
    expected = (stride + 1) * height
    if len(raw) < expected:
        raise ValueError("short scanline data: %d < %d" % (len(raw), expected))

    out = bytearray(stride * height)
    prev = bytearray(stride)
    src = 0
    for _ in range(height):
        filt = raw[src]
        src += 1
        line = bytearray(raw[src:src + stride])
        src += stride
        if filt == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filt == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filt == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filt == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif filt != 0:
            raise ValueError("bad filter %d" % filt)
        out[_ * stride:(_ + 1) * stride] = line
        prev = line

    # BGRA -> RGBA и снятие premultiplied alpha.
    rgba = bytearray(stride * height)
    for i in range(0, len(out), channels):
        b, g, r = out[i], out[i + 1], out[i + 2]
        a = out[i + 3] if channels == 4 else 255
        if channels == 4 and 0 < a < 255:
            r = min(255, (r * 255 + a // 2) // a)
            g = min(255, (g * 255 + a // 2) // a)
            b = min(255, (b * 255 + a // 2) // a)
        rgba[i] = r
        rgba[i + 1] = g
        rgba[i + 2] = b
        rgba[i + 3] = a

    return Image.frombytes("RGBA", (width, height), bytes(rgba))


def save_png(data: bytes, dest: str, report: dict):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if data[12:16] == b"CgBI":
        img = cgbi_to_png(data)
        img.save(dest, "PNG", optimize=True)
        report["converted"] += 1
        report["sizes"].append((os.path.basename(dest), img.size))
    else:
        with open(dest, "wb") as fh:
            fh.write(data)
        report["copied"] += 1
        with Image.open(io.BytesIO(data)) as im:
            report["sizes"].append((os.path.basename(dest), im.size))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    ipa = sys.argv[1]
    z = zipfile.ZipFile(ipa)
    report = {"converted": 0, "copied": 0, "sizes": []}
    anim = {}
    sounds = []
    ui = []

    for info in z.infolist():
        name = info.filename
        if info.is_dir() or not name.startswith(APP_PREFIX):
            continue
        rel = name[len(APP_PREFIX):]
        base = posixpath.basename(rel)
        ext = posixpath.splitext(base)[1].lower()

        if rel.startswith("AnimationsBacteria/") and ext == ".png":
            parts = rel.split("/")
            clip = parts[1]
            m = re.search(r"(\d{4})\.png$", base)
            idx = int(m.group(1)) if m else 0
            anim.setdefault(clip, []).append((idx, name))
        elif rel.startswith("SoundsBacteria/") and ext == ".wav":
            dest = os.path.join(ASSETS, "Sounds", base)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(z.read(name))
            sounds.append(base)
        elif ext == ".png" and "/" not in rel and base not in SKIP_NAMES:
            dest = os.path.join(ASSETS, "UI", base)
            save_png(z.read(name), dest, report)
            ui.append(base)

    manifest = {"clips": {}, "sounds": sorted(sounds), "ui": sorted(ui)}
    for clip, frames in sorted(anim.items()):
        frames.sort()
        clip_dir = os.path.join(ASSETS, "Animations", clip)
        os.makedirs(clip_dir, exist_ok=True)
        w = h = None
        for new_idx, (_, src) in enumerate(frames):
            dest = os.path.join(clip_dir, "%04d.png" % new_idx)
            data = z.read(src)
            save_png(data, dest, report)
            if w is None:
                with Image.open(dest) as im:
                    w, h = im.size
        manifest["clips"][clip] = {"frames": len(frames), "width": w, "height": h}
        print("  %-16s %3d кадров  %sx%s" % (clip, len(frames), w, h))

    os.makedirs(ASSETS, exist_ok=True)
    with open(os.path.join(ASSETS, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    print("\nPNG скопировано: %d, конвертировано из CgBI: %d" % (report["copied"], report["converted"]))
    print("WAV: %d, UI-картинок: %d" % (len(sounds), len(ui)))
    print("Ассеты: %s" % ASSETS)
    return 0


if __name__ == "__main__":
    sys.exit(main())