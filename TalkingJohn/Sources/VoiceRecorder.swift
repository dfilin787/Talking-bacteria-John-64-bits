import AVFoundation
import UIKit

/// Воспроизведение пайплайна оригинала: `startAudioRecording` писал вход в AudioQueue,
/// `AQSoundPlayer` прогонял запись через SoundTouch, а `playTalkAnimation`
/// синхронизировал воспроизведение с клипом `talk`.
///
/// Здесь то же самое на AVAudioEngine: тап с микрофона копится в буфер, по завершении
/// весь буфер проходит через SoundTouch и уходит в player node.
final class VoiceRecorder {

    enum State: Equatable {
        case idle
        case listening
        case speaking
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.listening, .listening), (.speaking, .speaking): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    struct Settings {
        var maxDuration: TimeInterval = 10
        /// Порог RMS, ниже которого считается тишиной.
        var noiseGate: Float = 0.0035
        /// Сколько секунд тишины подряд завершают запись (после того как голос был).
        var silenceTimeout: TimeInterval = 0.9
        /// Насколько поднять голос, в полутонах.
        var pitchSemitones: Double = 9
        var volume: Float = 1.0
    }

    private let engine: AVAudioEngine
    private let playerNode = AVAudioPlayerNode()

    private var collector: SampleCollector?
    /// Коллектор текущего tap'а (создаётся на аудио-потоке по формату буфера).
    private var tapCollector: SampleCollector?
    private let processingQueue = DispatchQueue(label: "john.voice.process", qos: .userInitiated)
    /// Сериализует обращения к графу движка: recorder и эффекты делят один AVAudioEngine.
    private let graphQueue: DispatchQueue

    /// isCapturing пишется на главном потоке и читается на аудио-потоке —
    /// защищаем локом, иначе формальная гонка на Bool.
    private let captureLock = NSLock()
    private var _isCapturing = false
    private var isCapturing: Bool {
        get { captureLock.lock(); defer { captureLock.unlock() }; return _isCapturing }
        set { captureLock.lock(); _isCapturing = newValue; captureLock.unlock() }
    }
    private var captureStartedAt = Date()
    private var lastVoiceAt = Date()
    private var silenceStopScheduled = false
    /// Был ли хоть какой-то голос за время прослушки — авто-стоп только после него.
    /// Пишется на аудио-потоке, читается на main — под captureLock.
    private var _heardVoice = false
    private var heardVoice: Bool {
        get { captureLock.lock(); defer { captureLock.unlock() }; return _heardVoice }
        set { captureLock.lock(); _heardVoice = newValue; captureLock.unlock() }
    }

    var settings = Settings()
    private(set) var state: State = .idle
    var onStateChanged: ((State) -> Void)?
    /// RMS входного сигнала — для индикатора записи.
    private(set) var level: Float = 0

    /// - Parameters:
    ///   - engine: общий движок приложения (тот же, что играет эффекты).
    ///   - graphQueue: очередь, на которой разрешено трогать граф этого движка.
    init(engine: AVAudioEngine, graphQueue: DispatchQueue, format: AVAudioFormat) {
        self.engine = engine
        self.graphQueue = graphQueue
        engine.attach(playerNode)
        // nil-формат: узел согласуется с микшером, частоту которого задаёт вход
        // микрофона (48к). Жёсткие 44.1к не совпадали с буфером записи (48к),
        // и scheduleBuffer молчал — бактерия не говорила.
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    deinit {
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        if engine.isRunning { engine.stop() }
    }

    // MARK: - Запись

    /// Начинает слушать микрофон. Аудиосессию должен подготовить владелец
    /// (категория playAndRecord) — здесь только работа с графом движка.
    func beginListening() {
        guard !isCapturing else { return }

        // Состояние меняется только на главном потоке; аудиопоток лишь читает isCapturing.
        isCapturing = true
        silenceStopScheduled = false
        heardVoice = false
        tapCollector = nil
        collector = nil
        captureStartedAt = Date()
        lastVoiceAt = Date()
        level = 0

        graphQueue.async { [weak self] in
            guard let self else { return }
            // Движок уже запущен для эффектов БЕЗ входа. Первое обращение к
            // inputNode добавляет входной узел в живой граф, и tap не получает
            // данные. Правильный порядок: stop -> вход/формат -> tap -> start.
            if self.engine.isRunning { self.engine.stop() }
            let input = self.engine.inputNode
            input.removeTap(onBus: 0)
            var format = input.outputFormat(forBus: 0)
            if format.sampleRate <= 0 || format.channelCount == 0 {
                try? AVAudioSession.sharedInstance().setActive(true)
                format = input.inputFormat(forBus: 0)
            }
            if format.sampleRate <= 0 || format.channelCount == 0 {
                format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
                    ?? input.outputFormat(forBus: 0)
            }
            guard format.sampleRate > 0, format.channelCount > 0 else {
                DispatchQueue.main.async {
                    self.isCapturing = false
                    self.transition(to: .failed("Микрофон недоступен"))
                }
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                guard let self else { return }
                // Коллектор создаётся РОВНО ОДИН раз за прослушку: проверяем
                // tapCollector (поле аудио-потока), а не collector — тот
                // присваивается на main и здесь всегда был nil, из-за чего
                // коллектор пересоздавался на каждом буфере и запись состояла
                // из последних 20 мс (повтор не проходил порог 0.25 с).
                if self.tapCollector == nil {
                    self.tapCollector = SampleCollector(sampleRate: buffer.format.sampleRate)
                }
                if let target = self.tapCollector {
                    self.consume(buffer, into: target)
                }
            }
            // Запускаем граф ПОСЛЕ установки tap — иначе вход не качает данные.
            self.engine.prepare()
            do { try self.engine.start() } catch {
                DispatchQueue.main.async {
                    self.isCapturing = false
                    self.transition(to: .failed("Не удалось начать запись"))
                }
                return
            }
            DispatchQueue.main.async {
                self.transition(to: .listening)
            }
        }
    }

    func stopListeningAndSpeak() {
        guard isCapturing else { return }
        let captured = tapCollector ?? collector
        tearDownCapture()

        // Повторяем только если реально был голос. Иначе рекордер «говорил»
        // 10 секунд тишины (maxDuration), микрофон в это время выключен —
        // пользователь говорил в пустоту и его никто не слушал.
        // Голос был — повторяем, даже если запись короткая (порог 0.12 с):
        // иначе бактерия «ждала разговора», получала его и молча уходила в idle.
        guard let captured, let raw = captured.makeBuffer(), captured.duration >= 0.08 else {
            transition(to: .idle)
            return
        }
        transition(to: .speaking)
        let pitch = settings.pitchSemitones
        let volume = settings.volume

        processingQueue.async { [weak self] in
            guard let self else { return }
            // Если SoundTouch не отдал сэмплы — играем оригинал, а не молчим.
            let shifted = Self.applyPitch(to: raw, semitones: pitch) ?? raw
            DispatchQueue.main.async {
                self.play(shifted, volume: volume)
            }
        }
    }

    func cancel() {
        tearDownCapture()
        collector = nil
        transition(to: .idle)
    }

    func stopSpeaking() {
        graphQueue.async { [weak self] in self?.playerNode.stop() }
        transition(to: .idle)
    }

    func stopEverything() {
        tearDownCapture()
        graphQueue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            if self.engine.isRunning { self.engine.stop() }
        }
        transition(to: .idle)
    }

    // MARK: - Внутреннее

    private func tearDownCapture() {
        guard isCapturing else { return }
        isCapturing = false
        // Снимаем только tap. Движок НЕ останавливаем: stop() глушит input-узел
        // и сбрасывает его формат, из-за чего следующая прослушка «не слышит».
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Вызывается на аудиопотоке. Только копирование сэмплов и арифметика.
    private func consume(_ buffer: AVAudioPCMBuffer, into collector: SampleCollector) {
        guard isCapturing else { return }
        let mono = buffer.mono() ?? buffer
        collector.append(mono)

        var rms: Float = 0
        let count = Int(mono.frameLength)
        if count > 0, let channel = mono.floatChannelData?.pointee {
            var sum: Float = 0
            for i in 0..<count { sum += channel[i] * channel[i] }
            rms = (sum / Float(count)).squareRoot()
        } else if count > 0, let channel = mono.int16ChannelData?.pointee {
            // int16-вход: без этой ветки RMS всегда 0 и голос не детектился
            var sum: Float = 0
            let scale: Float = 1.0 / 32768.0
            for i in 0..<count {
                let v = Float(channel[i]) * scale
                sum += v * v
            }
            rms = (sum / Float(count)).squareRoot()
        }

        let elapsed = Date().timeIntervalSince(captureStartedAt)
        let voiced = rms > settings.noiseGate
        if voiced { lastVoiceAt = Date(); heardVoice = true }
        let silence = Date().timeIntervalSince(lastVoiceAt)
        // авто-стоп по тишине только после того, как голос реально был;
        // иначе ждём, пока пользователь заговорит (до maxDuration)
        let shouldStop = elapsed >= settings.maxDuration
            || (heardVoice && silence >= settings.silenceTimeout)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }
            self.level = rms
            if shouldStop && !self.silenceStopScheduled {
                self.silenceStopScheduled = true
                self.stopListeningAndSpeak()
            }
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, volume: Float) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        graphQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.engine.isRunning { try self.engine.start() }
            } catch {
                DispatchQueue.main.async { self.transition(to: .idle) }
                return
            }
            self.playerNode.stop()
            self.playerNode.volume = volume
            // Буфер записи — в формате микшера, иначе воспроизведение молчит.
            let mixerFormat = self.engine.mainMixerNode.outputFormat(forBus: 0)
            let prepared = (mixerFormat.sampleRate > 0
                ? SoundBank.convert(buffer, to: mixerFormat) : nil) ?? buffer
            self.playerNode.scheduleBuffer(prepared, at: nil, options: [], completionHandler: nil)
            self.playerNode.play()

            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.06) { [weak self] in
                guard let self, self.state == .speaking else { return }
                self.graphQueue.async { self.playerNode.stop() }
                self.transition(to: .idle)
            }
        }
    }

    /// SoundTouch: подъём тона без изменения длительности.
    private static func applyPitch(to source: AVAudioPCMBuffer, semitones: Double) -> AVAudioPCMBuffer? {
        let format = source.format
        guard let samples = source.floatChannelData?.pointee, source.frameLength > 0,
              let processor = SoundTouchProcessor(sampleRate: format.sampleRate, channels: 1) else { return nil }
        processor.pitchSemitones = semitones
        processor.tempo = 1.0

        guard let data = processor.processFloatSamples(samples, frameCount: UInt(source.frameLength)) else {
            return nil
        }
        let frames = data.count / MemoryLayout<Float>.size
        guard frames > 0,
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = result.floatChannelData?.pointee else { return nil }

        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                destination.update(from: base.assumingMemoryBound(to: Float.self), count: frames)
            }
        }
        result.frameLength = AVAudioFrameCount(frames)
        return result
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChanged?(newState)
    }
}

// MARK: - Копилка сэмплов

/// Копит моно-float подряд. Дешевле и предсказуемее, чем склейка AVAudioPCMBuffer.
final class SampleCollector {
    private var samples: [Float] = []
    private let sampleRate: Double
    private let limit: Int

    init(sampleRate: Double, maxSeconds: TimeInterval = 12) {
        self.sampleRate = sampleRate
        self.limit = Int(sampleRate * maxSeconds)
        samples.reserveCapacity(min(limit, Int(sampleRate * 4)))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard samples.count < limit, buffer.frameLength > 0 else { return }
        let room = limit - samples.count
        let count = min(Int(buffer.frameLength), room)
        guard count > 0 else { return }
        // Микрофон часто отдаёт int16, а не float: floatChannelData тогда nil,
        // и сэмплы не копились вообще — повтор был пустым. Читаем оба формата.
        if let channel = buffer.floatChannelData?.pointee {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        } else if let channel = buffer.int16ChannelData?.pointee {
            let scale: Float = 1.0 / 32768.0
            samples.reserveCapacity(samples.count + count)
            for i in 0..<count { samples.append(Float(channel[i]) * scale) }
        }
    }

    var duration: TimeInterval { Double(samples.count) / sampleRate }

    func makeBuffer() -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?.pointee else { return nil }
        samples.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress {
                destination.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

extension AVAudioPCMBuffer {
    /// Сводит многоканальный буфер в моно. Моно отдаёт как есть.
    func mono() -> AVAudioPCMBuffer? {
        guard format.channelCount > 1 else { return self }
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let result = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameLength),
              let converter = AVAudioConverter(from: format, to: monoFormat) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return self
        }
        guard status != .error, error == nil, result.frameLength > 0 else { return nil }
        return result
    }
}