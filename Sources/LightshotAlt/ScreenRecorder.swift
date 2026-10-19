import AVFoundation
import AppKit
import ScreenCaptureKit

enum AudioSource: String, CaseIterable {
    case system, microphone, both, mute
    var title: String {
        switch self {
        case .system: return "System Audio"
        case .microphone: return "Microphone"
        case .both: return "System Audio + Microphone"
        case .mute: return "Mute (no audio)"
        }
    }
    var usesSystemAudio: Bool { self == .system || self == .both }
    var usesMicrophone: Bool { self == .microphone || self == .both }
}

struct RecordingOptions {
    var audioSource: AudioSource
    var showCursor: Bool
}

enum RecordingError: LocalizedError {
    case microphoneDenied
    case displayNotFound
    case writer(String)
    case notRecording
    case noSamples

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access is required for this audio source. Enable it in System Settings → Privacy & Security → Microphone."
        case .displayNotFound: return "The display to record could not be found."
        case .writer(let s): return "Could not write the recording: \(s)"
        case .notRecording: return "No recording is in progress."
        case .noSamples: return "Nothing was recorded."
        }
    }
}

/// Records a screen region (plus audio) or audio only, using ScreenCaptureKit and AVAssetWriter.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let options: RecordingOptions
    let outputURL: URL
    private(set) var startedAt: Date?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "LightshotAlt.recorder")
    private let audio = AudioPipeline()
    private var sessionStartTime: CMTime?
    private var wroteSamples = false
    var onStreamStopped: ((Error?) -> Void)?

    init(options: RecordingOptions, outputURL: URL) {
        self.options = options
        self.outputURL = outputURL
    }

    /// `rect` is in points, relative to the top-left corner of `screen`.
    @MainActor
    func start(screen: NSScreen, rect: CGRect) async throws {
        if options.audioSource.usesMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw RecordingError.microphoneDenied }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let targetScreen = screen
        var used = Set<CGDirectDisplayID>()
        guard let display = ScreenCapturer.display(for: targetScreen, in: content, used: &used) else {
            throw RecordingError.displayNotFound
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        if let selfApp = content.applications.first(where: { $0.processID == selfPID }) {
            filter = SCContentFilter(display: display, excludingApplications: [selfApp], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        let scale = targetScreen.backingScaleFactor
        let region = rect.standardized
        var videoSize = CGSize.zero
        do {
            // H.264 needs even dimensions.
            let w = max(2, Int(region.width * scale) & ~1)
            let h = max(2, Int(region.height * scale) & ~1)
            config.sourceRect = region
            config.width = w
            config.height = h
            config.showsCursor = options.showCursor
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 6
            videoSize = CGSize(width: w, height: h)
        }
        config.capturesAudio = options.audioSource.usesSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.audioSource.usesMicrophone

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        do {
            let pixels = Double(videoSize.width * videoSize.height)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(min(max(pixels * 4, 2_000_000), 40_000_000)),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: 30,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError.writer("video input rejected") }
            writer.add(input)
            videoInput = input
        }
        if options.audioSource != .mute {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError.writer("audio input rejected") }
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else {
            throw RecordingError.writer(writer.error?.localizedDescription ?? "unknown error")
        }
        self.writer = writer

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.audioSource.usesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if options.audioSource.usesMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        do {
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            self.writer = nil
            throw error
        }
        self.stream = stream
        startedAt = Date()
    }

    /// Stops capturing and finalizes the file.
    @MainActor
    func stop() async throws -> URL {
        guard let stream, let writer else { throw RecordingError.notRecording }
        self.stream = nil
        try? await stream.stopCapture()

        let hadSamples: Bool = await withCheckedContinuation { continuation in
            queue.async {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                continuation.resume(returning: self.wroteSamples)
            }
        }
        guard hadSamples, writer.status == .writing else {
            writer.cancelWriting()
            self.writer = nil
            try? FileManager.default.removeItem(at: outputURL)
            if writer.status == .failed, let error = writer.error { throw RecordingError.writer(error.localizedDescription) }
            throw RecordingError.noSamples
        }
        await writer.finishWriting()
        self.writer = nil
        if writer.status == .failed {
            throw RecordingError.writer(writer.error?.localizedDescription ?? "unknown error")
        }
        return outputURL
    }

    // MARK: - SCStreamOutput (called on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            guard let videoInput, isCompleteFrame(sampleBuffer), CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            beginSessionIfNeeded(at: sampleBuffer.presentationTimeStamp)
            append(sampleBuffer, to: videoInput)
        case .audio:
            guard options.audioSource.usesSystemAudio else { return }
            let buffer = options.audioSource == .both
                ? audio.mixedWithMicrophone(sampleBuffer)
                : audio.normalized(sampleBuffer, source: "sys")
            if let buffer { appendAudio(buffer) }
        case .microphone:
            guard options.audioSource.usesMicrophone else { return }
            if options.audioSource == .both {
                audio.enqueueMicrophone(sampleBuffer)
            } else if let buffer = audio.normalized(sampleBuffer, source: "mic") {
                appendAudio(buffer)
            }
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamStopped?(error) }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    private func beginSessionIfNeeded(at time: CMTime) {
        guard sessionStartTime == nil, let writer else { return }
        writer.startSession(atSourceTime: time)
        sessionStartTime = time
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput else { return }
        // The session starts on the first video frame, so audio that arrives earlier is dropped.
        append(sampleBuffer, to: audioInput)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard let start = sessionStartTime, sampleBuffer.presentationTimeStamp >= start,
              input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) { wroteSamples = true }
    }
}
