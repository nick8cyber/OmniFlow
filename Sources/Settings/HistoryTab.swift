import SwiftUI
import AVFoundation

// History tab (formerly "Run Log"): local pipeline history with per-run
// audio playback, transcripts, and pipeline step inspection.

struct RunLogView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History")
                        .font(.headline)
                    Text("Stored locally. Only the \(appState.maxPipelineHistoryCount) most recent runs are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear History") {
                    showsClearConfirmation = true
                }
                .disabled(appState.pipelineHistory.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            if appState.pipelineHistory.isEmpty {
                Spacer()
                EmptyStateView(icon: "clock.arrow.circlepath",
                               title: "No runs yet",
                               hint: "Use dictation to populate history.")
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(appState.pipelineHistory) { item in
                            RunLogEntryView(item: item)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .confirmationDialog("Delete all \(appState.pipelineHistory.count) runs and their audio?",
                            isPresented: $showsClearConfirmation,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                appState.clearPipelineHistory()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct RunLogEntryView: View {
    @EnvironmentObject private var appState: AppState
    let item: PipelineHistoryItem

    @State private var isExpanded = false

    private var isError: Bool {
        item.postProcessingStatus.hasPrefix("Error:")
    }

    private var transcriptPreview: String {
        let text = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = text.isEmpty
            ? item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            : text
        return preview.isEmpty ? "(no transcript)" : preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.timestamp.formatted(date: .numeric, time: .standard))
                        .font(.subheadline.weight(.semibold))
                    Text(transcriptPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                entryButtons
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
            if isExpanded {
                Divider()
                expandedSection
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isError ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1))
        .cornerRadius(10)
    }

    private var entryButtons: some View {
        HStack(spacing: 6) {
            Group {
                if isError && item.audioFileName != nil {
                    if appState.retryingItemIDs.contains(item.id) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 28, height: 28)
                    } else {
                        Button {
                            appState.retryTranscription(item: item)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Retry transcription")
                        .frame(width: 28, height: 28)
                    }
                } else {
                    Color.clear.frame(width: 28, height: 28)
                }
            }
            Button {
                TestCaseExporter.exportWithSavePanel(item: item,
                                                     audioDirURL: AppState.audioStorageDirectory())
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help("Export test case")
            .frame(width: 28, height: 28)
            CopyButton(text: item.postProcessedTranscript.isEmpty
                ? item.rawTranscript : item.postProcessedTranscript,
                showsLabel: false)
                .buttonStyle(.plain)
                .help("Copy transcript")
                .disabled(item.postProcessedTranscript.isEmpty && item.rawTranscript.isEmpty)
                .frame(width: 28, height: 28)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.deleteHistoryEntry(id: item.id)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Delete entry")
            .frame(width: 28, height: 28)
        }
    }

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let audioFileName = item.audioFileName {
                AudioPlayerView(audioURL: AppState.audioStorageDirectory()
                    .appendingPathComponent(audioFileName))
            } else {
                Label("No audio recorded", systemImage: "waveform.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !item.customVocabulary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Vocabulary")
                        .font(.caption.weight(.semibold))
                    FlowLayout(spacing: 4) {
                        ForEach(vocabularyTerms, id: \.self) { term in
                            Text(term)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(4)
                        }
                    }
                }
            }
            PipelineStepView(stepNumber: 1, title: "Capture Context") {
                if let dataURL = item.contextScreenshotDataURL,
                   let base64 = dataURL.split(separator: ",").last,
                   let data = Data(base64Encoded: String(base64)),
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 120)
                }
                PromptDisclosure(prompt: item.contextPrompt)
                Text(item.contextSummary.isEmpty ? "No context captured" : item.contextSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PipelineStepView(stepNumber: 2, title: "Transcribe Audio") {
                Text("Sent audio to the configured transcription model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MonospacedCopyBlock(text: item.rawTranscript.isEmpty ? "(empty transcript)" : item.rawTranscript,
                                    emptyText: item.rawTranscript.isEmpty,
                                    copyTooltip: "Copy literal transcript",
                                    copiedTooltip: "Copied literal transcript")
            }
            PipelineStepView(stepNumber: 3, title: "Post-Process") {
                Text(item.postProcessingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PromptDisclosure(prompt: item.postProcessingPrompt)
                MonospacedCopyBlock(text: item.postProcessedTranscript.isEmpty
                    ? "(empty transcript)" : item.postProcessedTranscript,
                    emptyText: item.postProcessedTranscript.isEmpty,
                    copyTooltip: "Copy cleaned transcript",
                    copiedTooltip: "Copied cleaned transcript")
            }
        }
    }

    private var vocabularyTerms: [String] {
        item.customVocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct PromptDisclosure: View {
    let prompt: String?
    @State private var isShown = false

    var body: some View {
        Group {
            if let prompt, !prompt.isEmpty {
                Button {
                    isShown.toggle()
                } label: {
                    Label(isShown ? "Hide Prompt" : "Show Prompt",
                          systemImage: isShown ? "chevron.down" : "chevron.right")
                }
                .font(.caption)
                if isShown {
                    ScrollView {
                        Text(prompt)
                            .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                }
            }
        }
    }
}

private struct MonospacedCopyBlock: View {
    let text: String
    let emptyText: Bool
    let copyTooltip: String
    let copiedTooltip: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                Text(text)
                    .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            CopyButton(text: text, showsLabel: false)
                .buttonStyle(.plain)
                .help(copyTooltip)
                .padding(4)
        }
    }
}

struct PipelineStepView<Content: View>: View {
    let stepNumber: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text("\(stepNumber)")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                    )
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
    }
}

// MARK: - Audio player

final class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinished()
    }
}

struct AudioPlayerView: View {
    let audioURL: URL

    @State private var player: AVAudioPlayer?
    @State private var delegateHolder: DelegateHolder?
    @State private var isPlaying = false
    @State private var elapsed: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isUnreadable = false
    @State private var progressTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    struct DelegateHolder {
        let delegate: AudioPlayerDelegate
    }

    var body: some View {
        Group {
            if isUnreadable {
                Label("Audio file is missing or unreadable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                playerControls
            }
        }
        .onAppear {
            // Deleted or truncated history files should surface as an error,
            // not as a silent dead play button.
            isUnreadable = !FileManager.default.fileExists(atPath: audioURL.path)
        }
    }

    private var playerControls: some View {
        HStack(spacing: 10) {
            Button {
                isPlaying ? stop() : play()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * progressFraction)
                }
            }
            .frame(height: 4)
            Text("\(timeString(elapsed)) / \(timeString(duration))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .onReceive(progressTimer) { _ in
            guard isPlaying, let player else { return }
            elapsed = player.currentTime
        }
        .onDisappear {
            stop()
        }
    }

    private var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1)
    }

    private func timeString(_ value: TimeInterval) -> String {
        let total = Int(value)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func play() {
        stop()
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            let holder = DelegateHolder(delegate: AudioPlayerDelegate { [weak audioPlayer] in
                Task { @MainActor in
                    isPlaying = false
                    elapsed = audioPlayer?.duration ?? 0
                }
            })
            audioPlayer.delegate = holder.delegate
            audioPlayer.play()
            player = audioPlayer
            delegateHolder = holder
            duration = audioPlayer.duration
            elapsed = 0
            isPlaying = true
        } catch {
            isUnreadable = true
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
