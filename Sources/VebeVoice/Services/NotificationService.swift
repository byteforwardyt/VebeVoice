import Foundation
import UserNotifications

enum NotificationService {
    enum UserInfoKey {
        static let kind = "kind"
    }

    enum Kind {
        static let audioCaptureFallback = "audioCaptureFallback"
    }

    static func showAudioCaptureFallback(
        failureCount: Int,
        experimentalSettingDisabled: Bool
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliverAudioCaptureFallback(
                    failureCount: failureCount,
                    experimentalSettingDisabled: experimentalSettingDisabled,
                    using: center
                )
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, requestError in
                    if let requestError {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(requestError.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    self.deliverAudioCaptureFallback(
                        failureCount: failureCount,
                        experimentalSettingDisabled: experimentalSettingDisabled,
                        using: center
                    )
                }
            case .denied:
                DebugLogger.shared.debug(
                    "Skipping audio capture fallback notification because notification permission is denied",
                    source: "NotificationService"
                )
            @unknown default:
                break
            }
        }
    }

    private static func deliverAudioCaptureFallback(
        failureCount: Int,
        experimentalSettingDisabled: Bool,
        using center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        if experimentalSettingDisabled {
            content.title = "Faster Recording Start turned off"
            content.body = "VebeVoice detected malformed microphone audio three times and switched to the compatibility audio path. You can turn it back on in Settings."
        } else {
            content.title = "Microphone audio recovered"
            content.body = "VebeVoice detected malformed audio and switched this session to the compatibility audio path. Faster Recording Start will retry next recording. (\(failureCount)/3)"
        }
        content.sound = nil
        content.userInfo = [UserInfoKey.kind: Kind.audioCaptureFallback]

        let request = UNNotificationRequest(
            identifier: "audio-capture-fallback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { addError in
            if let addError {
                DebugLogger.shared.warning(
                    "Failed to show audio capture fallback notification: \(addError.localizedDescription)",
                    source: "NotificationService"
                )
            }
        }
    }

}
