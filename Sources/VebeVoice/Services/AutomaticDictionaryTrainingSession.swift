import AppKit
import Combine
import Foundation

@MainActor
final class AutomaticDictionaryTrainingSession: ObservableObject {
    enum Screen: Equatable {
        case choice
        case success
    }

    let candidate: AutomaticDictionaryCorrectionCandidate

    @Published private(set) var screen: Screen = .choice
    @Published private(set) var successTitle = "Added to Dictionary"

    var onInteraction: (() -> Void)?
    var onSuccess: (() -> Void)?

    private var isCancelled = false

    init(candidate: AutomaticDictionaryCorrectionCandidate) {
        self.candidate = candidate
    }

    var intendedText: String {
        CustomDictionaryTrainingMerge.normalizedReplacement(self.candidate.correctedText)
    }

    func addOnlyCorrection() {
        self.persist(triggers: [self.candidate.heardText])
    }

    func cancel() {
        self.isCancelled = true
    }

    private func persist(triggers: [String]) {
        guard !self.isCancelled else { return }
        self.onInteraction?()
        let currentEntries = SettingsStore.shared.customDictionaryEntries
        let updatedExisting = currentEntries.contains {
            $0.replacement.caseInsensitiveCompare(self.intendedText) == .orderedSame
        }
        let mergedEntries = CustomDictionaryTrainingMerge.mergedEntries(
            current: currentEntries,
            replacement: self.intendedText,
            triggers: triggers
        )
        guard mergedEntries != currentEntries else {
            self.completeSave(title: "Already in Dictionary")
            return
        }

        SettingsStore.shared.customDictionaryEntries = mergedEntries
        ASRService.invalidateDictionaryCache()
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
        self.completeSave(title: updatedExisting ? "Dictionary Updated" : "Added to Dictionary")
    }

    private func completeSave(title: String) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        self.successTitle = title
        self.screen = .success
        self.onSuccess?()
    }
}
