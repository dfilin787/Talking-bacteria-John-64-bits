import Foundation

/// Описание реакции персонажа — аналог `SoundAnimation` из оригинала:
/// папка кадров, набор звуков, кадр старта звука и флаг перестановки.
struct Reaction {
    let clipName: String
    let sounds: [SoundBank.Effect]
    let fps: Double
    /// Кадр, на котором стартует звук (`soundFrameStart`).
    let soundFrameStart: Int
    /// Минимальное число проходов клипа, если звук короче анимации.
    let minRepeats: Int
    /// Обрезать звук по длине клипа: еда показывается ровно один раз, а её
    /// WAV длиннее клипа и иначе тянул второй проход («ест по 2 раза»).
    let trimSoundToClip: Bool

    init(clipName: String,
         sounds: [SoundBank.Effect],
         fps: Double = 15,
         soundFrameStart: Int = 0,
         minRepeats: Int = 1,
         trimSoundToClip: Bool = false) {
        self.clipName = clipName
        self.sounds = sounds
        self.fps = fps
        self.soundFrameStart = soundFrameStart
        self.minRepeats = minRepeats
        self.trimSoundToClip = trimSoundToClip
    }
}

/// Перестановочный выбор вариантов — как `PermutationGenerator` в оригинале:
/// все варианты проигрываются по одному, прежде чем порядок перемешается заново.
/// Наивный randomElement() даёт повторы подряд, чего в оригинале не было.
final class PermutationPicker {
    private var order: [Int] = []
    private var position = 0
    private let count: Int

    init(count: Int) {
        self.count = max(1, count)
        reshuffle()
    }

    private func reshuffle() {
        order = Array(0..<count).shuffled()
        position = 0
    }

    func next() -> Int {
        if position >= order.count { reshuffle() }
        let value = order[position]
        position += 1
        return value
    }
}

/// Выбор реакции из пула по перестановке: сначала все варианты, потом новый порядок.
final class ReactionPool {
    private let pool: [Reaction]
    private let picker: PermutationPicker

    init(_ pool: [Reaction]) {
        self.pool = pool
        self.picker = PermutationPicker(count: pool.count)
    }

    var first: Reaction? { pool.first }

    func next() -> Reaction? {
        guard !pool.isEmpty else { return nil }
        return pool[picker.next() % pool.count]
    }
}

/// Готовые реакции. Карта клипов — по наблюдениям за оригиналом:
/// - толчок бактерии (тап/флинг) → смех `laugh`/`laughGiggle`/`laughGuffaw`;
/// - шприц → `needle` (сам укол) + вариация реакции `crazy1`/`crazy2`;
/// - пончик → случайный `eat*Donut`, в конце `multiply` → новая бактерия;
/// - таблетка в бактерию → `explode` (смерть);
/// - покой → `sway`/`bumpUpDown`/`bumpLeftRight`/`lookLeftRight`.
enum Reactions {
    static let headLaugh = Reaction(clipName: "laugh",
                                    sounds: [.laugh, .laugh2, .laugh3],
                                    fps: 15)
    static let giggle = Reaction(clipName: "laughGiggle",
                                 sounds: [.giggle],
                                 fps: 15)
    static let guffaw = Reaction(clipName: "laughGuffaw",
                                 sounds: [.laugh3, .laugh2],
                                 fps: 16)
    /// Вариации реакции на укол шприцем.
    static let injectionCrazy1 = Reaction(clipName: "crazy1",
                                          sounds: [.crazy1, .crazy1Alt, .crazy1Alt2],
                                          fps: 16)
    static let injectionCrazy2 = Reaction(clipName: "crazy2",
                                          sounds: [.crazy1Alt, .crazy1Alt2, .crazy1],
                                          fps: 16)
    static let eatPink = Reaction(clipName: "eatPinkDonut", sounds: [.eat1, .eat2], fps: 15, trimSoundToClip: true)
    static let eatOrange = Reaction(clipName: "eatOrangeDonut", sounds: [.eat2, .eat1], fps: 15, trimSoundToClip: true)
    static let eatBrown = Reaction(clipName: "eatBrownDonut", sounds: [.eat1, .eat2], fps: 15, trimSoundToClip: true)
    static let multiply = Reaction(clipName: "multiply", sounds: [.multiply], fps: 12, minRepeats: 2)
    static let explode = Reaction(clipName: "explode", sounds: [.explode, .explode2], fps: 16)

    /// Смех — реакция на толчок.
    static let laughPool = [headLaugh, giggle, guffaw]
    /// Вариации укола шприцем.
    static let injectionPool = [injectionCrazy1, injectionCrazy2]
    static let eatPool = [eatPink, eatOrange, eatBrown]
}