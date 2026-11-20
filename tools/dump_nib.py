#!/usr/bin/env python3
"""Разбирает NIB оригинала: точная раскладка кнопок, размеры, видимость, картинки.

NIB 2011 года — NSKeyedArchiver (binary plist) с ключами UI*, а не NS*.
Разворачиваем UID-ссылки и восстанавливаем дерево UIView.

Запуск:  python tools/dump_nib.py "путь к .ipa" [имя nib]
"""

import plistlib
import re
import sys
import zipfile

APP = "Payload/TalkingJohn.app/"
RECT = re.compile(r"\{\{(-?[\d.]+), (-?[\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}")
POINT = re.compile(r"\{(-?[\d.]+), (-?[\d.]+)\}")


class Archive:
    def __init__(self, data):
        plist = plistlib.loads(data)
        self.objects = plist["$objects"]

    def resolve(self, value, depth=0):
        if depth > 12:
            return None
        if isinstance(value, plistlib.UID):
            return self.resolve(self.objects[value.data], depth + 1)
        return value

    def class_name(self, obj):
        if not isinstance(obj, dict):
            return None
        meta = self.resolve(obj.get("$class"))
        if isinstance(meta, dict):
            return meta.get("$classname")
        return None

    def resource(self, obj):
        value = self.resolve(obj)
        if isinstance(value, dict):
            name = self.resolve(value.get("UIResourceName"))
            if isinstance(name, str):
                return name
        return None

    def list_of(self, obj, key):
        container = self.resolve(obj.get(key))
        if isinstance(container, dict):
            items = self.resolve(container.get("NS.objects"))
            if isinstance(items, list):
                return [self.resolve(x) for x in items]
        return []

    def button_images(self, obj):
        """UIButtonStatefulContent: словарь состояние -> контент."""
        found = []
        container = self.resolve(obj.get("UIButtonStatefulContent"))
        if not isinstance(container, dict):
            return found
        values = self.resolve(container.get("NS.objects")) or []
        for value in values:
            resolved = self.resolve(value)
            name = self.resource(resolved)
            if name:
                found.append(name)
            elif isinstance(resolved, dict):
                inner = self.resource(resolved.get("UIImage"))
                if inner:
                    found.append(inner)
        return found


def geometry(obj, archive):
    bounds = archive.resolve(obj.get("UIBounds"))
    center = archive.resolve(obj.get("UICenter"))
    frame = archive.resolve(obj.get("UIFrame"))
    if isinstance(frame, str) and RECT.match(frame):
        x, y, w, h = map(float, RECT.match(frame).groups())
        return x, y, w, h
    if isinstance(bounds, str) and isinstance(center, str):
        mb, mc = RECT.match(bounds), POINT.match(center)
        if mb and mc:
            _, _, w, h = map(float, mb.groups())
            cx, cy = map(float, mc.groups())
            return cx - w / 2, cy - h / 2, w, h
    return None


def walk(archive, obj, depth, out, seen):
    if not isinstance(obj, dict) or id(obj) in seen:
        return
    seen.add(id(obj))
    name = archive.class_name(obj)
    if not name:
        return
    rect = geometry(obj, archive)
    hidden = archive.resolve(obj.get("UIHidden"))
    alpha = archive.resolve(obj.get("UIAlpha"))
    image = archive.resource(obj.get("UIImage"))
    buttons = archive.button_images(obj)
    tag = archive.resolve(obj.get("UITag"))
    interaction = archive.resolve(obj.get("UIUserInteractionDisabled"))

    label = str(name)
    if label.startswith("UI") or label in ("UIView", "UIImageView", "UIButton"):
        parts = []
        if rect:
            parts.append("frame=(%.0f, %.0f, %.0f, %.0f)" % rect)
        if image:
            parts.append("image=%s" % image)
        if buttons:
            parts.append("states=%s" % ",".join(buttons))
        if hidden:
            parts.append("HIDDEN")
        if alpha is not None and isinstance(alpha, (int, float)) and alpha != 1:
            parts.append("alpha=%.2f" % alpha)
        if tag not in (None, 0):
            parts.append("tag=%s" % tag)
        if interaction:
            parts.append("noInteraction")
        out.append("%s%s %s" % ("  " * depth, label, " ".join(parts)))

    for child in archive.list_of(obj, "UISubviews"):
        walk(archive, child, depth + 1, out, seen)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    archive_zip = zipfile.ZipFile(sys.argv[1])
    wanted = sys.argv[2] if len(sys.argv) > 2 else None
    nibs = [n for n in archive_zip.namelist() if n.endswith(".nib")]
    if wanted:
        nibs = [n for n in nibs if wanted.lower() in n.lower()]

    for nib in nibs:
        print("=" * 72)
        print(nib.split("/")[-1])
        print("=" * 72)
        archive = Archive(archive_zip.read(nib))
        out = []
        seen = set()
        # Корень: первый UIView с UIBounds во всём графе.
        for obj in archive.objects:
            if isinstance(obj, dict) and "UISubviews" in obj and "UIBounds" in obj:
                walk(archive, obj, 0, out, seen)
                break
        print("\n".join(out) if out else "  дерево не найдено")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())