<p align="center">
  <strong>OmniFlow for Windows</strong>
</p>

<p align="center">
  Native C# / .NET 8 tray application — the Windows counterpart of the macOS OmniFlow dictation app.
</p>

---

## Overview

OmniFlow for Windows is a self-contained dictation app: hold a hotkey, speak, and the
transcript is pasted at the cursor. It runs entirely from the system tray.

**Dictation runs on Google Gemini Live** (`gemini-3.5-transcribe-live` over the native
BidiGenerateContent WebSocket). Groq (`whisper-large-v3`) is the optional transcription
fallback; the non-live Gemini `gemini-3.5-transcribe` is the built-in record-then-transcribe
fallback. Google transcripts paste as-is, with the paste target re-verified before every
insertion (ADR-0009).

## Build

Requires the .NET 8 SDK.

```cmd
cd windows
build.cmd          :: build + tests + publish single-file exe to windows\dist\OmniFlow.exe
```

Or manually:

```cmd
dotnet build windows\OmniFlow.sln
dotnet test  windows\tests\OmniFlow.Tests\OmniFlow.Tests.csproj
```

## Layout

- `windows/src/OmniFlow/` — the application (WinForms tray app, Gemini Live + batch, Groq fallback)
- `windows/tests/OmniFlow.Tests/` — xunit suite (also runs in CI: `.github/workflows/windows.yml`)
- `windows/README.md` — the authoritative spec for the Windows app

## License

Licensed under the MIT license — see [LICENSE](LICENSE).
