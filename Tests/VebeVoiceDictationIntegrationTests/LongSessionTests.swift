import AVFoundation
import Darwin
@testable import VebeVoice
import XCTest

@MainActor
final class LongSessionTests: XCTestCase {
    func testDeniedAccessibilityCanBeRetried() {
        var permissionChecks = 0
        let typing = TypingService(accessibilityCheck: {
            permissionChecks += 1
            return false
        })
        typing.typeTextInstantly("First attempt")
        typing.typeTextInstantly("Second attempt")
        XCTAssertEqual(permissionChecks, 2, "A denied insertion must release its busy state")
    }

    func testTenMinuteBufferKeepsFullAudioAndBoundsPreview() {
        let buffer = ThreadSafeAudioBuffer()
        for second in 0..<600 {
            buffer.append(Array(repeating: Float(second), count: 16_000))
            let preview = buffer.getSuffix(ASRService.streamingPreviewSampleLimit)
            XCTAssertLessThanOrEqual(preview.count, 30 * 16_000)
            XCTAssertEqual(preview.last, Float(second))
        }
        let all = buffer.getAll()
        XCTAssertEqual(all.count, 600 * 16_000)
        XCTAssertEqual(all.first, 0)
        XCTAssertEqual(all.last, 599)
        buffer.clear()
        buffer.append([123])
        XCTAssertEqual(buffer.getAll(), [123], "A second session must not contain the first session's audio")
        XCTAssertTrue(buffer.getPrefix(-1).isEmpty)
        XCTAssertTrue(buffer.getSuffix(-1).isEmpty)
    }

    func testTenMinuteCaptureResamplesWithoutDriftOrLostTail() {
        let buffer = ThreadSafeAudioBuffer()
        var mismatches = 0
        let pipeline = AudioCapturePipeline(
            audioBuffer: buffer,
            onFirstAudio: { _, _, _, _, _, _ in },
            onDurationMismatch: { _, _, _ in mismatches += 1 },
            onLevel: { _ in }
        )
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        let start = mach_absolute_time()
        let packet = [Float](repeating: 0.25, count: 480)
        pipeline.setRecordingEnabled(true, sessionID: 1, startHostTime: start)
        for index in 0..<60_000 {
            packet.withUnsafeBufferPointer { data in
                pipeline.handle(samples: data.baseAddress!, frameCount: 480, sampleRate: 48_000,
                                inputHostTime: start + UInt64(Double(index) * 0.01 * ticksPerSecond),
                                inputSampleTime: Int64(index * 480))
            }
        }
        pipeline.markRecordingEnd(atHostTime: start + UInt64(600 * ticksPerSecond))
        pipeline.finishRecording()
        XCTAssertEqual(buffer.count, 9_600_000, accuracy: 1)
        XCTAssertEqual(buffer.getSuffix(1).first, 0.25)
        XCTAssertEqual(mismatches, 0)
    }

    /// Opt in by creating /private/tmp/vebevoice-long-session.wav with the fixture script.
    /// Uses the real cached Parakeet v2 engine without changing the user's engine selection.
    func testTenMinuteParakeetTranscriptionAndNextSession() async throws {
        let url = URL(fileURLWithPath: "/private/tmp/vebevoice-long-session.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Run Tests/VebeVoiceDictationIntegrationTests/Resources/make-long-session-fixture.sh for the extended ASR test")
        let provider = FluidAudioProvider(modelOverride: .parakeetTDTv2, configureWordBoosting: false)
        try XCTSkipUnless(provider.modelsExistOnDisk(), "Parakeet v2 must already be cached locally")
        try await provider.prepare()
        let file = try AVAudioFile(forReading: url)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let samples = try AudioBufferConverter.monoSamples(from: input, targetSampleRate: 16_000)
        XCTAssertEqual(samples.count, 9_600_000, accuracy: 1)
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await provider.transcribeFinal(samples)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let text = result.text.lowercased()
        print("LONG_SESSION audio_seconds=600 final_seconds=\(seconds) words=\(text.split(separator: " ").count)")
        XCTAssertTrue(text.contains("lighthouse"), "Beginning of recording was lost")
        XCTAssertTrue(text.contains("notebook"), "Middle of recording was lost")
        XCTAssertTrue(text.contains("sunflower"), "End of recording was lost")
        XCTAssertGreaterThan(text.split(separator: " ").count, 500)
        let next = try await provider.transcribeFinal(Array(samples.prefix(8 * 16_000)))
        XCTAssertTrue(next.text.lowercased().contains("lighthouse"))
        XCTAssertFalse(next.text.lowercased().contains("sunflower"), "Decoder leaked the prior session into the next one")
        print("LONG_SESSION next_session_passed=true")
    }
}
