import AVFoundation
import QuartzCore
import UIKit

/// Главный экран. Раскладка и поведение восстановлены по видео геймплея
/// и дизассемблеру оригинала (armv7, `TalkingCatViewController`).
///
/// Фон — Blood-membrane-iPhone.jpg: красное поле, розовая мембрана и оранжевый
/// низ на всю канву 320×480. Кнопка записи слева сверху, справа столбиком
/// шприц (260,136), аптечка (260,204), пончик (260,272).
///
/// Логика оригинала:
/// - пончик → `playRandomEatAnimation`, затем `enableBacteriaMultiplyButton:`
///   открывает размножение: бактерия делится (`multiply`, `duplicateBacteria`);
/// - аптечка → `touchBacteriaPill` спавнит таблетку (`BacteriaPillView`,
///   `getRandomPositionOnScreen`); смахнул в бактерию → `playPopAnimation:`
///   (клип `explode`: бактерия рассыпается кольцом пузырей и исчезает);
/// - шприц → `startPlayingNeedleAnimation`, бактерия ржёт;
/// - `maxAvailableBacterias` = 6, стартуют две бактерии.
final class GameViewController: UIViewController {

    // Дизайн-канва оригинала.
    private let designSize = CGSize(width: 320, height: 480)
    private let characterCanvas = CGSize(width: 137, height: 200)
    /// Положение спрайта в оригинале: по центру канвы, чуть ниже середины.

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
    private var sceneRecorder: SceneRecorder!
    private var recordingBadge: UIView?
    /// Бактерия, которая слушает/повторяет голос (долгое нажатие на камеру).
    private var talker: BacteriaView?
    /// Счётчик толчков по бактерии: смех не моментальный, а после 2-3 толчков,
    /// когда бактерия остановится (как lastLaughTickle/isLaughing в оригинале).
    private var pokeCounts: [ObjectIdentifier: Int] = [:]
    private var laughCheckTimer: Timer?

    private var scale: CGFloat = 1
    private var previousScale: CGFloat = 0
    private var stageFrame: CGRect = .zero

    private var idleTimer: Timer?
    private var recordAnimationTimer: Timer?
    private var recordFrameIndex = 0
    private var isBusy = false
    /// Какие бактерии сейчас заняты реакцией (смех/еда/укол/взрыв).
    /// Независимость: тап по одной не блокирует остальных — они продолжают
    /// ездить и реагировать. Глобальный isBusy остаётся только для записи голоса.
    private var busyBacteria = Set<ObjectIdentifier>()
    private func isBacteriaBusy(_ view: BacteriaView) -> Bool {
        busyBacteria.contains(ObjectIdentifier(view))
    }
    private var pillOnScreen = false
    private var pillVelocity: CGPoint = .zero
    private var pillDisplayLink: CADisplayLink?
    private var pillLastTimestamp: TimeInterval = 0

    /// Бактерии сами немного ездят по экрану и их можно толкать пальцем,
    /// как таблетку. Скорость в дизайн-точках в секунду.
    private var bacteriaVelocities: [CGPoint] = []
    private var wanderTimer: Timer?
    private var motionDisplayLink: CADisplayLink?
    private var motionLastTimestamp: TimeInterval = 0
    /// Какая бактерия сейчас в руке (индекс в bacteriaViews) и куда её тащат.
    private var draggedBacteria: BacteriaView?
    private var dragOffset: CGPoint = .zero
    private var dragLastPoint: CGPoint = .zero
    private var dragLastTime: TimeInterval = 0
    private var dragVelocity: CGPoint = .zero

    private let laughPool = ReactionPool(Reactions.laughPool)
    private let injectionPool = ReactionPool(Reactions.injectionPool)
    private let eatPool = ReactionPool(Reactions.eatPool)
    private var soundPickers: [String: PermutationPicker] = [:]

    /// `maxAvailableBacterias` в оригинале возвращает 6.
    private let maxBacteria = 6
    /// Нижняя граница поля — верх фиолетовой мембраны (≈0.90 высоты фона).
    /// Бактерии не заходят в жёлтый слой под ней.
    private let membraneFraction: CGFloat = 0.90
    /// Правая граница поля — левее столбика кнопок.
    private let buttonsReserve: CGFloat = 110

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
        // разрешение на микрофон просим сразу при старте, как в оригинале
        requestMicrophone { _ in }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyLayout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if sceneRecorder.isRecording { sceneRecorder.stop() }
        recorder.stopEverything()
        stopEffects()
        stopIdle()
        stopMotion()
        stopRecordAnimation()
        stopPillPhysics()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if recorder.state == .idle { startIdle() }
    }

    func pauseForBackground() {
        if sceneRecorder.isRecording { sceneRecorder.cancel() }
        recorder.stopEverything()
        stopEffects()
        stopIdle()
        stopMotion()
        stopRecordAnimation()
        stopPillPhysics()
        bacteriaViews.forEach { $0.stopAndReset() }
        needleView.stopAndReset()
        needleView.isHidden = true
        draggedBacteria = nil
        busyBacteria.removeAll()
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

        // Фон из видео геймплея: красное поле, розовая мембрана, оранжевый низ.
        backgroundView.image = uiImage("Blood-membrane-iPhone")
        backgroundView.contentMode = .scaleToFill
        backgroundView.isUserInteractionEnabled = false
        stageView.addSubview(backgroundView)

        needleView.contentSize = designSize
        needleView.isHidden = true
        stageView.addSubview(needleView)

        // На старте две бактерии — как в оригинале.
        addBacteria()
        addBacteria()

        // Таблетка на экране — pill-50.png, как в BacteriaPillView.
        pillView.image = uiImage("pill-50")
        pillView.contentMode = .scaleAspectFit
        pillView.isHidden = true
        pillView.isUserInteractionEnabled = true
        stageView.addSubview(pillView)

        // Вокруг таблетки на видео — кольцо пузырей. Это кадры `explode`
        // (первый кадр — целая бактерия, его пропускаем), зацикленные.

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleStageTap(_:)))
        stageView.addGestureRecognizer(tap)

        // Один пан и на таблетку, и на бактерию: что схватили — то и тащим.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDragPan(_:)))
        pan.delegate = self
        stageView.addGestureRecognizer(pan)

        // Тап (смех/щекотка) срабатывает, только если это не толчок:
        // иначе любое перетаскивание бактерии засчитывалось бы как щекотка.
        tap.require(toFail: pan)
    }

    /// Создаёт бактерию, добавляет её на сцену и в массив скоростей.
    /// Размер нормальный (пропорция кадра 137:200), место — свободное.
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

    /// Кнопка пончика сереет при достижении лимита бактерий (6).
    private func updateDonutButton() {
        let full = bacteriaViews.count >= maxBacteria
        donutButton.isEnabled = !full
        donutButton.alpha = full ? 0.4 : 1.0
    }

    /// Ставит бактерию в свободное место поля, не налезая на других и кнопки.
    private func placeBacteria(_ bacteria: BacteriaView) {
        let field = bacteriaField()
        // размер proportional кадру, случайный в разумных пределах
        let h = CGFloat.random(in: 150...190) * scale
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
        // пробуем случайные точки, выбираем самую далёкую от соседей
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

    /// Поле движения бактерий: выше мембраны, левее кнопок, с отступами.
    private func bacteriaField() -> CGRect {
        let w = stageView.bounds.width
        let h = stageView.bounds.height
        let top = max(view.safeAreaInsets.top, 12) + 8
        let bottom = h * membraneFraction
        let right = w - buttonsReserve * scale
        return CGRect(x: 8, y: top, width: max(right - 8, 100), height: max(bottom - top, 100))
    }

    /// Скорость блуждания в экранных точках/с — бактерии заметно, но плавно ездят.
    private func randomWanderVelocity() -> CGPoint {
        let speed = CGFloat.random(in: 18...34)
        let angle = CGFloat.random(in: 0...(2 * .pi))
        return CGPoint(x: cos(angle) * speed, y: sin(angle) * speed)
    }

    private func buildControls() {
        recordFrames = (0...3).compactMap { uiImage("RecButton\($0)") }
        recordButton.setImage(recordFrames.first, for: .normal)
        recordButton.imageView?.contentMode = .scaleAspectFit
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        recordButton.accessibilityLabel = "Снять видео"
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleRecordLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        recordButton.addGestureRecognizer(longPress)
        view.addSubview(recordButton)

        configureItem(donutButton, image: "gumb-donut-60", action: #selector(feedDonut), label: "Пончик")
        configureItem(injectionButton, image: "injection-60", action: #selector(giveInjection), label: "Шприц")
        configureItem(pillButton, image: "gumb-pill-60", action: #selector(givePill), label: "Таблетка")
        // В ролике крест виден с самого начала: nib прячет его только до первого кадра.
        pillButton.isHidden = false
        pillButton.alpha = 1
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

    /// Сцена на весь экран: фон растянут по всей площади, без полей-леттербокса.
    /// Бактерии и таблетка живут в координатах stageView (= экран).
    private func applyLayout() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        scale = bounds.width / designSize.width
        stageFrame = bounds
        stageView.frame = bounds
        backgroundView.frame = bounds
        let stageSize = bounds.size

        // Свежие бактерии ставим в свободное место поля; уже живущие — только
        // масштабируем пропорционально, сохраняя позиции и скорости.
        let ratio = previousScale > 0 ? scale / previousScale : 1
        for (index, bacteria) in bacteriaViews.enumerated() {
            if bacteria.frame == .zero {
                placeBacteria(bacteria)
            } else if ratio != 1 {
                let center = CGPoint(x: bacteria.center.x * ratio, y: bacteria.center.y * ratio)
                bacteria.bounds = CGRect(x: 0, y: 0,
                                         width: bacteria.bounds.width * ratio,
                                         height: bacteria.bounds.height * ratio)
                bacteria.center = center
                if index < bacteriaVelocities.count {
                    bacteriaVelocities[index].x *= ratio
                    bacteriaVelocities[index].y *= ratio
                }
            }
            bacteria.contentSize = bacteria.bounds.size
        }
        previousScale = scale
        needleView.frame = CGRect(origin: .zero, size: stageSize)
        needleView.contentSize = stageSize

        if pillOnScreen {
            let size = 50 * scale
            pillView.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        }

        // Кнопки заметно крупнее оригинала и привязаны к краям экрана.
        let side = max(96 * scale, 84)
        let margin: CGFloat = 10
        let topSafe = max(view.safeAreaInsets.top, 12)
        let bottomSafe = view.safeAreaInsets.bottom
        recordButton.frame = CGRect(x: margin, y: topSafe, width: side, height: side)

        // правый столбик по центру вертикали, с равным шагом
        let gap = side + 18
        let columnHeight = gap * 2 + side
        let columnTop = max(topSafe + side + 24, (bounds.height - columnHeight) / 2)
        let rightX = bounds.width - side - margin
        injectionButton.frame = CGRect(x: rightX, y: columnTop, width: side, height: side)
        pillButton.frame = CGRect(x: rightX, y: columnTop + gap, width: side, height: side)
        donutButton.frame = CGRect(x: rightX, y: columnTop + gap * 2, width: side, height: side)
        _ = bottomSafe
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
        sceneRecorder = SceneRecorder(engine: audioEngine, graphQueue: queue)
        sceneRecorder.onStateChanged = { [weak self] state in
            self?.handleSceneRecorderState(state)
        }
        sceneRecorder.onSaved = { [weak self] in
            self?.flashSavedBadge()
        }
    }

    // MARK: - Реакции

    @objc private func handleStageTap(_ gesture: UITapGestureRecognizer) {
        guard recorder.state == .idle else { return }
        let point = gesture.location(in: stageView)

        if pillOnScreen, pillView.frame.insetBy(dx: -12, dy: -12).contains(point) {
            // Тап по таблетке — толчок в сторону ближайшей бактерии.
            flickPillTowardBacteria()
            return
        }
        // Тап по бактерии = толчок. Смех приходит не сразу, а после нескольких
        // толчков, когда бактерия остановится (как в оригинале).
        guard let target = bacteriaViews.last(where: { $0.frame.contains(point) }),
              !isBacteriaBusy(target) else { return }
        pokeBacteria(target)
    }

    /// Толчок бактерии: копим счётчик, смех запускается отложенно когда
    /// бактерия замедлится. Смех заразный — расходится на соседей.
    private func pokeBacteria(_ target: BacteriaView, kickVelocity: CGPoint? = nil) {
        let id = ObjectIdentifier(target)
        pokeCounts[id, default: 0] += 1
        // толкаем бактерию физически
        if let index = bacteriaViews.firstIndex(where: { $0 === target }) {
            if let kickVelocity {
                bacteriaVelocities[index] = kickVelocity
            } else {
                let angle = CGFloat.random(in: 0...(2 * .pi))
                let kick = CGFloat.random(in: 120...220) * scale
                bacteriaVelocities[index] = CGPoint(x: cos(angle) * kick, y: sin(angle) * kick)
            }
        }
        scheduleLaughCheck()
    }

    /// Раз в 0.4 с проверяем: толканная бактерия остановилась и накопилось
    /// ≥2 толчков → запускаем заразный смех.
    private func scheduleLaughCheck() {
        guard laughCheckTimer == nil else { return }
        laughCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkLaughAfterPokes()
        }
    }

    private func checkLaughAfterPokes() {
        guard recorder.state == .idle else { return }
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
            // остановилась после нескольких толчков → смеётся и заражает соседей
            pokeCounts[id] = nil
            spreadLaugh(from: bacteria)
        }
        if !anyPending && pokeCounts.isEmpty {
            laughCheckTimer?.invalidate()
            laughCheckTimer = nil
        }
    }

    /// Заразный смех: источник + все свободные соседи (spreadLaughAnimationWithSource:).
    private func spreadLaugh(from source: BacteriaView) {
        guard let reaction = laughPool.next() else { return }
        perform(reaction, on: source)
        for other in bacteriaViews where other !== source && !isBacteriaBusy(other) {
            // небольшая задержка, чтобы смех расходился волной, а не хором в один кадр
            let delay = Double.random(in: 0.05...0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak other] in
                guard let self, let other, self.bacteriaViews.contains(where: { $0 === other }),
                      !self.isBacteriaBusy(other), let r = self.laughPool.next() else { return }
                self.perform(r, on: other)
            }
        }
    }

    /// Пончик: бактерия ест случайный пончик, затем делится. После 6 бактерий
    /// кнопка сереет (лимит maxAvailableBacterias = 6).
    @objc private func feedDonut() {
        guard recorder.state == .idle, bacteriaViews.count < maxBacteria,
              let reaction = eatPool.next() else { return }
        // кормим случайную свободную бактерию, а не всегда первую
        guard let target = bacteriaViews.filter({ !isBacteriaBusy($0) }).randomElement() else { return }
        perform(reaction, on: target) { [weak self] in
            guard let self else { return }
            self.multiplyBacteria(from: target)
        }
    }

    /// Размножение: клип `multiply`, рядом появляется новая бактерия.
    /// Лимит — `maxAvailableBacterias` = 6.
    private func multiplyBacteria(from parent: BacteriaView) {
        guard bacteriaViews.count < maxBacteria,
              let clip = ClipLibrary.shared.clip(ClipName.multiply) else { return }
        busyBacteria.insert(ObjectIdentifier(parent))
        playEffect(.multiply)
        parent.play(clip, repeats: 1, fps: 12, completion: { [weak self] in
            guard let self else { return }
            parent.stopAndReset()
            self.busyBacteria.remove(ObjectIdentifier(parent))
            // addBacteria уже поставил ребёнка в свободное место и включил idle
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

    /// Аптечка: спавнит таблетку на экране (`touchBacteriaPill`).
    /// Сама по себе она ничего не делает — нужно смахнуть её в бактерию.
    @objc private func givePill() {
        guard recorder.state == .idle else { return }
        if !pillOnScreen { spawnPill() }
    }

    /// Шприц: оверлей `needle` на весь экран, а реакция ВСЕХ бактерий
    /// (вариации crazy1/crazy2) начинается сразу, не дожидаясь конца иглы —
    /// иначе укол чувствуется «с опозданием».
    @objc private func giveInjection() {
        guard recorder.state == .idle else { return }
        removePill()
        if let needle = ClipLibrary.shared.clip(ClipName.needle) {
            needleView.isHidden = false
            needleView.play(needle, repeats: 1, fps: 22, completion: { [weak self] in
                guard let self else { return }
                self.needleView.isHidden = true
                self.needleView.stopAndReset()
            })
        }
        // реагируют все свободные бактерии, волной
        let free = bacteriaViews.filter { !isBacteriaBusy($0) }
        for (offset, bacteria) in free.enumerated() {
            let delay = Double(offset) * 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak bacteria] in
                guard let self, let bacteria, self.bacteriaViews.contains(where: { $0 === bacteria }),
                      !self.isBacteriaBusy(bacteria),
                      let reaction = self.injectionPool.next() else { return }
                self.perform(reaction, on: bacteria)
            }
        }
    }

    /// Таблетка попала в бактерию: `playPopAnimation:` — клип `explode`,
    /// бактерия рассыпается кольцом пузырей и исчезает навсегда.
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
            // `areBacteriasExtincted` — если все сдохли, появляется одна новая.
            if self.bacteriaViews.isEmpty {
                self.spawnLoneBacteria()
            } else {
                // остальные продолжают жить — возвращаем их в покой
                self.startIdle()
            }
        })
    }

    private func removeBacteria(_ target: BacteriaView) {
        target.stopAndReset()
        target.removeFromSuperview()
        busyBacteria.remove(ObjectIdentifier(target))
        if let index = bacteriaViews.firstIndex(where: { $0 === target }) {
            bacteriaViews.remove(at: index)
            if index < bacteriaVelocities.count { bacteriaVelocities.remove(at: index) }
        }
        if draggedBacteria === target { draggedBacteria = nil }
        updateDonutButton()
    }

    /// Все погибли — возвращается одна бактерия (addBacteria ставит место и idle).
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

    /// Реакция на конкретной бактерии. Не блокирует остальных: каждая живёт
    /// своей жизнью — тап по одной не замораживает колонию.
    private func perform(_ reaction: Reaction,
                         on target: BacteriaView? = nil,
                         completion: (() -> Void)? = nil) {
        guard let clip = ClipLibrary.shared.clip(reaction.clipName) else { return }
        let view = target ?? bacteriaViews.randomElement()
        guard let view, !isBacteriaBusy(view) else { return }
        busyBacteria.insert(ObjectIdentifier(view))

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

    /// Клип играется ровно `minRepeats` проходов, звук стартует на `soundFrameStart`
    /// и обрезается вместе с клипом. По окончании бактерия возвращается к покою.
    private func startReaction(_ clip: AnimationClip,
                               on target: BacteriaView,
                               reaction: Reaction,
                               effect: SoundBank.Effect,
                               buffer: AVAudioPCMBuffer?,
                               completion: (() -> Void)?) {
        let startFrame = min(reaction.soundFrameStart, clip.frameCount - 1)
        var soundStarted = false

        target.play(
            clip,
            repeats: max(1, reaction.minRepeats),
            fps: reaction.fps,
            frameSound: { [weak self] frame in
                guard let self, !soundStarted, frame == startFrame else { return }
                soundStarted = true
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
                self.busyBacteria.remove(ObjectIdentifier(target))
                completion?()
                // бактерия снова в покое, если не идёт запись и она ещё жива
                if self.recorder.state == .idle, self.bacteriaViews.contains(where: { $0 === target }) {
                    self.resumeIdle(for: target)
                }
            }
        )
    }

    /// Возвращает одну бактерию к покачиванию, не трогая остальных.
    private func resumeIdle(for view: BacteriaView) {
        guard !isBacteriaBusy(view), recorder.state == .idle else { return }
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

    // MARK: - Таблетка и размножение

    /// Таблетка — просто pill-50.png по центру поля, без лишних колец и бактерий.
    private func spawnPill() {
        guard !pillOnScreen else { return }
        pillOnScreen = true
        let side = 50 * scale
        pillView.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        pillView.center = CGPoint(x: stageView.bounds.midX, y: stageView.bounds.midY)
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

    /// Свайп: тащим таблетку ИЛИ бактерию пальцем, при отпускании летит по инерции.
    @objc private func handleDragPan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: stageView)
        switch gesture.state {
        case .began:
            if pillOnScreen, pillView.frame.insetBy(dx: -24, dy: -24).contains(location) {
                draggedBacteria = nil
                stopPillPhysics()
                dragLastPoint = location
                dragLastTime = CACurrentMediaTime()
                dragVelocity = .zero
            } else if let grabbed = bacteriaViews.last(where: {
                $0.frame.insetBy(dx: -10, dy: -10).contains(location)
            }) {
                draggedBacteria = grabbed
                dragOffset = CGPoint(x: location.x - grabbed.center.x,
                                     y: location.y - grabbed.center.y)
                dragLastPoint = location
                dragLastTime = CACurrentMediaTime()
                dragVelocity = .zero
                setBacteriaVelocity(.zero, for: grabbed)
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
            if let grabbed = draggedBacteria {
                grabbed.center = CGPoint(x: location.x - dragOffset.x, y: location.y - dragOffset.y)
            } else if pillOnScreen {
                pillView.center = location
            }
        case .ended, .cancelled:
            let fling = CGPoint(x: dragVelocity.x * 0.35, y: dragVelocity.y * 0.35)
            if let grabbed = draggedBacteria {
                // бактерия летит по инерции, потом снова начинает медленно ездить
                draggedBacteria = nil
                // если реально толкнули (быстрый флинг) — копим толчок toward смеха
                if hypot(fling.x, fling.y) > 60 * scale, !isBacteriaBusy(grabbed) {
                    pokeBacteria(grabbed, kickVelocity: fling)
                } else {
                    setBacteriaVelocity(fling, for: grabbed)
                }
            } else if pillOnScreen {
                pillVelocity = fling
                startPillPhysics()
            }
            dragVelocity = .zero
        default:
            break
        }
    }

    private func setBacteriaVelocity(_ velocity: CGPoint, for bacteria: BacteriaView) {
        guard let index = bacteriaViews.firstIndex(where: { $0 === bacteria }),
              index < bacteriaVelocities.count else { return }
        bacteriaVelocities[index] = velocity
    }

    private func flickPillTowardBacteria() {
        guard pillOnScreen else { return }
        // целимся в ближайшую бактерию
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

    // MARK: - Движение бактерий

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

    /// Раз в пару секунд подкидываем бактериям новое направление — они сами ездят.
    private func scheduleWander() {
        wanderTimer?.invalidate()
        wanderTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 1.8...3.6),
                                           repeats: false) { [weak self] _ in
            guard let self else { return }
            for index in self.bacteriaVelocities.indices {
                // не трогаем ту, что в руке, и ту, что летит после толчка
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
        // мотор езды работает всегда, кроме фона; при записи голоса слушает
        // только одна бактерия, остальные продолжают ездить
        if motionLastTimestamp == 0 { motionLastTimestamp = link.timestamp; return }
        let dt = min(link.timestamp - motionLastTimestamp, 1.0 / 30.0)
        motionLastTimestamp = link.timestamp

        let field = bacteriaField()
        guard field.width > 0, field.height > 0 else { return }

        // Отталкивание парами — как collision2D в оригинале: бактерии не
        // налезают друг на друга, а расходятся.
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
                    if !isBacteriaBusy(a) { a.center.x -= nx * push; a.center.y -= ny * push }
                    if !isBacteriaBusy(b) { b.center.x += nx * push; b.center.y += ny * push }
                }
            }
        }

        for (index, bacteria) in bacteriaViews.enumerated() {
            guard index < bacteriaVelocities.count else { continue }
            if bacteria === draggedBacteria { continue }
            // занятая реакцией бактерия стоит на месте, остальные ездят
            if isBacteriaBusy(bacteria) { continue }

            var v = bacteriaVelocities[index]
            var center = bacteria.center
            center.x += v.x * dt
            center.y += v.y * dt

            // затухание толчка до скорости блуждания — та же модель, что у таблетки
            let speed = hypot(v.x, v.y)
            let cruise = 34 * scale
            if speed > cruise {
                let k = max(cruise, speed * 0.97)
                v.x *= k / speed
                v.y *= k / speed
            }

            // границы поля: не в кнопки, не в мембрану/жёлтый слой
            let halfW = bacteria.bounds.width * 0.42
            let halfH = bacteria.bounds.height * 0.42
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

        var center = pillView.center
        center.x += pillVelocity.x * dt
        center.y += pillVelocity.y * dt
        // Затухание, как movePillWithAcceleration в оригинале.
        pillVelocity.x *= 0.985
        pillVelocity.y *= 0.985

        let radius = pillView.bounds.width / 2
        // таблетка, как и бактерии, не выходит за поле: не в кнопки и не в мембрану
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

        // Попадание в бактерию — _bacteriaRadiusAndPillSquared.
        if let victim = bacteriaViews.first(where: { bacteria in
            let dx = center.x - bacteria.frame.midX
            let dy = center.y - bacteria.frame.midY
            let hitRadius = bacteria.frame.width * 0.42 + radius
            return dx * dx + dy * dy < hitRadius * hitRadius
        }) {
            consumePill(on: victim)
            return
        }
        if abs(pillVelocity.x) < 4 && abs(pillVelocity.y) < 4 {
            pillVelocity = .zero
            stopPillPhysics()
        }
    }

    /// Таблетка попала в бактерию: бактерия рассыпается пузырями и погибает.
    /// Таблетка одноразовая — исчезает сразу, колония продолжает жить.
    private func consumePill(on victim: BacteriaView) {
        stopPillPhysics()
        pillOnScreen = false
        pillView.isHidden = true
        pillView.transform = .identity
        popBacteria(victim)
    }

    // MARK: - Покой

    /// Покой колонии: все свободные бактерии покачиваются (sway), мотор езды
    /// работает постоянно, а раз в пару секунд случайная бактерия делает
    /// маленькое действие (моргание/взгляд/качание) — как в оригинале.
    private func startIdle() {
        guard recorder.state == .idle else { return }
        if let base = ClipLibrary.shared.clip(ClipName.idleBase) {
            for view in bacteriaViews where !isBacteriaBusy(view) {
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
        // редкие мелкие действия на фоне постоянного покачивания — не «кивает всегда»
        let delay = Double.random(in: 6...12)
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.playRandomIdle()
            self?.scheduleIdleAction()
        }
    }

    private func playRandomIdle() {
        guard recorder.state == .idle else { return }
        // иногда осматривается или кивает; основу покоя составляет sway
        let names = [ClipName.lookLeftRight, ClipName.lookLeftRight,
                     ClipName.bumpLeftRight, ClipName.bumpUpDown]
        guard let clip = ClipLibrary.shared.random(from: names),
              let target = bacteriaViews.filter({ !isBacteriaBusy($0) }).randomElement() else { return }
        busyBacteria.insert(ObjectIdentifier(target))
        target.play(clip, repeats: 1, fps: 13, completion: { [weak self] in
            guard let self else { return }
            self.busyBacteria.remove(ObjectIdentifier(target))
            self.resumeIdle(for: target)
        })
    }

    // MARK: - Запись видео (кнопка-камера)

    /// Тап по камере — повтор голоса (как в оригинале Talking): слушает → говорит.
    @objc private func toggleRecording() {
        guard !sceneRecorder.isRecording else { return }
        switch recorder.state {
        case .listening:
            recorder.stopListeningAndSpeak()
        case .speaking:
            recorder.stopSpeaking()
        case .idle, .failed:
            requestMicrophone { [weak self] granted in
                guard let self, granted else { return }
                // глушим только idle-таймер, мотор езды остальных не трогаем
                self.idleTimer?.invalidate()
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.effects?.stopAll()
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playAndRecord, mode: .default,
                                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
                        try session.setActive(true)
                        if !self.audioEngine.isRunning { try self.audioEngine.start() }
                    } catch { return }
                    DispatchQueue.main.async { self.recorder.beginListening() }
                }
            }
        }
    }

    /// Долгое нажатие на камеру — видеозапись сцены со звуком в Фото.
    @objc private func handleRecordLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, recorder.state == .idle else { return }
        if sceneRecorder.isRecording {
            sceneRecorder.stop()
            return
        }
        requestMicrophone { [weak self] granted in
            guard let self, granted else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.defaultToSpeaker, .allowBluetoothA2DP])
                    try session.setActive(true)
                    if !self.audioEngine.isRunning { try self.audioEngine.start() }
                } catch { return }
                DispatchQueue.main.async { self.sceneRecorder.start(capturing: self.stageView) }
            }
        }
    }

    private func handleSceneRecorderState(_ state: SceneRecorder.State) {
        switch state {
        case .recording:
            showRecordingBadge()
            recordButton.setImage(recordFrames.last, for: .normal)
        case .saving:
            recordingBadge?.removeFromSuperview()
            recordingBadge = nil
        case .idle:
            recordingBadge?.removeFromSuperview()
            recordingBadge = nil
            recordButton.setImage(recordFrames.first, for: .normal)
        case .failed(let message):
            recordingBadge?.removeFromSuperview()
            recordingBadge = nil
            recordButton.setImage(recordFrames.first, for: .normal)
            NSLog("Запись видео: \(message)")
        }
    }

    private func showRecordingBadge() {
        recordingBadge?.removeFromSuperview()
        let badge = UIView()
        badge.backgroundColor = UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        badge.layer.cornerRadius = 7
        badge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 14),
            badge.heightAnchor.constraint(equalToConstant: 14),
            badge.centerXAnchor.constraint(equalTo: recordButton.centerXAnchor),
            badge.topAnchor.constraint(equalTo: recordButton.bottomAnchor, constant: 4)
        ])
        recordingBadge = badge
        UIView.animate(withDuration: 0.6, delay: 0, options: [.repeat, .autoreverse]) {
            badge.alpha = 0.25
        }
    }

    private func flashSavedBadge() {
        let label = UILabel()
        label.text = "Сохранено в Фото"
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.65)
        label.textAlignment = .center
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            label.widthAnchor.constraint(equalToConstant: 180),
            label.heightAnchor.constraint(equalToConstant: 34)
        ])
        label.alpha = 0
        UIView.animate(withDuration: 0.25, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.4, delay: 1.4) { label.alpha = 0 } completion: { _ in
                label.removeFromSuperview()
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
            finishVoiceRepeat()
        case .listening:
            isBusy = true
            idleTimer?.invalidate()
            // слушает одна (случайная) бактерия, остальные продолжают жить
            let listener = bacteriaViews.randomElement()
            talker = listener
            if let listener {
                busyBacteria.insert(ObjectIdentifier(listener))
                if let listen = ClipLibrary.shared.clip(ClipName.listen) {
                    listener.play(listen, repeats: 0, fps: 8)
                }
            }
            startRecordAnimation()
        case .speaking:
            stopRecordAnimation()
            if let talker, let talk = ClipLibrary.shared.clip(ClipName.talk) {
                talker.play(talk, repeats: 0, fps: 14)
            }
        case .failed:
            stopRecordAnimation()
            finishVoiceRepeat()
        }
    }

    /// Возврат после повтора голоса: говорящий возвращается в колонию.
    private func finishVoiceRepeat() {
        if let talker {
            busyBacteria.remove(ObjectIdentifier(talker))
            resumeIdle(for: talker)
        }
        self.talker = nil
        isBusy = false
        startIdle()
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
    /// Тап и пан не конфликтуют: тап — короткий, пан — движение.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }
        guard recorder.state == .idle else { return false }
        let point = gestureRecognizer.location(in: stageView)
        // пан начинается, только если схватили таблетку или бактерию
        if pillOnScreen, pillView.frame.insetBy(dx: -24, dy: -24).contains(point) { return true }
        return bacteriaViews.contains { $0.frame.insetBy(dx: -10, dy: -10).contains(point) }
    }
}