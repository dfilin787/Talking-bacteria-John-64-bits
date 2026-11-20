# Talking John — 64-битная пересборка

Переписанная с нуля версия **Talking Bacteria John, John & John** (Outfit7, 2011, v1.0.2).
Оригинал был собран под armv7/armv7s и на современной iOS не запускается. Здесь — тот же
геймплей на Swift + UIKit, arm64, iOS 15+.

Личный проект. Арт и звуки принадлежат Outfit7; в App Store не публикуется.

## Что взято из оригинала

Разобран бинарник `TalkingJohn` (armv7-слайс) и восстановлена модель анимации:

| Оригинал | Здесь |
|---|---|
| `SoundAnimation`, `SoundsAnimation` | `Reaction` + `BacteriaView` |
| `soundFrameStart`, `playSoundForFrame:` | параметр `soundFrameStart`, замыкание `frameSound` |
| `waitForSoundSync`, `waitingForSoundSync` | `syncGate` — клип крутится, пока звучит привязанный звук |
| `repeatCount`, `repeatCountCurrent` | `repeats` / `minRepeats` |
| `PermutationGenerator`, `usePermutationForSounds` | `PermutationPicker`, `ReactionPool` |
| `BacteriaAnimView`, `AnimLayeredImage` | `BacteriaView` на `CADisplayLink` |
| `SpeakHereController`, `AQSoundPlayer`, AudioQueue | `VoiceRecorder` на `AVAudioEngine` |
| `soundtouch::SoundTouch`, `initWithPitch:bufferSize:` | та же библиотека 2.3.3, обёртка `SoundTouchProcessor` |
| `touchHead`, `touchStomach`, `touchBacteriaDonut/Pill/Needle` | те же обработчики |

Ключевая находка: звуки длиннее клипов (`laugh.wav` — 47 кадров при клипе в 33,
`eat1.wav` — 69 при 41), поэтому анимация **зацикливается под длительность звука**,
а не проигрывается один раз. Это и есть `waitForSoundSync`.

Питч-шифт делается оригинальной SoundTouch, а не `AVAudioUnitTimePitch`, — характерный
«бурундучий» тембр сохраняется один в один.

## Выброшено

Facebook SDK 2011 года, `YouTubeUpload` (ClientLogin мёртв), реклама Mobclix,
`AppsGridController` и `Outfit7News` (кросс-промо на мёртвые URL), `UIWebView` в about.
Это примерно половина кодовой базы оригинала.

## Структура

```
Assets/
  Animations/<клип>/0000.png…   504 кадра, 18 клипов
  Sounds/*.wav                  16 WAV, моно 11025 Гц
  UI/*.png                      кнопки, фон, иконки
  manifest.json                 что извлечено
TalkingJohn/
  Sources/*.swift               вся логика
  Support/                      ObjC++ обёртка SoundTouch + bridging header
  Assets.xcassets               иконка приложения
  Info.plist
Vendor/SoundTouch/              исходники SoundTouch 2.3.3 (LGPL, см. LICENSE.TXT)
tools/extract_assets.py         извлечение ассетов из .ipa
tools/verify_project.py         ассеты, plist, SoundTouch, манифест
tools/check_swift_refs.py       селекторы, поля, баланс скобок
tools/test_animation_logic.py   модель покадрового движка, 17 сценариев
tools/check_all.py              все проверки подряд
project.yml                     конфигурация XcodeGen
```

Проверки гоняются без Mac:

```bash
python tools/check_all.py
```

Модель анимации в `test_animation_logic.py` повторяет `BacteriaView.step()` один в один
и ловит рассинхрон звука с кадрами — именно так был найден и исправлен двойной учёт
проходов при удержании последнего кадра.

37 PNG в оригинале лежали в эппловском формате **CgBI** (BGRA, premultiplied alpha,
zlib без заголовка). Экстрактор разворачивает их обратно в RGBA — иначе они выглядят
как сине-красный мусор.

## Сборка

**Без Mac:** сборка уезжает в GitHub Actions — раннер `macos-15` с Xcode 16.4.
Подробно в [BUILD-WITHOUT-MAC.md](BUILD-WITHOUT-MAC.md). Пайплайн лежит в
`.github/workflows/build.yml`, артефактом приходит `TalkingJohn-unsigned.ipa`,
который ставится через Sideloadly / AltStore / TrollStore.

**С Mac:** Xcode 15+ и [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd TalkingJohn
xcodegen generate
open TalkingJohn.xcodeproj
```

Дальше в Xcode: выбрать свою команду подписи (Signing & Capabilities → Team),
подключить iPhone, Cmd+R. Bundle ID `com.pokoyo.talkingjohn` при необходимости поменяй.

Ассеты уже извлечены. Если нужно повторить с другого `.ipa`:

```bash
python tools/extract_assets.py "/путь/к/Talking Bacteria John, John & John 1.0.2.ipa"
python tools/verify_project.py
```

## Управление

- **Тап по голове** — смех (`laugh`, `laughGiggle`, `laughGuffaw`)
- **Тап по животу** — щекотка (`crazy1`, `crazy2`)
- **Пончик / второй пончик** — еда (`eatPinkDonut`, `eatOrangeDonut`)
- **Таблетка** — деление (`multiply`)
- **Шприц** — полноэкранная сцена `needle`, затем взрыв (`explode`)
- **Кнопка записи** — слушает микрофон, поднимает голос на 9 полутонов и повторяет
  синхронно с клипом `talk`. Запись обрывается по 1.1 с тишины или через 8 с.

В покое персонаж моргает, покачивается, оглядывается и подпрыгивает — случайные
паузы 2.6–5.4 с, как в оригинале.

## Настройки под себя

`VoiceRecorder.Settings` — высота голоса (`pitchSemitones`), порог тишины
(`noiseGate`), таймаут (`silenceTimeout`), максимальная длина фразы (`maxDuration`).

`Reactions` — какой клип с какими звуками, fps и кадр старта звука.

## Права

Код проекта — твой. SoundTouch распространяется по LGPL 2.1 (`Vendor/SoundTouch/LICENSE.TXT`),
линкуется статически; для личного использования обязательств нет.
Арт, анимации и звуки — собственность Outfit7.