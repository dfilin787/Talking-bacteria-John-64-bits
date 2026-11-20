import AVFoundation
import QuartzCore
import UIKit

/// Главный экран. Логика повторяет оригинальный `TalkingBacteriaViewController`:
/// тап по голове — смех, по животу — щекотка, пончик — еда, таблетка — деление,
/// шприц — полноэкранная сцена, кнопка записи — «повтори за мной».
final class GameViewController: UIViewController {

    // Дизайн-канва оригинала: 320×480 точек.
    private let designSize = CGSize(width: 320, height: 480)
    private let characterCanvas = CGSize(width: 137, height: 200)
    private let characterOrigin = CGPoint(x: 91.5, y: 168)

    private let stageView = UIView()
    private let backgroundView = UIImageView()
    private let bacteriaView = BacteriaView()
    private let needleView = BacteriaView()
    private let levelBar = UIView()
    private let levelFill = UIView()
    private let hintLabel = UILabel()
    private let recordButton = UIButton(type: .custom)
    private var itemButtons: [UIButton] = []
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
    private var levelTimer: Timer?
    private var recordFrameIndex = 0
    private var isBusy = false
    private let laughPool = ReactionPool(Reactions.laughPool)
    private let ticklePool = ReactionPool(Reactions.ticklePool)
    private var soundPickers: [String: PermutationPicker] = [:]

    // MARK: - Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.16, green: 0.06, blue: 0.05, alpha: 1)
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
        stopLevelMeter()
        stopRecordAnimation()
    }

    private func stopEffects() {
        queue.async { [weak self] in
            guard let self else { return }
            self.effects?.stopAll()
            if self.audioEngine.isRunning { self.audioEngine.pause() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if recorder.state == .idle { startIdle() }
    }

    /// Вызывается сценой при уходе в фон: глушим звук и таймеры.
    func pauseForBackground() {
        recorder.stopEverything()
        stopEffects()
        stopIdle()
        stopLevelMeter()
        stopRecordAnimation()
        bacteriaView.stopAndReset()
        needleView.stopAndReset()
        needleView.isHidden = true
        bacteriaView.isHidden = false
        isBusy = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Возврат из фона: поднимаем сессию и покой.
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

    // MARK: - Построение интерфейса

    private func buildStage() {
        stageView.clipsToBounds = true
        view.addSubview(stageView)

        backgroundView.image = uiImage("bacteriaBackground")
        backgroundView.contentMode = .scaleToFill
        backgroundView.isUserInteractionEnabled = false
        stageView.addSubview(backgroundView)

        bacteriaView.contentSize = characterCanvas
        stageView.addSubview(bacteriaView)

        needleView.contentSize = designSize
        needleView.isHidden = true
        stageView.addSubview(needleView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleStageTap(_:)))
        stageView.addGestureRecognizer(tap)

        hintLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hintLabel.textColor = UIColor(white: 1, alpha: 0.92)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.text = "Погладь голову, пощекочи живот или дай пончик"
        hintLabel.layer.shadowColor = UIColor.black.cgColor
        hintLabel.layer.shadowOpacity = 0.6
        hintLabel.layer.shadowRadius = 3
        hintLabel.layer.shadowOffset = .zero
        view.addSubview(hintLabel)

        levelBar.backgroundColor = UIColor(white: 1, alpha: 0.22)
        levelBar.layer.cornerRadius = 3
        levelBar.isHidden = true
        levelBar.clipsToBounds = true
        view.addSubview(levelBar)

        levelFill.backgroundColor = UIColor(red: 1, green: 0.42, blue: 0.35, alpha: 1)
        levelFill.layer.cornerRadius = 3
        levelBar.addSubview(levelFill)
    }

    private func buildControls() {
        recordFrames = (0...3).compactMap { uiImage("RecButton\($0)") }
        recordButton.setImage(recordFrames.first, for: .normal)
        recordButton.imageView?.contentMode = .scaleAspectFit
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        recordButton.accessibilityLabel = "Записать голос"
        view.addSubview(recordButton)

        let items: [(String, Selector, String)] = [
            ("gumb-donut-60", #selector(feedDonut), "Пончик"),
            ("gumb-donut2-60", #selector(feedSecondDonut), "Второй пончик"),
            ("gumb-pill-60", #selector(givePill), "Таблетка"),
            ("injection-60", #selector(giveInjection), "Шприц")
        ]
        for (asset, action, label) in items {
            let button = UIButton(type: .custom)
            button.setImage(uiImage(asset), for: .normal)
            button.imageView?.contentMode = .scaleAspectFit
            button.addTarget(self, action: action, for: .touchUpInside)
            button.accessibilityLabel = label
            button.addTarget(self, action: #selector(itemTouchDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(itemTouchUp(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
            view.addSubview(button)
            itemButtons.append(button)
        }
    }

    private func applyLayout() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let bottomInset = view.safeAreaInsets.bottom
        let topInset = max(view.safeAreaInsets.top, 12)
        let controlHeight: CGFloat = 76
        let available = CGRect(x: 0, y: topInset,
                               width: bounds.width,
                               height: bounds.height - topInset - bottomInset - controlHeight - 34)

        scale = min(available.width / designSize.width, available.height / designSize.height)
        let stageSize = CGSize(width: designSize.width * scale, height: designSize.height * scale)
        stageFrame = CGRect(x: (bounds.width - stageSize.width) / 2,
                            y: available.minY + (available.height - stageSize.height) / 2,
                            width: stageSize.width, height: stageSize.height)
        stageView.frame = stageFrame
        backgroundView.frame = CGRect(origin: .zero, size: stageSize)

        characterFrame = CGRect(x: characterOrigin.x * scale, y: characterOrigin.y * scale,
                                width: characterCanvas.width * scale, height: characterCanvas.height * scale)
        bacteriaView.frame = characterFrame
        bacteriaView.contentSize = characterFrame.size
        needleView.frame = CGRect(origin: .zero, size: stageSize)
        needleView.contentSize = stageSize

        let buttonSize: CGFloat = 60
        let spacing: CGFloat = 14
        let totalWidth = CGFloat(itemButtons.count + 1) * buttonSize + CGFloat(itemButtons.count) * spacing
        var x = (bounds.width - totalWidth) / 2
        let y = bounds.height - bottomInset - buttonSize - 12

        recordButton.frame = CGRect(x: x, y: y, width: buttonSize, height: buttonSize)
        x += buttonSize + spacing
        for button in itemButtons {
            button.frame = CGRect(x: x, y: y, width: buttonSize, height: buttonSize)
            x += buttonSize + spacing
        }

        hintLabel.frame = CGRect(x: 16, y: stageFrame.maxY + 6,
                                 width: bounds.width - 32, height: 30)
        levelBar.frame = CGRect(x: bounds.width / 2 - 60, y: stageFrame.maxY + 2,
                                width: 120, height: 6)
        levelFill.frame = CGRect(x: 0, y: 0, width: 0, height: 6)
    }

    // MARK: - Звук

    private func configureAudio() {
        // Подключение узлов и старт движка — только на одной очереди:
        // AVAudioEngine не переживает конкурентные connect/start.
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
                // Без звука игра остаётся играбельной — анимации работают.
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
        guard characterFrame.contains(point) else {
            playRandomIdle()
            return
        }
        let relativeY = (point.y - characterFrame.minY) / characterFrame.height
        if relativeY < 0.42 {
            touchHead()
        } else {
            touchStomach()
        }
    }

    private func touchHead() {
        guard let reaction = laughPool.next() else { return }
        showHint("Хи-хи-хи!")
        perform(reaction)
    }

    private func touchStomach() {
        guard let reaction = ticklePool.next() else { return }
        showHint("Щекотно!")
        perform(reaction)
    }

    @objc private func feedDonut() {
        guard !isBusy, recorder.state == .idle else { return }
        showHint("Ням!")
        perform(Reactions.eatPink)
    }

    @objc private func feedSecondDonut() {
        guard !isBusy, recorder.state == .idle else { return }
        showHint("Ням-ням!")
        perform(Reactions.eatOrange)
    }

    @objc private func givePill() {
        guard !isBusy, recorder.state == .idle else { return }
        showHint("Делится!")
        perform(Reactions.multiply)
    }

    /// Проигрывает реакцию по модели оригинала: клип крутится, пока звучит
    /// привязанный к кадру звук (`waitForSoundSync`), но не меньше minRepeats проходов.
    private func perform(_ reaction: Reaction) {
        guard let clip = ClipLibrary.shared.clip(reaction.clipName) else { return }
        stopIdle()
        isBusy = true

        let picker = soundPicker(for: reaction)
        let effect = reaction.sounds[picker.next()]

        // Длительность узнаём заранее: запуск звука асинхронный, и опрашивать
        // «тихо ли сейчас» на первой границе прохода нельзя — звук ещё не стартовал.
        queue.async { [weak self] in
            guard let self else { return }
            let buffer = SoundBank.shared.buffer(for: effect)
            let duration = buffer.map { Double($0.frameLength) / $0.format.sampleRate } ?? 0
            DispatchQueue.main.async {
                self.startReaction(clip, reaction: reaction, effect: effect,
                                   buffer: buffer, duration: duration)
            }
        }
    }

    private func startReaction(_ clip: AnimationClip,
                               reaction: Reaction,
                               effect: SoundBank.Effect,
                               buffer: AVAudioPCMBuffer?,
                               duration: TimeInterval) {
        let startFrame = min(reaction.soundFrameStart, clip.frameCount - 1)
        var soundStarted = false
        var soundEndsAt: TimeInterval = 0
        var passesDone = 0

        bacteriaView.play(
            clip,
            repeats: 0,
            fps: reaction.fps,
            syncGate: {
                // Вызывается ровно один раз на границе прохода клипа.
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

    @objc private func giveInjection() {
        guard !isBusy, recorder.state == .idle else { return }
        stopIdle()
        isBusy = true
        showHint("Ой!")
        guard let needle = ClipLibrary.shared.clip(ClipName.needle) else {
            isBusy = false
            startIdle()
            return
        }
        needleView.isHidden = false
        bacteriaView.isHidden = true
        needleView.play(needle, repeats: 1, fps: 15, completion: { [weak self] in
            guard let self else { return }
            self.needleView.isHidden = true
            self.needleView.stopAndReset()
            self.bacteriaView.isHidden = false
            self.perform(Reactions.explode)
        })
    }

    // MARK: - Покой

    private func startIdle() {
        guard recorder.state == .idle, !isBusy else { return }
        if let base = ClipLibrary.shared.clip(ClipName.idleBase) {
            bacteriaView.play(base, repeats: 0, fps: 8)
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
        bacteriaView.play(clip, repeats: 1, fps: clip.name == ClipName.blink ? 10 : 13,
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
                guard granted else {
                    self.showHint("Нужен доступ к микрофону")
                    return
                }
                self.stopIdle()
                // Сессия могла быть деактивирована при уходе в фон — поднимаем её
                // до того, как движок начнёт читать вход микрофона.
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
                        DispatchQueue.main.async { self.showHint("Звук недоступен") }
                        return
                    }
                    DispatchQueue.main.async {
                        self.recorder.beginListening()
                        self.showHint("Говори — я повторю")
                    }
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
            stopLevelMeter()
            levelBar.isHidden = true
            isBusy = false
            showHint("Погладь голову, пощекочи живот или дай пончик")
            startIdle()
        case .listening:
            isBusy = true
            stopIdle()
            if let listen = ClipLibrary.shared.clip(ClipName.listen) {
                bacteriaView.play(listen, repeats: 0, fps: 8)
            }
            levelBar.isHidden = false
            startRecordAnimation()
            startLevelMeter()
        case .speaking:
            stopRecordAnimation()
            stopLevelMeter()
            levelBar.isHidden = true
            showHint("Повторяю!")
            if let talk = ClipLibrary.shared.clip(ClipName.talk) {
                bacteriaView.play(talk, repeats: 0, fps: 14)
            }
        case .failed(let message):
            stopRecordAnimation()
            stopLevelMeter()
            levelBar.isHidden = true
            isBusy = false
            showHint(message)
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

    private func startLevelMeter() {
        stopLevelMeter()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let normalized = min(1, CGFloat(self.recorder.level) * 9)
            let width = self.levelBar.bounds.width * normalized
            UIView.animate(withDuration: 0.08) {
                self.levelFill.frame = CGRect(x: 0, y: 0, width: width, height: self.levelBar.bounds.height)
            }
        }
    }

    private func stopLevelMeter() {
        levelTimer?.invalidate()
        levelTimer = nil
        levelFill.frame = CGRect(x: 0, y: 0, width: 0, height: levelBar.bounds.height)
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

    private func showHint(_ text: String) {
        hintLabel.text = text
    }

    private func uiImage(_ name: String) -> UIImage? {
        if let image = UIImage(named: name) { return image }
        // Сначала @2x — на Retina-экране оригинальные кнопки как раз удвоенные.
        for candidate in [name + "@2x", name] {
            if let url = BundleLocator.file(directory: "UI", name: candidate, extension: "png"),
               let image = UIImage(contentsOfFile: url.path) {
                return image
            }
        }
        return nil
    }
}