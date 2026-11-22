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
    private let donutButton = UIButton(type: .custom)
    private let injectionButton = UIButton(type: .custom)
    private let pillButton = UIButton(type: .custom)

    private let audioEngine = AVAudioEngine()
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let queue = DispatchQueue(label: "john.audio", qos: .userInitiated)
    private var effects: EffectPlayer?
    private var recorder: VoiceRecorder!
    /// Бактерия, которая слушает/повторяет голос (долгое нажатие на камеру).
    private var talkers: [BacteriaView] = []
    /// Счётчик толчков по бактерии: смех не моментальный, а после 2-3 толчков,
    /// когда бактерия остановится (как lastLaughTickle/isLaughing в оригинале).

    private var scale: CGFloat = 1
    private var previousScale: CGFloat = 0
    private var stageFrame: CGRect = .zero

    private var idleTimer: Timer?
    /// Какие бактерии сейчас заняты «эксклюзивной» реакцией (еда/размножение/
    /// смерть/говорит). Только они не принимают новые взаимодействия.
    /// Смех и idle-кивки НЕ блокируют: во время них бактерию можно трогать,
    /// колоть и толкать — как в оригинале (иначе шприц «через раз»).
    private var busyBacteria = Set<ObjectIdentifier>()
    /// Бактерии, у которых сейчас играет реакция (смех/укол/еда). Ввод НЕ
    /// блокируется, но idle/прослушка не перезаписывают их клип на середине —
    /// иначе анимация шприца обрывалась покачиванием через 2-5 секунд.
    private var reactingBacteria = Set<ObjectIdentifier>()
    private func isReacting(_ view: BacteriaView) -> Bool {
        reactingBacteria.contains(ObjectIdentifier(view))
    }
    /// Свободна для фоновых клипов (idle/listen): не занята и не реагирует.
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
    /// Таблетка живёт, пока с ней что-то делают; исчезает только после долгого
    /// бездействия (как в оригинале — не одноразовая).
    private var pillLastInteraction = Date()
    private let pillIdleTimeout: TimeInterval = 12
    /// Бактерия, которую сейчас убивает таблетка — защита от повторных попаданий.
    /// Сколько бактерий сейчас едят/делятся — не больше 2 одновременно (лимит 6).
    private var eatingCount = 0
    private let maxEating = 2
    /// Кулдаун шприца по времени — нельзя колоть бесконечно, флаг не залипает.
    private var lastInjectionAt: TimeInterval = 0

    /// Бактерии сами немного ездят по экрану и их можно толкать пальцем,
    /// как таблетку. Скорость в дизайн-точках в секунду.
    private var bacteriaVelocities: [CGPoint] = []
    private var wanderTimer: Timer?
    private var motionDisplayLink: CADisplayLink?
    private var motionLastTimestamp: TimeInterval = 0
    /// Какая бактерия сейчас в руке (индекс в bacteriaViews) и куда её тащат.
    private var draggedBacteria: BacteriaView?
    private var dragStartPoint: CGPoint = .zero
    private var dragLastPoint: CGPoint = .zero
    private var dragLastTime: TimeInterval = 0
    private var dragVelocity: CGPoint = .zero

    private let laughPool = ReactionPool(Reactions.laughPool)
    private let injectionPool = ReactionPool(Reactions.injectionPool)
    private let eatPool = ReactionPool(Reactions.eatPool)
    private var soundPickers: [String: PermutationPicker] = [:]

    /// `maxAvailableBacterias` в оригинале возвращает 6.
    private let maxBacteria = 6
    /// Единая высота бактерии (в дизайн-точках): и стартовые, и новые из пончиков
    /// одного размера — как просил пользователь.
    private let bacteriaDesignHeight: CGFloat = 170
    private var bacteriaHeight: CGFloat { bacteriaDesignHeight * scale }
    /// Нижняя граница поля — верх фиолетовой мембраны (≈0.90 высоты фона).
    /// Бактерии не заходят в жёлтый слой под ней.
    private let membraneFraction: CGFloat = 0.90

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
        // повтор голоса всегда активен: слушаем микро постоянно
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
        // после любого исчезновения вида прослушка могла быть остановлена —
        // возвращаем постоянный повтор голоса
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
        // stopAndReset сбрасывает клипы и выбрасывает их completion-замыкания,
        // а именно в них декрементятся eatingCount/pendingChildren. Без сброса
        // счётчики утекают и пончик/размножение молча умирают до перезапуска.
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
        // после фона клипы бактерий остановлены (stopAndReset в pause) —
        // возвращаем всем свободным покачивание, иначе колония стоит кадром
        startIdle()
        for view in bacteriaViews where isFreeForIdle(view) {
            resumeIdle(for: view)
        }
        startAlwaysListening()
    }

    private func stopEffects() {
        queue.async { [weak self] in
            guard let self else { return }
            // Только глушим эффекты. pause() останавливал и вход микрофона
            // вместе с tap'ом, и постоянная прослушка умирала молча.
            self.effects?.stopAll()
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

        // require(toFail: pan) убран: пан стартует на тач-дауне и глушил тап
        // целиком («нажатие не убивает»). Тап сам фейлится, если палец уехал
        // больше slop — этого достаточно, чтобы тап и толчок не конфликтовали.
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

    /// Ставит бактерию в свободное место поля, не налезая на других.
    /// Все бактерии одного размера (bacteriaDesignHeight) — и старые, и новые.
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

    /// Поле движения бактерий: выше мембраны, на ВСЮ ширину экрана —
    /// бактерии бегают и под кнопками (кнопки лежат поверх них), как в оригинале.
    private func bacteriaField() -> CGRect {
        let w = stageView.bounds.width
        let h = stageView.bounds.height
        let top = max(view.safeAreaInsets.top, 12)
        let bottom = h * membraneFraction
        return CGRect(x: 0, y: top, width: max(w, 100), height: max(bottom - top, 100))
    }

    /// Скорость блуждания в экранных точках/с — бактерии заметно, но плавно ездят.
    private func randomWanderVelocity() -> CGPoint {
        let speed = CGFloat.random(in: 18...34)
        let angle = CGFloat.random(in: 0...(2 * .pi))
        return CGPoint(x: cos(angle) * speed, y: sin(angle) * speed)
    }

    private func buildControls() {
        // backgroundImage растягивается на весь фрейм кнопки без insets —
        // иконка реально крупная, а не мелкая внутри большой кнопки

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

        // ВСЕ бактерии одного размера (старые и новые из пончиков).
        // Позиции сохраняем пропорционально, размер задаём единый.
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

        // Кнопки средние (не мелкие и не огромные): backgroundImage на весь фрейм.
        let side = max(96 * scale, 84)
        let margin: CGFloat = 8
        let topSafe = max(view.safeAreaInsets.top, 12)

        // правый столбик по центру вертикали, с равным шагом
        let gap = side + 16
        let columnHeight = gap * 2 + side
        let columnTop = max(topSafe + side + 24, (bounds.height - columnHeight) / 2)
        let rightX = bounds.width - side - margin
        injectionButton.frame = CGRect(x: rightX, y: columnTop, width: side, height: side)
        pillButton.frame = CGRect(x: rightX, y: columnTop + gap, width: side, height: side)
        donutButton.frame = CGRect(x: rightX, y: columnTop + gap * 2, width: side, height: side)
    }

    // MARK: - Звук

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

    // MARK: - Реакции

    @objc private func handleStageTap(_ gesture: UITapGestureRecognizer) {
        
        let point = gesture.location(in: stageView)

        if pillOnScreen, pillView.frame.insetBy(dx: -12, dy: -12).contains(point) {
            // Тап по таблетке — толчок в сторону ближайшей бактерии.
            flickPillTowardBacteria()
            return
        }
        // Тап по бактерии = смерть (лопается пузырями), как ты просил.
        // Смех от толчка остаётся только на свайпе-флинге, не на тапе.
        guard let target = bacteriaViews.last(where: { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }),
              !isBacteriaBusy(target) else { return }
        popBacteria(target)
    }

    /// Толчок бактерии свайпом: физический пинок + копим счётчик толчков.
    /// Смех приходит НЕ сразу, а когда бактерия остановится после ≥2 толчков
    /// (как lastLaughTickle/isLaughing в оригинале). Смеётся только толкнутая.
    private func pokeBacteria(_ target: BacteriaView, kickVelocity: CGPoint? = nil) {
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

    /// Раз в 0.4 с: толканная бактерия остановилась и накопилось ≥2 толчков → смех.
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
            // остановилась после нескольких толчков → смеётся (только она)
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


    /// Пончик: бактерия ест случайный пончик, затем делится. Одновременно едят
    /// не больше двух бактерий (как в оригинале — чтобы не превысить лимит 6).
    /// После 6 бактерий кнопка сереет.
    @objc private func feedDonut() {
        guard eatingCount < maxEating,
              bacteriaViews.count + pendingChildren < maxBacteria,
              let reaction = eatPool.next() else { return }
        // кормим случайную свободную бактерию, а не всегда первую
        guard let target = bacteriaViews.filter({ !isBacteriaBusy($0) }).randomElement() else { return }
        eatingCount += 1
        perform(reaction, on: target) { [weak self] in
            guard let self else { return }
            self.eatingCount -= 1
            self.multiplyBacteria(from: target)
        }
    }

    /// Размножение: клип `multiply`, рядом появляется новая бактерия.
    /// Лимит — `maxAvailableBacterias` = 6, учитываем уже запланированных детей.
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
            // финальная проверка на момент появления ребёнка
            guard self.bacteriaViews.count < self.maxBacteria else { return }
            // addBacteria уже ставит ребёнка в свободное место и включает idle
            let child = self.addBacteria()
            // ребёнок того же размера, что и остальные (крупный, как новые)
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
    /// Таблетка не одноразовая: живёт, пока с ней взаимодействуют, и исчезает
    /// только после долгого бездействия. Повторный тап по кнопке не плодит новые.
    @objc private func givePill() {
        
        if pillOnScreen {
            pillLastInteraction = Date()
            return
        }
        spawnPill()
    }

    /// Шприц: оверлей `needle`, реакция всех бактерий ХОРОМ (звук от каждой),
    /// старт в момент укола (середина клипа иглы). Кулдаун по времени — простой
    /// и не залипает (в отличие от флага).
    @objc private func giveInjection() {
        let now = CACurrentMediaTime()
        guard now - lastInjectionAt > 2.0 else { return }
        lastInjectionAt = now
        removePill()
        let needle = ClipLibrary.shared.clip(ClipName.needle)
        // момент укола — примерно середина клипа иглы
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
        // все свободные бактерии реагируют хором в момент укола;
        // реакция неэксклюзивная — во время неё бактерию можно трогать дальше
        let free = bacteriaViews.filter { !isBacteriaBusy($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + stabDelay) { [weak self] in
            guard let self else { return }
            // одна вариация на всех: этот укол — crazy1, следующий — crazy2
            guard let reaction = self.injectionPool.next() else { return }
            for bacteria in free where self.bacteriaViews.contains(where: { $0 === bacteria })
                && !self.isBacteriaBusy(bacteria) {
                self.perform(reaction, on: bacteria, exclusive: false)
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
    /// - Parameter exclusive: true — бактерия «занята» (еда/смерть/размножение)
    ///   и не принимает новые взаимодействия; false — смех/укол, во время которых
    ///   бактерию можно трогать, толкать и колоть (иначе шприц «через раз»).
    private func perform(_ reaction: Reaction,
                         on target: BacteriaView? = nil,
                         exclusive: Bool = true,
                         completion: (() -> Void)? = nil) {
        guard let clip = ClipLibrary.shared.clip(reaction.clipName) else { return }
        let view = target ?? bacteriaViews.randomElement()
        guard let view, !isBacteriaBusy(view) else { return }
        if exclusive { busyBacteria.insert(ObjectIdentifier(view)) }
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

    /// Клип играется `minRepeats` проходов, но не заканчивается раньше звука
    /// (waitForSoundSync оригинала): звук laugh3 = 5 с, а клип 2 с — без синка
    /// анимка пропадала, а звук ещё играл. Голос запоминаем и обрезаем при
    /// прерывании/смерти, чтобы звук не переживал бактерию.
    private func startReaction(_ clip: AnimationClip,
                               on target: BacteriaView,
                               reaction: Reaction,
                               effect: SoundBank.Effect,
                               buffer: AVAudioPCMBuffer?,
                               completion: (() -> Void)?) {
        let startFrame = min(reaction.soundFrameStart, clip.frameCount - 1)
        var soundStarted = false
        var voice = -1

        // Еда показывается ровно один раз: её WAV длиннее клипа, поэтому звук
        // режем по длине клипа и не даём syncGate тянуть второй проход.
        let clipDuration = Double(clip.frameCount) / reaction.fps
        let playedBuffer: AVAudioPCMBuffer?
        if reaction.trimSoundToClip, let buffer {
            playedBuffer = Self.trim(buffer, toSeconds: clipDuration)
        } else {
            playedBuffer = buffer
        }

        // Клип держится, пока его звук ещё звучит. isPlaying потокобезопасен
        // (deadlinesLock): queue.sync здесь вызывался с main, пока queue занята,
        // и вешал/ронял игру на кнопках. Для еды синк не нужен — звук обрезан.
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
                // бактерия снова в покое, если не идёт запись и она ещё жива
                if self.bacteriaViews.contains(where: { $0 === target }) {
                    self.resumeIdle(for: target)
                }
            }
        )
        reactionVoices[ObjectIdentifier(target)] = { voice }
    }

    /// Обрезает буфер до заданной длительности (звук еды по длине клипа).
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

    /// Голос, звучащий у бактерии (для обрезки при прерывании/смерти).
    private var reactionVoices: [ObjectIdentifier: () -> Int] = [:]
    private func stopVoice(for target: BacteriaView) {
        let id = ObjectIdentifier(target)
        guard let getter = reactionVoices[id] else { return }
        let v = getter()
        reactionVoices[id] = nil
        guard v >= 0 else { return }
        queue.async { [weak self] in self?.effects?.stop(voice: v) }
    }

    /// Возвращает одну бактерию к покачиванию, не трогая остальных.
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

    // MARK: - Таблетка и размножение

    /// Таблетка — просто pill-50.png по центру поля, без лишних колец и бактерий.
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

    /// Свайп: таблетку тащим пальцем, бактерию — толкаем (не фулл-таскание).
    /// Толчок считается по ОБЩЕМУ смещению от старта, а не по последнему тику:
    /// иначе палец замер в конце — скорость ноль — толчка нет («толкать нельзя»).
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
                // бактерию не тащим — запоминаем старт для толчка
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
                // бактерию не перемещаем за пальцем — толчок будет на отпускании
            } else if pillOnScreen {
                pillView.center = clampToField(location, half: pillView.bounds.width / 2)
                pillLastInteraction = Date()
            }
        case .ended, .cancelled:
            if let grabbed = draggedBacteria {
                draggedBacteria = nil
                // толчок по общему смещению от старта свайпа
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

    /// Ограничивает точку полем бактерий (не в кнопки, не в мембрану).
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

        // долгое бездействие — таблетка исчезает (как в оригинале)
        if Date().timeIntervalSince(pillLastInteraction) > pillIdleTimeout {
            removePill()
            return
        }

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

        // Попадание в бактерию — только если она не занята (не умирает уже).
        if let victim = bacteriaViews.first(where: { bacteria in
            guard !isBacteriaBusy(bacteria) else { return false }
            let dx = center.x - bacteria.frame.midX
            let dy = center.y - bacteria.frame.midY
            let hitRadius = bacteria.frame.width * 0.42 + radius
            return dx * dx + dy * dy < hitRadius * hitRadius
        }) {
            consumePill(on: victim)
        }
        // display link не останавливаем при покое: таблетка живёт и ждёт
        // взаимодействия или таймаута бездействия
        if abs(pillVelocity.x) < 2 && abs(pillVelocity.y) < 2 {
            pillVelocity = .zero
        }
    }

    /// Таблетка попала в бактерию: бактерия рассыпается пузырями и погибает.
    /// Таблетка НЕ одноразовая — отскакивает и живёт дальше, пока с ней что-то
    /// делают; исчезает только по таймауту бездействия.
    private func consumePill(on victim: BacteriaView) {
        // защита: одна бактерия не может умирать от таблетки повторно
        guard !isBacteriaBusy(victim) else { return }
        pillLastInteraction = Date()
        // Таблетка ПРОЛЕТАЕТ сквозь бактерию (как в оригинале): скорость не
        // меняется, бактерия умирает. Летит дальше и убивает следующих.
        popBacteria(victim)
    }

    // MARK: - Покой

    /// Покой колонии: все свободные бактерии покачиваются (sway), мотор езды
    /// работает постоянно, а раз в пару секунд случайная бактерия делает
    /// маленькое действие (моргание/взгляд/качание) — как в оригинале.
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
        // idle-действия (кивки/взгляд) заметно часто, как в оригинале
        let delay = Double.random(in: 2.5...5.0)
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.playRandomIdle()
            self?.scheduleIdleAction()
        }
    }

    private func playRandomIdle() {
        
        // кивки и осмотр — основа idle-поведения; НЕ блокируют взаимодействие:
        // во время кивка бактерию можно трогать, толкать и колоть
        let names = [ClipName.bumpUpDown, ClipName.bumpLeftRight,
                     ClipName.bumpUpDown, ClipName.lookLeftRight]
        guard let clip = ClipLibrary.shared.random(from: names),
              let target = bacteriaViews.filter({ isFreeForIdle($0) }).randomElement() else { return }
        target.play(clip, repeats: 1, fps: 13, completion: { [weak self] in
            guard let self else { return }
            self.resumeIdle(for: target)
        })
    }

    // MARK: - Запись экрана (кнопка-камера) и постоянный повтор голоса

    /// Кнопка-камера отвечает ТОЛЬКО за запись экрана (как в оригинале).
    /// Повтор голоса при этом не трогаем — он всегда активен отдельно.

    /// Постоянная прослушка: стартуем после разрешения и перезапускаем после
    /// каждого повтора — бактерия всегда слушает и повторяет за пользователем.
    private func startAlwaysListening() {
        requestMicrophone { [weak self] granted in
            guard let self, granted else { return }
            // вся работа с графом — на одной очереди, последовательно:
            // сессия → запуск движка → tap. Без гонок с configureAudio.
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
            // постоянная прослушка с паузой, чтобы idle-анимации были видны
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.startAlwaysListening()
            }
        case .listening:
            // слушают ВСЕ свободные бактерии; занятые реакцией не трогаем
            if let listen = ClipLibrary.shared.clip(ClipName.listen) {
                let free = bacteriaViews.filter { isFreeForIdle($0) }
                talkers = free
                for view in free { view.play(listen, repeats: 0, fps: 8) }
            }
        case .speaking:
            if let talk = ClipLibrary.shared.clip(ClipName.talk) {
                for view in talkers where bacteriaViews.contains(where: { $0 === view }) {
                    view.play(talk, repeats: 0, fps: 14)
                }
            }
        case .failed:
            finishVoiceRepeat()
            // через паузу пробуем снова (микрофон мог быть занят)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startAlwaysListening()
            }
        }
    }

    /// Возврат после повтора голоса: говорящий возвращается в колонию.
    private func finishVoiceRepeat() {
        for view in talkers { resumeIdle(for: view) }
        talkers = []
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
        
        let point = gestureRecognizer.location(in: stageView)
        // пан начинается, только если схватили таблетку или бактерию
        if pillOnScreen, pillView.frame.insetBy(dx: -24, dy: -24).contains(point) { return true }
        return bacteriaViews.contains { $0.frame.insetBy(dx: -10, dy: -10).contains(point) }
    }
}