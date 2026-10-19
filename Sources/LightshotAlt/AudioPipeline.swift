import AVFoundation

/// Normalizes system-audio and microphone sample buffers to one canonical PCM format
/// (Float32, 48 kHz, stereo, interleaved) and optionally mixes the two sources.
/// Not thread-safe: call it from a single serial queue.
final class AudioPipeline {
    static let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!

    private var converters: [String: (input: AVAudioFormat, converter: AVAudioConverter)] = [:]
    private var micFIFO: [Float] = []
    /// Keep at most this many interleaved mic samples queued (0.5 s); older ones are dropped so latency cannot grow.
    private let maxQueuedMicSamples = 48_000

    // MARK: - Public

    /// Converts a buffer from either source to the canonical format, keeping its timestamp.
    func normalized(_ sampleBuffer: CMSampleBuffer, source: String) -> CMSampleBuffer? {
        guard let pcm = convert(sampleBuffer, key: source) else { return nil }
        return AudioPipeline.makeSampleBuffer(pcm, presentationTime: sampleBuffer.presentationTimeStamp)
    }

    /// Queues microphone audio to be mixed into subsequent system-audio buffers.
    func enqueueMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = convert(sampleBuffer, key: "mic") else { return }
        let count = Int(pcm.frameLength) * Int(pcm.format.channelCount)
        micFIFO.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: count))
        if micFIFO.count > maxQueuedMicSamples {
            micFIFO.removeFirst(micFIFO.count - maxQueuedMicSamples)
        }
    }

    /// Mixes queued microphone audio into a system-audio buffer and returns the result.
    func mixedWithMicrophone(_ systemBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let pcm = convert(systemBuffer, key: "sys") else { return nil }
        let count = Int(pcm.frameLength) * Int(pcm.format.channelCount)
        let out = pcm.floatChannelData![0]
        let take = min(count, micFIFO.count)
        if take > 0 {
            micFIFO.withUnsafeBufferPointer { mic in
                for i in 0..<take { out[i] = max(-1, min(1, out[i] + mic[i])) }
            }
            micFIFO.removeFirst(take)
        }
        return AudioPipeline.makeSampleBuffer(pcm, presentationTime: systemBuffer.presentationTimeStamp)
    }

    // MARK: - Conversion

    private func convert(_ sampleBuffer: CMSampleBuffer, key: String) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: inputBuffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        if inputFormat == AudioPipeline.canonicalFormat { return inputBuffer }

        let converter: AVAudioConverter
        if let cached = converters[key], cached.input == inputFormat {
            converter = cached.converter
        } else {
            guard let fresh = AVAudioConverter(from: inputFormat, to: AudioPipeline.canonicalFormat) else { return nil }
            converters[key] = (inputFormat, fresh)
            converter = fresh
        }
        let ratio = AudioPipeline.canonicalFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: AudioPipeline.canonicalFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let result = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard result != .error, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }

    /// Wraps a PCM buffer in a CMSampleBuffer (copying the audio data).
    static func makeSampleBuffer(_ pcm: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: pcm.format.streamDescription,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                        presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                                   sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                             bufferList: pcm.audioBufferList) == noErr else { return nil }
        return sampleBuffer
    }
}
