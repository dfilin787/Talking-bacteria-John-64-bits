import AVFoundation
import UIKit

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

        var noiseGate: Float = 0.030

        var silenceTimeout: TimeInterval = 1.0

        var pitchSemitones: Double = 9
        var volume: Float = 1.0
    }

    private let engine: AVAudioEngine
    private let playerNode = AVAudioPlayerNode()

    private var collector: SampleCollector?

    private var tapCollector: SampleCollector?
    private let processingQueue = DispatchQueue(label: "john.voice.process", qos: .userInitiated)

    private let graphQueue: DispatchQueue

    private let captureLock = NSLock()
    private var _isCapturing = false
    private var isCapturing: Bool {
        get { captureLock.lock(); defer { captureLock.unlock() }; return _isCapturing }
        set { captureLock.lock(); _isCapturing = newValue; captureLock.unlock() }
    }
    private var captureStartedAt = Date()
    private var lastVoiceAt = Date()
    private var silenceStopScheduled = false

    private var _heardVoice = false
    private var heardVoice: Bool {
        get { captureLock.lock(); defer { captureLock.unlock() }; return _heardVoice }
        set { captureLock.lock(); _heardVoice = newValue; captureLock.unlock() }
    }

    var settings = Settings()
    private(set) var state: State = .idle
    var onStateChanged: ((State) -> Void)?

    private(set) var level: Float = 0

    init(engine: AVAudioEngine, graphQueue: DispatchQueue, format: AVAudioFormat) {
        self.engine = engine
        self.graphQueue = graphQueue
        engine.attach(playerNode)

        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    deinit {
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        if engine.isRunning { engine.stop() }
    }

    func beginListening() {
        guard !isCapturing else { return }

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
                if self.tapCollector == nil {
                    self.tapCollector = SampleCollector(sampleRate: buffer.format.sampleRate)
                }
                if let target = self.tapCollector {
                    self.consume(buffer, into: target)
                }
            }

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

        guard heardVoice, let captured, let raw = captured.makeBuffer(),
              captured.duration >= 0.08 else {
            transition(to: .idle)
            return
        }
        transition(to: .speaking)
        let pitch = settings.pitchSemitones
        let volume = settings.volume

        processingQueue.async { [weak self] in
            guard let self else { return }

            let trimmed = Self.trimSilence(raw, gate: self.settings.noiseGate) ?? raw

            let shifted = Self.applyPitch(to: trimmed, semitones: pitch) ?? trimmed
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

    private func tearDownCapture() {
        guard isCapturing else { return }
        isCapturing = false

        engine.inputNode.removeTap(onBus: 0)
    }

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

        let idleWindow: TimeInterval = 3.0
        let shouldStop = (heardVoice && silence >= settings.silenceTimeout)
            || (!heardVoice && elapsed >= idleWindow)
            || elapsed >= settings.maxDuration

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

    private static func trimSilence(_ buffer: AVAudioPCMBuffer, gate: Float) -> AVAudioPCMBuffer? {
        guard let channel = buffer.floatChannelData?.pointee else { return buffer }
        let total = Int(buffer.frameLength)
        let window = max(1, Int(buffer.format.sampleRate * 0.02))

        let cutGate = gate * 0.25
        let padFrames = Int(buffer.format.sampleRate * 0.12)
        func rms(_ from: Int, _ to: Int) -> Float {
            var sum: Float = 0
            let n = max(1, to - from)
            for i in from..<to { sum += channel[i] * channel[i] }
            return (sum / Float(n)).squareRoot()
        }
        let start = 0
        var end = total
        while end - window >= start && rms(end - window, end) < cutGate { end -= window }
        end = min(total, end + padFrames)
        let frames = end - start
        guard frames > window, frames < total,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: AVAudioFrameCount(frames)) else { return buffer }
        copy.frameLength = AVAudioFrameCount(frames)
        if let dst = copy.floatChannelData?.pointee {
            dst.update(from: channel.advanced(by: start), count: frames)
        }
        return copy
    }

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
