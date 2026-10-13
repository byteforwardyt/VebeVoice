@testable import VebeVoice
import Foundation
import XCTest

@MainActor
final class DictationE2ETests: XCTestCase {
    private let customDictionaryEntriesKey = "CustomDictionaryEntries"
    private let autoConvertPunctuationEnabledKey = "AutoConvertPunctuationEnabled"
    private let literalDictationFormattingEnabledKey = "LiteralDictationFormattingEnabled"
    private let punctuationDictionaryPrefixKey = "PunctuationDictionaryPrefix"
    private let punctuationDictionaryRulesKey = "PunctuationDictionaryRules"

    private var punctuationFormattingDefaultsKeys: [String] {
        [
            self.autoConvertPunctuationEnabledKey,
            self.punctuationDictionaryPrefixKey,
            self.punctuationDictionaryRulesKey,
        ]
    }

    func testTranscriptionHistoryEntryClipboardTextPrefersProcessedText() {
        let entry = TranscriptionHistoryEntry(
            rawText: " raw transcript ",
            processedText: " processed transcript ",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: true
        )

        XCTAssertEqual(entry.clipboardText, "processed transcript")
    }

    func testTranscriptionHistoryEntryClipboardTextFallsBackToRawText() {
        let entry = TranscriptionHistoryEntry(
            rawText: " raw transcript ",
            processedText: "   ",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: false
        )

        XCTAssertEqual(entry.clipboardText, "raw transcript")
    }

    func testTranscriptionHistoryEntryClipboardTextSkipsEmptyText() {
        let entry = TranscriptionHistoryEntry(
            rawText: "   ",
            processedText: "   ",
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: false
        )

        XCTAssertNil(entry.clipboardText)
    }

    func testTranscriptionStartSound_noneOptionHasNoFile() {
        XCTAssertEqual(SettingsStore.TranscriptionStartSound.none.displayName, "None")
        XCTAssertNil(SettingsStore.TranscriptionStartSound.none.startSoundFileName)
    }

    func testDictionaryTransferDocument_encodesSimpleUserFormat() throws {
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["vibe voice", "vibe boys"], to: "VebeVoice"),
            ],
            customWords: ["VebeVoice", "GEMBA-E"]
        )

        let data = try DictionaryTransferService.shared.encode(document)
        let json = String(data: data, encoding: .utf8) ?? ""
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let replacements = try XCTUnwrap(root["replacements"] as? [[String: Any]])
        let firstReplacement = try XCTUnwrap(replacements.first)

        XCTAssertEqual(firstReplacement["from"] as? [String], ["vibe voice", "vibe boys"])
        XCTAssertEqual(firstReplacement["to"] as? String, "VebeVoice")
        XCTAssertEqual(root["customWords"] as? [String], ["VebeVoice", "GEMBA-E"])
        XCTAssertFalse(json.contains("\"triggers\""))
        XCTAssertFalse(json.contains("\"replacement\""))
        XCTAssertFalse(json.contains("\"aliases\""))
    }

    func testDictionaryTransferImport_replaceMapsSimpleFormatToStores() throws {
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: [" Vibe Voice ", "VIBE BOYS", ""], to: " VebeVoice "),
            ],
            customWords: [" VebeVoice ", "vebevoice", " Barath "]
        )
        let existingReplacement = SettingsStore.CustomDictionaryEntry(triggers: ["old"], replacement: "Old")
        let existingWord = ParakeetVocabularyStore.VocabularyConfig.Term(text: "OldWord", weight: 13.0)

        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [existingReplacement],
            currentCustomWords: [existingWord]
        )

        XCTAssertEqual(state.replacements.count, 1)
        XCTAssertEqual(state.replacements.first?.triggers, ["vibe voice", "vibe boys"])
        XCTAssertEqual(state.replacements.first?.replacement, "VebeVoice")
        XCTAssertEqual(state.customWords.map(\.text), ["VebeVoice", "Barath"])
        XCTAssertEqual(state.customWords.map(\.weight), [10.0, 10.0])
        XCTAssertEqual(state.customWords.map(\.aliases), [[], []])
    }

    func testDictionaryTransferImport_mergeDedupesAndMovesDuplicateTriggers() throws {
        let oldReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["vibe voice", "old trigger"],
            replacement: "Old"
        )
        let existingReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["vibe boys"],
            replacement: "VebeVoice"
        )
        let existingWord = ParakeetVocabularyStore.VocabularyConfig.Term(
            text: "Barath",
            weight: 13.0,
            aliases: ["barath w"]
        )
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["vibe voice", "vibe boys"], to: "VebeVoice"),
            ],
            customWords: ["barath", "GEMBA-E"]
        )

        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .merge,
            currentReplacements: [oldReplacement, existingReplacement],
            currentCustomWords: [existingWord]
        )

        let vebeVoiceEntry = try XCTUnwrap(state.replacements.first { $0.replacement == "VebeVoice" })
        let oldEntry = try XCTUnwrap(state.replacements.first { $0.replacement == "Old" })
        let barathTerm = try XCTUnwrap(state.customWords.first { $0.text == "Barath" })
        let gembaeTerm = try XCTUnwrap(state.customWords.first { $0.text == "GEMBA-E" })

        XCTAssertEqual(Set(vebeVoiceEntry.triggers), Set(["vibe voice", "vibe boys"]))
        XCTAssertEqual(oldEntry.triggers, ["old trigger"])
        XCTAssertEqual(barathTerm.weight, 13.0)
        XCTAssertEqual(barathTerm.aliases, ["barath w"])
        XCTAssertEqual(gembaeTerm.weight, 10.0)
    }

    func testDictionaryTransferImport_acceptsAppStyleReplacementKeysAndSingleFromValue() throws {
        let json = """
        {
          "replacements": [
            {
              "from": "vibe voice",
              "to": "VebeVoice"
            },
            {
              "triggers": ["gemba e"],
              "replacement": "GEMBA-E"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.map(\.triggers), [["vibe voice"], ["gemba e"]])
        XCTAssertEqual(state.replacements.map(\.replacement), ["VebeVoice", "GEMBA-E"])
    }

    func testDictionaryTransferImport_acceptsLocalAPIReplacementItemsResponse() throws {
        let json = """
        {
          "count": 1,
          "items": [
            {
              "triggers": ["vibe voice"],
              "replacement": "VebeVoice"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.first?.triggers, ["vibe voice"])
        XCTAssertEqual(state.replacements.first?.replacement, "VebeVoice")
        XCTAssertEqual(state.customWords.count, 0)
    }

    func testDictionaryTransferImportFeedsActualReplacementPath() throws {
        defer { ASRService.invalidateDictionaryCache() }
        let document = DictionaryTransferDocument(
            replacements: [
                DictionaryTransferReplacement(from: ["vibe voice"], to: "VebeVoice"),
            ],
            customWords: []
        )
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = state.replacements
            ASRService.invalidateDictionaryCache()

            XCTAssertEqual(
                ASRService.applyCustomDictionary("I use vibe voice daily."),
                "I use VebeVoice daily."
            )
        }
    }

    func testCustomDictionaryReplacementTreatsReplacementTextLiterally() {
        defer { ASRService.invalidateDictionaryCache() }
        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: ["dollar path"],
            replacement: #"$5 \path"#
        )

        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [entry]
            ASRService.invalidateDictionaryCache()

            XCTAssertEqual(
                ASRService.applyCustomDictionary("Use dollar path now."),
                #"Use $5 \path now."#
            )
        }
    }

    func testCustomDictionaryReplacementMatchesPunctuationTriggers() {
        defer { ASRService.invalidateDictionaryCache() }
        let entry = SettingsStore.CustomDictionaryEntry(
            triggers: [",,", ","],
            replacement: ","
        )

        self.withRestoredDefaults(keys: [self.customDictionaryEntriesKey]) {
            SettingsStore.shared.customDictionaryEntries = [entry]
            ASRService.invalidateDictionaryCache()

            XCTAssertEqual(
                ASRService.applyCustomDictionary("Hello,, world."),
                "Hello, world."
            )
            XCTAssertEqual(
                ASRService.applyCustomDictionary("Hello, world."),
                "Hello, world."
            )
        }
    }

    func testSlashCommandFormattingLeavesNonCommandSlashUsageAlone() {
        let text = "Use 1/2 and and/or. Open src slash services. Go to https slash slash example dot com. Slash and burn."

        XCTAssertEqual(
            ASRService.applySlashCommandFormatting(text),
            text
        )
    }

    func testLiteralFormattingCanBeDisabled() {
        self.withRestoredDefaults(keys: [self.literalDictationFormattingEnabledKey]) {
            UserDefaults.standard.removeObject(forKey: self.literalDictationFormattingEnabledKey)
            XCTAssertFalse(SettingsStore.shared.literalDictationFormattingEnabled)

            UserDefaults.standard.set(false, forKey: self.literalDictationFormattingEnabledKey)

            XCTAssertEqual(ASRService.applySlashCommandFormatting("slash compact"), "slash compact")
            XCTAssertEqual(ASRService.applyMentionFormatting("mention Paul"), "mention Paul")
            XCTAssertEqual(
                ASRService.makeDictationLiteralOutputPlan(
                    for: "/compact ",
                    appName: "Codex",
                    bundleID: "com.openai.codex"
                ).plainText,
                "/compact "
            )
        }
    }

    func testMentionFormattingLeavesProseAlone() {
        let text = "I am at the store. Meet me at lunch. I am at Paul. Look at Paul's message."

        XCTAssertEqual(
            ASRService.applyMentionFormatting(text, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
            text
        )
    }

    func testMentionOutputPlanDoesNotAutoConfirmAutocomplete() {
        let plan = ASRService.makeDictationLiteralOutputPlan(
            for: "@Paul can you check this",
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(plan.steps, [.text("@Paul can you check this")])
        XCTAssertEqual(plan.plainText, "@Paul can you check this")
    }

    func testMentionOutputPlanStaysPlainOutsideMentionApps() {
        let text = "@Paul can you check this"

        XCTAssertEqual(
            ASRService.makeDictationLiteralOutputPlan(
                for: text,
                appName: "Notes",
                bundleID: "com.apple.Notes"
            ).steps,
            [.text(text)]
        )
    }

    func testSpokenPunctuationFormattingRequiresDictionaryPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting(
                    "Hello literal comma world literal question mark literal open paren yes literal close paren literal quote done literal quote"
                ),
                "Hello, world? (yes) \"done\""
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Hello comma world question mark"),
                "Hello comma world question mark"
            )
        }
    }

    func testSpokenPunctuationFormattingConvertsCodeAndContactPunctuationWithPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting(
                    "email literal at the rate example literal dot com literal slash help literal underscore me"
                ),
                "email@example.com/help_me"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting(
                    "email literal at sign example literal dot com",
                    appName: "Codex",
                    bundleID: "com.openai.codex"
                ),
                "email@example.com"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("email at sign example"),
                "email at sign example"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("x literal hyphen ray costs 50 literal percent"),
                "x-ray costs 50%"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("a literal plus b literal equals c"),
                "a + b = c"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("plus equal percent"),
                "plus equal percent"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal plus literal equal 50 literal percent"),
                "+ = 50%"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("plus I need the normal word"),
                "plus I need the normal word"
            )
        }
    }

    func testSpokenPunctuationFormattingKeepsBareDotInProse() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("the polka dot dress"),
                "the polka dot dress"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("example literal dot com"),
                "example.com"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("version 1 literal dot 2"),
                "version 1.2"
            )
        }
    }

    func testSpokenPunctuationFormattingCleansGeneratedCommaNoiseWithPrefix() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal hyphen literal comma literal hyphen literal comma literal hyphen"),
                "---"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("50 literal comma literal percent"),
                "50%"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal open bracket literal comma literal close bracket"),
                "[]"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal open paren literal comma literal close paren"),
                "()"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal question mark literal comma literal exclamation mark"),
                "?!"
            )
        }
    }

    func testSpokenPunctuationFormattingPreservesExistingCommasNearSymbols() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Thanks, @Sam"),
                "Thanks, @Sam"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Use C++, now"),
                "Use C++, now"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("-,-,-"),
                "-,-,-"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("50, %"),
                "50, %"
            )
        }
    }

    func testSpokenPunctuationFormattingRespectsSetting() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            UserDefaults.standard.set(false, forKey: self.autoConvertPunctuationEnabledKey)

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("Hello literal comma world literal question mark"),
                "Hello literal comma world literal question mark"
            )
        }
    }

    func testSpokenPunctuationFormattingUsesCustomPrefixAndRules() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            settings.punctuationDictionaryPrefix = "type"
            settings.punctuationDictionaryRules = [
                SettingsStore.PunctuationDictionaryRule(
                    aliases: ["right arrow", "arrow"],
                    symbol: "->"
                ),
            ]

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("type right arrow"),
                "->"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal right arrow"),
                "literal right arrow"
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("type comma"),
                "type comma"
            )
        }
    }

    func testSpokenPunctuationFormattingUsesEditedRules() {
        self.withRestoredDefaults(keys: self.punctuationFormattingDefaultsKeys) {
            let settings = SettingsStore.shared
            UserDefaults.standard.set(true, forKey: self.autoConvertPunctuationEnabledKey)
            settings.punctuationDictionaryRules = [
                SettingsStore.PunctuationDictionaryRule(
                    aliases: ["full stop"],
                    symbol: "."
                ),
            ]

            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal full stop"),
                "."
            )
            XCTAssertEqual(
                ASRService.applySpokenPunctuationFormatting("literal period"),
                "literal period"
            )
        }
    }

    func testTerminalLiteralAutocompleteSpacingLeavesNonAutocompleteTextAlone() {
        XCTAssertEqual(
            ASRService.applyTerminalLiteralAutocompleteSpacing(
                "/model ",
                appName: "Notes",
                bundleID: "com.apple.Notes"
            ),
            "/model "
        )
        XCTAssertEqual(
            ASRService.applyTerminalLiteralAutocompleteSpacing(
                "Run /status please ",
                appName: "Codex",
                bundleID: "com.openai.codex"
            ),
            "Run /status please "
        )
        XCTAssertEqual(
            ASRService.applyTerminalLiteralAutocompleteSpacing(
                "@Paul can you check this ",
                appName: "Slack",
                bundleID: "com.tinyspeck.slackmacgap"
            ),
            "@Paul can you check this "
        )
    }

    func testSlashCommandOutputPlanDoesNotAutoConfirmAutocomplete() {
        XCTAssertEqual(
            ASRService.makeDictationLiteralOutputPlan(
                for: "/goal update the plan",
                appName: "Codex",
                bundleID: "com.openai.codex"
            ).steps,
            [.text("/goal update the plan")]
        )
        XCTAssertEqual(
            ASRService.makeDictationLiteralOutputPlan(
                for: "Run /status please",
                appName: "Codex",
                bundleID: "com.openai.codex"
            ).steps,
            [.text("Run /status please")]
        )
    }

    func testDictionaryTrainingNormalizesSamplesAndIgnoresIntendedText() {
        let triggers = CustomDictionaryTrainingMerge.normalizedTriggers(
            from: [" Vibe Voice. ", "VebeVoice", "vibe voice", " "],
            intendedReplacement: "VebeVoice"
        )

        XCTAssertEqual(triggers, ["vibe voice"])
    }

    func testDictionaryTrainingMergeDedupesAndMovesDuplicateTriggers() {
        let oldReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["Vibe Voice.", "old trigger"],
            replacement: "Old"
        )
        let existingReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["vibe boys"],
            replacement: "VebeVoice"
        )

        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [existingReplacement, oldReplacement],
            replacement: " vebevoice ",
            triggers: ["Vibe Voice.", "vibe boys", "VebeVoice", ""]
        )

        let vebeVoiceEntry = entries.first { $0.replacement == "VebeVoice" }
        let oldEntry = entries.first { $0.replacement == "Old" }

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.replacement), ["VebeVoice", "Old"])
        XCTAssertEqual(Set(vebeVoiceEntry?.triggers ?? []), Set(["vibe voice", "vibe boys"]))
        XCTAssertEqual(oldEntry?.triggers, ["old trigger"])
    }

    func testDictionaryTrainingNewReplacementPrependsEntry() {
        let existingReplacement = SettingsStore.CustomDictionaryEntry(
            triggers: ["existing trigger"],
            replacement: "Existing"
        )

        let entries = CustomDictionaryTrainingMerge.mergedEntries(
            current: [existingReplacement],
            replacement: "VebeVoice",
            triggers: ["vibe voice"]
        )

        XCTAssertEqual(entries.map(\.replacement), ["VebeVoice", "Existing"])
        XCTAssertEqual(entries.first?.triggers, ["vibe voice"])
    }

    func testManualDictionaryEntryParsesCommaSeparatedVariants() {
        XCTAssertEqual(
            CustomDictionaryManualEntry.normalizedDraftTriggers("vibe voice, vibe boys, vibe voice"),
            ["vibe voice", "vibe boys"]
        )
    }

    func testManualDictionaryEntryPreservesLiteralCommas() {
        XCTAssertEqual(CustomDictionaryManualEntry.normalizedDraftTriggers(","), [","])
        XCTAssertEqual(CustomDictionaryManualEntry.normalizedDraftTriggers(",,"), [",,"])
    }

    func testAutomaticDictionaryCorrectionDetectsEditedWordInsideDictation() {
        let before = "Notes: I met Barad yesterday."
        let after = "Notes: I met Barath yesterday."
        let insertedRange = (before as NSString).range(of: "I met Barad yesterday.")

        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        )

        XCTAssertEqual(candidate?.heardText, "Barad")
        XCTAssertEqual(candidate?.correctedText, "Barath")
    }

    func testAutomaticDictionaryCorrectionDetectsInsertionOnlySpellingFix() {
        let before = "Barat joined the call"
        let after = "Barath joined the call"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        )

        XCTAssertEqual(candidate?.heardText, "Barat")
        XCTAssertEqual(candidate?.correctedText, "Barath")
    }

    func testAutomaticDictionaryCorrectionDetectsInsertionAtDictationEnd() {
        let before = "Barat"
        let after = "Barath"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)
        let change = AutomaticDictionaryCorrectionDetector.textChange(before: before, after: after)

        XCTAssertNotNil(change)
        if let change {
            XCTAssertTrue(AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(
                change,
                after: after,
                insertedRange: insertedRange
            ))
        }
        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange,
            allowsInsertionAtEnd: true
        )
        XCTAssertEqual(candidate?.heardText, "Barat")
        XCTAssertEqual(candidate?.correctedText, "Barath")
    }

    func testAutomaticDictionaryCorrectionRejectsNewWordAtDictationEnd() {
        let before = "VebeVoice works"
        let after = "VebeVoice works well"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)
        let change = AutomaticDictionaryCorrectionDetector.textChange(before: before, after: after)

        XCTAssertNotNil(change)
        if let change {
            XCTAssertFalse(AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(
                change,
                after: after,
                insertedRange: insertedRange
            ))
        }
    }

    func testProgressiveDownloaderRetainsFileByMovingIt() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("VebeVoiceDownloadSource-\(UUID().uuidString)")
        try Data([1, 2, 3]).write(to: source)
        let retained = try ProgressiveFileDownloader.retainDownloadedFile(at: source)
        defer { try? FileManager.default.removeItem(at: retained) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: retained), Data([1, 2, 3]))
    }

    func testAutomaticDictionaryCorrectionIgnoresTypingAfterDictation() {
        let before = "VebeVoice works"
        let after = "VebeVoice works well"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionAllowsContinuedCorrectionAtRangeEnd() {
        let change = AutomaticDictionaryTextChange(
            oldRange: NSRange(location: 5, length: 0),
            newRange: NSRange(location: 5, length: 1)
        )
        let insertedRange = NSRange(location: 0, length: 5)

        XCTAssertFalse(AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(
            change,
            insertedRange: insertedRange
        ))
        XCTAssertTrue(AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(
            change,
            insertedRange: insertedRange,
            allowsInsertionAtEnd: true
        ))
    }

    func testAutomaticDictionaryCorrectionKeepsWaitingWhileCaretTouchesCorrectedWord() {
        let correctedRange = NSRange(location: 8, length: 6)

        XCTAssertTrue(AutomaticDictionaryCorrectionDetector.selectionTouchesCandidate(
            NSRange(location: 14, length: 0),
            candidateRange: correctedRange
        ))
        XCTAssertFalse(AutomaticDictionaryCorrectionDetector.selectionTouchesCandidate(
            NSRange(location: 15, length: 0),
            candidateRange: correctedRange
        ))
    }

    func testAutomaticDictionaryCorrectionTreatsSpaceAfterWordAsCompletion() {
        let change = AutomaticDictionaryTextChange(
            oldRange: NSRange(location: 6, length: 0),
            newRange: NSRange(location: 6, length: 1)
        )
        let correctedRange = NSRange(location: 0, length: 6)

        XCTAssertFalse(AutomaticDictionaryCorrectionDetector.changeContinuesCandidate(
            change,
            after: "Barath ",
            candidateRange: correctedRange
        ))
        XCTAssertTrue(AutomaticDictionaryCorrectionDetector.changeContinuesCandidate(
            change,
            after: "Baratha",
            candidateRange: correctedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresEditOutsideDictation() {
        let before = "Title: I met Barad"
        let after = "Heading: I met Barad"
        let insertedRange = (before as NSString).range(of: "I met Barad")

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresCaseOnlyEdit() {
        let before = "vebevoice"
        let after = "VebeVoice"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresPunctuationAndSpacingOnlyEdit() {
        let before = "Use Vibe-Voice today"
        let after = "Use Vibe Voice today"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionaryCorrectionIgnoresSingleCharacterCorrection() {
        let before = "Choose k today"
        let after = "Choose okay today"
        let insertedRange = NSRange(location: 0, length: (before as NSString).length)

        XCTAssertNil(AutomaticDictionaryCorrectionDetector.candidate(
            before: before,
            after: after,
            insertedRange: insertedRange
        ))
    }

    func testAutomaticDictionarySuggestionRequiresRepeatedCorrection() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.globalCooldown = 0
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 1000)

        XCTAssertFalse(policy.shouldShow(candidate, now: now))
        XCTAssertTrue(policy.shouldShow(candidate, now: now.addingTimeInterval(60)))
    }

    func testAutomaticDictionarySuggestionPersistsDismissalCooldown() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        configuration.dismissedPairCooldown = 100
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 2000)

        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        XCTAssertTrue(policy.shouldShow(candidate, now: now))
        policy.markShown(candidate, now: now)
        policy.record(.dismissed, for: candidate, now: now)

        let restoredPolicy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        XCTAssertFalse(restoredPolicy.shouldShow(candidate, now: now.addingTimeInterval(50)))
        XCTAssertTrue(restoredPolicy.shouldShow(candidate, now: now.addingTimeInterval(101)))
    }

    func testAutomaticDictionarySuggestionAppliesGlobalCooldown() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 600
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let first = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let second = AutomaticDictionaryCorrectionCandidate(heardText: "Floral Voice", correctedText: "VebeVoice")
        let now = Date(timeIntervalSince1970: 3000)

        XCTAssertTrue(policy.shouldShow(first, now: now))
        policy.markShown(first, now: now)
        XCTAssertFalse(policy.shouldShow(second, now: now.addingTimeInterval(60)))
        XCTAssertTrue(policy.shouldShow(second, now: now.addingTimeInterval(601)))
    }

    func testAutomaticDictionarySuggestionStopsAfterSessionIgnoreLimit() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        configuration.dismissedPairCooldown = 0
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let now = Date(timeIntervalSince1970: 4000)

        for index in 0..<configuration.maximumSessionIgnores {
            let candidate = AutomaticDictionaryCorrectionCandidate(
                heardText: "heard \(index)",
                correctedText: "corrected \(index)"
            )
            XCTAssertTrue(policy.shouldShow(candidate, now: now.addingTimeInterval(Double(index))))
            policy.markShown(candidate, now: now.addingTimeInterval(Double(index)))
            policy.record(.timedOut, for: candidate, now: now.addingTimeInterval(Double(index)))
        }

        let next = AutomaticDictionaryCorrectionCandidate(heardText: "another error", correctedText: "another word")
        XCTAssertFalse(policy.shouldShow(next, now: now.addingTimeInterval(10)))
    }

    func testAutomaticDictionarySuggestionNeverReturnsAfterAcceptance() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 5000)

        XCTAssertTrue(policy.shouldShow(candidate, now: now))
        policy.record(.accepted, for: candidate, now: now)
        XCTAssertFalse(policy.shouldShow(candidate, now: now.addingTimeInterval(10_000)))
    }

    func testAutomaticDictionarySuggestionStopsAfterPairDismissalLimit() throws {
        let defaults = try self.makeSuggestionPolicyDefaults()
        var configuration = DictionarySuggestionPolicyConfig()
        configuration.requiredOccurrences = 1
        configuration.globalCooldown = 0
        configuration.dismissedPairCooldown = 0
        configuration.maximumSessionIgnores = 10
        let policy = AutomaticDictionarySuggestionPolicy(defaults: defaults, configuration: configuration)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "Barad", correctedText: "Barath")
        let now = Date(timeIntervalSince1970: 6000)

        for index in 0..<configuration.maximumPairDismissals {
            let date = now.addingTimeInterval(Double(index))
            XCTAssertTrue(policy.shouldShow(candidate, now: date))
            policy.record(.dismissed, for: candidate, now: date)
        }
        XCTAssertFalse(policy.shouldShow(candidate, now: now.addingTimeInterval(10)))
    }

    private func makeSuggestionPolicyDefaults() throws -> UserDefaults {
        let suiteName = "AutomaticDictionarySuggestionPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDictionaryTransferImport_rejectsInvalidReplacementTriggerType() {
        let json = """
        {
          "replacements": [
            {
              "from": 42,
              "to": "VebeVoice"
            }
          ]
        }
        """

        XCTAssertThrowsError(try DictionaryTransferService.shared.decode(Data(json.utf8)))
    }

    func testDictionaryTransferImport_acceptsParakeetVocabularyTermsFile() throws {
        let json = """
        {
          "alpha": 2.8,
          "terms": [
            {
              "text": "VebeVoice",
              "aliases": ["vibe voice"],
              "weight": 13.0
            },
            {
              "text": "GEMBA-E"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.count, 0)
        XCTAssertEqual(state.customWords.map(\.text), ["VebeVoice", "GEMBA-E"])
        XCTAssertEqual(state.customWords.map(\.weight), [13.0, 10.0])
        XCTAssertEqual(state.customWords.map(\.aliases), [[], []])
    }

    func testDictionaryTransferImport_acceptsLocalAPICustomWordsResponse() throws {
        let json = """
        {
          "count": 2,
          "items": [
            {
              "text": "VebeVoice",
              "weight": 10.0,
              "aliases": ["vibe voice"]
            },
            {
              "text": "Barath"
            }
          ]
        }
        """

        let document = try DictionaryTransferService.shared.decode(Data(json.utf8))
        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.count, 0)
        XCTAssertEqual(state.customWords.map(\.text), ["VebeVoice", "Barath"])
        XCTAssertEqual(state.customWords.map(\.weight), [10.0, 10.0])
        XCTAssertEqual(state.customWords.map(\.aliases), [[], []])
    }

    func testDictationEndToEnd_whisperTiny_transcribesFixture() async throws {
        // Arrange
        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny)

        // Act
        try await provider.prepare()
        let samples = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        let result = try await provider.transcribe(samples)

        // Assert
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(raw.isEmpty, "Expected non-empty transcription text.")

        let normalized = Self.normalize(raw)
        XCTAssertTrue(normalized.contains("hello"), "Expected transcription to contain 'hello'. Got: \(raw)")
        XCTAssertTrue(normalized.contains("vibe"), "Expected transcription to contain 'vibe'. Got: \(raw)")
        XCTAssertTrue(
            normalized.contains("voice") || normalized.contains("vebevoice") || normalized.contains("boys"),
            "Expected transcription to contain 'voice' (or a close variant like 'boys'). Got: \(raw)"
        )
    }

    func testWhisperProvider_legacyBinCacheDoesNotCountAsDownloadedOrDeletedByReadinessCheck() throws {
        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let legacyURL = modelDirectory.appendingPathComponent("ggml-tiny.bin")
        try Data([0x01, 0x02, 0x03]).write(to: legacyURL)

        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny)

        XCTAssertFalse(provider.modelsExistOnDisk())
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testWhisperProvider_readinessCheckDoesNotCreateMissingDirectory() {
        let modelDirectory = Self.modelDirectoryForRun()
        let provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .whisperTiny)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertFalse(provider.modelsExistOnDisk())
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }

    // MARK: - Model download HTML/markup rejection

    func testLooksLikeHTML_rejectsMarkupVariants() {
        // A proxy/block page or stand-in markup document must be rejected regardless of
        // which markup token it opens with — not just <!doctype / <html.
        let rejected = [
            "<!DOCTYPE html><html lang=\"en\"><head></head></html>",
            "<html><body>Blocked by corporate proxy</body></html>",
            "<script>window.location='https://proxy'</script>",
            "<head><title>Access Denied</title></head>",
            "<body>Forbidden</body>",
            "<meta http-equiv=\"refresh\" content=\"0\">",
            "<!-- corporate gateway notice -->",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><error>blocked</error>",
            "</html>",
            "<!doctype HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\">",
        ]
        for markup in rejected {
            XCTAssertTrue(
                HuggingFaceModelDownloader.looksLikeHTML(Data(markup.utf8)),
                "Expected markup to be rejected: \(markup)"
            )
        }
    }

    func testLooksLikeHTML_rejectsLeadingWhitespaceAndBOMVariants() {
        let bom: [UInt8] = [0xef, 0xbb, 0xbf]

        // Leading ASCII whitespace before the markup token.
        XCTAssertTrue(HuggingFaceModelDownloader.looksLikeHTML(Data("   \n\t<!DOCTYPE html>".utf8)))
        XCTAssertTrue(HuggingFaceModelDownloader.looksLikeHTML(Data("\r\n  <html>".utf8)))

        // UTF-8 BOM, then markup.
        XCTAssertTrue(HuggingFaceModelDownloader.looksLikeHTML(Data(bom + Array("<html>".utf8))))

        // BOM, then whitespace, then an XML declaration.
        XCTAssertTrue(
            HuggingFaceModelDownloader.looksLikeHTML(Data(bom + Array("  \n<?xml version=\"1.0\"?>".utf8)))
        )
    }

    func testLooksLikeHTML_acceptsModelArtifacts() {
        // JSON object (vocab / metadata / Manifest) — note the embedded `<pad>` must NOT
        // trip the detector; only a LEADING `<` does.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("{\"0\": \"<pad>\", \"1\": \"a\"}".utf8)))
        // JSON array body.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("[1, 2, 3]".utf8)))
        // MIL program text (`model.mil`).
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("program(1.0)\n[buildInfo = ...]".utf8)))
        // Binary CoreML / Mach-O magic prefix.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00])))
        // Leading-NUL binary (e.g. coremldata.bin / weight.bin style payloads).
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data([0x00, 0x00, 0x01, 0x3c, 0x68])))
        // Empty payload.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data()))
        // A stray `<` NOT followed by a markup-ish byte must not be over-rejected.
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("< not markup".utf8)))
        XCTAssertFalse(HuggingFaceModelDownloader.looksLikeHTML(Data("<".utf8)))
    }

    func testValidateDownloadedFile_rejectsHTMLBodyAndAcceptsJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VebeVoice-ValidateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // HTML body written without an HTML Content-Type (response: nil) must still be
        // rejected by the byte-sniff path.
        let htmlURL = dir.appendingPathComponent("coremldata.bin")
        try Data("<!DOCTYPE html><html><body>Blocked</body></html>".utf8).write(to: htmlURL)
        XCTAssertThrowsError(
            try HuggingFaceModelDownloader.validateDownloadedFile(
                at: htmlURL,
                response: nil,
                relativePath: "coremldata.bin"
            )
        )

        // A real JSON vocab payload must pass validation.
        let jsonURL = dir.appendingPathComponent("parakeet_v3_vocab.json")
        try Data("{\"0\": \"<pad>\", \"1\": \"the\"}".utf8).write(to: jsonURL)
        XCTAssertNoThrow(
            try HuggingFaceModelDownloader.validateDownloadedFile(
                at: jsonURL,
                response: nil,
                relativePath: "parakeet_v3_vocab.json"
            )
        )
    }

    func testCachedFileIsMarkup_detectsCachedCorruptHTMLAndAcceptsModelData() throws {
        // Guards the cached-file path: a corrupt HTML payload already on disk (cached
        // before download-time validation existed) must be detected so it is re-downloaded,
        // while a real model artifact must not be flagged, and an unreadable path must be
        // treated as valid (never deleted on uncertainty).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VebeVoice-CachedMarkupTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A cached HTML/proxy page persisted as a model file must be detected as markup.
        let htmlURL = dir.appendingPathComponent("coremldata.bin")
        try Data("<!DOCTYPE html><html><body>Blocked by proxy</body></html>".utf8).write(to: htmlURL)
        XCTAssertTrue(HuggingFaceModelDownloader.cachedFileIsMarkup(at: htmlURL))

        // A real JSON vocab payload must not be flagged.
        let jsonURL = dir.appendingPathComponent("parakeet_v3_vocab.json")
        try Data("{\"0\": \"<pad>\", \"1\": \"the\"}".utf8).write(to: jsonURL)
        XCTAssertFalse(HuggingFaceModelDownloader.cachedFileIsMarkup(at: jsonURL))

        // An unreadable / missing path must be treated as valid (conservative on read error).
        let missingURL = dir.appendingPathComponent("does-not-exist.bin")
        XCTAssertFalse(HuggingFaceModelDownloader.cachedFileIsMarkup(at: missingURL))
    }

    func testCachedPayloadContainsMarkup_detectsCorruptFileInPresentArtifactTree() throws {
        // Guards the provider-PREFLIGHT path: a corrupt HTML payload nested inside a
        // present `.mlpackage` bundle (or a loose required file) must be detected so the preflight
        // re-downloads instead of trusting a file-existence/manifest check, while a valid cached
        // tree must not be flagged, and missing/empty required entries stay conservative.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VebeVoice-CachedPayloadTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A realistic `.mlpackage` layout: a JSON manifest plus a nested binary weight payload.
        let packageName = "encoder.mlpackage"
        let weightsDir = root.appendingPathComponent(packageName)
            .appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent(packageName).appendingPathComponent("Manifest.json")
        try Data("{\"fileFormatVersion\": \"1.0.0\"}".utf8).write(to: manifestURL)
        let weightURL = weightsDir.appendingPathComponent("weight.bin")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: weightURL)

        // A loose required file (e.g. a tokenizer) with real binary content.
        let tokenizerURL = root.appendingPathComponent("tokenizer.model")
        try Data([0x0a, 0x09, 0x05, 0x00]).write(to: tokenizerURL)

        let entries = [packageName, "tokenizer.model"]

        // An all-valid tree must not be flagged.
        XCTAssertFalse(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: root, relativePaths: entries)
        )

        // A proxy HTML page persisted as a binary INSIDE the package must be detected.
        try Data("<!DOCTYPE html><html><body>Blocked by proxy</body></html>".utf8).write(to: weightURL)
        XCTAssertTrue(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: root, relativePaths: entries)
        )

        // Restore the binary; corrupt the loose required file instead — must still be detected.
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: weightURL)
        try Data("<html><head></head></html>".utf8).write(to: tokenizerURL)
        XCTAssertTrue(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: root, relativePaths: entries)
        )

        // Missing entries and an empty required directory are conservative: never flagged corrupt
        // on uncertainty (incompleteness is the existence check's concern, not this one's).
        try Data([0x0a, 0x09, 0x05, 0x00]).write(to: tokenizerURL)
        let emptyPackage = root.appendingPathComponent("empty.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPackage, withIntermediateDirectories: true)
        XCTAssertFalse(
            HuggingFaceModelDownloader.cachedPayloadContainsMarkup(
                root: root,
                relativePaths: ["empty.mlpackage", "does-not-exist.json"]
            )
        )
    }

    private static func modelDirectoryForRun() -> URL {
        // Use a stable path on CI so GitHub Actions cache can speed up runs.
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" ||
            ProcessInfo.processInfo.environment["CI"] == "true"
        {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                preconditionFailure("Could not find caches directory")
            }
            return caches.appendingPathComponent("WhisperModels")
        }

        // Local runs: isolate per test execution.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VebeVoiceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return base.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let noPunct = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.punctuationCharacters.contains(scalar) { return " " }
            return Character(scalar)
        }
        return String(noPunct)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func withRestoredDefaults(keys: [String], run: () -> Void) {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }

        defer {
            for key in keys {
                if let previous = snapshot[key] {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        run()
    }
}
