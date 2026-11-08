using FreeFlow.Core;
using Xunit;

namespace FreeFlow.Tests;

// macOS PasteGateTests parity: the paste gate decides immediately before the
// synthetic Ctrl+V whether the target still matches what was captured.
public class PasteGateTests
{
    [Fact]
    public void NormalizeCollapsesWhitespace()
    {
        Assert.Equal("hello world two", PasteGate.Normalize("  hello   world\n\ntwo  "));
        Assert.Equal("Same", PasteGate.Normalize("Same"));
    }

    [Fact]
    public void DictationPastesWhenFocusUnchanged()
    {
        Assert.Null(PasteGate.Evaluate(editSession: false, capturedSelection: null,
            currentSelection: "some selection",
            sessionProcessName: "chrome", foregroundProcessName: "chrome"));
    }

    [Fact]
    public void DictationSkipsWhenFocusMoved()
    {
        var reason = PasteGate.Evaluate(editSession: false, capturedSelection: null,
            currentSelection: null, sessionProcessName: "chrome",
            foregroundProcessName: "WindowsTerminal");
        Assert.Equal("focus moved to WindowsTerminal", reason);
    }

    [Fact]
    public void DictationPastesWhenProcessNamesUnknown()
    {
        Assert.Null(PasteGate.Evaluate(editSession: false, capturedSelection: null,
            currentSelection: null, sessionProcessName: null, foregroundProcessName: "other"));
        Assert.Null(PasteGate.Evaluate(editSession: false, capturedSelection: null,
            currentSelection: null, sessionProcessName: "chrome", foregroundProcessName: null));
    }

    [Fact]
    public void EditSessionPastesWhenSelectionUnchanged()
    {
        Assert.Null(PasteGate.Evaluate(editSession: true,
            capturedSelection: "Fix  the\ntypo", currentSelection: "Fix the typo",
            sessionProcessName: "winword", foregroundProcessName: "winword"));
    }

    [Fact]
    public void EditSessionSkipsWhenSelectionChanged()
    {
        var reason = PasteGate.Evaluate(editSession: true,
            capturedSelection: "old selection",
            currentSelection: "user selected something else meanwhile",
            sessionProcessName: "winword", foregroundProcessName: "winword");
        Assert.Equal("selection changed since capture", reason);
    }

    [Fact]
    public void EditSessionSkipsWhenSelectionGone()
    {
        var reason = PasteGate.Evaluate(editSession: true,
            capturedSelection: "old selection", currentSelection: null,
            sessionProcessName: "winword", foregroundProcessName: "winword");
        Assert.Equal("selection no longer present or unreadable", reason);
    }

    [Fact]
    public void EditSessionWithoutCaptureFallsBackToDictationRules()
    {
        Assert.Null(PasteGate.Evaluate(editSession: true, capturedSelection: null,
            currentSelection: null, sessionProcessName: "winword",
            foregroundProcessName: "winword"));
    }
}
