import AVFoundation
import QuartzCore
import UIKit

final class GameViewController: UIViewController {

    private let designSize = CGSize(width: 320, height: 480)
    private let characterCanvas = CGSize(width: 137, height: 200)

    private let stageView = UIView()
    private let backgroundView = UIImageView()
    private var bacteriaViews: [BacteriaView] = []
    private let needleView = BacteriaView()
    private let pillView = UIImageView()
    private let donutButton = UIButton(type: .custom)
    private let injectionButton = UIButton(type: .custom)
    private let pillButton = UIButton(type: .custom)

    private let audioEngine = AVAudioEngine()
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let queue = DispatchQueue(label: "john.audio", qos: .userInitiated)
    private var effects: EffectPlayer?
    private var recorder: VoiceRecorder!

    private var talkers: [BacteriaView] = []

    private var scale: CGFloat = 1
    private var previousScale: CGFloat = 0
    private var stageFrame: CGRect = .zero

    private var idleTimer: Timer?

    private var busyBacteria = Set<ObjectIdentifier>()

    private var reactingBacteria = Set<ObjectIdentifier>()
    private func isReacting(_ view: BacteriaView) -> Bool {
        reactingBacteria.contains(ObjectIdentifier(view))
    }

    private func isFreeForIdle(_ view: BacteriaView) -> Bool {
        !isBacteriaBusy(view) && !isReacting(view)
    }
    private func isBacteriaBusy(_ view: BacteriaView) -> Bool {
        busyBacteria.contains(ObjectIdentifier(view))
    }
    private var pillOnScreen = false
    private var pillVelocity: CGPoint = .zero
    private var pillDisplayLink: CADisplayLink?
    private var pillLastTimestamp: TimeInterval = 0

    private var pillLastInteraction = Date()
    private let pillIdleTimeout: TimeInterval = 12

    private var eatingCount = 0
    private let maxEating = 2

    private var lastInjectionAt: TimeInterval = 0

    private var bacteriaVelocities: [CGPoint] = []
    private var wanderTimer: Timer?
    private var motionDisplayLink: CADisplayLink?
    private var motionLastTimestamp: TimeInterval = 0

    private var draggedBacteria: BacteriaView?
    private var dragStartPoint: CGPoint = .zero
    private var dragLastPoint: CGPoint = .zero
    private var dragLastTime: TimeInterval = 0
    private var dragVelocity: CGPoint = .zero

    private let laughPool = ReactionPool(Reactions.laughPool)
    private let injectionPool = ReactionPool(Reactions.injectionPool)
    private let eatPool = ReactionPool(Reactions.eatPool)
    private var soundPickers: [String: PermutationPicker] = [:]

    private let maxBacteria = 6

    private let bacteriaDesignHeight: CGFloat = 170
    private var bacteriaHeight: CGFloat { bacteriaDesignHeight * scale }

    private let membraneFraction: CGFloat = 0.90

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.55, green: 0.06, blue: 0.05, alpha: 1)
        buildStage()
        buildControls()
        configureAudio()
        configureRecorder()
        applyLayout()
        startIdle()

        startAlwaysListening()
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
        stopMotion()
        stopPillPhysics()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startIdle()

        startAlwaysListening()
    }

    func pauseForBackground() {
        recorder.stopEverything()
        stopEffects()
        stopIdle()
        stopMotion()
        stopPillPhysics()
        bacteriaViews.forEach { $0.stopAndReset() }
        needleView.stopAndReset()
        needleView.isHidden = true
        draggedBacteria = nil
        busyBacteria.removeAll()
        reactingBacteria.removeAll()
        talkers = []

        eatingCount = 0
        pendingChildren = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func resumeFromBackground() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                try session.setActive(true)
                if !self.audioEngine.isRunning { try self.audioEngine.start() }
            } catch {
                NSLog("Не удалось вернуть аудиосессию: \(error.localizedDescription)")
            }
        }

        startIdle()
        for view in bacteriaViews where isFreeForIdle(view) {
            resumeIdle(for: view)
        }
        startAlwaysListening()
    }

    private func stopEffects() {
        queue.async { [weak self] in
            guard let self else { return }

            self.effects?.stopAll()
        }
    }

    private func buildStage() {
        stageView.clipsToBounds = true
        view.addSubview(stageView)

        backgroundView.image = uiImage("Blood-membrane-iPhone")
        backgroundView.contentMode = .scaleToFill
        backgroundView.isUserInteractionEnabled = false
        stageView.addSubview(backgroundView)

        needleView.contentSize = designSize
        needleView.isHidden = true
        stageView.addSubview(needleView)

        addBacteria()
        addBacteria()

        pillView.image = uiImage("pill-50")
        pillView.contentMode = .scaleAspectFit
        pillView.isHidden = true
        pillView.isUserInteractionEnabled = true
        stageView.addSubview(pillView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleStageTap(_:)))
        stageView.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDragPan(_:)))
        pan.delegate = self
        stageView.addGestureRecognizer(pan)

    }

    @discardableResult
    private func addBacteria() -> BacteriaView {
        let bacteria = BacteriaView()
        bacteria.isUserInteractionEnabled = false
        stageView.insertSubview(bacteria, belowSubview: needleView)
        bacteriaViews.append(bacteria)
        bacteriaVelocities.append(randomWanderVelocityScaled())
        placeBacteria(bacteria)
        if let base = ClipLibrary.shared.clip(ClipName.idleBase) {
            bacteria.play(base, repeats: 0, fps: 8)
        }
        updateDonutButton()
        return bacteria
    }

    private func updateDonutButton() {
        let full = bacteriaViews.count >= maxBacteria
        donutButton.isEnabled = !full
        donutButton.alpha = full ? 0.4 : 1.0
    }

    private func placeBacteria(_ bacteria: BacteriaView) {
        let field = bacteriaField()
        let h = bacteriaHeight
        let w = h * (characterCanvas.width / characterCanvas.height)
        bacteria.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        bacteria.contentSize = CGSize(width: w, height: h)

        let radius = max(w, h) * 0.5
        let xLo = field.minX + radius
        let xHi = max(field.maxX - radius, xLo)
        let yLo = field.minY + radius
        let yHi = max(field.maxY - radius, yLo)
        var best = CGPoint(x: field.midX, y: field.midY)
        var bestScore: CGFloat = -.greatestFiniteMagnitude

        for _ in 0..<24 {
            let x = CGFloat.random(in: xLo...xHi)
            let y = CGFloat.random(in: yLo...yHi)
            let p = CGPoint(x: x, y: y)
            var minDist: CGFloat = .greatestFiniteMagnitude
            for other in bacteriaViews where other !== bacteria {
                minDist = min(minDist, hypot(p.x - other.center.x, p.y - other.center.y))
            }
            if minDist > bestScore { bestScore = minDist; best = p }
            if minDist > radius * 2.2 { break }
        }
        bacteria.center = best
    }

    private func bacteriaField() -> CGRect {
        let w = stageView.bounds.width
        let h = stageView.bounds.height
        let top = max(view.safeAreaInsets.top, 12)
        let bottom = h * membraneFraction
        return CGRect(x: 0, y: top, width: max(w, 100), height: max(bottom - top, 100))
    }

    private func randomWanderVelocity() -> CGPoint {
        let speed = CGFloat.random(in: 18...34)
        let angle = CGFloat.random(in: 0...(2 * .pi))
        return CGPoint(x: cos(angle) * speed, y: sin(angle) * speed)
    }

    private func buildControls() {

        configureItem(donutButton, image: "gumb-donut-60", action: #selector(feedDonut), label: "Пончик")
        configureItem(injectionButton, image: "injection-60", action: #selector(giveInjection), label: "Шприц")
        configureItem(pillButton, image: "gumb-pill-60", action: #selector(givePill), label: "Таблетка")
        pillButton.isHidden = false
        pillButton.alpha = 1
    }

    private func configureItem(_ button: UIButton, image: String, action: Selector, label: String) {
        button.setBackgroundImage(uiImage(image), for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityLabel = label
        button.addTarget(self, action: #selector(itemTouchDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(itemTouchUp(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.addSubview(button)
    }

    private func applyLayout() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        scale = bounds.width / designSize.width
        stageFrame = bounds
        stageView.frame = bounds
        backgroundView.frame = bounds
        let stageSize = bounds.size

        let ratio = previousScale > 0 ? scale / previousScale : 1
        let h = bacteriaHeight
        let w = h * (characterCanvas.width / characterCanvas.height)
        for (index, bacteria) in bacteriaViews.enumerated() {
            if bacteria.frame == .zero {
                placeBacteria(bacteria)
            } else {
                let center = CGPoint(x: bacteria.center.x * ratio, y: bacteria.center.y * ratio)
                bacteria.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                bacteria.center = clampToField(center, halfW: w * 0.5, halfH: h * 0.5)
                if index < bacteriaVelocities.count {
                    bacteriaVelocities[index].x *= ratio
                    bacteriaVelocities[index].y *= ratio
                }
            }
            bacteria.contentSize = CGSize(width: w, height: h)
        }
        previousScale = scale
        needleView.frame = CGRect(origin: .zero, size: stageSize)
        needleView.contentSize = stageSize

        if pillOnScreen {
            let size = 50 * scale
            pillView.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        }

        let side = max(96 * scale, 84)
        let margin: CGFloat = 8
        let topSafe = max(view.safeAreaInsets.top, 12)

        let gap = side + 16
        let columnHeight = gap * 2 + side
        let columnTop = max(topSafe + side + 24, (bounds.height - columnHeight) / 2)
        let rightX = bounds.width - side - margin
        injectionButton.frame = CGRect(x: rightX, y: columnTop, width: side, height: side)
        pillButton.frame = CGRect(x: rightX, y: columnTop + gap, width: side, height: side)
        donutButton.frame = CGRect(x: rightX, y: columnTop + gap * 2, width: side, height: side)
    }

    private func configureAudio() {
        queue.async { [weak self] in
            guard let self else { return }
            self.effects = EffectPlayer(engine: self.audioEngine, format: self.audioFormat)
            SoundBank.shared.preloadAll()
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
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

    @objc private func handleStageTap(_ gesture: UITapGestureRecognizer) {

        let point = gesture.location(in: stageView)

        if pillOnScreen, pillView.frame.insetBy(dx: -12, dy: -12).contains(point) {

            flickPillTowardBacteria()
            return
        }

        guard let target = bacteriaViews.last(where: { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }),
              !isBacteriaBusy(target) else { return }
        interruptVoice(for: target)
        popBacteria(target)
    }

    private func pokeBacteria(_ target: BacteriaView, kickVelocity: CGPoint? = nil) {
        interruptVoice(for: target)
        if let index = bacteriaViews.firstIndex(where: { $0 === target }) {
            if let kickVelocity {
                bacteriaVelocities[index] = kickVelocity
            } else {
                let angle = CGFloat.random(in: 0...(2 * .pi))
                let kick = CGFloat.random(in: 60...110) * scale
                bacteriaVelocities[index] = CGPoint(x: cos(angle) * kick, y: sin(angle) * kick)
            }
        }
        pokeCounts[ObjectIdentifier(target), default: 0] += 1
        scheduleLaughCheck()
    }

    private var pokeCounts: [ObjectIdentifier: Int] = [:]
    private var laughCheckTimer: Timer?

    private func scheduleLaughCheck() {
        guard laughCheckTimer == nil else { return }
        laughCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkLaughAfterPokes()
        }
    }

    private func checkLaughAfterPokes() {

        var anyPending = false
        for (index, bacteria) in bacteriaViews.enumerated() {
            let id = ObjectIdentifier(bacteria)
            guard let count = pokeCounts[id], count >= 2 else {
                if pokeCounts[id] != nil { anyPending = true }
                continue
            }
            if isBacteriaBusy(bacteria) { anyPending = true; continue }
            let speed = index < bacteriaVelocities.count
                ? hypot(bacteriaVelocities[index].x, bacteriaVelocities[index].y) : 0
            if speed > 40 * scale { anyPending = true; continue }

            pokeCounts[id] = nil
            if let reaction = laughPool.next() {
                perform(reaction, on: bacteria, exclusive: false)
            }
        }
        if !anyPending && pokeCounts.isEmpty {
            laughCheckTimer?.invalidate()
            laughCheckTimer = nil
        }
    }

    @objc private func feedDonut() {
        guard eatingCount < maxEating,
              bacteriaViews.count + pendingChildren < maxBacteria,
              let reaction = eatPool.next() else { return }

        guard let target = bacteriaViews.filter({ !isBacteriaBusy($0) }).randomElement() else { return }
        eatingCount += 1
        perform(reaction, on: target) { [weak self] in
            guard let self else { return }
            self.eatingCount -= 1
            self.multiplyBacteria(from: target)
        }
    }

    private var pendingChildren = 0
    private func multiplyBacteria(from parent: BacteriaView) {
        guard bacteriaViews.count + pendingChildren < maxBacteria,
              let clip = ClipLibrary.shared.clip(ClipName.multiply) else { return }
        pendingChildren += 1
        busyBacteria.insert(ObjectIdentifier(parent))
        playEffect(.multiply)
        parent.play(clip, repeats: 1, fps: 12, completion: { [weak self] in
            guard let self else { return }
            parent.stopAndReset()
            self.busyBacteria.remove(ObjectIdentifier(parent))
            self.pendingChildren -= 1

            guard self.bacteriaViews.count < self.maxBacteria else { return }

            let child = self.addBacteria()

            child.alpha = 0
            child.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.65,
                           initialSpringVelocity: 0.4, options: []) {
                child.alpha = 1
                child.transform = .identity
            } completion: { _ in
                self.resumeIdle(for: child)
                self.resumeIdle(for: parent)
            }
        })
    }

    @objc private func givePill() {

        if pillOnScreen {
            pillLastInteraction = Date()
            return
        }
        spawnPill()
    }

    @objc private func giveInjection() {
        let now = CACurrentMediaTime()
        guard now - lastInjectionAt > 2.0 else { return }
        lastInjectionAt = now
        removePill()
        let needle = ClipLibrary.shared.clip(ClipName.needle)

        let needleFrames = needle?.frameCount ?? 51
        let stabDelay = Double(needleFrames) / 2.0 / 15.0
        if let needle {
            needleView.isHidden = false
            needleView.play(needle, repeats: 1, fps: 15, completion: { [weak self] in
                guard let self else { return }
                self.needleView.isHidden = true
                self.needleView.stopAndReset()
            })
        }

        let free = bacteriaViews.filter { !isBacteriaBusy($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + stabDelay) { [weak self] in
            guard let self else { return }

            guard let reaction = self.injectionPool.next() else { return }
            for bacteria in free where self.bacteriaViews.contains(where: { $0 === bacteria })
                && !self.isBacteriaBusy(bacteria) {
                self.perform(reaction, on: bacteria, exclusive: false)
            }
        }
    }

    private func interruptVoice(for target: BacteriaView) {
        reactingBacteria.remove(ObjectIdentifier(target))
        talkers.removeAll { $0 === target }
    }

    private func popBacteria(_ target: BacteriaView) {
        busyBacteria.insert(ObjectIdentifier(target))
        playEffect(.explode)
        guard let explode = ClipLibrary.shared.clip(ClipName.explode) else {
            removeBacteria(target)
            return
        }
        target.play(explode, repeats: 1, fps: 16, completion: { [weak self] in
            guard let self else { return }
            self.removeBacteria(target)

            if self.bacteriaViews.isEmpty {
                self.spawnLoneBacteria()
            } else {

                self.startIdle()
            }
        })
    }

    private func removeBacteria(_ target: BacteriaView) {
        stopVoice(for: target)
        target.stopAndReset()
        target.removeFromSuperview()
        busyBacteria.remove(ObjectIdentifier(target))
        reactingBacteria.remove(ObjectIdentifier(target))
        if let index = bacteriaViews.firstIndex(where: { $0 === target }) {
            bacteriaViews.remove(at: index)
            if index < bacteriaVelocities.count { bacteriaVelocities.remove(at: index) }
        }
        if draggedBacteria === target { draggedBacteria = nil }
        updateDonutButton()
    }

    private func spawnLoneBacteria() {
        let bacteria = addBacteria()
        bacteria.alpha = 0
        bacteria.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.65,
                       initialSpringVelocity: 0.4, options: []) {
            bacteria.alpha = 1
            bacteria.transform = .identity
        }
    }

    private func perform(_ reaction: Reaction,
                         on target: BacteriaView? = nil,
                         exclusive: Bool = true,
                         completion: (() -> Void)? = nil) {
        guard let clip = ClipLibrary.shared.clip(reaction.clipName) else { return }
        let view = target ?? bacteriaViews.randomElement()
        guard let view, !isBacteriaBusy(view) else { return }
        if exclusive { busyBacteria.insert(ObjectIdentifier(view)) }
        talkers.removeAll { $0 === view }
        reactingBacteria.insert(ObjectIdentifier(view))

        let picker = soundPicker(for: reaction)
        let effect = reaction.sounds[picker.next()]

        queue.async { [weak self] in
            guard let self else { return }
            let buffer = SoundBank.shared.buffer(for: effect)
            DispatchQueue.main.async {
                self.startReaction(clip, on: view, reaction: reaction, effect: effect,
                                   buffer: buffer, completion: completion)
            }
        }
    }

    private func startReaction(_ clip: AnimationClip,
                               on target: BacteriaView,
                               reaction: Reaction,
                               effect: SoundBank.Effect,
                               buffer: AVAudioPCMBuffer?,
                               completion: (() -> Void)?) {
        let startFrame = min(reaction.soundFrameStart, clip.frameCount - 1)
        var soundStarted = false
        var voice = -1

        let clipDuration = Double(clip.frameCount) / reaction.fps
        let playedBuffer: AVAudioPCMBuffer?
        if reaction.trimSoundToClip, let buffer {
            playedBuffer = Self.trim(buffer, toSeconds: clipDuration)
        } else {
            playedBuffer = buffer
        }

        var gate: (() -> Bool)?
        if !reaction.trimSoundToClip {
            gate = { [weak self] in
                guard let self, voice >= 0 else { return true }
                return !(self.effects?.isPlaying(voice: voice) ?? false)
            }
        }

        target.play(
            clip,
            repeats: max(1, reaction.minRepeats),
            fps: reaction.fps,
            syncGate: gate,
            frameSound: { [weak self] frame in
                guard let self, !soundStarted, frame == startFrame else { return }
                soundStarted = true
                if let playedBuffer {
                    self.queue.async { [weak self] in
                        guard let self else { return }
                        if !self.audioEngine.isRunning {
                            do { try self.audioEngine.start() } catch { return }
                        }
                        let (_, idx) = self.effects?.play(playedBuffer) ?? (0, -1)
                        DispatchQueue.main.async { voice = idx }
                    }
                }
            },
            completion: { [weak self] in
                guard let self else { return }
                self.busyBacteria.remove(ObjectIdentifier(target))
                self.reactingBacteria.remove(ObjectIdentifier(target))
                self.stopVoice(for: target)
                completion?()

                if self.bacteriaViews.contains(where: { $0 === target }) {
                    self.resumeIdle(for: target)
                }
            }
        )
        reactionVoices[ObjectIdentifier(target)] = { voice }
    }

    private static func trim(_ buffer: AVAudioPCMBuffer, toSeconds seconds: Double) -> AVAudioPCMBuffer? {
        let maxFrames = AVAudioFrameCount(seconds * buffer.format.sampleRate)
        guard maxFrames > 0, buffer.frameLength > maxFrames,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: maxFrames) else {
            return buffer
        }
        copy.frameLength = maxFrames
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: Int(maxFrames)) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: Int(maxFrames)) }
        } else {
            return buffer
        }
        return copy
    }

    private var reactionVoices: [ObjectIdentifier: () -> Int] = [:]
    private func stopVoice(for target: BacteriaView) {
        let id = ObjectIdentifier(target)
        guard let getter = reactionVoices[id] else { return }
        let v = getter()
        reactionVoices[id] = nil
        guard v >= 0 else { return }
        queue.async { [weak self] in self?.effects?.stop(voice: v) }
    }

    private func resumeIdle(for view: BacteriaView) {
        guard isFreeForIdle(view) else { return }
        if let base = ClipLibrary.shared.clip(ClipName.idleBase) {
            view.play(base, repeats: 0, fps: 8)
        }
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

    private func spawnPill() {
        guard !pillOnScreen else { return }
        pillOnScreen = true
        pillLastInteraction = Date()
        let side = 50 * scale
        pillView.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        pillView.center = CGPoint(x: stageView.bounds.midX, y: stageView.bounds.midY)
        pillView.alpha = 1
        pillView.transform = .identity
        pillView.isHidden = false
        pillVelocity = .zero
        startPillPhysics()
    }

    private func removePill() {
        stopPillPhysics()
        pillOnScreen = false
        pillView.isHidden = true
        pillView.alpha = 1
        pillView.transform = .identity
    }

    @objc private func handleDragPan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: stageView)
        switch gesture.state {
        case .began:
            if pillOnScreen, pillView.frame.insetBy(dx: -24, dy: -24).contains(location) {
                draggedBacteria = nil
                stopPillPhysics()
                pillLastInteraction = Date()
                dragStartPoint = location
                dragLastPoint = location
                dragLastTime = CACurrentMediaTime()
                dragVelocity = .zero
            } else if let grabbed = bacteriaViews.last(where: {
                $0.frame.insetBy(dx: -10, dy: -10).contains(location)
            }), !isBacteriaBusy(grabbed) {

                draggedBacteria = grabbed
                dragStartPoint = location
                dragLastPoint = location
                dragLastTime = CACurrentMediaTime()
                dragVelocity = .zero
            } else {
                draggedBacteria = nil
                gesture.state = .failed
            }
        case .changed:
            let now = CACurrentMediaTime()
            let dt = max(now - dragLastTime, 1.0 / 240.0)
            dragVelocity = CGPoint(x: (location.x - dragLastPoint.x) / dt,
                                   y: (location.y - dragLastPoint.y) / dt)
            dragLastPoint = location
            dragLastTime = now
            if draggedBacteria != nil {

            } else if pillOnScreen {
                pillView.center = clampToField(location, half: pillView.bounds.width / 2)
                pillLastInteraction = Date()
            }
        case .ended, .cancelled:
            if let grabbed = draggedBacteria {
                draggedBacteria = nil

                let dx = location.x - dragStartPoint.x
                let dy = location.y - dragStartPoint.y
                let dist = hypot(dx, dy)
                if dist > 12 * scale {
                    let speed = min(dist * 6, 420 * scale)
                    let kick = CGPoint(x: dx / dist * speed, y: dy / dist * speed)
                    pokeBacteria(grabbed, kickVelocity: kick)
                }
            } else if pillOnScreen {
                pillVelocity = CGPoint(x: dragVelocity.x * 0.5, y: dragVelocity.y * 0.5)
                pillLastInteraction = Date()
                startPillPhysics()
            }
            dragVelocity = .zero
        default:
            break
        }
    }

    private func clampToField(_ point: CGPoint, half: CGFloat) -> CGPoint {
        clampToField(point, halfW: half, halfH: half)
    }

    private func clampToField(_ point: CGPoint, halfW: CGFloat, halfH: CGFloat) -> CGPoint {
        let field = bacteriaField()
        let x = min(max(point.x, field.minX + halfW), field.maxX - halfW)
        let y = min(max(point.y, field.minY + halfH), field.maxY - halfH)
        return CGPoint(x: x, y: y)
    }

    private func flickPillTowardBacteria() {
        guard pillOnScreen else { return }

        guard let victim = bacteriaViews.min(by: { a, b in
            hypot(a.frame.midX - pillView.center.x, a.frame.midY - pillView.center.y) <
            hypot(b.frame.midX - pillView.center.x, b.frame.midY - pillView.center.y)
        }) else { return }
        let target = CGPoint(x: victim.frame.midX, y: victim.frame.midY)
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

    private func startMotion() {
        guard motionDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepMotion(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        motionDisplayLink = link
        motionLastTimestamp = 0
        scheduleWander()
    }

    private func stopMotion() {
        motionDisplayLink?.invalidate()
        motionDisplayLink = nil
        wanderTimer?.invalidate()
        wanderTimer = nil
    }

    private func scheduleWander() {
        wanderTimer?.invalidate()
        wanderTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 1.8...3.6),
                                           repeats: false) { [weak self] _ in
            guard let self else { return }
            for index in self.bacteriaVelocities.indices {

                if self.bacteriaViews.indices.contains(index),
                   self.bacteriaViews[index] === self.draggedBacteria { continue }
                let v = self.bacteriaVelocities[index]
                if hypot(v.x, v.y) < 40 * self.scale {
                    self.bacteriaVelocities[index] = self.randomWanderVelocityScaled()
                }
            }
            self.scheduleWander()
        }
    }

    private func randomWanderVelocityScaled() -> CGPoint {
        let v = randomWanderVelocity()
        return CGPoint(x: v.x * scale, y: v.y * scale)
    }

    @objc private func stepMotion(_ link: CADisplayLink) {

        if motionLastTimestamp == 0 { motionLastTimestamp = link.timestamp; return }
        let dt = min(link.timestamp - motionLastTimestamp, 1.0 / 30.0)
        motionLastTimestamp = link.timestamp

        let field = bacteriaField()
        guard field.width > 0, field.height > 0 else { return }

        for i in bacteriaViews.indices {
            for j in (i + 1)..<bacteriaViews.count {
                let a = bacteriaViews[i]
                let b = bacteriaViews[j]
                if a === draggedBacteria || b === draggedBacteria { continue }
                let dx = b.center.x - a.center.x
                let dy = b.center.y - a.center.y
                let dist = max(hypot(dx, dy), 0.001)
                let minDist = (a.bounds.width + b.bounds.width) * 0.42
                if dist < minDist {
                    let push = (minDist - dist) * 0.5
                    let nx = dx / dist
                    let ny = dy / dist
                    if !isBacteriaBusy(a) {
                        a.center = clampToField(CGPoint(x: a.center.x - nx * push, y: a.center.y - ny * push),
                                                halfW: a.bounds.width * 0.5, halfH: a.bounds.height * 0.5)
                    }
                    if !isBacteriaBusy(b) {
                        b.center = clampToField(CGPoint(x: b.center.x + nx * push, y: b.center.y + ny * push),
                                                halfW: b.bounds.width * 0.5, halfH: b.bounds.height * 0.5)
                    }
                }
            }
        }

        for (index, bacteria) in bacteriaViews.enumerated() {
            guard index < bacteriaVelocities.count else { continue }
            if bacteria === draggedBacteria { continue }

            if isBacteriaBusy(bacteria) { continue }

            var v = bacteriaVelocities[index]
            var center = bacteria.center
            center.x += v.x * dt
            center.y += v.y * dt

            let speed = hypot(v.x, v.y)
            let cruise = 34 * scale
            if speed > cruise {
                let k = max(cruise, speed * 0.97)
                v.x *= k / speed
                v.y *= k / speed
            }

            let halfW = bacteria.bounds.width * 0.5
            let halfH = bacteria.bounds.height * 0.5
            if center.x < field.minX + halfW { center.x = field.minX + halfW; v.x = abs(v.x) }
            if center.x > field.maxX - halfW { center.x = field.maxX - halfW; v.x = -abs(v.x) }
            if center.y < field.minY + halfH { center.y = field.minY + halfH; v.y = abs(v.y) }
            if center.y > field.maxY - halfH { center.y = field.maxY - halfH; v.y = -abs(v.y) }

            bacteria.center = center
            bacteriaVelocities[index] = v
        }
    }

    @objc private func stepPill(_ link: CADisplayLink) {
        guard pillOnScreen else { stopPillPhysics(); return }
        if pillLastTimestamp == 0 {
            pillLastTimestamp = link.timestamp
            return
        }
        let dt = min(link.timestamp - pillLastTimestamp, 1.0 / 30.0)
        pillLastTimestamp = link.timestamp

        if Date().timeIntervalSince(pillLastInteraction) > pillIdleTimeout {
            removePill()
            return
        }

        var center = pillView.center
        center.x += pillVelocity.x * dt
        center.y += pillVelocity.y * dt

        pillVelocity.x *= 0.985
        pillVelocity.y *= 0.985

        let radius = pillView.bounds.width / 2

        let field = bacteriaField()
        if center.x < field.minX + radius || center.x > field.maxX - radius {
            pillVelocity.x *= -0.6
            center.x = min(max(center.x, field.minX + radius), field.maxX - radius)
        }
        if center.y < field.minY + radius || center.y > field.maxY - radius {
            pillVelocity.y *= -0.6
            center.y = min(max(center.y, field.minY + radius), field.maxY - radius)
        }
        pillView.center = center

        if let victim = bacteriaViews.first(where: { bacteria in
            guard !isBacteriaBusy(bacteria) else { return false }
            let dx = center.x - bacteria.frame.midX
            let dy = center.y - bacteria.frame.midY
            let hitRadius = bacteria.frame.width * 0.42 + radius
            return dx * dx + dy * dy < hitRadius * hitRadius
        }) {
            consumePill(on: victim)
        }

        if abs(pillVelocity.x) < 2 && abs(pillVelocity.y) < 2 {
            pillVelocity = .zero
        }
    }

    private func consumePill(on victim: BacteriaView) {

        guard !isBacteriaBusy(victim) else { return }
        pillLastInteraction = Date()

        popBacteria(victim)
    }

    private func startIdle() {

        if let base = ClipLibrary.shared.clip(ClipName.idleBase) {
            for view in bacteriaViews where isFreeForIdle(view) {
                view.play(base, repeats: 0, fps: 8)
            }
        }
        startMotion()
        scheduleIdleAction()
    }

    private func stopIdle() {
        idleTimer?.invalidate()
        idleTimer = nil
        stopMotion()
    }

    private func scheduleIdleAction() {
        idleTimer?.invalidate()

        let delay = Double.random(in: 2.5...5.0)
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.playRandomIdle()
            self?.scheduleIdleAction()
        }
    }

    private func playRandomIdle() {

        let names = [ClipName.bumpUpDown, ClipName.bumpLeftRight,
                     ClipName.bumpUpDown, ClipName.lookLeftRight]
        guard let clip = ClipLibrary.shared.random(from: names),
              let target = bacteriaViews.filter({ isFreeForIdle($0) }).randomElement() else { return }
        target.play(clip, repeats: 1, fps: 13, completion: { [weak self] in
            guard let self else { return }
            self.resumeIdle(for: target)
        })
    }

    private func startAlwaysListening() {
        requestMicrophone { [weak self] granted in
            guard let self, granted else { return }

            self.queue.async { [weak self] in
                guard let self else { return }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                    try session.setActive(true)
                } catch { return }
                self.recorder.beginListening()
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
            finishVoiceRepeat()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.startAlwaysListening()
            }
        case .listening:
            if let listen = ClipLibrary.shared.clip(ClipName.listen) {
                let free = bacteriaViews.filter { isFreeForIdle($0) }
                talkers = free
                for view in free {
                    reactingBacteria.insert(ObjectIdentifier(view))
                    view.play(listen, repeats: 0, fps: 8)
                }
            }
        case .speaking:
            if let talk = ClipLibrary.shared.clip(ClipName.talk) {
                for view in talkers where bacteriaViews.contains(where: { $0 === view }) {
                    reactingBacteria.insert(ObjectIdentifier(view))
                    view.play(talk, repeats: 0, fps: 14)
                }
            }
        case .failed:
            finishVoiceRepeat()

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startAlwaysListening()
            }
        }
    }

    private func finishVoiceRepeat() {
        for view in talkers {
            reactingBacteria.remove(ObjectIdentifier(view))
            resumeIdle(for: view)
        }
        talkers = []
    }

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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }

        let point = gestureRecognizer.location(in: stageView)

        if pillOnScreen, pillView.frame.insetBy(dx: -24, dy: -24).contains(point) { return true }
        return bacteriaViews.contains { $0.frame.insetBy(dx: -10, dy: -10).contains(point) }
    }
}
