import Foundation

enum PasteGateTests {
    static func run() {
        testNormalizationCollapsesWhitespace()
        testDictationPastesWhenFocusUnchanged()
        testDictationSkipsWhenFocusMoved()
        testDictationPastesWhenBundleIDsUnknown()
        testCommandSessionPastesWhenSelectionUnchanged()
        testCommandSessionSkipsWhenSelectionChanged()
        testCommandSessionSkipsWhenSelectionGone()
        testCommandSessionWithoutCaptureFallsBackToDictationRules()
        testSkipReasonsAreStable()
    }

    // MARK: - 1

    private static func testNormalizationCollapsesWhitespace() {
        expectEqual(PasteGate.normalizedSelection("  hello   world\n\ntwo  "),
                    "hello world two",
                    "whitespace runs and newlines collapse to single spaces")
        expectEqual(PasteGate.normalizedSelection("Same"), "Same", "plain text unchanged")
    }

    // MARK: - 2

    private static func testDictationPastesWhenFocusUnchanged() {
        expectEqual(PasteGate.evaluate(isCommandSession: false,
                                       capturedSelection: nil,
                                       currentSelection: "some selection",
                                       sessionBundleID: "com.example.editor",
                                       frontmostBundleID: "com.example.editor"),
                    .paste,
                    "dictation with matching frontmost app pastes")
    }

    private static func testDictationSkipsWhenFocusMoved() {
        expectEqual(PasteGate.evaluate(isCommandSession: false,
                                       capturedSelection: nil,
                                       currentSelection: nil,
                                       sessionBundleID: "com.example.editor",
                                       frontmostBundleID: "com.apple.Terminal"),
                    .skip(reason: "focus moved to com.apple.Terminal"),
                    "dictation into another app is cancelled")
    }

    private static func testDictationPastesWhenBundleIDsUnknown() {
        expectEqual(PasteGate.evaluate(isCommandSession: false,
                                       capturedSelection: nil,
                                       currentSelection: nil,
                                       sessionBundleID: nil,
                                       frontmostBundleID: "com.example.other"),
                    .paste,
                    "unknown session bundle id cannot be verified — paste")
        expectEqual(PasteGate.evaluate(isCommandSession: false,
                                       capturedSelection: nil,
                                       currentSelection: nil,
                                       sessionBundleID: "com.example.editor",
                                       frontmostBundleID: nil),
                    .paste,
                    "unknown frontmost bundle id cannot be verified — paste")
    }

    // MARK: - 3

    private static func testCommandSessionPastesWhenSelectionUnchanged() {
        expectEqual(PasteGate.evaluate(isCommandSession: true,
                                       capturedSelection: "Fix  the\ntypo",
                                       currentSelection: "Fix the typo",
                                       sessionBundleID: "com.example.editor",
                                       frontmostBundleID: "com.example.editor"),
                    .paste,
                    "normalized equality (whitespace differences) still pastes")
    }

    private static func testCommandSessionSkipsWhenSelectionChanged() {
        expectEqual(PasteGate.evaluate(isCommandSession: true,
                                       capturedSelection: "old selection",
                                       currentSelection: "user selected something else meanwhile",
                                       sessionBundleID: "com.example.editor",
                                       frontmostBundleID: "com.example.editor"),
                    .skip(reason: "selection changed since capture"),
                    "a selection the user made during conversion must not be consumed")
    }

    private static func testCommandSessionSkipsWhenSelectionGone() {
        expectEqual(PasteGate.evaluate(isCommandSession: true,
                                       capturedSelection: "old selection",
                                       currentSelection: nil,
                                       sessionBundleID: "com.example.editor",
                                       frontmostBundleID: "com.example.editor"),
                    .skip(reason: "selection no longer present or unreadable"),
                    "unreadable or gone selection is never replaced blind")
    }

    private static func testCommandSessionWithoutCaptureFallsBackToDictationRules() {
        expectEqual(PasteGate.evaluate(isCommandSession: true,
                                       capturedSelection: nil,
                                       currentSelection: nil,
                                       sessionBundleID: "com.example.editor",
                                       frontmostBundleID: "com.example.editor"),
                    .paste,
                    "command session without a captured selection behaves like dictation")
    }

    private static func testSkipReasonsAreStable() {
        // Reasons surface in the UI and logs; changing them is a user-visible
        // contract change.
        expectEqual(PasteGate.evaluate(isCommandSession: true,
                                       capturedSelection: "a",
                                       currentSelection: "b",
                                       sessionBundleID: nil,
                                       frontmostBundleID: nil).reasonIfSkip(),
                    "selection changed since capture",
                    "mismatch reason text")
        expectEqual(PasteGate.evaluate(isCommandSession: false,
                                       capturedSelection: nil,
                                       currentSelection: nil,
                                       sessionBundleID: "a",
                                       frontmostBundleID: "b").reasonIfSkip(),
                    "focus moved to b",
                    "focus reason text")
    }
}

private extension PasteGate.Decision {
    func reasonIfSkip() -> String? {
        if case .skip(let reason) = self { return reason }
        return nil
    }
}
