import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AppSelectionSnapshot {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
}

struct AppContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let currentActivity: String
    let contextSystemPrompt: String?
    let contextPrompt: String?
    let screenshotDataURL: String?
    let screenshotMimeType: String?
    let screenshotError: String?

    var contextSummary: String { currentActivity }
}

final class AppContextService {
    static let defaultContextModel = "qwen/qwen3.6-27b"
    static let defaultContextPrompt = """
You are a context synthesis assistant for a speech-to-text pipeline.
Given app/window metadata and an optional screenshot, output exactly two sentences that describe what the user is doing right now and the likely writing intent in the current window.
Prioritize concrete details only from the context: for email, identify recipients, subject or thread cues, and whether the user is replying or composing; for terminal/code/text work, identify the active command, file, document title, or topic.
If details are missing, state uncertainty instead of inventing facts.
Return only two sentences, no labels, no markdown, no extra commentary.
"""
    static let defaultContextPromptDate = "2026-02-24"
    static let defaultScreenshotMaxDimension: CGFloat = 1024

    private static let maxScreenshotDataURILength = 500_000

    private let apiKey: String
    private let baseURL: String
    private let contextSystemPrompt: String
    private let contextModel: String
    private let screenshotMaxDimension: CGFloat

    init(apiKey: String,
         baseURL: String = "https://api.groq.com/openai/v1",
         customContextPrompt: String = "",
         contextModel: String = AppContextService.defaultContextModel,
         screenshotMaxDimension: CGFloat = AppContextService.defaultScreenshotMaxDimension) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        let trimmedPrompt = customContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contextSystemPrompt = trimmedPrompt.isEmpty ? Self.defaultContextPrompt : trimmedPrompt
        let trimmedModel = contextModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contextModel = trimmedModel.isEmpty ? Self.defaultContextModel : trimmedModel
        self.screenshotMaxDimension = screenshotMaxDimension > 0
            ? screenshotMaxDimension
            : Self.defaultScreenshotMaxDimension
    }

    private var contextRequestTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "context_request_timeout_seconds")
        return override > 0 ? override : 20
    }

    // MARK: - Selection snapshot (cheap AX-only read, no LLM)

    func collectSelectionSnapshot() -> AppSelectionSnapshot {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return AppSelectionSnapshot(appName: nil,
                                        bundleIdentifier: nil,
                                        windowTitle: nil,
                                        selectedText: nil)
        }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        return AppSelectionSnapshot(appName: frontApp.localizedName,
                                    bundleIdentifier: frontApp.bundleIdentifier,
                                    windowTitle: focusedWindowTitle(from: appElement)
                                        ?? frontApp.localizedName,
                                    selectedText: rawSelectedText(from: appElement))
    }

    // MARK: - Context collection

    func collectContext() async -> AppContext {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return AppContext(appName: nil,
                              bundleIdentifier: nil,
                              windowTitle: nil,
                              selectedText: nil,
                              currentActivity: "You are dictating in an unrecognized context.",
                              contextSystemPrompt: contextSystemPrompt,
                              contextPrompt: nil,
                              screenshotDataURL: nil,
                              screenshotMimeType: nil,
                              screenshotError: "No frontmost application")
        }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        let windowTitle = focusedWindowTitle(from: appElement)
        let windowBounds = focusedWindowBounds(from: appElement)
        let selectedText = selectedText(from: appElement)

        var screenshotDataURL: String?
        var screenshotMimeType: String?
        var screenshotError: String?
        switch captureScreenshot(processIdentifier: frontApp.processIdentifier,
                                 windowBounds: windowBounds,
                                 windowTitle: windowTitle) {
        case .success(let dataURL, let mimeType):
            screenshotDataURL = dataURL
            screenshotMimeType = mimeType
        case .failure(let message):
            screenshotError = message
        }

        let inference = await inferActivityWithLLM(appName: frontApp.localizedName,
                                             bundleIdentifier: frontApp.bundleIdentifier,
                                             windowTitle: windowTitle,
                                             selectedText: selectedText,
                                             screenshotDataURL: screenshotDataURL)

        return AppContext(appName: frontApp.localizedName,
                          bundleIdentifier: frontApp.bundleIdentifier,
                          windowTitle: windowTitle,
                          selectedText: selectedText,
                          currentActivity: inference.activity,
                          contextSystemPrompt: contextSystemPrompt,
                          contextPrompt: inference.prompt,
                          screenshotDataURL: screenshotDataURL,
                          screenshotMimeType: screenshotMimeType,
                          screenshotError: screenshotError)
    }

    // MARK: - Activity summary (pure)

    static func activitySummary(from rawContent: String, model: String) -> String? {
        var content = rawContent
        if ModelConfiguration.config(for: model).shouldStripThinkTags {
            content = ModelConfiguration.stripThinkTags(content)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return normalizedActivitySummary(trimmed)
    }

    private static func normalizedActivitySummary(_ value: String) -> String {
        var segments: [String] = []
        var current = ""
        for character in value {
            if character == "." || character == "!" || character == "?" || character == "。" {
                let segment = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty {
                    segments.append(segment)
                }
                current = ""
            } else {
                current.append(character)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            segments.append(tail)
        }
        guard segments.count > 2 else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return segments.prefix(2).joined(separator: ". ") + "."
    }

    // MARK: - LLM inference

    private func inferActivityWithLLM(appName: String?,
                                      bundleIdentifier: String?,
                                      windowTitle: String?,
                                      selectedText: String?,
                                      screenshotDataURL: String?) async -> (activity: String, prompt: String?) {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (fallbackCurrentActivity(appName: appName,
                                            hasScreenshot: screenshotDataURL != nil), nil)
        }
        let metadata = """
App: \(appName ?? "Unknown")
Bundle ID: \(bundleIdentifier ?? "Unknown")
Window: \(windowTitle ?? "Unknown")
Selected text: \(selectedText ?? "None")
"""
        let attempts: [(model: String, screenshot: String?)]
        if let screenshot = screenshotDataURL {
            attempts = [(contextModel, screenshot), (contextModel, nil)]
        } else {
            attempts = [(contextModel, nil)]
        }
        for attempt in attempts {
            if let result = await requestActivity(model: attempt.model,
                                                  screenshotDataURL: attempt.screenshot,
                                                  metadata: metadata) {
                return result
            }
        }
        return (fallbackCurrentActivity(appName: appName,
                                        hasScreenshot: screenshotDataURL != nil), nil)
    }

    private func requestActivity(model: String,
                                 screenshotDataURL: String?,
                                 metadata: String) async -> (activity: String, prompt: String)? {
        let userMessageForPrompt: String
        let userContent: Any
        if let screenshot = screenshotDataURL {
            userContent = [
                ["type": "text", "text": "Analyze the screenshot plus metadata to infer current activity."],
                ["type": "text", "text": metadata],
                ["type": "image_url", "image_url": ["url": screenshot]]
            ]
            userMessageForPrompt = "Analyze the screenshot plus metadata to infer current activity.\n\(metadata)"
        } else {
            userMessageForPrompt = "Analyze the context and infer the user's current activity in exactly two sentences.\n\n\(metadata)"
            userContent = userMessageForPrompt
        }
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": contextSystemPrompt],
                ["role": "user", "content": userContent]
            ]
        ]

        guard var components = URLComponents(
                string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var path = components.path
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        components.path = path + "/chat/completions"
        guard let url = components.url,
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = contextRequestTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        guard let (data, response) = try? await LLMAPITransport.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String,
              let activity = Self.activitySummary(from: content, model: model) else { return nil }

        let prompt = """
Model: \(model)

[System]
\(contextSystemPrompt)
[User]
\(userMessageForPrompt)
"""
        return (activity, prompt)
    }

    private func fallbackCurrentActivity(appName: String?, hasScreenshot: Bool) -> String {
        let activeApp = appName ?? "the active application"
        if hasScreenshot {
            return "Could not reliably infer a two-sentence summary for \(activeApp) from the screenshot and metadata."
        }
        return "Could not reliably infer a two-sentence summary for \(activeApp) from the visible metadata."
    }

    // MARK: - AX reading

    private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == CFStringGetTypeID() else { return nil }
        return unsafeBitCast(rawValue, to: CFString.self) as String
    }

    private func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(rawValue, to: AXValue.self)
    }

    private func accessibilityString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let rawValue = axString(element, attribute) else { return nil }
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    private func accessibilityRawString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let rawValue = axString(element, attribute), !rawValue.isEmpty else { return nil }
        return rawValue
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let window = axElement(appElement, kAXFocusedWindowAttribute) else { return nil }
        return accessibilityString(window, kAXTitleAttribute)
    }

    private func selectedText(from appElement: AXUIElement) -> String? {
        if let focusedElement = axElement(appElement, kAXFocusedUIElementAttribute),
           let text = accessibilityString(focusedElement, kAXSelectedTextAttribute) {
            return text
        }
        return accessibilityString(appElement, kAXSelectedTextAttribute)
    }

    private func rawSelectedText(from appElement: AXUIElement) -> String? {
        if let focusedElement = axElement(appElement, kAXFocusedUIElementAttribute),
           let text = accessibilityRawString(focusedElement, kAXSelectedTextAttribute) {
            return text
        }
        return accessibilityRawString(appElement, kAXSelectedTextAttribute)
    }

    private func focusedWindowBounds(from appElement: AXUIElement) -> CGRect? {
        guard let window = axElement(appElement, kAXFocusedWindowAttribute),
              let positionValue = axValue(window, kAXPositionAttribute),
              let sizeValue = axValue(window, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    // MARK: - Screenshot pipeline

    private enum ScreenshotResult {
        case success(dataURL: String, mimeType: String)
        case failure(String)
    }

    private struct CandidateWindow {
        let id: CGWindowID
        let layer: Int
        let area: Int
        let bounds: CGRect?
        let name: String?
    }

    private func captureScreenshot(processIdentifier: pid_t,
                                   windowBounds: CGRect?,
                                   windowTitle: String?) -> ScreenshotResult {
        guard CGPreflightScreenCaptureAccess() else {
            return .failure("Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording.")
        }
        guard let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]] else {
            return .failure("Unable to read window list")
        }

        var candidates: [CandidateWindow] = []
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == Int(processIdentifier),
                  info[kCGWindowIsOnscreen as String] as? Bool == true,
                  let windowNumber = info[kCGWindowNumber as String] as? Int,
                  let windowID = CGWindowID(exactly: windowNumber) else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let bounds = boundsRect(info[kCGWindowBounds as String])
            let area = bounds.map { Int($0.width * $0.height) } ?? 1
            let trimmedName = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmedName?.isEmpty == false) ? trimmedName : nil
            candidates.append(CandidateWindow(id: windowID,
                                              layer: layer,
                                              area: area,
                                              bounds: bounds,
                                              name: name))
        }

        if let bounds = windowBounds, !bounds.isEmpty {
            var overlaps: [(candidate: CandidateWindow, overlap: CGFloat)] = []
            for candidate in candidates {
                guard let candidateBounds = candidate.bounds else { continue }
                let intersection = candidateBounds.intersection(bounds)
                guard !intersection.isEmpty else { continue }
                overlaps.append((candidate, intersection.width * intersection.height))
            }
            overlaps.sort { lhs, rhs in
                if lhs.candidate.layer != rhs.candidate.layer {
                    return lhs.candidate.layer < rhs.candidate.layer
                }
                return lhs.overlap > rhs.overlap
            }
            if let best = overlaps.first,
               case .success(let dataURL, let mimeType) = captureWindowImage(best.candidate.id) {
                return .success(dataURL: dataURL, mimeType: mimeType)
            }
        }

        if let title = windowTitle {
            let target = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty {
                let named = candidates.filter { candidate in
                    guard let name = candidate.name else { return false }
                    let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    return normalized == target || normalized.contains(target)
                }
                let sorted = named.sorted { lhs, rhs in
                    if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
                    return lhs.area > rhs.area
                }
                if let best = sorted.first,
                   case .success(let dataURL, let mimeType) = captureWindowImage(best.id) {
                    return .success(dataURL: dataURL, mimeType: mimeType)
                }
            }
        }

        guard let screenImage = CGWindowListCreateImage(CGRect.infinite,
                                                        .optionOnScreenOnly,
                                                        kCGNullWindowID,
                                                        [.bestResolution]) else {
            return .failure("Could not capture screenshot from the active window")
        }
        let cropped = croppedWhitespaceImage(screenImage)
        if case .success(let dataURL, let mimeType) = convertImageToDataURL(
                cropped, mimeType: "image/jpeg", fileType: .jpeg, compression: 0.5) {
            return .success(dataURL: dataURL, mimeType: mimeType)
        }
        return .failure("Could not capture screenshot within size limits")
    }

    private func boundsRect(_ dictionary: Any?) -> CGRect? {
        guard let dict = dictionary as? [String: Any],
              let x = dict["X"] as? CGFloat,
              let y = dict["Y"] as? CGFloat,
              let width = dict["Width"] as? CGFloat,
              let height = dict["Height"] as? CGFloat else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func captureWindowImage(_ windowID: CGWindowID) -> ScreenshotResult {
        guard let image = CGWindowListCreateImage(.null,
                                                  .optionIncludingWindow,
                                                  windowID,
                                                  [.bestResolution]) else {
            return .failure("Could not capture screenshot from the active window")
        }
        if case .success(let dataURL, let mimeType) = convertImageToDataURL(
                image, mimeType: "image/jpeg", fileType: .jpeg, compression: 0.5) {
            return .success(dataURL: dataURL, mimeType: mimeType)
        }
        return .failure("Could not capture screenshot within size limits")
    }

    private func convertImageToDataURL(_ image: CGImage,
                                       mimeType: String,
                                       fileType: NSBitmapImageRep.FileType,
                                       compression: CGFloat) -> ScreenshotResult {
        let compressionSteps = [compression, compression * 0.5, compression * 0.25]
        let dimensionSteps: [CGFloat] = [
            screenshotMaxDimension,
            screenshotMaxDimension * 0.75,
            screenshotMaxDimension * 0.5
        ]
        for dimension in dimensionSteps {
            let resized = resizedImage(image, maxDimension: dimension)
            for step in compressionSteps {
                let rep = NSBitmapImageRep(cgImage: resized)
                guard let data = rep.representation(using: fileType,
                                                    properties: [.compressionFactor: step]) else { continue }
                let base64 = data.base64EncodedString()
                guard base64.count <= Self.maxScreenshotDataURILength else { continue }
                return .success(dataURL: "data:\(mimeType);base64,\(base64)",
                                mimeType: mimeType)
            }
        }
        return .failure("Could not capture screenshot within size limits")
    }

    private func resizedImage(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > maxDimension || height > maxDimension else { return image }
        let scale = min(maxDimension / width, maxDimension / height, 1.0)
        let newWidth = max(1, Int((width * scale).rounded(.down)))
        let newHeight = max(1, Int((height * scale).rounded(.down)))
        guard let context = CGContext(data: nil,
                                      width: newWidth,
                                      height: newHeight,
                                      bitsPerComponent: image.bitsPerComponent,
                                      bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: image.bitmapInfo.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    private func croppedWhitespaceImage(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let whiteThreshold: UInt8 = 245
        let alphaThreshold: UInt8 = 5
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = (y * width + x) * 4
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]
                let alpha = pixels[offset + 3]
                let isWhite = red >= whiteThreshold && green >= whiteThreshold && blue >= whiteThreshold
                let isTransparent = alpha <= alphaThreshold
                if !isWhite && !isTransparent {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                x += 1
            }
            y += 1
        }
        guard maxX >= minX, maxY >= minY else { return image }
        return image.cropping(to: CGRect(x: minX,
                                         y: minY,
                                         width: maxX - minX + 1,
                                         height: maxY - minY + 1)) ?? image
    }
}
