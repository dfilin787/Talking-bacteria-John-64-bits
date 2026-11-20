import AVFoundation
import QuartzCore
import UIKit

/// Все звуковые эффекты персонажа. WAV из оригинала: моно, 11025 Гц, 16 бит.
/// Загружаются в память один раз — суммарно меньше двух мегабайт.
/// Все обращения идут с одной аудиочереди, поэтому кэш не защищён замком.
final class SoundBank {
    static let shared = SoundBank()

    enum Effect: String, CaseIterable {
        case laugh
        case laugh2
        case laugh3
        case giggle = "krohotanje"
        case crazy1 = "crazy_1"
        case crazy1Alt = "crazy_1_alt"
        case crazy1Alt2 = "crazy_1_alt2"
        case eat1
        case eat2
        case explode
        case explode2
        case multiply
    }

    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)

    private init() {}

    /// Читает WAV из папки-референса `Sounds` и приводит к формату движка.
    func buffer(for effect: Effect) -> AVAudioPCMBuffer? {
        if let cached = buffers[effect.rawValue] { return cached }
        guard let url = BundleLocator.file(directory: "Sounds", name: effect.rawValue, extension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: source) } catch { return nil }

        guard let converted = Self.convert(source, to: format) else { return nil }
        buffers[effect.rawValue] = converted
        return converted
    }

    func buffer(named name: String) -> AVAudioPCMBuffer? {
        guard let effect = Effect(rawValue: name) else { return nil }
        return buffer(for: effect)
    }

    func preloadAll() {
        for effect in Effect.allCases { _ = buffer(for: effect) }
    }

    /// Пересчитывает частоту дискретизации и число каналов через AVAudioConverter.
    static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if source.format.sampleRate == format.sampleRate,
           source.format.channelCount == format.channelCount {
            return source
        }
        guard let converter = AVAudioConverter(from: source.format, to: format) else { return nil }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio + 1024)
        guard let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: destination, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, destination.frameLength > 0 else { return nil }
        return destination
    }
}

/// Проигрыватель эффектов поверх общего AVAudioEngine.
final class EffectPlayer {
    private let engine: AVAudioEngine
    private var players: [AVAudioPlayerNode] = []
    private var deadlines: [TimeInterval] = []
    private let deadlinesLock = NSLock()
    private var nextPlayer = 0
    private let format: AVAudioFormat

    init(engine: AVAudioEngine, format: AVAudioFormat, voices: Int = 4) {
        self.engine = engine
        self.format = format
        for _ in 0..<voices {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            players.append(node)
            deadlines.append(0)
        }
    }

    /// Проигрывает эффект и возвращает предсказанную длительность в секундах.
    /// Вызывать только на аудиочереди владельца движка.
    @discardableResult
    func play(_ buffer: AVAudioPCMBuffer, volume: Float = 1.0) -> TimeInterval {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard !players.isEmpty else { return 0 }
        if !engine.isRunning {
            do { try engine.start() } catch { return 0 }
        }
        let index = nextPlayer
        let node = players[index]
        nextPlayer = (nextPlayer + 1) % players.count
        node.stop()
        node.volume = volume
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        node.play()
        // AVAudioPlayerNode.isPlaying остаётся true и после окончания буфера,
        // поэтому окончание считаем по времени, а не по флагу узла.
        deadlinesLock.lock()
        deadlines[index] = CACurrentMediaTime() + duration
        deadlinesLock.unlock()
        return duration
    }

    func stopAll() {
        players.forEach { $0.stop() }
        deadlinesLock.lock()
        for i in deadlines.indices { deadlines[i] = 0 }
        deadlinesLock.unlock()
    }

    /// Тишина на всех голосах по расчётным дедлайнам. Пригодится для отладки;
    /// синхронизация анимации в игре считается по длительности буфера напрямую.
    var isSilent: Bool {
        let now = CACurrentMediaTime()
        deadlinesLock.lock()
        let silent = deadlines.allSatisfy { $0 <= now }
        deadlinesLock.unlock()
        return silent
    }
}