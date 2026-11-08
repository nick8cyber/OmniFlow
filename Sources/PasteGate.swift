import Foundation

/// The last gate before the synthetic Cmd+V. Everything destructive about a
/// dictation happens in that keystroke: the target app replaces whatever is
/// selected with the pasteboard content. The 2026-11-08 audit found pastes
/// firing 5-45 s after the selection was captured with no re-verification —
/// a selection the user made during conversion was silently consumed and the
/// caret jumped to its anchor. This gate re-checks the world immediately
/// before pasting.
///
/// Pure decision only: the caller probes AX and the frontmost app and passes
/// the results in, so the gate stays unit-testable without a live session.
enum PasteGate {

    enum Decision: Equatable {
        /// Target verified — post Cmd+V.
        case paste
        /// Do not post Cmd+V. The transcript is already on the pasteboard,
        /// so the user can paste it manually.
        case skip(reason: String)
    }

    /// Whitespace-collapsed comparison form: AX sources disagree about
    /// newlines and runs of spaces, and the capture path already normalizes
    /// some of that away (AppContextService.accessibilityString).
    static func normalizedSelection(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    static func evaluate(isCommandSession: Bool,
                         capturedSelection: String?,
                         currentSelection: String?,
                         sessionBundleID: String?,
                         frontmostBundleID: String?) -> Decision {
        if isCommandSession {
            // The transform result is meant to replace the captured selection,
            // so that selection must still sit exactly where it was captured.
            // A stale read must never guess: cancelling keeps the text on the
            // pasteboard and costs the user a manual Cmd+V at worst.
            guard let capturedSelection, !capturedSelection.isEmpty else {
                // Nothing was actually captured — behave like plain dictation.
                return evaluateDictation(sessionBundleID: sessionBundleID,
                                         frontmostBundleID: frontmostBundleID)
            }
            guard let currentSelection, !currentSelection.isEmpty else {
                return .skip(reason: "selection no longer present or unreadable")
            }
            if normalizedSelection(currentSelection) != normalizedSelection(capturedSelection) {
                return .skip(reason: "selection changed since capture")
            }
            return .paste
        }
        return evaluateDictation(sessionBundleID: sessionBundleID,
                                 frontmostBundleID: frontmostBundleID)
    }

    private static func evaluateDictation(sessionBundleID: String?,
                                          frontmostBundleID: String?) -> Decision {
        // Plain dictation replacing a live selection is standard paste
        // semantics; only a moved focus turns the paste into a surprise.
        if let sessionBundleID, !sessionBundleID.isEmpty,
           let frontmostBundleID, !frontmostBundleID.isEmpty,
           sessionBundleID != frontmostBundleID {
            return .skip(reason: "focus moved to \(frontmostBundleID)")
        }
        return .paste
    }
}
