namespace FreeFlow.Core;

/// <summary>
/// The last gate before the synthetic Ctrl+V (macOS PasteGate parity, 2026-11-08
/// audit): pastes fired 5-45 s after the capture with no re-verification could
/// consume a selection the user made during conversion, and the caret jumped to
/// its anchor. Pure decision only — the caller probes the foreground window and
/// the current selection and passes the results in.
/// </summary>
public static class PasteGate
{
    /// <summary>Whitespace-collapsed comparison form (mac normalizedSelection):
    /// UIA/AX sources disagree about newlines and runs of spaces.</summary>
    public static string Normalize(string text) =>
        string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    /// <summary>Returns null to paste, or a skip reason. On skip the transcript
    /// stays on the clipboard so the user can paste it manually.</summary>
    public static string? Evaluate(bool editSession, string? capturedSelection,
        string? currentSelection, string? sessionProcessName, string? foregroundProcessName)
    {
        if (editSession)
        {
            // The transform result is meant to replace the captured selection;
            // that selection must still sit exactly where it was captured. A
            // stale read must never guess.
            if (string.IsNullOrEmpty(capturedSelection))
                return EvaluateDictation(sessionProcessName, foregroundProcessName);
            if (string.IsNullOrWhiteSpace(currentSelection))
                return "selection no longer present or unreadable";
            if (Normalize(currentSelection) != Normalize(capturedSelection))
                return "selection changed since capture";
            return null;
        }
        return EvaluateDictation(sessionProcessName, foregroundProcessName);
    }

    private static string? EvaluateDictation(string? sessionProcessName, string? foregroundProcessName)
    {
        // Plain dictation replacing a live selection is standard paste
        // semantics; only a moved focus turns the paste into a surprise.
        if (!string.IsNullOrEmpty(sessionProcessName) &&
            !string.IsNullOrEmpty(foregroundProcessName) &&
            sessionProcessName != foregroundProcessName)
            return $"focus moved to {foregroundProcessName}";
        return null;
    }
}
