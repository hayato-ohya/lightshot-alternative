import XCTest
import AVFoundation
@testable import LightshotAlt

final class AudioPipelineTests: XCTestCase {
    /// Builds a PCM sample buffer filled with a constant value.
    private func buffer(sampleRate: Double, channels: AVAudioChannelCount, frames: Int, value: Float, pts: Double) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(channels) {
            for i in 0..<frames { pcm.floatChannelData![c][i] = value }
        }
        return AudioPipeline.makeSampleBuffer(pcm, presentationTime: CMTime(seconds: pts, preferredTimescale: 48_000))!
    }

    private func samples(_ sb: CMSampleBuffer) -> [Float] {
        let frames = CMSampleBufferGetNumSamples(sb)
        let pcm = AVAudioPCMBuffer(pcmFormat: AudioPipeline.canonicalFormat, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        XCTAssertEqual(CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList), noErr)
        return Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: frames * 2))
    }

    func testNormalizedConvertsMonoToCanonicalStereo() {
        let pipeline = AudioPipeline()
        let mic = buffer(sampleRate: 48_000, channels: 1, frames: 480, value: 0.25, pts: 1.0)
        let out = pipeline.normalized(mic, source: "mic")!
        XCTAssertEqual(CMSampleBufferGetNumSamples(out), 480)
        XCTAssertEqual(out.presentationTimeStamp.seconds, 1.0, accuracy: 0.0001)
        let s = samples(out)
        XCTAssertEqual(s[0], 0.25, accuracy: 0.01)   // left
        XCTAssertEqual(s[1], 0.25, accuracy: 0.01)   // right
    }

    func testMixAddsQueuedMicrophoneToSystemAudio() {
        let pipeline = AudioPipeline()
        pipeline.enqueueMicrophone(buffer(sampleRate: 48_000, channels: 2, frames: 480, value: 0.2, pts: 0))
        let system = buffer(sampleRate: 48_000, channels: 2, frames: 480, value: 0.3, pts: 2.0)
        let mixed = pipeline.mixedWithMicrophone(system)!
        let s = samples(mixed)
        XCTAssertEqual(s.count, 960)
        XCTAssertEqual(s[100], 0.5, accuracy: 0.001)
        XCTAssertEqual(mixed.presentationTimeStamp.seconds, 2.0, accuracy: 0.0001)
        // Mic queue was consumed: the next system buffer is passed through unchanged.
        let next = pipeline.mixedWithMicrophone(buffer(sampleRate: 48_000, channels: 2, frames: 480, value: 0.3, pts: 2.01))!
        XCTAssertEqual(samples(next)[100], 0.3, accuracy: 0.001)
    }

    func testMixResamplesMicrophoneAndClips() {
        let pipeline = AudioPipeline()
        pipeline.enqueueMicrophone(buffer(sampleRate: 44_100, channels: 1, frames: 4410, value: 0.9, pts: 0))
        let system = buffer(sampleRate: 48_000, channels: 2, frames: 2400, value: 0.9, pts: 0)
        let mixed = pipeline.mixedWithMicrophone(system)!
        let s = samples(mixed)
        XCTAssertEqual(s.count, 4800)
        XCTAssertEqual(s.max()!, 1.0, accuracy: 0.001, "sum must be clipped to 1.0")
        XCTAssertGreaterThan(s[2000], 0.95)
    }
}
