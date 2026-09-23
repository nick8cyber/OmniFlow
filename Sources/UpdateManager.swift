import AppKit
import Foundation

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let publishedAt: String
    let assets: [GitHubReleaseAsset]

    init(tagName: String,
         name: String?,
         body: String?,
         htmlUrl: String,
         publishedAt: String,
         assets: [GitHubReleaseAsset]) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlUrl = htmlUrl
        self.publishedAt = publishedAt
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }
}

enum UpdateStatus: Equatable {
    case idle
    case downloading
    case installing
    case readyToRelaunch
    case error(String)
}

private struct SemanticRelease {
    let release: GitHubRelease
    let version: SemanticVersion
    let publishedDate: Date
}

private enum UpdateInstallError: LocalizedError {
    case hdiutilAttachFailed(Int)
    case noMountPoint
    case noAppFound

    var errorDescription: String? {
        switch self {
        case .hdiutilAttachFailed(let code):
            return "hdiutil attach failed with exit code \(code)"
        case .noMountPoint:
            return "No mount point found in hdiutil output"
        case .noAppFound:
            return "No .app found in DMG."
        }
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private static let releasesURL = "https://api.github.com/repos/nick8cyber/omniflow/releases?per_page=100"
    private static let stabilityBufferDays = 3
    private static let checkIntervalSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let postTranscriptionReminderInterval: TimeInterval = 24 * 60 * 60
    private nonisolated static let downloadBufferSize = 65_536
    private nonisolated static let downloadProgressThrottleInterval = 0.033
    private static let skipButtonResponse = NSApplication.ModalResponse(rawValue: 1003)

    @Published var updateAvailable = false
    @Published var latestRelease: GitHubRelease?
    @Published var latestReleaseVersion = ""
    @Published var latestReleaseDate = ""
    @Published var isChecking = false
    @Published var downloadProgress: Double?
    @Published var updateStatus: UpdateStatus = .idle
    @Published var lastCheckDate: Date? {
        didSet {
            if let lastCheckDate {
                UserDefaults.standard.set(lastCheckDate, forKey: "updateLastCheckDate")
            } else {
                UserDefaults.standard.removeObject(forKey: "updateLastCheckDate")
            }
        }
    }

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "updateAutoCheckEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateAutoCheckEnabled") }
    }

    private var periodicCheckTimer: Timer?
    private var activeDownloadTask: Task<Void, Never>?

    private init() {
        lastCheckDate = UserDefaults.standard.object(forKey: "updateLastCheckDate") as? Date
    }

    // MARK: - Scheduling

    func startPeriodicChecks() {
        guard periodicCheckTimer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.shouldAutoCheck() else { return }
                await self.checkForUpdates(userInitiated: false)
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.shouldAutoCheck() else { return }
                await self.checkForUpdates(userInitiated: false)
            }
        }
        timer.tolerance = 300
        periodicCheckTimer = timer
    }

    private func shouldAutoCheck() -> Bool {
        guard autoCheckEnabled else { return false }
        guard let lastCheck = lastCheckDate else { return true }
        return Date().timeIntervalSince(lastCheck) > Self.checkIntervalSeconds
    }

    // MARK: - Check cycle

    func checkForUpdates(userInitiated: Bool) async {
        let currentBuildTag = Bundle.main.infoDictionary?["OmniFlowBuildTag"] as? String
        if !userInitiated && currentBuildTag == nil {
            return
        }
        isChecking = true
        defer { isChecking = false }

        guard let releasesURL = URL(string: Self.releasesURL) else { return }
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        do {
            let (fetchedData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                if userInitiated {
                    showErrorAlert("Could not reach GitHub.")
                }
                return
            }
            if httpResponse.statusCode == 404 {
                // A private repository answers 404 without a token: treat as no releases.
                lastCheckDate = Date()
                clearAvailableUpdate()
                if userInitiated {
                    showUpToDateAlert()
                }
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if userInitiated {
                    showErrorAlert("GitHub returned status \(httpResponse.statusCode).")
                }
                return
            }
            data = fetchedData
        } catch {
            if userInitiated {
                showErrorAlert("Failed to check for updates: \(error.localizedDescription)")
            }
            return
        }

        let releases: [GitHubRelease]
        do {
            releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        } catch {
            if userInitiated {
                showErrorAlert("Failed to check for updates: \(error.localizedDescription)")
            }
            return
        }

        lastCheckDate = Date()

        guard let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let currentVersion = SemanticVersion(currentVersionString) else {
            updateAvailable = false
            if userInitiated {
                showErrorAlert("The current app version does not use semantic versioning.")
            }
            return
        }

        let candidates = Self.releaseCandidates(from: releases)
        guard let latest = candidates.last else {
            updateAvailable = false
            if userInitiated {
                showErrorAlert("No semantic version release was found.")
            }
            return
        }

        // Aggregate release notes from everything newer than the running version.
        let included = candidates.filter { currentVersion < $0.version && $0.version <= latest.version }
        let bodies = included.reversed().compactMap { entry -> String? in
            guard let body = entry.release.body?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { return nil }
            return body
        }
        let aggregatedBody = bodies.isEmpty ? (latest.release.body ?? "") : bodies.joined(separator: "\n\n")
        let publishedRelease = GitHubRelease(tagName: latest.release.tagName,
                                             name: latest.release.name,
                                             body: aggregatedBody,
                                             htmlUrl: latest.release.htmlUrl,
                                             publishedAt: latest.release.publishedAt,
                                             assets: latest.release.assets)
        latestRelease = publishedRelease
        latestReleaseVersion = Self.normalizedVersionString(from: latest.release.tagName)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        latestReleaseDate = dateFormatter.string(from: latest.publishedDate)

        if latest.release.tagName == currentBuildTag || latest.version <= currentVersion {
            updateAvailable = false
            if userInitiated {
                showUpToDateAlert()
            }
            return
        }

        let daysSincePublished = Date().timeIntervalSince(latest.publishedDate) / 86400
        if daysSincePublished < Double(Self.stabilityBufferDays) {
            if userInitiated {
                updateAvailable = true
                showRecentReleaseAlert(release: publishedRelease, publishedDate: latest.publishedDate)
            } else {
                updateAvailable = false
            }
            return
        }

        if !userInitiated,
           let skipped = UserDefaults.standard.string(forKey: "updateSkippedVersion"),
           skipped == latest.release.tagName {
            updateAvailable = false
            return
        }

        updateAvailable = true
        if userInitiated {
            showUpdateAlert()
        }
    }

    private static func releaseCandidates(from releases: [GitHubRelease]) -> [SemanticRelease] {
        var candidates: [SemanticRelease] = []
        for release in releases {
            guard let version = SemanticVersion(release.tagName),
                  let publishedDate = releasePublishedDate(release.publishedAt) else { continue }
            candidates.append(SemanticRelease(release: release,
                                              version: version,
                                              publishedDate: publishedDate))
        }
        candidates.sort { left, right in
            if left.version != right.version {
                return left.version < right.version
            }
            return left.publishedDate < right.publishedDate
        }
        return candidates
    }

    private static func releasePublishedDate(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func normalizedVersionString(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "^v", options: [.regularExpression, .caseInsensitive]) else {
            return trimmed
        }
        return String(trimmed[range.upperBound...])
    }

    private func clearAvailableUpdate() {
        updateAvailable = false
        latestRelease = nil
        latestReleaseVersion = ""
        latestReleaseDate = ""
    }

    // MARK: - Post-transcription reminder

    func shouldShowPostTranscriptionReminder() -> Bool {
        guard updateAvailable, let release = latestRelease, updateStatus == .idle else { return false }
        if let skipped = UserDefaults.standard.string(forKey: "updateSkippedVersion"),
           skipped == release.tagName {
            return false
        }
        return shouldShowReminderForVersion(release: release)
    }

    private func shouldShowReminderForVersion(release: GitHubRelease) -> Bool {
        let storedVersion = UserDefaults.standard.string(forKey: "updateLastPostTranscriptionReminderVersion")
        if storedVersion != release.tagName {
            return true
        }
        guard let lastDate = UserDefaults.standard.object(forKey: "updateLastPostTranscriptionReminderDate") as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastDate) > Self.postTranscriptionReminderInterval
    }

    func markPostTranscriptionReminderShown() {
        guard let release = latestRelease else { return }
        suppressPostTranscriptionReminder(for: release.tagName)
    }

    private func suppressPostTranscriptionReminder(for tagName: String) {
        UserDefaults.standard.set(tagName, forKey: "updateLastPostTranscriptionReminderVersion")
        UserDefaults.standard.set(Date(), forKey: "updateLastPostTranscriptionReminderDate")
    }

    // MARK: - Dialogs

    func showUpdateAlert() {
        guard let release = latestRelease else { return }
        let versionText = latestReleaseVersion.isEmpty
            ? release.tagName
            : "v\(latestReleaseVersion)"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "A New Version is Available"
        alert.informativeText = "\(AppName.displayName) \(versionText) was released \(latestReleaseDate).\n\nWould you like to download the update?"
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "What's New")
        alert.addButton(withTitle: "Remind Me Later")
        alert.addButton(withTitle: "Skip This Version")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            downloadAndInstall(release: release)
        case .alertSecondButtonReturn:
            showReleaseNotes()
            showUpdateAlert()
        case .alertThirdButtonReturn:
            suppressPostTranscriptionReminder(for: release.tagName)
        case Self.skipButtonResponse:
            UserDefaults.standard.set(release.tagName, forKey: "updateSkippedVersion")
            clearAvailableUpdate()
        default:
            break
        }
    }

    private func showRecentReleaseAlert(release: GitHubRelease, publishedDate: Date) {
        let interval = Date().timeIntervalSince(publishedDate)
        let ageText: String
        if interval < 3600 {
            ageText = "less than an hour ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            ageText = hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else {
            let days = Int(interval / 86400)
            ageText = days == 1 ? "1 day ago" : "\(days) days ago"
        }
        let versionText = latestReleaseVersion.isEmpty
            ? release.tagName
            : "v\(latestReleaseVersion)"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "New Release Available"
        alert.informativeText = "\(AppName.displayName) \(versionText) was released \(ageText). It's very recent — you can download it now or wait a few days for stability.\n\nWould you like to download it?"
        alert.addButton(withTitle: "Download Now")
        alert.addButton(withTitle: "What's New")
        alert.addButton(withTitle: "Wait")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            downloadAndInstall(release: release)
        case .alertSecondButtonReturn:
            showReleaseNotes()
            showRecentReleaseAlert(release: release, publishedDate: publishedDate)
        case .alertThirdButtonReturn:
            suppressPostTranscriptionReminder(for: release.tagName)
            updateAvailable = false
        default:
            break
        }
    }

    func showUpToDateAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "You're Up to Date"
        alert.informativeText = "You're running the latest version of \(AppName.displayName)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showReleaseNotes() {
        let versionText = latestReleaseVersion.isEmpty
            ? (latestRelease?.tagName ?? "")
            : "v\(latestReleaseVersion)"
        var notesBody = latestRelease?.body ?? ""
        if let downloadRange = notesBody.range(of: "\n## Download") {
            notesBody = String(notesBody[notesBody.startIndex..<downloadRange.lowerBound])
        }
        if notesBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notesBody = "No release notes were published for this version."
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "What's New in \(AppName.displayName) \(versionText)"
        alert.informativeText = "Release notes from GitHub."

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textStorage?.setAttributedString(Self.releaseNotesAttributedString(notesBody))
        scrollView.documentView = textView
        alert.accessoryView = scrollView

        alert.addButton(withTitle: "OK")
        if let htmlUrl = latestRelease?.htmlUrl, let url = URL(string: htmlUrl) {
            alert.addButton(withTitle: "Open on GitHub")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.runModal()
        }
    }

    private static func releaseNotesAttributedString(_ body: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let subtitleFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let headerFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 3)

        func appendInlineBold(_ line: String, base: NSFont, paragraph: NSMutableParagraphStyle) {
            var remaining = Substring(line)
            while let start = remaining.range(of: "**") {
                let before = remaining[remaining.startIndex..<start.lowerBound]
                if !before.isEmpty {
                    result.append(NSAttributedString(string: String(before),
                                                     attributes: [.font: base, .paragraphStyle: paragraph]))
                }
                let afterStart = remaining[start.upperBound...]
                if let end = afterStart.range(of: "**") {
                    let boldPart = afterStart[afterStart.startIndex..<end.lowerBound]
                    result.append(NSAttributedString(string: String(boldPart),
                                                     attributes: [.font: boldFont, .paragraphStyle: paragraph]))
                    remaining = afterStart[end.upperBound...]
                } else {
                    result.append(NSAttributedString(string: String(afterStart),
                                                     attributes: [.font: base, .paragraphStyle: paragraph]))
                    return
                }
            }
            if !remaining.isEmpty {
                result.append(NSAttributedString(string: String(remaining),
                                                 attributes: [.font: base, .paragraphStyle: paragraph]))
            }
        }

        let lines = body.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            var text = rawLine
            if text.hasPrefix("### ") {
                text = String(text.dropFirst(4))
                paragraph.paragraphSpacing = 6
                appendInlineBold(text, base: subtitleFont, paragraph: paragraph)
            } else if text.hasPrefix("## ") {
                text = String(text.dropFirst(3))
                paragraph.paragraphSpacing = 6
                appendInlineBold(text, base: headerFont, paragraph: paragraph)
            } else if text.hasPrefix("- ") {
                text = "• " + String(text.dropFirst(2))
                paragraph.paragraphSpacing = 4
                paragraph.headIndent = 16
                appendInlineBold(text, base: baseFont, paragraph: paragraph)
            } else {
                paragraph.paragraphSpacing = 6
                appendInlineBold(text, base: baseFont, paragraph: paragraph)
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
            }
        }
        return result
    }

    // MARK: - Download and install

    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadProgress = nil
        updateStatus = .idle
    }

    func downloadAndInstall(release: GitHubRelease) {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            if let url = URL(string: release.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        activeDownloadTask?.cancel()
        activeDownloadTask = Task { [weak self] in
            await self?.performUpdate(asset: asset)
        }
    }

    private func performUpdate(asset: GitHubReleaseAsset) async {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("omniflow-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        } catch {
            updateStatus = .error("Failed to create temp directory: \(error.localizedDescription)")
            return
        }
        let dmgURL = tempDirectory.appendingPathComponent("OmniFlow.dmg")

        updateStatus = .downloading
        downloadProgress = 0
        do {
            guard let assetURL = URL(string: asset.browserDownloadUrl) else {
                updateStatus = .error("Download failed: invalid asset URL.")
                downloadProgress = nil
                try? fileManager.removeItem(at: tempDirectory)
                return
            }
            var request = URLRequest(url: assetURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let totalSize = response.expectedContentLength > 0
                ? response.expectedContentLength
                : Int64(asset.size)
            try await downloadToFile(bytes: bytes, totalSize: totalSize, destination: dmgURL)
        } catch is CancellationError {
            try? fileManager.removeItem(at: tempDirectory)
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            try? fileManager.removeItem(at: tempDirectory)
            return
        } catch {
            updateStatus = .error("Download failed: \(error.localizedDescription)")
            downloadProgress = nil
            try? fileManager.removeItem(at: tempDirectory)
            return
        }

        updateStatus = .installing
        downloadProgress = nil
        do {
            let mountPoint = try Self.mountDMG(at: dmgURL)
            defer {
                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", mountPoint, "-quiet"]
                try? detach.run()
            }
            let contents = try fileManager.contentsOfDirectory(atPath: mountPoint)
            guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                throw UpdateInstallError.noAppFound
            }
            let appInDMG = URL(fileURLWithPath: mountPoint, isDirectory: true)
                .appendingPathComponent(appName, isDirectory: true)
            let stagingDir = fileManager.temporaryDirectory
                .appendingPathComponent("omniflow-staged-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let stagedApp = stagingDir.appendingPathComponent("\(AppName.displayName).app", isDirectory: true)
            try fileManager.copyItem(at: appInDMG, to: stagedApp)
            try? fileManager.removeItem(at: tempDirectory)
            updateStatus = .readyToRelaunch
            replaceAndRelaunch(stagedApp: stagedApp, stagingDir: stagingDir)
        } catch {
            updateStatus = .error("Install failed: \(error.localizedDescription)")
            try? fileManager.removeItem(at: tempDirectory)
        }
    }

    private func downloadToFile(bytes: URLSession.AsyncBytes,
                                totalSize: Int64,
                                destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: destination.path) {
                fileManager.createFile(atPath: destination.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(Self.downloadBufferSize)
            var receivedBytes: Int64 = 0
            var lastProgressPush = CFAbsoluteTimeGetCurrent()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.downloadBufferSize {
                    try handle.write(contentsOf: buffer)
                    receivedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastProgressPush >= Self.downloadProgressThrottleInterval {
                        lastProgressPush = now
                        let fraction = totalSize > 0 ? Double(receivedBytes) / Double(totalSize) : 0
                        await MainActor.run { [weak self] in
                            self?.downloadProgress = fraction
                        }
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
            }
            let finalFraction = totalSize > 0 ? Double(receivedBytes) / Double(totalSize) : 1.0
            await MainActor.run { [weak self] in
                self?.downloadProgress = min(max(finalFraction, 0), 1)
            }
        }.value
    }

    private static func mountDMG(at dmgURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmgURL.path, "-nobrowse", "-noverify", "-noautoopen", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.hdiutilAttachFailed(Int(process.terminationStatus))
        }
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateInstallError.noMountPoint
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return mountPoint
            }
        }
        throw UpdateInstallError.noMountPoint
    }

    private func replaceAndRelaunch(stagedApp: URL, stagingDir: URL) {
        let currentAppPath = Bundle.main.bundlePath
        let backupPath = currentAppPath + ".bak"
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        mv "$2" "$5" && mv "$3" "$2" && open "$2" && rm -rf "$4" "$5" \\
            || { mv "$5" "$2" 2>/dev/null; exit 1; }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "--",
                             String(pid), currentAppPath, stagedApp.path, stagingDir.path, backupPath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
