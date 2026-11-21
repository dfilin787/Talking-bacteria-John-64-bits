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
        var noiseGate: Float = 0.010
        /// Сколько секунд тишины подряд завершают запись (после того как голос был).
        var silenceTimeout: TimeInterval = 1.4
        /// Насколько поднять голос, в полутонах.
        var pitchSemitones: Double = 9
        var volume: Float = 1.0
    }

    private let engine: AVAudioEngine
    private let playerNode = AVAudioPlayerNode()

    private var collector: SampleCollector?
    private let processingQueue = DispatchQueue(label: "john.voice.process", qos: .userInitiated)
    /// Сериализует обращения к графу движка: recorder и эффекты делят один AVAudioEngine.
    private let graphQueue: DispatchQueue

    private var isCapturing = false
    private var captureStartedAt = Date()
    private var lastVoiceAt = Date()
    private var silenceStopScheduled = false
    /// Был ли хоть какой-то голос за время прослушки — авто-стоп только после него.
    private var heardVoice = false

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
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
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

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            transition(to: .failed("Микрофон недоступен"))
            return
        }

        // Состояние меняется только на главном потоке; аудиопоток лишь читает isCapturing.
        isCapturing = true
        silenceStopScheduled = false
        heardVoice = false
        captureStartedAt = Date()
        lastVoiceAt = Date()
        level = 0

        // Узел воспроизведения подключён один раз в init — здесь только тап и запуск.
        graphQueue.async { [weak self] in
            guard let self else { return }
            let collector = SampleCollector(sampleRate: format.sampleRate)
            do {
                self.engine.prepare()
                if !self.engine.isRunning { try self.engine.start() }
            } catch {
                DispatchQueue.main.async {
                    self.isCapturing = false
                    self.transition(to: .failed("Не удалось начать запись"))
                }
                return
            }

            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.consume(buffer, into: collector)
            }
            DispatchQueue.main.async {
                self.collector = collector
                self.transition(to: .listening)
            }
        }
    }

    func stopListeningAndSpeak() {
        guard isCapturing else { return }
        let captured = collector
        tearDownCapture()

        guard let captured, captured.duration >= 0.25, let raw = captured.makeBuffer() else {
            transition(to: .idle)
            return
        }
        transition(to: .speaking)
        let pitch = settings.pitchSemitones
        let volume = settings.volume

        processingQueue.async { [weak self] in
            guard let self else { return }
            let shifted = Self.applyPitch(to: raw, semitones: pitch)
            DispatchQueue.main.async {
                guard let shifted else {
                    self.transition(to: .idle)
                    return
                }
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
        engine.inputNode.removeTap(onBus: 0)
        graphQueue.async { [weak self] in
            guard let self, self.engine.isRunning else { return }
            self.engine.stop()
        }
    }

    /// Вызывается на аудиопотоке. Только копирование сэмплов и арифметика.
    private func consume(_ buffer: AVAudioPCMBuffer, into collector: SampleCollector) {
        guard isCapturing else { return }
        let mono = buffer.mono() ?? buffer
        collector.append(mono)

        var rms: Float = 0
        if let channel = mono.floatChannelData?.pointee, mono.frameLength > 0 {
            var sum: Float = 0
            let count = Int(mono.frameLength)
            for i in 0..<count { sum += channel[i] * channel[i] }
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
            self.playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
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
        guard let channel = buffer.floatChannelData?.pointee, samples.count < limit else { return }
        let room = limit - samples.count
        let count = min(Int(buffer.frameLength), room)
        guard count > 0 else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
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