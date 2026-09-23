import SwiftUI
import AppKit

struct PipelineDebugPanelView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pipeline Debug")
                        .font(.title3)
                    Text("Live data for the transcription + post-processing pipeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export Test Case…") {
                    if let latest = appState.pipelineHistory.first {
                        TestCaseExporter.exportWithSavePanel(item: latest,
                                                             audioDirURL: AppState.audioStorageDirectory())
                    }
                }
                .disabled(appState.pipelineHistory.first == nil)
            }
            PipelineDebugContentView(statusMessage: appState.debugStatusMessage,
                                     postProcessingStatus: appState.lastPostProcessingStatus,
                                     postProcessingPrompt: appState.lastPostProcessingPrompt,
                                     contextSummary: appState.lastContextSummary,
                                     contextScreenshotStatus: appState.lastContextScreenshotStatus,
                                     contextScreenshotDataURL: appState.lastContextScreenshotDataURL,
                                     rawTranscript: appState.lastRawTranscript,
                                     postProcessedTranscript: appState.lastPostProcessedTranscript)
        }
        .padding(16)
        .frame(width: 620, height: 640)
    }
}

struct PipelineDebugContentView: View {
    let statusMessage: String
    let postProcessingStatus: String
    let postProcessingPrompt: String
    let contextSummary: String
    let contextScreenshotStatus: String
    let contextScreenshotDataURL: String?
    let rawTranscript: String
    let postProcessedTranscript: String

    var body: some View {
        if contextSummary.isEmpty && rawTranscript.isEmpty {
            Text("Run a dictation pass to populate debug output.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !statusMessage.isEmpty {
                        textSection(title: "Status", text: statusMessage, copyable: false)
                    }
                    if !contextSummary.isEmpty {
                        textSection(title: "Context Summary", text: contextSummary, copyable: false)
                    }
                    if !postProcessingStatus.isEmpty {
                        textSection(title: "Post-Processing", text: postProcessingStatus, copyable: false)
                    }
                    if !postProcessingPrompt.isEmpty {
                        textSection(title: "Post-Processing Prompt", text: postProcessingPrompt, copyable: true)
                    }
                    if !rawTranscript.isEmpty {
                        textSection(title: "Raw Transcript", text: rawTranscript, copyable: true)
                    }
                    if !postProcessedTranscript.isEmpty {
                        textSection(title: "Post-Processed Transcript", text: postProcessedTranscript, copyable: true)
                    }
                    screenshotSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func textSection(title: String, text: String, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if copyable {
                    Button("Copy \(title)") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                    }
                    .font(.caption)
                }
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 15, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            .cornerRadius(6)
        }
    }

    @ViewBuilder
    private var screenshotSection: some View {
        if !contextScreenshotStatus.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Context Screenshot")
                    .font(.caption.weight(.semibold))
                let lowered = contextScreenshotStatus.lowercased()
                Text("Status: \(contextScreenshotStatus)")
                    .font(.caption)
                    .foregroundColor(lowered.contains("could not") || lowered.contains("no screenshot")
                        || lowered.contains("not available") ? .red : .secondary)
                if let dataURL = contextScreenshotDataURL, let image = Self.decodedImage(fromDataURL: dataURL) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 320)
                    }
                    .frame(maxHeight: 320)
                    let byteCount = (dataURL.split(separator: ",").last.map { $0.count } ?? 0) * 3 / 4
                    Text("Screenshot payload: \(byteCount / 1024) KB (Base64)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Open in Preview") {
                            Self.openInPreview(image: image)
                        }
                        Button("Copy Screenshot") {
                            NSPasteboard.general.writeObjects([image])
                        }
                    }
                } else {
                    Text("No screenshot image available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func decodedImage(fromDataURL dataURL: String) -> NSImage? {
        guard let base64 = dataURL.split(separator: ",").last,
              let data = Data(base64Encoded: String(base64)) else { return nil }
        return NSImage(data: data)
    }

    private static func openInPreview(image: NSImage) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-to-text-context-screenshot.png")
        if let tiff = image.tiffRepresentation,
           let representation = NSBitmapImageRep(data: tiff),
           let png = representation.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            NSWorkspace.shared.open(url)
        }
    }
}
