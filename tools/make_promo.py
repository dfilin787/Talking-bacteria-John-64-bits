#!/usr/bin/env python3
"""Генератор промо-ролика Talking John (вертикальный, 30 fps).

Кадры рисуются Pillow и потоком уходят в ffmpeg (rawvideo -> h264).
Звук: синтезированный эмбиент-пад + оригинальные эффекты игры в нужных сценах.
Стиль сверен с референсом IMG_5643.MP4: тёмный фон с пятнами, светящиеся
заголовки, плашки-спеки, мокапы телефона, таймлайн, лого-карточки.
"""

import math
import os
import struct
import subprocess
import wave
from array import array

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "Assets")
OUT_VIDEO = os.path.join(os.path.expanduser("~"), "Downloads", "talking_john_promo.mp4")

W, H = 720, 1280
FPS = 30
DURATION = 27.0
FRAMES = int(DURATION * FPS)

FONT_BOLD = "C:/Windows/Fonts/arialbd.ttf"
FONT_REG = "C:/Windows/Fonts/arial.ttf"

RED = (178, 28, 24)
BG_DARK = (26, 6, 8)
GLOW = (255, 120, 90)
PINK = (238, 168, 190)
TEAL = (150, 214, 200)
WHITE = (255, 255, 255)


def font(path, size):
    return ImageFont.truetype(path, size)


def load(name, subdir="Animations"):
    return Image.open(os.path.join(ASSETS, subdir, name)).convert("RGBA")


def glow_text(text, fnt, fill=WHITE, glow=GLOW, blur=14, passes=3):
    tmp = Image.new("RGBA", (W, 260), (0, 0, 0, 0))
    d = ImageDraw.Draw(tmp)
    d.text((30, 40), text, font=fnt, fill=fill + (255,))
    box = tmp.getbbox()
    if not box:
        return tmp.crop((0, 0, W, 10))
    pad = blur * 2
    crop = tmp.crop((max(0, box[0] - pad), max(0, box[1] - pad),
                     min(W, box[2] + pad), box[3] + pad))
    glow_layer = Image.new("RGBA", crop.size, (0, 0, 0, 0))
    alpha = crop.split()[3].point(lambda a: int(a * 0.9))
    glow_layer.paste(glow + (255,), (0, 0), alpha)
    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", crop.size, (0, 0, 0, 0))
    for _ in range(passes):
        out = Image.alpha_composite(out, glow_layer)
    out = Image.alpha_composite(out, crop)
    return out


def rounded(size, radius, fill):
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=fill + (255,))
    return img


def pill_badge(text, fnt, fill, text_color=(40, 20, 26)):
    tmp = ImageDraw.Draw(Image.new("RGBA", (10, 10)))
    bbox = tmp.textbbox((0, 0), text, font=fnt)
    w = bbox[2] - bbox[0] + 56
    h = bbox[3] - bbox[1] + 30
    img = rounded((w, h), h // 2, fill)
    d = ImageDraw.Draw(img)
    d.text((28, 14 - bbox[1]), text, font=fnt, fill=text_color + (255,))
    return img


def make_background():
    bg = Image.open(os.path.join(ASSETS, "UI", "Blood-membrane-iPhone.jpg")).convert("RGB")
    bg = bg.resize((W, H), Image.LANCZOS)
    dark = Image.new("RGB", (W, H), BG_DARK)
    bg = Image.blend(bg, dark, 0.72)
    vig = Image.new("L", (W, H), 0)
    dv = ImageDraw.Draw(vig)
    dv.ellipse([-W * 0.35, -H * 0.25, W * 1.35, H * 1.25], fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(120))
    black = Image.new("RGB", (W, H), (8, 2, 3))
    bg = Image.composite(bg, black, vig)
    return bg


def make_blob():
    size = 420
    blob = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(blob)
    d.ellipse([40, 60, size - 60, size - 40], fill=110)
    d.ellipse([90, 20, size - 30, size - 90], fill=90)
    blob = blob.filter(ImageFilter.GaussianBlur(60))
    return blob


def make_icon():
    base = Image.new("RGBA", (300, 300), (0, 0, 0, 0))
    grad_top = (214, 60, 44)
    grad_bot = (120, 16, 18)
    for y in range(300):
        k = y / 299.0
        c = tuple(int(grad_top[i] + (grad_bot[i] - grad_top[i]) * k) for i in range(3))
        ImageDraw.Draw(base).line([(0, y), (300, y)], fill=c + (255,))
    mask = Image.new("L", (300, 300), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 299, 299], radius=68, fill=255)
    base.putalpha(mask)
    bact = load(os.path.join("sway", "0008.png")).resize((210, 306), Image.LANCZOS)
    base.paste(bact, (45, -6), bact)
    return base


BG = make_background()
BLOB = make_blob()
ICON = make_icon()
SWAY = [load(os.path.join("sway", "%04d.png" % i)) for i in range(21)]
LISTEN = load(os.path.join("listen", "0000.png"))
TALK = [load(os.path.join("talk", "%04d.png" % i)) for i in range(16)]
BTN_DONUT = load("gumb-donut-60.png", "UI")
BTN_PILL = load("gumb-pill-60.png", "UI")
BTN_INJ = load("injection-60.png", "UI")
PILL = load("pill-50.png", "UI")

F_TITLE = font(FONT_BOLD, 92)
F_HEAD = font(FONT_BOLD, 64)
F_SUB = font(FONT_REG, 30)
F_BADGE = font(FONT_BOLD, 26)
F_SMALL = font(FONT_REG, 24)
F_MONO = font(FONT_BOLD, 30)


def screen_game(t, mode):
    sw, sh = 300, 520
    img = Image.open(os.path.join(ASSETS, "UI", "Blood-membrane-iPhone.jpg")).convert("RGB")
    img = img.resize((sw, sh), Image.LANCZOS).convert("RGBA")
    idx = int(t * 8) % 21
    if mode == "voice":
        phase = (t * 0.5) % 1.0
        sprite = LISTEN if phase < 0.45 else TALK[int(t * 14) % 16]
        sprite = sprite.resize((120, 175), Image.LANCZOS)
        img.paste(sprite, (90, 150), sprite)
        if phase >= 0.45:
            d = ImageDraw.Draw(img)
            for i in range(3):
                r = 14 + i * 12 + int(6 * math.sin(t * 6 + i))
                d.arc([150 - r, 120 - r, 150 + r, 120 + r], 200, 340,
                      fill=(255, 220, 180, 160 - i * 40), width=3)
    else:
        a = SWAY[idx].resize((110, 160), Image.LANCZOS)
        b = SWAY[(idx + 7) % 21].resize((130, 190), Image.LANCZOS)
        img.paste(a, (30, 60), a)
        img.paste(b, (120, 250), b)
        px = 60 + int((math.sin(t * 1.7) * 0.5 + 0.5) * 160)
        py = 200 + int((math.cos(t * 1.3) * 0.5 + 0.5) * 140)
        p = PILL.resize((44, 44), Image.LANCZOS)
        img.paste(p, (px, py), p)
    for i, btn in enumerate([BTN_INJ, BTN_PILL, BTN_DONUT]):
        bb = btn.resize((52, 52), Image.LANCZOS)
        img.paste(bb, (sw - 62, 120 + i * 66), bb)
    return img


def phone(screen, tilt=0):
    sw, sh = screen.size
    pad = 16
    body = Image.new("RGBA", (sw + pad * 2, sh + pad * 2 + 46), (0, 0, 0, 0))
    d = ImageDraw.Draw(body)
    d.rounded_rectangle([0, 0, body.width - 1, body.height - 1], radius=42,
                        fill=(16, 16, 18, 255))
    d.rounded_rectangle([pad - 4, pad - 4, pad + sw + 3, pad + sh + 3], radius=10,
                        fill=(0, 0, 0, 255))
    body.paste(screen, (pad, pad))
    d = ImageDraw.Draw(body)
    d.rounded_rectangle([body.width // 2 - 34, 8, body.width // 2 + 34, 14], radius=3,
                        fill=(40, 40, 44, 255))
    d.ellipse([body.width // 2 - 16, body.height - 40, body.width // 2 + 16, body.height - 8],
              outline=(60, 60, 66, 255), width=3)
    if tilt:
        body = body.rotate(tilt, expand=True, resample=Image.BICUBIC)
    return body


T_TITLE = glow_text("talking john", F_TITLE)
T_REV = glow_text("64-bit revival", F_SUB, fill=(255, 200, 180), blur=8, passes=2)
T_H2 = glow_text("с 2011 и до сегодня", F_HEAD)
T_H3 = glow_text("она слушает тебя", F_HEAD)
T_S3 = glow_text("говоришь — повторяет, без кнопок", F_SUB, fill=(255, 210, 190), blur=8, passes=2)
T_H4 = glow_text("всё как в оригинале", F_HEAD)
T_H5 = glow_text("звук ведёт анимацию", F_HEAD)
T_S5 = glow_text("waitforsoundsync: клип ждёт звук", F_SUB, fill=(255, 210, 190), blur=8, passes=2)

B_V1 = pill_badge("armv7 · ios 5+", F_BADGE, PINK)
B_V2 = pill_badge("arm64 · ios 15+", F_BADGE, TEAL)
B_ONE = pill_badge("один геймплей: swift + uikit", F_SMALL, (90, 40, 46), (255, 220, 210))
B_P1 = pill_badge("+9 полутонов", F_BADGE, PINK)
B_P2 = pill_badge("soundtouch 2.3.3", F_BADGE, TEAL)
B_G1 = pill_badge("пончик → делится", F_BADGE, PINK)
B_G2 = pill_badge("шприц → хор", F_BADGE, TEAL)
B_G3 = pill_badge("таблетка пролетает", F_BADGE, (240, 200, 140))
B_F1 = pill_badge("фан-порт · не связано с outfit7", F_SMALL, (90, 40, 46), (255, 220, 210))
T_REPO = glow_text("github.com/dfilin787", F_SUB, fill=(255, 210, 190), blur=8, passes=2)
T_REPO2 = glow_text("/Talking-bacteria-John-64-bits", F_SMALL, fill=(255, 190, 170), blur=6, passes=2)

SCENES = [(0.0, 3.0), (3.0, 8.0), (8.0, 14.0), (14.0, 20.0), (20.0, 27.0)]
BEATS = []
_bp = os.path.join(ROOT, "out", "beats.txt")
if os.path.exists(_bp):
    BEATS = [float(v) for v in open(_bp).read().split(",") if v.strip()]


def beat_pulse(t, decay=7.0):
    p = 0.0
    for b in BEATS:
        dt = t - b
        if 0 <= dt < 0.6:
            p = max(p, math.exp(-dt * decay))
    return p
FADE = 0.22


def ease(k):
    return k * k * (3 - 2 * k)


def clamp01(x):
    return max(0.0, min(1.0, x))


def appear(t, at, dur=0.5):
    return ease(clamp01((t - at) / dur))


def draw_center(img, layer, y, alpha=1.0, dy=0):
    if alpha <= 0:
        return
    x = (W - layer.width) // 2
    if alpha >= 1:
        img.paste(layer, (x, int(y + dy)), layer)
    else:
        faded = layer.copy()
        faded.putalpha(faded.split()[3].point(lambda a: int(a * alpha)))
        img.paste(faded, (x, int(y + dy)), faded)


def scene1(t):
    img = BG.copy()
    k = appear(t, 0.1, 0.5)
    icon = ICON.resize((int(250 * (0.6 + 0.4 * k)),) * 2, Image.LANCZOS)
    glow = Image.new("RGBA", (icon.width + 160, icon.height + 160), (0, 0, 0, 0))
    halo = Image.new("RGBA", glow.size, (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    hd.ellipse([60, 60, glow.width - 60, glow.height - 60], fill=(255, 90, 60, 150))
    halo = halo.filter(ImageFilter.GaussianBlur(50))
    glow = Image.alpha_composite(glow, halo)
    glow.paste(icon, (80, 80), icon)
    draw_center(img, glow, 260 + (1 - k) * 40, alpha=k)
    draw_center(img, T_TITLE, 600, alpha=appear(t, 0.4), dy=(1 - appear(t, 0.9)) * 30)
    draw_center(img, T_REV, 730, alpha=appear(t, 0.8), dy=(1 - appear(t, 1.4)) * 20)
    return img


def scene2(t):
    img = BG.copy()
    draw_center(img, T_H2, 150, alpha=appear(t, 0.2), dy=(1 - appear(t, 0.2)) * 26)
    draw_center(img, B_V1, 330, alpha=appear(t, 0.7))
    draw_center(img, B_V2, 400, alpha=appear(t, 1.0))
    y = 520
    d = ImageDraw.Draw(img)
    k = appear(t, 1.4, 1.2)
    d.line([(90, y), (90 + int((W - 180) * k), y)], fill=(255, 200, 180, 200), width=4)
    if k > 0.98:
        d.ellipse([W - 100, y - 8, W - 84, y + 8], fill=(255, 230, 200, 255))
    for i, label in enumerate(["5", "10", "15", "20", "сегодня"]):
        x = 90 + int((W - 180) * i / 4)
        a = appear(t, 1.5 + i * 0.15, 0.4)
        d.line([(x, y - 6), (x, y + 6)], fill=(255, 190, 170, int(200 * a)), width=3)
        tw = d.textbbox((0, 0), label, font=F_SMALL)[2]
        d.text((x - tw // 2, y + 18), label, font=F_SMALL, fill=(255, 200, 185, int(230 * a)))
    draw_center(img, B_ONE, 640, alpha=appear(t, 2.4))
    return img


def scene3(t):
    img = BG.copy()
    draw_center(img, T_H3, 130, alpha=appear(t, 0.2), dy=(1 - appear(t, 0.2)) * 26)
    draw_center(img, T_S3, 240, alpha=appear(t, 0.6))
    ph = phone(screen_game(t, "voice"), tilt=-4)
    img.paste(ph, ((W - ph.width) // 2, 360), ph)
    draw_center(img, B_P1, 1030, alpha=appear(t, 1.6))
    draw_center(img, B_P2, 1100, alpha=appear(t, 1.9))
    return img


def scene4(t):
    img = BG.copy()
    draw_center(img, T_H4, 130, alpha=appear(t, 0.2), dy=(1 - appear(t, 0.2)) * 26)
    ph = phone(screen_game(t, "play"), tilt=4)
    img.paste(ph, ((W - ph.width) // 2, 260), ph)
    draw_center(img, B_G1, 900, alpha=appear(t, 1.2))
    draw_center(img, B_G2, 970, alpha=appear(t, 1.6))
    draw_center(img, B_G3, 1040, alpha=appear(t, 2.0))
    return img


def scene5(t):
    img = BG.copy()
    draw_center(img, T_H5, 150, alpha=appear(t, 0.2), dy=(1 - appear(t, 0.2)) * 26)
    draw_center(img, T_S5, 260, alpha=appear(t, 0.6))
    d = ImageDraw.Draw(img)
    y = 430
    k = appear(t, 1.0, 1.0)
    d.rounded_rectangle([110, y, 110 + int(340 * k), y + 46], radius=12, fill=PINK + (230,))
    d.text((110, y + 62), "клип laugh: 33 кадра", font=F_SMALL, fill=(255, 210, 195, 255))
    y = 580
    k2 = appear(t, 1.4, 1.2)
    d.rounded_rectangle([110, y, 110 + int(480 * k2), y + 46], radius=12, fill=TEAL + (230,))
    d.text((110, y + 62), "звук laugh.wav: 47 кадров", font=F_SMALL, fill=(210, 240, 232, 255))
    if appear(t, 2.6) > 0:
        d.text((110, 760), "анимация крутится, пока звук не доиграет",
               font=F_SMALL, fill=(255, 220, 205, int(255 * appear(t, 2.6))))
    draw_center(img, B_ONE, 880, alpha=appear(t, 3.0))
    return img


def scene6(t):
    img = BG.copy()
    k = appear(t, 0.2, 0.7)
    icon = ICON.resize((int(220 * (0.7 + 0.3 * k)),) * 2, Image.LANCZOS)
    draw_center(img, icon, 330, alpha=k)
    draw_center(img, T_TITLE, 620, alpha=appear(t, 0.6))
    draw_center(img, B_F1, 760, alpha=appear(t, 1.0))
    draw_center(img, T_REPO, 850, alpha=appear(t, 1.5))
    draw_center(img, T_REPO2, 905, alpha=appear(t, 1.8))
    fade = clamp01((t - 5.6) / 1.0)
    if fade > 0:
        img = Image.blend(img, Image.new("RGB", (W, H), (0, 0, 0)), fade)
    return img


SCENE_FN = [scene1, scene2, scene3, scene4, scene6]


def render_frame(global_t):
    idx = 0
    for i, (a, b) in enumerate(SCENES):
        if global_t >= a:
            idx = i
    local = global_t - SCENES[idx][0]
    img = SCENE_FN[idx](local)
    end = SCENES[idx][1]
    if idx + 1 < len(SCENES) and global_t > end - FADE:
        k = (global_t - (end - FADE)) / FADE
        nxt = SCENE_FN[idx + 1](global_t - SCENES[idx + 1][0])
        img = Image.blend(img, nxt, ease(k))
    if global_t < 0.6:
        img = Image.blend(Image.new("RGB", (W, H), (0, 0, 0)), img, ease(global_t / 0.6))
    p = beat_pulse(global_t)
    if p > 0.02 and 0.6 < global_t < 35.0:
        scale = 1.0 + 0.035 * p
        nw, nh = int(W * scale), int(H * scale)
        img = img.resize((nw, nh), Image.BILINEAR)
        left = (nw - W) // 2
        top = (nh - H) // 2
        shake = int(6 * p)
        left += shake if int(global_t * 30) % 2 else -shake
        img = img.crop((left, top, left + W, top + H))
        flash = Image.new("RGB", (W, H), (255, 120, 90))
        img = Image.blend(img, flash, 0.10 * p)
    return img


def blob_overlay(img, t):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for i in range(4):
        x = int(W * (0.15 + 0.6 * ((i * 0.37 + 0.05 * math.sin(t * 0.3 + i)) % 1.0)) - 210)
        y = int(H * (0.1 + 0.75 * ((i * 0.29 + 0.04 * math.cos(t * 0.23 + i * 2)) % 1.0)) - 210)
        tinted = Image.new("RGBA", BLOB.size, (120, 20, 26, 0))
        tinted.putalpha(BLOB.point(lambda a: int(a * 0.35)))
        layer.paste(tinted, (x, y), tinted)
    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


def read_wav(path):
    with wave.open(path, "rb") as w:
        rate = w.getframerate()
        n = w.getnframes()
        ch = w.getnchannels()
        raw = w.readframes(n)
    samples = array("h")
    samples.frombytes(raw)
    if ch == 2:
        samples = samples[0::2]
    mono = [s / 32768.0 for s in samples]
    if rate != 44100:
        factor = 44100.0 / rate
        out = []
        for i in range(int(len(mono) * factor)):
            src = i / factor
            i0 = int(src)
            frac = src - i0
            a = mono[min(i0, len(mono) - 1)]
            b = mono[min(i0 + 1, len(mono) - 1)]
            out.append(a + (b - a) * frac)
        mono = out
    return mono


MUSIC_FLAC = os.path.join(os.path.expanduser("~"), "Music", "flac",
                          "Villian, Aarne - Претендент На Убийство - 2026",
                          "01. Претендент На Убийство.flac")
MUSIC_START = 56.0


def build_audio(path):
    total = int(DURATION * 44100)
    buf = [0.0] * total
    if os.path.exists(MUSIC_FLAC):
        tmp = os.path.join(ROOT, "out", "music_excerpt.wav")
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-ss", str(MUSIC_START),
                        "-t", str(DURATION), "-i", MUSIC_FLAC,
                        "-ac", "1", "-ar", "44100", tmp], check=True)
        track = read_wav(tmp)
        for i, v in enumerate(track[:total]):
            fade_in = min(1.0, i / (44100 * 0.8))
            fade_out = min(1.0, (total - i) / (44100 * 1.2))
            buf[i] += v * 0.8 * fade_in * fade_out
    sfx = [
        (9.5, "laugh.wav", 0.55),
        (15.0, "eat1.wav", 0.45),
        (17.5, "explode.wav", 0.5),
        (21.0, "multiply.wav", 0.4),
    ]
    for at, name, vol in sfx:
        data = read_wav(os.path.join(ASSETS, "Sounds", name))
        off = int(at * 44100)
        for i, v in enumerate(data):
            p = off + i
            if p >= total:
                break
            buf[p] += v * vol
    out = array("h")
    peak = max(1e-6, max(abs(v) for v in buf))
    gain = 0.85 / peak
    for v in buf:
        s = int(max(-1.0, min(1.0, v * gain)) * 32000)
        out.append(s)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(44100)
        w.writeframes(out.tobytes())


def main():
    wav_path = os.path.join(ROOT, "out", "promo_audio.wav")
    os.makedirs(os.path.dirname(wav_path), exist_ok=True)
    build_audio(wav_path)
    cmd = [
        "ffmpeg", "-y",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (W, H), "-r", str(FPS), "-i", "-",
        "-i", wav_path,
        "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "160k", "-shortest",
        OUT_VIDEO,
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for f in range(FRAMES):
        t = f / FPS
        img = render_frame(t)
        img = blob_overlay(img, t)
        proc.stdin.write(img.tobytes())
        if f % 120 == 0:
            print("кадр %d/%d" % (f, FRAMES), flush=True)
    proc.stdin.close()
    proc.wait()
    print("готово:", OUT_VIDEO)


if __name__ == "__main__":
    main()