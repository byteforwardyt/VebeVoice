import CoreAudio
#if SWIFT_PACKAGE
import CoreAudioCaptureSupport
#endif
import Foundation

/// Prepared, input-only Core Audio capture.
///
/// `AudioDeviceIOProc` publishes native hardware-cycle PCM into a fixed SPSC
/// ring in C. This Swift wrapper drains that ring away from Core Audio's
/// realtime thread, so resampling, level calculation, logging, and ASR buffer
/// mutation never happen in the device callback.
final class DirectCoreAudioInput {
    typealias PacketHandler = @Sendable (
        _ samples: UnsafePointer<Float>,
        _ frameCount: Int,
        _ sampleRate: Double,
        _ inputHostTime: UInt64,
        _ inputSampleTime: Int64
    ) -> Void

    /// The consumer retains the allocation until its last ring access, including
    /// when a bounded stop times out and the main actor retires this input.
    private final class CaptureHandle: @unchecked Sendable {
        let rawValue: VVCoreAudioCaptureRef

        init(_ rawValue: VVCoreAudioCaptureRef) { self.rawValue = rawValue }

        deinit { vv_core_audio_capture_destroy(self.rawValue) }
    }

    let deviceID: AudioObjectID
    let sampleRate: Double
    let hardwareBufferFrameSize: UInt32

    private var capture: CaptureHandle?
    private let packetHandler: PacketHandler
    private let workerQueue = DispatchQueue(
        label: "com.vebevoice.audio.direct-input-consumer",
        qos: .userInteractive
    )
    private let workerGroup = DispatchGroup()

    init(deviceID: AudioObjectID, packetHandler: @escaping PacketHandler) throws {
        var capture: VVCoreAudioCaptureRef?
        let status = vv_core_audio_capture_create(deviceID, &capture)
        guard status == noErr, let capture else {
            throw Self.error(status: status, operation: "prepare direct Core Audio input")
        }

        self.deviceID = deviceID
        self.capture = CaptureHandle(capture)
        self.sampleRate = vv_core_audio_capture_sample_rate(capture)
        self.hardwareBufferFrameSize = vv_core_audio_capture_buffer_frame_size(capture)
        self.packetHandler = packetHandler
    }

    deinit {
        self.invalidate()
    }

    var droppedPacketCount: UInt64 {
        guard let capture else { return 0 }
        return vv_core_audio_capture_dropped_packet_count(capture.rawValue)
    }

    func start() throws {
        guard let capture else {
            throw Self.error(status: kAudioHardwareBadObjectError, operation: "start direct Core Audio input")
        }
        guard vv_core_audio_capture_is_running(capture.rawValue) == false else { return }
        // Never reset a ring while the previous consumer is still draining it.
        guard self.workerGroup.wait(timeout: .now()) == .success else {
            throw Self.error(status: kAudioHardwareIllegalOperationError, operation: "restart audio input while its previous worker is draining")
        }

        vv_core_audio_capture_clear(capture.rawValue)
        let status = vv_core_audio_capture_start(capture.rawValue)
        guard status == noErr else {
            throw Self.error(status: status, operation: "start direct Core Audio input")
        }

        let packetHandler = self.packetHandler
        let workerGroup = self.workerGroup
        let workerHandle = capture
        workerGroup.enter()
        self.workerQueue.async {
            defer { workerGroup.leave() }
            Self.consumePackets(capture: workerHandle.rawValue, packetHandler: packetHandler)
        }
    }

    /// Stops hardware IO and synchronously drains every packet already published
    /// by the realtime callback before returning.
    ///
    /// The drain wait is bounded: this is called on the main thread (from
    /// `ASRService.stopActiveAudioCapture`), and a wedged device (e.g. Bluetooth)
    /// must not beachball the UI.
    @discardableResult
    func stop() -> OSStatus {
        guard let capture else { return noErr }
        let status = vv_core_audio_capture_stop(capture.rawValue)
        vv_core_audio_capture_wake(capture.rawValue)
        if self.workerGroup.wait(timeout: .now() + 2.0) == .timedOut {
            DebugLogger.shared.warning(
                "DirectCoreAudioInput: worker drain timed out after 2s in stop()",
                source: "DirectCoreAudioInput"
            )
        }
        return status
    }

    func invalidate() {
        guard self.capture != nil else { return }
        _ = self.stop()
        self.capture = nil
    }

    private nonisolated static func consumePackets(
        capture: VVCoreAudioCaptureRef,
        packetHandler: PacketHandler
    ) {
        while true {
            var packet = VVCoreAudioPacket()
            while vv_core_audio_capture_peek(capture, &packet) {
                if let samples = packet.samples, packet.frameCount > 0 {
                    packetHandler(
                        samples,
                        Int(packet.frameCount),
                        packet.sampleRate,
                        packet.inputHostTime,
                        packet.inputSampleTime
                    )
                }
                vv_core_audio_capture_consume(capture)
            }

            guard vv_core_audio_capture_is_running(capture) else {
                // AudioDeviceStop waits for the IOProc to leave. One final
                // acquire/drain above therefore captures the complete tail.
                return
            }
            _ = vv_core_audio_capture_wait(capture, 100)
        }
    }

    private static func error(status: OSStatus, operation: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to \(operation) (OSStatus \(status)).",
            ]
        )
    }
}
