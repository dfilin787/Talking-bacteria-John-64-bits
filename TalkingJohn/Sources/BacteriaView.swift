import UIKit

/// Проигрыватель покадровой анимации на CADisplayLink.
///
/// Повторяет модель оригинального `SoundAnimation`: клип крутится по кругу,
/// звук привязан к кадру (`soundFrameStart`), а завершение определяется либо
/// числом повторов (`repeatCount`), либо ожиданием конца звука (`waitForSoundSync`).
final class BacteriaView: UIView {

    private let imageView = UIImageView()
    private var displayLink: CADisplayLink?

    private var clip: AnimationClip?
    private var frameIndex = 0
    private var accumulated: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0

    private var repeatsLeft: Int = 1          // 0 = бесконечно
    /// Клип дошёл до конца прохода и ждёт окончания звука, удерживая последний кадр.
    private var holdingForSound = false
    private var syncGate: (() -> Bool)?
    private var frameSound: ((Int) -> Void)?
    private var onFinish: (() -> Void)?

    /// Кадров в секунду.
    private(set) var framesPerSecond: Double = 14

    /// Размер кадра в точках родительской системы координат.
    var contentSize: CGSize = CGSize(width: 137, height: 200) {
        didSet { setNeedsLayout() }
    }

    private(set) var isPlaying = false
    var currentClipName: String? { clip?.name }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        imageView.contentMode = .scaleToFill
        imageView.layer.magnificationFilter = .linear
        imageView.layer.minificationFilter = .linear
        imageView.clipsToBounds = false
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = CGRect(origin: .zero, size: contentSize)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { pauseLink() } else if isPlaying { startLink() }
    }

    // MARK: - Управление

    func showStaticFrame(_ image: UIImage) {
        stop()
        imageView.image = image
    }

    /// - Parameters:
    ///   - repeats: число полных проходов клипа; 0 — крутить без ограничения.
    ///   - syncGate: если задан, клип не остановится, пока замыкание не вернёт true
    ///     (аналог `waitForSoundSync` — ждём окончания звука).
    ///   - frameSound: вызывается при входе в кадр, если для него назначен звук.
    func play(_ newClip: AnimationClip,
              repeats: Int = 1,
              fps: Double = 14,
              syncGate: (() -> Bool)? = nil,
              frameSound: ((Int) -> Void)? = nil,
              completion: (() -> Void)? = nil) {
        guard !newClip.isEmpty else { completion?(); return }
        framesPerSecond = max(1, fps)
        clip = newClip
        frameIndex = 0
        accumulated = 0
        lastTimestamp = 0
        repeatsLeft = max(0, repeats)
        holdingForSound = false
        self.syncGate = syncGate
        self.frameSound = frameSound
        onFinish = completion
        isPlaying = true
        imageView.image = newClip.frame(at: 0)
        frameSound?(0)
        if window != nil { startLink() }
    }

    func stop() {
        pauseLink()
        isPlaying = false
        holdingForSound = false
        onFinish = nil
        syncGate = nil
        frameSound = nil
        frameIndex = 0
        accumulated = 0
    }

    /// Останавливается и показывает первый кадр текущего клипа.
    func stopAndReset() {
        let first = clip?.frame(at: 0)
        stop()
        if let first { imageView.image = first }
    }

    // MARK: - Тик

    private func startLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }

    private func pauseLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard isPlaying, let clip, clip.frameCount > 0 else { return }

        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        accumulated += link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp

        let frameDuration = 1.0 / framesPerSecond
        guard accumulated >= frameDuration else { return }

        let advance = Int(accumulated / frameDuration)
        accumulated -= Double(advance) * frameDuration

        // Проход закончился, звук ещё звучит: продолжаем крутить клип,
        // но новые проходы уже не считаем — решение будет на следующей границе.
        if holdingForSound {
            if syncGate?() == true {
                finishPlayback()
                return
            }
            holdingForSound = false
            frameIndex = 0
            frameSound?(0)
        }

        var finished = false
        for _ in 0..<advance {
            let next = frameIndex + 1

            if next >= clip.frameCount {
                // Граница прохода: решение принимается ровно один раз.
                if repeatsLeft > 0 { repeatsLeft -= 1 }

                if let syncGate {
                    if syncGate() {
                        frameIndex = clip.frameCount - 1
                        finished = true
                        break
                    }
                    holdingForSound = true
                    frameIndex = clip.frameCount - 1
                    imageView.image = clip.frame(at: frameIndex)
                    return
                }

                if repeatsLeft == 0 {
                    frameIndex = clip.frameCount - 1
                    finished = true
                    break
                }
                frameIndex = 0
                frameSound?(0)
                continue
            }

            frameIndex = next
            frameSound?(next)
        }

        imageView.image = clip.frame(at: frameIndex)

        if finished { finishPlayback() }
    }

    private func finishPlayback() {
        isPlaying = false
        holdingForSound = false
        pauseLink()
        let callback = onFinish
        onFinish = nil
        syncGate = nil
        frameSound = nil
        callback?()
    }
}