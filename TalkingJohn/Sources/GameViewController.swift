import AVFoundation
import QuartzCore
import UIKit

/// Главный экран. Раскладка взята из TalkingBacteriaViewController.nib оригинала:
/// фон Blood-3-iphone.jpg на всю канву 320×480, кнопка записи слева сверху (0,2),
/// справа столбиком пончик (260,272), шприц (260,136), таблетка (260,204).
/// Кнопка таблетки скрыта, пока бактерия не поест — `enableBacteriaMultiplyButton:`.
///
/// Логика по методам оригинала: `touchBacteriaDonut` → `playRandomEatAnimation`,
/// после еды появляется таблетка (`BacteriaPillView`, `getRandomPositionOnScreen`),
/// её можно смахнуть в бактерию → `duplicateBacteria` / `playNewbornMultiplyAnimation`.
/// Шприц — `playPopAnimation:` (бактерия лопается и исчезает), не «убийство».
final class GameViewController: UIViewController {

    // Дизайн-канва оригинала.
    private let designSize = CGSize(width: 320, height: 480)
    private let characterCanvas = CGSize(width: 137, height: 200)
    /// Положение спрайта в оригинале: по центру канвы, чуть ниже середины.
    private let characterOrigin = CGPoint(x: 91.5, y: 170)

    private let stageView = UIView()
    private let backgroundView = UIImageView()
    private var bacteriaViews: [BacteriaView] = []
    private let needleView = BacteriaView()
    private let pillView = UIImageView()
    private let recordButton = UIButton(type: .custom)
    private let donutButton = UIButton(type: .custom)
    private let injectionButton = UIButton(type: .custom)
    private let pillButton = UIButton(type: .custom)
    private var recordFrames: [UIImage] = []

    private let audioEngine = AVAudioEngine()
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let queue = DispatchQueue(label: "john.audio", qos: .userInitiated)
    private var effects: EffectPlayer?
    private var recorder: VoiceRecorder!

    private var scale: CGFloat = 1
    private var stageFrame: CGRect = .zero
    private var characterFrame: CGRect = .zero

    private var idleTimer: Timer?
    private var recordAnimationTimer: Timer?
    private var recordFrameIndex = 0
    private var isBusy = false
    /// Сколько раз поел — после еды доступна таблетка.
    private var hasEaten = false
    private var pillOnScreen = false
    private var pillVelocity: CGPoint = .zero
    private var pillDisplayLink: CADisplayLink?
    private var pillLastTimestamp: TimeInterval = 0

    private let laughPool = ReactionPool(Reactions.laughPool)
    private let ticklePool = ReactionPool(Reactions.ticklePool)
    private let eatPool = ReactionPool(Reactions.eatPool)
    private var soundPickers: [String: PermutationPicker] = [:]

    private let maxBacteria = 4

    // MARK: - Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.55, green: 0.06, blue: 0.05, alpha: 1)
        buildStage()
        buildControls()
        configureAudio()
        configureRecorder()
        applyLayout()
        startIdle()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyLayout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        recorder.stopEverything()
        stopEffects()
        stopIdle()
        stopRecordAnimation()
        stopPillPhysics()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if recorder.state == .idle { startIdle() }
    }

    func pauseForBackground() {
        recorder.stopEverything()
        stopEffects()
        stopIdle()
        stopRecordAnimation()
        stopPillPhysics()
        bacteriaViews.forEach { $0.stopAndReset() }
        needleView.stopAndReset()
        needleView.isHidden = true
        isBusy = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func resumeFromBackground() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try session.setActive(true)
                if !self.audioEngine.isRunning { try self.audioEngine.start() }
            } catch {
                NSLog("Не удалось вернуть аудиосессию: \(error.localizedDescription)")
            }
        }
        if recorder.state == .idle { startIdle() }
    }

    private func stopEffects() {
        queue.async { [weak self] in
            guard let self else { return }
            self.effects?.stopAll()
            if self.audioEngine.isRunning { self.audioEngine.pause() }
        }
    }

    // MARK: - Построение интерфейса

    private func buildStage() {
        stageView.clipsToBounds = true
        view.addSubview(stageView)

        // Фон оригинала из nib: Blood-3-iphone.jpg, а не мембрана.
        backgroundView.image = uiImage("Blood-3-iphone")
        backgroundView.contentMode = .scaleToFill
        backgroundView.isUserInteractionEnabled = false
        stageView.addSubview(backgroundView)

        let first = BacteriaView()
        first.contentSize = characterCanvas
        stageView.addSubview(first)
        bacteriaViews.append(first)

        needleView.contentSize = designSize
        needleView.isHidden = true
        stageView.addSubview(needleView)

        // Таблетка на экране — pill-50.png, как в BacteriaPillView.
        pillView.image = uiImage("pill-50")
        pillView.contentMode = .scaleAspectFit
        pillView.isHidden = true
        pillView.isUserInteractionEnabled = true
        stageView.addSubview(pillView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleStageTap(_:)))
        stageView.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePillPan(_:)))
        pan.delegate = self
        stageView.addGestureRecognizer(pan)
    }

    private func buildControls() {
        recordFrames = (0...3).compactMap { uiImage("RecButton\($0)") }
        recordButton.setImage(recordFrames.first, for: .normal)
        recordButton.imageView?.contentMode = .scaleAspectFit
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        recordButton.accessibilityLabel = "Записать голос"
        view.addSubview(recordButton)

        configureItem(donutButton, image: "gumb-donut-60", action: #selector(feedDonut), label: "Пончик")
        configureItem(injectionButton, image: "injection-60", action: #selector(giveInjection), label: "Шприц")
        configureItem(pillButton, image: "gumb-pill-60", action: #selector(givePill), label: "Таблетка")
        // В оригинале кнопка таблетки скрыта до первой еды.
        pillButton.isHidden = true
        pillButton.alpha = 0
    }

    private func configureItem(_ button: UIButton, image: String, action: Selector, label: String) {
        button.setImage(uiImage(image), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityLabel = label
        button.addTarget(self, action: #selector(itemTouchDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(itemTouchUp(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.addSubview(button)
    }

    /// Раскладка из nib: запись (0,2), пончик (260,272), шприц (260,136), таблетка (260,204).
    private func applyLayout() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let topInset = max(view.safeAreaInsets.top, 8)
        let bottomInset = view.safeAreaInsets.bottom
        let available = CGRect(x: 0, y: topInset,
                               width: bounds.width,
                               height: bounds.height - topInset - bottomInset)
        scale = min(available.width / designSize.width, available.height / designSize.height)
        let stageSize = CGSize(width: designSize.width * scale, height: designSize.height * scale)
        stageFrame = CGRect(x: (bounds.width - stageSize.width) / 2,
                            y: available.minY + (available.height - stageSize.height) / 2,
                            width: stageSize.width, height: stageSize.height)
        stageView.frame = stageFrame
        backgroundView.frame = CGRect(origin: .zero, size: stageSize)

        characterFrame = CGRect(x: characterOrigin.x * scale, y: characterOrigin.y * scale,
                                width: characterCanvas.width * scale, height: characterCanvas.height * scale)
        for (index, bacteria) in bacteriaViews.enumerated() {
            let offset = CGPoint(x: CGFloat(index) * 26 * scale, y: CGFloat(index) * 18 * scale)
            bacteria.frame = characterFrame.offsetBy(dx: offset.x, dy: offset.y)
            bacteria.contentSize = characterFrame.size
        }
        needleView.frame = CGRect(origin: .zero, size: stageSize)
        needleView.contentSize = stageSize

        if pillOnScreen {
            let size = 50 * scale
            pillView.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        }

        // Кнопки в координатах канвы, как в nib.
        func place(_ button: UIButton, x: CGFloat, y: CGFloat, side: CGFloat = 60) {
            button.frame = CGRect(x: stageFrame.minX + x * scale,
                                  y: stageFrame.minY + y * scale,
                                  width: side * scale, height: side * scale)
        }
        place(recordButton, x: 0, y: 2)
        place(donutButton, x: 260, y: 272)
        place(injectionButton, x: 260, y: 136)
        place(pillButton, x: 260, y: 204)
    }

    // MARK: - Звук

    private func configureAudio() {
        queue.async { [weak self] in
            guard let self else { return }
            self.effects = EffectPlayer(engine: self.audioEngine, format: self.audioFormat)
            SoundBank.shared.preloadAll()
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try AVAudioSession.sharedInstance().setActive(true)
                self.audioEngine.prepare()
                try self.audioEngine.start()
            } catch {
                NSLog("Аудиодвижок эффектов не запустился: \(error.localizedDescription)")
            }
        }
    }

    private func configureRecorder() {
        recorder = VoiceRecorder(engine: audioEngine, graphQueue: queue, format: audioFormat)
        recorder.onStateChanged = { [weak self] state in
            self?.handleRecorderState(state)
        }
    }

    // MARK: - Реакции

    @objc private func handleStageTap(_ gesture: UITapGestureRecognizer) {
        guard !isBusy, recorder.state == .idle else { return }
        let point = gesture.location(in: stageView)

        if pillOnScreen, pillView.frame.insetBy(dx: -12, dy: -12).contains(point) {
            // Тап по таблетке — толчок в сторону бактерии.
            flickPillTowardBacteria()
            return
        }
        guard characterFrame.contains(point) else { return }
        let relativeY = (point.y - characterFrame.minY) / characterFrame.height
        if relativeY < 0.42 {
            touchHead()
        } else {
            touchStomach()
        }
    }

    private func touchHead() {
        guard let reaction = laughPool.next() else { return }
        perform(reaction)
    }

    private func touchStomach() {
        guard let reaction = ticklePool.next() else { return }
        perform(reaction)
    }

    /// Пончик: случайная еда из трёх, после еды открывается таблетка.
    @objc private func feedDonut() {
        guard !isBusy, recorder.state == .idle, let reaction = eatPool.next() else { return }
        perform(reaction) { [weak self] in
            guard let self else { return }
            self.hasEaten = true
            self.enableMultiplyButton(true)
            self.spawnPill()
        }
    }

    /// Таблетка из панели: сразу бросаем её на экран, дальше свайп в бактерию.
    @objc private func givePill() {
        guard !isBusy, recorder.state == .idle, hasEaten else { return }
        if !pillOnScreen { spawnPill() }
        flickPillTowardBacteria()
    }

    /// Шприц: бактерия лопается (playPopAnimation) и исчезает, но не «умирает» —
    /// через мгновение появляется новая, как addNewBacteria в оригинале.
    @objc private func giveInjection() {
        guard !isBusy, recorder.state == .idle else { return }
        stopIdle()
        isBusy = true
        removePill()
        guard let needle = ClipLibrary.shared.clip(ClipName.needle) else {
            isBusy = false
            startIdle()
            return
        }
        needleView.isHidden = false
        needleView.play(needle, repeats: 1, fps: 15, completion: { [weak self] in
            guard let self else { return }
            self.needleView.isHidden = true
            self.needleView.stopAndReset()
            self.popBacteria()
        })
    }

    /// Взрыв-«pop»: бактерия растворяется, затем возвращается.
    private func popBacteria() {
        playEffect(.explode)
        guard let explode = ClipLibrary.shared.clip(ClipName.explode) else {
            isBusy = false
            startIdle()
            return
        }
        let target = bacteriaViews.first
        target?.play(explode, repeats: 1, fps: 16, completion: { [weak self] in
            guard let self else { return }
            // Последний кадр explode пустой — бактерия исчезла. Возвращаем её.
            target?.alpha = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                target?.alpha = 1
                self.isBusy = false
                self.startIdle()
            }
        })
    }

    private func perform(_ reaction: Reaction, completion: (() -> Void)? = nil) {
        guard let clip = ClipLibrary.shared.clip(reaction.clipName) else { return }
        stopIdle()
        isBusy = true

        let picker = soundPicker(for: reaction)
        let effect = reaction.sounds[picker.next()]

        queue.async { [weak self] in
            guard let self else { return }
            let buffer = SoundBank.shared.buffer(for: effect)
            let duration = buffer.map { Double($0.frameLength) / $0.format.sampleRate } ?? 0
            DispatchQueue.main.async {
                self.startReaction(clip, reaction: reaction, effect: effect,
                                   buffer: buffer, duration: duration, completion: completion)
            }
        }
    }

    private func startReaction(_ clip: AnimationClip,
                               reaction: Reaction,
                               effect: SoundBank.Effect,
                               buffer: AVAudioPCMBuffer?,
                               duration: TimeInterval,
                               completion: (() -> Void)?) {
        let startFrame = min(reaction.soundFrameStart, clip.frameCount - 1)
        var soundStarted = false
        var soundEndsAt: TimeInterval = 0
        var passesDone = 0

        bacteriaViews.first?.play(
            clip,
            repeats: 0,
            fps: reaction.fps,
            syncGate: {
                passesDone += 1
                guard passesDone >= reaction.minRepeats else { return false }
                guard soundStarted else { return true }
                return CACurrentMediaTime() >= soundEndsAt
            },
            frameSound: { [weak self] frame in
                guard let self, !soundStarted, frame == startFrame else { return }
                soundStarted = true
                soundEndsAt = CACurrentMediaTime() + duration
                if let buffer {
                    self.queue.async { [weak self] in
                        guard let self else { return }
                        if !self.audioEngine.isRunning {
                            do { try self.audioEngine.start() } catch { return }
                        }
                        self.effects?.play(buffer)
                    }
                }
            },
            completion: { [weak self] in
                guard let self else { return }
                self.isBusy = false
                completion?()
                self.startIdle()
            }
        )
    }

    private func soundPicker(for reaction: Reaction) -> PermutationPicker {
        if let existing = soundPickers[reaction.clipName] { return existing }
        let picker = PermutationPicker(count: reaction.sounds.count)
        soundPickers[reaction.clipName] = picker
        return picker
    }

    private func playEffect(_ effect: SoundBank.Effect) {
        queue.async { [weak self] in
            guard let self, let buffer = SoundBank.shared.buffer(for: effect) else { return }
            if !self.audioEngine.isRunning {
                do { try self.audioEngine.start() } catch { return }
            }
            self.effects?.play(buffer)
        }
    }

    // MARK: - Таблетка и размножение

    /// Кнопка таблетки появляется после еды — enableBacteriaMultiplyButton:.
    private func enableMultiplyButton(_ enabled: Bool) {
        guard enabled else { return }
        guard pillButton.isHidden else { return }
        pillButton.isHidden = false
        UIView.animate(withDuration: 0.3) { self.pillButton.alpha = 1 }
    }

    /// Таблетка выпадает в случайное место — getRandomPositionOnScreen.
    private func spawnPill() {
        guard !pillOnScreen else { return }
        pillOnScreen = true
        let side = 50 * scale
        let x = CGFloat.random(in: (30 * scale)...(stageFrame.width - side - 30 * scale))
        let y = CGFloat.random(in: (40 * scale)...(stageFrame.height - side - 60 * scale))
        pillView.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        pillView.center = CGPoint(x: x + side / 2, y: y + side / 2)
        pillView.alpha = 0
        pillView.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        pillView.isHidden = false
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.6,
                       initialSpringVelocity: 0.5, options: []) {
            self.pillView.alpha = 1
            self.pillView.transform = .identity
        }
        pillVelocity = .zero
        startPillPhysics()
    }

    private func removePill() {
        stopPillPhysics()
        pillOnScreen = false
        pillView.isHidden = true
        pillView.transform = .identity
    }

    /// Свайп: тащим таблетку пальцем, при отпускании она летит по инерции.
    @objc private func handlePillPan(_ gesture: UIPanGestureRecognizer) {
        guard pillOnScreen, !isBusy else { return }
        let location = gesture.location(in: stageView)
        switch gesture.state {
        case .began:
            guard pillView.frame.insetBy(dx: -20, dy: -20).contains(location) else { return }
            stopPillPhysics()
        case .changed:
            pillView.center = location
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: stageView)
            pillVelocity = CGPoint(x: velocity.x * 0.35, y: velocity.y * 0.35)
            startPillPhysics()
        default:
            break
        }
    }

    private func flickPillTowardBacteria() {
        guard pillOnScreen else { return }
        let target = CGPoint(x: characterFrame.midX, y: characterFrame.midY)
        let dx = target.x - pillView.center.x
        let dy = target.y - pillView.center.y
        let length = max(sqrt(dx * dx + dy * dy), 1)
        let speed: CGFloat = 900 * scale
        pillVelocity = CGPoint(x: dx / length * speed, y: dy / length * speed)
        startPillPhysics()
    }

    private func startPillPhysics() {
        guard pillDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepPill(_:)))
        link.add(to: .main, forMode: .common)
        pillDisplayLink = link
        pillLastTimestamp = 0
    }

    private func stopPillPhysics() {
        pillDisplayLink?.invalidate()
        pillDisplayLink = nil
    }

    @objc private func stepPill(_ link: CADisplayLink) {
        guard pillOnScreen else { stopPillPhysics(); return }
        if pillLastTimestamp == 0 {
            pillLastTimestamp = link.timestamp
            return
        }
        let dt = min(link.timestamp - pillLastTimestamp, 1.0 / 30.0)
        pillLastTimestamp = link.timestamp

        var center = pillView.center
        center.x += pillVelocity.x * dt
        center.y += pillVelocity.y * dt
        // Затухание, как movePillWithAcceleration в оригинале.
        pillVelocity.x *= 0.985
        pillVelocity.y *= 0.985

        let radius = pillView.bounds.width / 2
        if center.x < radius || center.x > stageFrame.width - radius {
            pillVelocity.x *= -0.6
            center.x = min(max(center.x, radius), stageFrame.width - radius)
        }
        if center.y < radius || center.y > stageFrame.height - radius {
            pillVelocity.y *= -0.6
            center.y = min(max(center.y, radius), stageFrame.height - radius)
        }
        pillView.center = center

        // Попадание в бактерию — _bacteriaRadiusAndPillSquared.
        let bacteriaCenter = CGPoint(x: characterFrame.midX, y: characterFrame.midY)
        let dx = center.x - bacteriaCenter.x
        let dy = center.y - bacteriaCenter.y
        let hitRadius = characterFrame.width * 0.42 + radius
        if dx * dx + dy * dy < hitRadius * hitRadius {
            consumePill()
            return
        }
        if abs(pillVelocity.x) < 4 && abs(pillVelocity.y) < 4 {
            pillVelocity = .zero
            stopPillPhysics()
        }
    }

    /// Таблетка попала в бактерию: исчезает внизу и запускает размножение.
    private func consumePill() {
        stopPillPhysics()
        pillOnScreen = false
        playEffect(.multiply)

        // Таблетка «проваливается» вниз и пропадает.
        UIView.animate(withDuration: 0.3, animations: {
            self.pillView.center = CGPoint(x: self.pillView.center.x,
                                           y: self.stageFrame.height + 40)
            self.pillView.alpha = 0
        }, completion: { _ in
            self.pillView.isHidden = true
            self.pillView.alpha = 1
            self.pillView.transform = .identity
        })

        multiplyBacteria()
    }

    /// duplicateBacteria + playNewbornMultiplyAnimation.
    private func multiplyBacteria() {
        guard let clip = ClipLibrary.shared.clip(ClipName.multiply) else { return }
        stopIdle()
        isBusy = true
        bacteriaViews.first?.play(clip, repeats: 2, fps: 12, completion: { [weak self] in
            guard let self else { return }
            self.addNewBacteria()
            self.isBusy = false
            self.startIdle()
        })
    }

    private func addNewBacteria() {
        guard bacteriaViews.count < maxBacteria else { return }
        let newborn = BacteriaView()
        newborn.contentSize = characterFrame.size
        let index = bacteriaViews.count
        newborn.frame = characterFrame.offsetBy(dx: CGFloat(index) * 26 * scale,
                                                dy: CGFloat(index) * 18 * scale)
        newborn.alpha = 0
        newborn.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        stageView.insertSubview(newborn, belowSubview: needleView)
        bacteriaViews.append(newborn)
        if let base = ClipLibrary.shared.clip(ClipName.idleBase) {
            newborn.play(base, repeats: 0, fps: 8)
        }
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.65,
                       initialSpringVelocity: 0.4, options: []) {
            newborn.alpha = 1
            newborn.transform = .identity
        }
    }

    // MARK: - Покой

    private func startIdle() {
        guard recorder.state == .idle, !isBusy else { return }
        if let base = ClipLibrary.shared.clip(ClipName.idleBase) {
            bacteriaViews.forEach { $0.play(base, repeats: 0, fps: 8) }
        }
        scheduleIdleAction()
    }

    private func stopIdle() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func scheduleIdleAction() {
        stopIdle()
        let delay = Double.random(in: 2.6...5.4)
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.playRandomIdle()
        }
    }

    private func playRandomIdle() {
        guard recorder.state == .idle, !isBusy else { return }
        let names = [ClipName.blink, ClipName.sway, ClipName.lookLeftRight,
                     ClipName.bumpLeftRight, ClipName.bumpUpDown]
        guard let clip = ClipLibrary.shared.random(from: names) else { return }
        isBusy = true
        bacteriaViews.first?.play(clip, repeats: 1, fps: clip.name == ClipName.blink ? 10 : 13,
                                  completion: { [weak self] in
            guard let self else { return }
            self.isBusy = false
            self.startIdle()
        })
    }

    // MARK: - Запись голоса

    @objc private func toggleRecording() {
        switch recorder.state {
        case .listening:
            recorder.stopListeningAndSpeak()
        case .speaking:
            recorder.stopSpeaking()
        case .idle, .failed:
            guard !isBusy else { return }
            requestMicrophone { [weak self] granted in
                guard let self else { return }
                guard granted else { return }
                self.stopIdle()
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.effects?.stopAll()
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playAndRecord, mode: .default,
                                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
                        try session.setActive(true)
                        if !self.audioEngine.isRunning { try self.audioEngine.start() }
                    } catch {
                        return
                    }
                    DispatchQueue.main.async { self.recorder.beginListening() }
                }
            }
        }
    }

    private func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    private func handleRecorderState(_ state: VoiceRecorder.State) {
        switch state {
        case .idle:
            stopRecordAnimation()
            isBusy = false
            startIdle()
        case .listening:
            isBusy = true
            stopIdle()
            if let listen = ClipLibrary.shared.clip(ClipName.listen) {
                bacteriaViews.first?.play(listen, repeats: 0, fps: 8)
            }
            startRecordAnimation()
        case .speaking:
            stopRecordAnimation()
            if let talk = ClipLibrary.shared.clip(ClipName.talk) {
                bacteriaViews.first?.play(talk, repeats: 0, fps: 14)
            }
        case .failed:
            stopRecordAnimation()
            isBusy = false
            startIdle()
        }
    }

    private func startRecordAnimation() {
        stopRecordAnimation()
        recordFrameIndex = 0
        recordAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            guard let self, !self.recordFrames.isEmpty else { return }
            self.recordFrameIndex = (self.recordFrameIndex + 1) % self.recordFrames.count
            self.recordButton.setImage(self.recordFrames[self.recordFrameIndex], for: .normal)
        }
    }

    private func stopRecordAnimation() {
        recordAnimationTimer?.invalidate()
        recordAnimationTimer = nil
        recordButton.setImage(recordFrames.first, for: .normal)
    }

    // MARK: - Мелочи

    @objc private func itemTouchDown(_ sender: UIButton) {
        UIView.animate(withDuration: 0.1) { sender.transform = CGAffineTransform(scaleX: 0.88, y: 0.88) }
    }

    @objc private func itemTouchUp(_ sender: UIButton) {
        UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.55,
                       initialSpringVelocity: 0.4, options: []) {
            sender.transform = .identity
        }
    }

    private func uiImage(_ name: String) -> UIImage? {
        if let image = UIImage(named: name) { return image }
        for candidate in [name + "@2x", name] {
            for ext in ["png", "jpg"] {
                if let url = BundleLocator.file(directory: "UI", name: candidate, extension: ext),
                   let image = UIImage(contentsOfFile: url.path) {
                    return image
                }
            }
        }
        return nil
    }
}

extension GameViewController: UIGestureRecognizerDelegate {
    /// Пан работает только по таблетке, тап — по всему остальному.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer, pillOnScreen else {
            return !(gestureRecognizer is UIPanGestureRecognizer)
        }
        let point = gestureRecognizer.location(in: stageView)
        return pillView.frame.insetBy(dx: -20, dy: -20).contains(point)
    }
}