import Foundation

extension Bundle {
    var vibeAppDisplayName: String {
        let displayName = self.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = self.object(forInfoDictionaryKey: "CFBundleName") as? String
        return [displayName, bundleName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "VebeVoice"
    }
}
