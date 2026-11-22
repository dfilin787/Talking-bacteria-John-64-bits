# Talking John — 64-bit revival

Восстановленная версия **Talking Bacteria John, John & John** (Outfit7, v1.0.2).
Оригинал был собран под armv7/armv7s и удалён из App Store, на современной iOS не запускается.
Здесь тот же геймплей, написанный заново на Swift + UIKit: **arm64, iOS 15+**.

Неофициальный фанатский порт для сохранения игры. Не связан с Outfit7 и не одобрен ими.
Подробнее о правах — [NOTICE.md](NOTICE.md).

## Геймплей

- **Повтор голоса** — бактерии постоянно слушают микрофон и повторяют сказанное
  питч-шифтом (+9 полутонов), как в оригинале. Говоришь — слушают, замолчал на секунду —
  повторяют. Порог отсекает фоновый шум, тихие края фразы обрезаются.
- **Пончик** — случайная свободная бактерия ест случайный пончик, затем делится (`multiply`).
  Одновременно едят не больше двух, всего бактерий не больше шести — как в оригинале.
- **Шприц** — укол, все свободные бактерии сходят с ума хором. Вариация одна на всех
  за укол и чередуется: `crazy1` → `crazy2` → `crazy1`.
- **Таблетка** — появляется в центре поля, её можно тащить и толкать пальцем.
  Пролетает сквозь бактерий и убивает их, не одноразовая: исчезает только после
  долгого бездействия.
- **Толчок свайпом** — бактерия отлетает и, после нескольких толчков, смеётся.
  Тап по бактерии — лопается пузырями (`explode`).
- Бактерии сами ездят по полю, отталкиваются друг от друга, проходят под кнопками
  и не заходят за мембрану.

## Как это работает

Оригинальный бинарник (armv7-слайс) разобран дизассемблером, модель поведения восстановлена
по нему и по видео геймплея. Соответствие ключевых механизмов:

| Оригинал | Здесь |
|---|---|
| `SoundAnimation`, `SoundsAnimation` | `Reaction` + `BacteriaView` |
| `soundFrameStart`, `playSoundForFrame:` | `soundFrameStart`, замыкание `frameSound` |
| `waitForSoundSync` | `syncGate` — клип крутится, пока звучит привязанный звук |
| `repeatCount` | `repeats` / `minRepeats` |
| `PermutationGenerator` | `PermutationPicker`, `ReactionPool` |
| `BacteriaAnimView`, `AnimLayeredImage` | `BacteriaView` на `CADisplayLink` |
| `SpeakHereController`, `AQSoundPlayer` (AudioQueue) | `VoiceRecorder` на `AVAudioEngine` |
| `collision2D` | попарное отталкивание в моторе движения |
| `maxAvailableBacterias` = 6 | лимит бактерий и счётчик одновременной еды |

Звуки длиннее клипов (`laugh.wav` — 47 кадров при клипе в 33), поэтому анимация
зацикливается под длительность звука — это и есть `waitForSoundSync`. Для еды звук
обрезается по длине клипа, чтобы проход был ровно один.

Питч-шифт делает **SoundTouch 2.3.3** — та же библиотека и версия, что в оригинале,
поэтому характерный тембр сохранён один в один (не `AVAudioUnitTimePitch`).

Из оригинала не переносились: Facebook SDK 2011 года, загрузка на YouTube через мёртвый
ClientLogin, реклама Mobclix, кросс-промо на неработающие URL, `UIWebView`-экран about.

## Структура

```
TalkingJohn/Sources/     игровой код (Swift)
TalkingJohn/Support/     Objective-C++ обёртка SoundTouch
Vendor/SoundTouch/       SoundTouch 2.3.3 (LGPL 2.1)
Assets/Animations/       покадровые клипы персонажа
Assets/Sounds/           звуковые эффекты
Assets/UI/               кнопки, фон, иконки
tools/                   проверки проекта и инструменты разбора IPA
.github/workflows/       сборка IPA на macOS-раннере
```

## Сборка

Локально нужен macOS с Xcode 15+ и [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project TalkingJohn.xcodeproj -scheme TalkingJohn \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Без Mac — сборка идёт в GitHub Actions (`.github/workflows/build.yml`): каждый push
собирает arm64 IPA и выкладывает её в артефакты запуска. Подпись не выполняется,
IPA ставится через AltStore / Sideloadly / TrollStore.

Проверки без Xcode (работают на любой ОС, нужен Python 3):

```bash
python tools/check_all.py
```

Прогоняет верификацию проекта, проверку внутренних ссылок Swift, поиск посторонних
символов в тексте и юнит-тесты логики покадровой анимации.

## Установка

Готовую IPA из артефактов CI подписать своим сертификатом через
[AltStore](https://altstore.io) или [Sideloadly](https://sideloadly.io), либо поставить
на устройство с TrollStore. Приложение не публикуется в App Store.

## Лицензии

- **Код этого проекта** — MIT, см. [LICENSE](LICENSE).
- **SoundTouch 2.3.3** (`Vendor/SoundTouch/`) — LGPL 2.1, © Olli Parviainen.
  Полный текст: `Vendor/SoundTouch/LICENSE.TXT`.
- **Арт, анимации, звуки, персонаж и название** — принадлежат Outfit7 Limited
  и в репозитории распространяются только в целях сохранения игры.
  MIT на них **не распространяется**. См. [NOTICE.md](NOTICE.md).

## Авторы

Игровой код, разбор оригинала и сборка — [@dfilin787](https://github.com/dfilin787)
совместно с Claude (Anthropic) в качестве ИИ-ассистента.