import SwiftUI
import AppKit

// Menu bar dropdown: quick actions only. Everything configurable lives in
// Settings (shortcuts, vocabulary, setup wizard) — the menu stays short.

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updateManager = UpdateManager.shared

    private func transcriptText(for item: PipelineHistoryItem) -> String {
        let postProcessed = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !postProcessed.isEmpty {
            return postProcessed
        }
        return item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcriptFull(for item: PipelineHistoryItem) -> String {
        item.postProcessedTranscript.isEmpty ? item.rawTranscript : item.postProcessedTranscript
    }

    private func transcriptSnippet(for item: PipelineHistoryItem) -> String {
        var snippet = transcriptText(for: item).replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.isEmpty {
            snippet = "(no transcript)"
        }
        if snippet.count > 48 {
            snippet = String(snippet.prefix(48)) + "..."
        }
        return snippet
    }

    private var recentHistoryItems: [PipelineHistoryItem] {
        Array(appState.pipelineHistory.filter { !transcriptText(for: $0).isEmpty }.prefix(10))
    }

    var body: some View {
        VStack(spacing: 4) {
            if !appState.hasScreenRecordingPermission {
                screenRecordingBanner
                Divider()
            }
            if !appState.hasAccessibility {
                accessibilityBanner
                Divider()
            }
            statusRow
            Divider()
            Button(appState.isRecording ? "Stop Recording" : "Start Dictating") {
                appState.toggleRecording()
            }
            .disabled(appState.isTranscribing)

            if let hotkeyError = appState.hotkeyMonitoringErrorMessage {
                Text(hotkeyError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }
            if let errorMessage = appState.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            if !appState.lastFailedAudioFileName.isEmpty && !appState.isRecording && !appState.isTranscribing {
                Button("Paste Last Recording") {
                    appState.retryLastRecording()
                }
            }
            if !appState.lastTranscript.isEmpty && !appState.isRecording && !appState.isTranscribing {
                pasteAgainSection
            }
            historyMenu
            microphoneMenu
            Divider()
            Button("Settings…") {
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }
            .keyboardShortcut(",")
            checkForUpdatesButton

            if updateManager.updateAvailable {
                Divider()
                updateBanner
            }

            Divider()
            Button("Quit \(AppName.displayName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }

    private var screenRecordingBanner: some View {
        Button(action: { appState.requestScreenCapturePermission() }) {
            Label("Screen Recording Permission Needed", systemImage: "camera.viewfinder")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange)
        }
        .buttonStyle(.plain)
    }

    private var accessibilityBanner: some View {
        Button(action: { appState.showAccessibilityAlert() }) {
            Label("Accessibility Required", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.red)
        }
        .buttonStyle(.plain)
    }

    private var statusRow: some View {
        Group {
            if appState.isRecording {
                Label("Recording...", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else if appState.isTranscribing {
                Label(appState.debugStatusMessage, systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                Text(appState.shortcutStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pasteAgainSection: some View {
        VStack(spacing: 2) {
            Button {
                appState.copyLastTranscriptToPasteboard()
            } label: {
                if appState.copyAgainShortcut.isDisabled {
                    Text("Paste Again")
                } else {
                    Text("Paste Again  (\(appState.copyAgainShortcut.displayName))")
                }
            }
            let truncated = appState.lastTranscript.count > 35
                ? String(appState.lastTranscript.prefix(35)) + "…"
                : appState.lastTranscript
            Text("\u{201C}\(truncated)\u{201D}")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .lineLimit(4)
                .frame(maxWidth: 280, alignment: .leading)
        }
    }

    private var historyMenu: some View {
        Menu("History") {
            if recentHistoryItems.isEmpty {
                Text("No transcripts yet")
            } else {
                ForEach(recentHistoryItems) { item in
                    Button(transcriptSnippet(for: item)) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(transcriptFull(for: item), forType: .string)
                    }
                    .disabled(transcriptText(for: item).isEmpty)
                }
                Divider()
            }
            Button("Open History") {
                appState.selectedSettingsTab = .runLog
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }
        }
    }

    private var microphoneMenu: some View {
        Menu("Microphone") {
            Button {
                appState.selectedMicrophoneID = "default"
            } label: {
                if appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty {
                    Text("✓ System Default")
                } else {
                    Text("  System Default")
                }
            }
            ForEach(appState.availableMicrophones) { device in
                Button {
                    appState.selectedMicrophoneID = device.uid
                } label: {
                    if appState.selectedMicrophoneID == device.uid {
                        Text("✓ \(device.name)")
                    } else {
                        Text("  \(device.name)")
                    }
                }
            }
        }
    }

    private var checkForUpdatesButton: some View {
        Button {
            Task {
                await updateManager.checkForUpdates(userInitiated: true)
            }
        } label: {
            HStack(spacing: 6) {
                if updateManager.isChecking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for Updates...")
                } else {
                    Text("Check for Updates")
                }
            }
        }
        .disabled(updateManager.isChecking)
    }

    @ViewBuilder
    private var updateBanner: some View {
        switch updateManager.updateStatus {
        case .downloading:
            VStack(spacing: 4) {
                Text("Downloading update... \(Int((updateManager.downloadProgress ?? 0) * 100))%")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                ProgressView(value: updateManager.downloadProgress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.blue)
        case .installing, .readyToRelaunch:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing update...")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.blue)
        default:
            Button {
                updateManager.showUpdateAlert()
            } label: {
                Label("Update available", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
            }
            .buttonStyle(.plain)
        }
    }
}
