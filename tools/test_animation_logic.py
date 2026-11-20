#!/usr/bin/env python3
"""Проверяет логику покадрового движка из BacteriaView на модели.

Повторяет алгоритм step() один в один и прогоняет сценарии: одиночный клип,
зацикливание под звук, ожидание звука, старт звука на заданном кадре.
Ловит двойной учёт проходов и преждевременное завершение.

Запуск:  python tools/test_animation_logic.py
"""

import sys


class Player:
    """Точная модель BacteriaView.step(): один вызов tick == advance кадров."""

    def __init__(self, frame_count, repeats, sync_gate=None, frame_sound=None):
        self.frame_count = frame_count
        self.repeats_left = repeats
        self.sync_gate = sync_gate
        self.frame_sound = frame_sound
        self.frame_index = 0
        self.playing = True
        self.finished = False
        self.holding = False
        self.passes = 0
        if frame_sound:
            frame_sound(0)

    def tick(self, advance=1):
        """advance — сколько кадров прошлось за тик (в Swift это Int(accumulated/frameDuration))."""
        if not self.playing:
            return
        if self.holding:
            if self.sync_gate and self.sync_gate():
                self.playing = False
                self.finished = True
                self.holding = False
                return
            self.holding = False
            self.frame_index = 0
            if self.frame_sound:
                self.frame_sound(0)
        finished = False
        for _ in range(advance):
            nxt = self.frame_index + 1

            if nxt >= self.frame_count:
                if self.repeats_left > 0:
                    self.repeats_left -= 1
                self.passes += 1

                if self.sync_gate is not None:
                    if self.sync_gate():
                        self.frame_index = self.frame_count - 1
                        finished = True
                        break
                    # Звук ещё идёт: держим последний кадр, проход уже посчитан.
                    self.holding = True
                    self.frame_index = self.frame_count - 1
                    return

                if self.repeats_left == 0:
                    self.frame_index = self.frame_count - 1
                    finished = True
                    break

                self.frame_index = 0
                if self.frame_sound:
                    self.frame_sound(0)
                continue

            self.frame_index = nxt
            if self.frame_sound:
                self.frame_sound(nxt)

        if finished:
            self.playing = False
            self.finished = True


failures = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s %s" % (name, detail))
        failures.append(name)


def test_single_pass():
    p = Player(frame_count=10, repeats=1)
    ticks = 0
    while p.playing and ticks < 1000:
        p.tick()
        ticks += 1
    check("одиночный проход завершается", p.finished)
    check("одиночный проход: ровно 1 проход", p.passes == 1, "получено %d" % p.passes)
    check("одиночный проход: 10 тиков", ticks == 10, "получено %d" % ticks)
    check("одиночный проход: останов на последнем кадре", p.frame_index == 9,
          "кадр %d" % p.frame_index)


def test_fixed_repeats():
    p = Player(frame_count=10, repeats=3)
    ticks = 0
    while p.playing and ticks < 1000:
        p.tick()
        ticks += 1
    check("три прохода", p.passes == 3, "получено %d" % p.passes)
    check("три прохода: 30 тиков", ticks == 30, "получено %d" % ticks)
    check("три прохода завершены", p.finished)


def test_sound_longer_than_clip():
    # laugh.wav ≈ 47 кадров при клипе laugh в 33 кадра => 2 прохода.
    state = {"left": 47}
    p = Player(frame_count=33, repeats=0, sync_gate=lambda: state["left"] <= 0)
    ticks = 0
    while p.playing and ticks < 5000:
        p.tick()
        state["left"] -= 1
        ticks += 1
    check("звук длиннее клипа: анимация ждёт sound sync", p.finished)
    check("звук 47 / клип 33 => 2 прохода", p.passes == 2, "получено %d" % p.passes)
    check("анимация не оборвалась раньше звука", ticks >= 47, "тиков %d" % ticks)


def test_sound_shorter_than_clip():
    # eat2.wav ≈ 52 кадра при клипе 41 => 2 прохода; короткий звук — 1 проход.
    state = {"left": 5}
    p = Player(frame_count=41, repeats=0, sync_gate=lambda: state["left"] <= 0)
    ticks = 0
    while p.playing and ticks < 5000:
        p.tick()
        state["left"] -= 1
        ticks += 1
    check("короткий звук: клип доигрывает проход целиком", p.passes == 1,
          "получено %d" % p.passes)
    check("короткий звук: завершено", p.finished)


def test_frame_sound_fires_each_pass():
    hits = []
    p = Player(frame_count=10, repeats=0,
               sync_gate=lambda: p.passes >= 3,
               frame_sound=lambda f: hits.append(f) if f == 3 else None)
    ticks = 0
    while p.playing and ticks < 1000:
        p.tick()
        ticks += 1
    check("звук на кадре 3 стартует в каждом проходе", len(hits) == 3,
          "срабатываний %d" % len(hits))
    check("три прохода по syncGate", p.passes == 3, "получено %d" % p.passes)


def test_hold_does_not_double_count():
    # Долгий звук: удержание последнего кадра не должно множить проходы.
    state = {"left": 200}
    p = Player(frame_count=10, repeats=0, sync_gate=lambda: state["left"] <= 0)
    ticks = 0
    while p.playing and ticks < 5000:
        p.tick()
        state["left"] -= 1
        ticks += 1
    check("удержание кадра не удваивает проходы", p.passes == 20,
          "ожидалось 20, получено %d" % p.passes)


def test_burst_advance():
    # Пропущенные кадры (advance > 1) не должны ломать счёт проходов.
    p = Player(frame_count=10, repeats=2)
    ticks = 0
    while p.playing and ticks < 1000:
        p.tick(3)
        ticks += 1
    check("рывок в 3 кадра: проходы посчитаны верно", p.passes == 2,
          "получено %d" % p.passes)
    check("рывок: завершено", p.finished)


def main():
    print("Модель покадрового движка BacteriaView:")
    test_single_pass()
    test_fixed_repeats()
    test_sound_longer_than_clip()
    test_sound_shorter_than_clip()
    test_frame_sound_fires_each_pass()
    test_hold_does_not_double_count()
    test_burst_advance()
    if failures:
        print("\nПровалено: %s" % ", ".join(failures))
        return 1
    print("\nВсе сценарии прошли.")
    return 0


if __name__ == "__main__":
    sys.exit(main())