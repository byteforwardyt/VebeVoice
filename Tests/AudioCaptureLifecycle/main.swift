import Foundation
final class DebugLogger {
    static let shared = DebugLogger()
    func warning(_ text: String, source: String) { print(text) }
}
@_silgen_name("probe_accesses") func probeAccesses() -> Int32
@_silgen_name("probe_destroy_count") func probeDestroyCount() -> Int32
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let capture = try DirectCoreAudioInput(deviceID: 1) { _, _, _, _, _ in
    entered.signal()
    release.wait()
}
try capture.start()
precondition(entered.wait(timeout: .now() + 5) == .success)
capture.stop()
var rejectedUnsafeRestart = false
do { try capture.start() } catch { rejectedUnsafeRestart = true }
precondition(rejectedUnsafeRestart, "A draining ring must not be restarted")
capture.invalidate()
capture.invalidate()
precondition(probeDestroyCount() == 0, "Worker still owns the ring")
release.signal()
let deadline = Date().addingTimeInterval(2)
while probeDestroyCount() == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
precondition(probeDestroyCount() == 1, "Ring must be destroyed exactly once after worker exits")
precondition(probeAccesses() == 0, "No worker access is allowed after destruction")
print("PASS: timed-out stop, blocked restart, deferred destruction, and repeated invalidation")
