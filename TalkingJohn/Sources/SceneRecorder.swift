import AVFoundation
import Photos
import UIKit

/// Запись сцены в видео с сохранением в Фото — как в оригинале:
/// `startAnimationRecording` снимал каждый кадр анимации (`addImageToRecording:`),
/// `recordAndConvertAnimationToVideo` кодировал их вместе со звуком,
/// `SaveVideoToLibrary` / `UISaveVideoAtPathToSavedPhotosAlbum` клал ролик в альбом.
///
/// Здесь то же на AVAssetWriter: кадры рендерятся с экрана покадрово, звук пишется
/// с главного микшера общего AVAudioEngine (эффекты + повтор голоса попадают в ролик).
final class SceneRecorder: NSObject {

    enum State {
        case idle
        case recording
        case saving
        case failed(String)
    }

    private let engine: AVAudioEngine
    private let graphQueue: DispatchQueue
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var fileURL: URL?
    private var startTime: CMTime?
    private var lastFrameTime: CMTime = .zero
    /// Якорь аудио: sampleTime узла и соответствующий ему CACurrentMediaTime.
    /// Видео и звук приводятся к одной шкале через этот якорь, иначе рассинхрон.
    private var audioAnchorSample: AVAudioFramePosition?
    private var audioAnchorHost: TimeInterval = 0
    private var audioSampleRate: Double = 44_100
    private var frameTimer: Timer?
    private weak var captureView: UIView?
    private let renderQueue = DispatchQueue(label: "john.scene.render", qos: .userInitiated)

    private(set) var state: State = .idle
    var onStateChanged: ((State) -> Void)?
    /// Вызывается на главном потоке после успешного сохранения в Фото.
    var onSaved: (() -> Void)?

    /// Длительность ролика ограничена, как в оригинале (короткий клип для шаринга).
    var maxDuration: TimeInterval = 15
    private var recordStartedAt = Date()

    init(engine: AVAudioEngine, graphQueue: DispatchQueue) {
        self.engine = engine
        self.graphQueue = graphQueue
        super.init()
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - Запись

    func start(capturing view: UIView) {
        guard !isRecording else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else {
            transition(.failed("Нечего снимать")); return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("john-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            transition(.failed("Не удалось создать видео")); return
        }

        // Чётные размеры — требование кодека H.264.
        let width = Int(size.width) & ~1
        let height = Int(size.height) & ~1
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: attrs)

        // Звук с микшера пишем МОНО: makeSampleBuffer копирует только канал 0,
        // а многоканальный byteCount читал за пределы первого канала и давал
        // шум в ролике. Моно-формат тапа конвертирует микшер сам.
        let mixer = engine.mainMixerNode
        let mixerFormat = mixer.outputFormat(forBus: 0)
        let sampleRate = mixerFormat.sampleRate > 0 ? mixerFormat.sampleRate : 44_100
        guard let tapFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            transition(.failed("Аудиоформат недоступен")); return
        }
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            transition(.failed("Видео не поддерживается")); return
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            transition(.failed(writer.error?.localizedDescription ?? "Ошибка записи")); return
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.pixelAdaptor = adaptor
        self.fileURL = url
        self.captureView = view
        self.audioSampleRate = sampleRate
        self.audioAnchorSample = nil
        // startTime задаётся ОДИН раз здесь, до таймера и тапа: captureFrame
        // (main) и writeAudio (renderQueue) только читают его — гонки нет.
        let start = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        self.startTime = start
        writer.startSession(atSourceTime: start)
        self.lastFrameTime = .zero
        self.recordStartedAt = Date()

        installAudioTap(format: tapFormat)
        startFrameTimer()
        transition(.recording)
    }

    func stop() {
        guard isRecording else { return }
        frameTimer?.invalidate()
        frameTimer = nil
        removeAudioTap()
        transition(.saving)

        guard let writer, let url = fileURL else { transition(.idle); return }
        let videoInput = self.videoInput
        let audioInput = self.audioInput
        renderQueue.async { [weak self] in
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if writer.status == .completed {
                        self.saveToPhotos(url: url)
                    } else {
                        self.cleanup(url: url)
                        self.reset()
                        self.transition(.failed(writer.error?.localizedDescription ?? "Видео не собралось"))
                    }
                }
            }
        }
    }

    func cancel() {
        frameTimer?.invalidate()
        frameTimer = nil
        removeAudioTap()
        if let url = fileURL { cleanup(url: url) }
        writer?.cancelWriting()
        reset()
        transition(.idle)
    }

    // MARK: - Кадры

    private func startFrameTimer() {
        // ~30 кадров/с достаточно для плавной покадровой анимации.
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
    }

    private func captureFrame() {
        guard isRecording, writer?.status == .writing, let view = captureView,
              let adaptor = pixelAdaptor,
              let videoInput, videoInput.isReadyForMoreMediaData else { return }

        if Date().timeIntervalSince(recordStartedAt) >= maxDuration {
            stop(); return
        }

        let now = CACurrentMediaTime()
        let time = CMTime(seconds: now, preferredTimescale: 600)
        guard let start = startTime else { return }
        let pts = CMTimeSubtract(time, start)
        // не пишем два кадра с одним и тем же временем
        if CMTimeCompare(pts, lastFrameTime) <= 0 { return }
        lastFrameTime = pts

        guard let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return }

        let size = view.bounds.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
        guard let cg = image.cgImage else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let context = CGContext(
                data: base, width: CVPixelBufferGetWidth(pixelBuffer), height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.draw(cg, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    // MARK: - Звук

    private func installAudioTap(format: AVAudioFormat) {
        let mixer = engine.mainMixerNode
        graphQueue.async { [weak self] in
            guard let self else { return }
            mixer.removeTap(onBus: 0)
            mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
                self?.writeAudio(buffer, at: time)
            }
        }
    }

    private func removeAudioTap() {
        let mixer = engine.mainMixerNode
        graphQueue.async { mixer.removeTap(onBus: 0) }
    }

    private func writeAudio(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        // копируем сэмплы на аудиопотоке, а append делаем на renderQueue —
        // там же, где stop() помечает inputs finished, чтобы не было гонки.
        guard isRecording, let copy = Self.copyBuffer(buffer) else { return }
        let sample = time.sampleTime
        renderQueue.async { [weak self] in
            guard let self, self.isRecording, self.writer?.status == .writing,
                  let audioInput = self.audioInput,
                  audioInput.isReadyForMoreMediaData, let start = self.startTime else { return }
            if self.audioAnchorSample == nil {
                self.audioAnchorSample = sample
                self.audioAnchorHost = CACurrentMediaTime()
            }
            guard let anchor = self.audioAnchorSample else { return }
            let host = self.audioAnchorHost + Double(sample - anchor) / self.audioSampleRate
            let pts = CMTime(seconds: host, preferredTimescale: 600)
            let rel = CMTimeSubtract(pts, start)
            guard CMTimeCompare(rel, .zero) >= 0 else { return }
            guard let sampleBuffer = Self.makeSampleBuffer(from: copy, presentationTime: rel) else { return }
            audioInput.append(sampleBuffer)
        }
    }

    /// AVAssetWriterInput(audio) принимает CMSampleBuffer, не AVAudioPCMBuffer.
    /// Оборачиваем PCM-буфер с таймингом через CMAudioFormatDescription.
    private static func makeSampleBuffer(from buffer: AVAudioPCMBuffer,
                                         presentationTime: CMTime) -> CMSampleBuffer? {
        let frames = CMItemCount(buffer.frameLength)
        guard frames > 0 else { return nil }
        var formatDesc: CMAudioFormatDescription?
        let asbd = buffer.format.streamDescription
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDesc) == noErr,
              let format = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)

        // копируем аудио-данные в CMBlockBuffer, чтобы владеть памятью
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size * Int(buffer.format.channelCount)
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let block = blockBuffer,
              let src = buffer.floatChannelData?[0] else { return nil }
        CMBlockBufferReplaceDataBytes(with: src, blockBuffer: block,
                                      offsetIntoDestination: 0, dataLength: byteCount)

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - Сохранение

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.cleanup(url: url)
                    self.reset()
                    self.transition(.failed("Нет доступа к Фото"))
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, error in
                    DispatchQueue.main.async {
                        self.cleanup(url: url)
                        if success {
                            self.reset()
                            self.transition(.idle)
                            self.onSaved?()
                        } else {
                            self.reset()
                            self.transition(.failed(error?.localizedDescription ?? "Не сохранилось"))
                        }
                    }
                }
            }
        }
    }

    private func cleanup(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Явная копия буфера: формат и сэмплы переносятся в новый буфер,
    /// чтобы аудиопоток мог сразу переиспользовать свой.
    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameCapacity),
              let src = source.floatChannelData, let dst = copy.floatChannelData else { return nil }
        copy.frameLength = source.frameLength
        let channels = Int(source.format.channelCount)
        let frames = Int(source.frameLength)
        for channel in 0..<channels {
            dst[channel].update(from: src[channel], count: frames)
        }
        return copy
    }

    private func reset() {
        writer = nil
        videoInput = nil
        audioInput = nil
        pixelAdaptor = nil
        fileURL = nil
        captureView = nil
        startTime = nil
    }

    private func transition(_ newState: State) {
        state = newState
        onStateChanged?(newState)
    }
}