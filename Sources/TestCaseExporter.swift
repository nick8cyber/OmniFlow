import AppKit
import Foundation
import UniformTypeIdentifiers

struct TestCaseExporter {
    enum ExportError: Error, LocalizedError {
        case tempDirectoryCreationFailed(underlying: Error?)
        case zipFailed(Int32)
        case missingAudioFile(String)

        var errorDescription: String? {
            switch self {
            case .tempDirectoryCreationFailed(let underlying):
                if let underlying {
                    return "Could not create temporary export directory: \(underlying.localizedDescription)"
                }
                return "Could not create temporary export directory"
            case .zipFailed(let code):
                return "zip exited with code \(code)"
            case .missingAudioFile(let name):
                return "Missing audio file for export: \(name)"
            }
        }
    }

    @MainActor
    static func exportWithSavePanel(item: PipelineHistoryItem, audioDirURL: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.zip]
        panel.nameFieldStringValue = "omniflow-case-\(isoTimestamp(from: item.timestamp)).zip"
        panel.title = "Export Test Case"
        panel.message = "Choose where to save the test case ZIP."
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try writeZip(item: item, audioDirURL: audioDirURL, destination: destination)
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Export Failed"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
        }
    }

    // MARK: - ZIP assembly

    private static func writeZip(item: PipelineHistoryItem,
                                 audioDirURL: URL,
                                 destination: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniflow-case-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        } catch {
            throw ExportError.tempDirectoryCreationFailed(underlying: error)
        }
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        var pipeline: [String: Any] = [
            "raw_transcript": item.rawTranscript,
            "post_processed_transcript": item.postProcessedTranscript,
            "context_summary": item.contextSummary,
            "context_prompt": item.contextPrompt ?? "",
            "post_processing_prompt": item.postProcessingPrompt ?? "",
            "post_processing_status": item.postProcessingStatus,
            "screenshot_status": item.contextScreenshotStatus
        ]
        let metadata: [String: Any] = [
            "app_name": item.contextAppName ?? "",
            "bundle_identifier": item.contextBundleIdentifier ?? "",
            "window_title": item.contextWindowTitle ?? "",
            "selected_text": item.capturedSelection ?? item.selectedText ?? ""
        ]
        let settings: [String: Any] = [
            "custom_vocabulary": item.customVocabulary,
            "system_prompt": item.systemPrompt ?? "",
            "context_system_prompt": item.contextSystemPrompt ?? ""
        ]

        if let dataURL = item.contextScreenshotDataURL {
            // The screenshot is an optional artifact: a broken data URL must
            // not cancel the whole export. Skip the file and record why.
            if let data = decodeDataURL(dataURL) {
                let fileExtension = dataURL.hasPrefix("data:image/png") ? "png" : "jpg"
                let screenshotName = "screenshot.\(fileExtension)"
                try data.write(to: tempDir.appendingPathComponent(screenshotName))
                pipeline["screenshot_path"] = "./\(screenshotName)"
            } else {
                var notes = pipeline["pipeline_notes"] as? [String] ?? []
                notes.append("screenshot_decode_failed")
                pipeline["pipeline_notes"] = notes
            }
        }

        if let audioFileName = item.audioFileName {
            let sourceURL = audioDirURL.appendingPathComponent(audioFileName)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw ExportError.missingAudioFile(audioFileName)
            }
            try FileManager.default.copyItem(at: sourceURL,
                                             to: tempDir.appendingPathComponent(audioFileName))
            pipeline["audio_path"] = "./\(audioFileName)"
        }

        let caseDictionary: [String: Any] = [
            "id": "case-\(isoTimestamp(from: item.timestamp))",
            "exported_at": isoTimestamp(from: Date()),
            "intent": item.intent.rawValue,
            "run_uuid": item.id.uuidString,
            "run_timestamp": isoTimestamp(from: item.timestamp),
            "metadata": metadata,
            "pipeline": pipeline,
            "settings": settings
        ]
        let caseData = try JSONSerialization.data(withJSONObject: caseDictionary,
                                                  options: [.prettyPrinted, .sortedKeys])
        try caseData.write(to: tempDir.appendingPathComponent("case.json"))

        let archiveWork = tempDir.appendingPathComponent("__archive-work", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveWork,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        let destinationTemp = archiveWork.appendingPathComponent("\(UUID().uuidString).zip")
        let archiveContents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0 != "__archive-work" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", destinationTemp.path] + archiveContents
        process.currentDirectoryURL = tempDir
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.zipFailed(process.terminationStatus)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: destinationTemp)
        } else {
            try FileManager.default.moveItem(at: destinationTemp, to: destination)
        }
    }

    private static func decodeDataURL(_ dataURL: String) -> Data? {
        guard let commaIndex = dataURL.lastIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: commaIndex)...])
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    private static func isoTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
