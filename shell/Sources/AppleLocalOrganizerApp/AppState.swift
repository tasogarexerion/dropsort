import AppKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @AppStorage("defaultStyle") var defaultStyle = "bullets"
    @AppStorage("defaultLength") var defaultLength = "short"
    @AppStorage("extraInstruction") var extraInstruction = ""
    @AppStorage("watchDesktopEnabled") var watchDesktopEnabled = true
    @AppStorage("watchDownloadsEnabled") var watchDownloadsEnabled = true
    @AppStorage("watchClipboardEnabled") var watchClipboardEnabled = true
    @AppStorage("watchScreenshotsEnabled") var watchScreenshotsEnabled = true
    @AppStorage("watchPDFInboxEnabled") var watchPDFInboxEnabled = true
    @AppStorage("backgroundNotificationsEnabled") var backgroundNotificationsEnabled = true
    @AppStorage("autoApplySuggestedTagsOnMove") var autoApplySuggestedTagsOnMove = true
    @AppStorage("watcherIntervalSeconds") var watcherIntervalSeconds = 30
    @AppStorage("clipboardInsightMinimumLength") var clipboardInsightMinimumLength = 240

    @Published var environmentStatus = EnvironmentStatus(
        shell_supported: true,
        ai_supported: false,
        reason: "Checking environment...",
        os_version: ProcessInfo.processInfo.operatingSystemVersionString
    )
    @Published var latestSummary: SummaryResult?
    @Published var recentResults = RecentResults(summaries: [], organizer_runs: [])
    @Published var downloadsRun: OrganizerRun?
    @Published var desktopRun: OrganizerRun?
    @Published var lastError: String?
    @Published var lastNotice: String?
    @Published var isBusy = false
    @Published var backgroundEvents: [BackgroundEvent] = []

    private let bridge = PythonBridge()
    private var desktopWatcherTask: Task<Void, Never>?
    private var downloadsWatcherTask: Task<Void, Never>?
    private var clipboardWatcherTask: Task<Void, Never>?
    private var didRequestNotificationAuthorization = false
    private var ignoredClipboardFingerprint: String?
    private var lastClipboardFingerprint: String?
    private var lastClipboardChangeCount = NSPasteboard.general.changeCount

    private init() {}

    var backgroundSettingsSignature: String {
        [
            watchDesktopEnabled,
            watchDownloadsEnabled,
            watchClipboardEnabled,
            watchScreenshotsEnabled,
            watchPDFInboxEnabled,
            backgroundNotificationsEnabled,
            autoApplySuggestedTagsOnMove,
        ]
        .map(String.init(describing:))
        .joined(separator: "|") + "|\(watcherIntervalSeconds)|\(clipboardInsightMinimumLength)"
    }

    var backgroundServiceStatusText: String {
        let services = activeBackgroundServices()
        guard !services.isEmpty else {
            return "Background services are off."
        }
        return "Background: \(services.joined(separator: " / ")) • every \(watcherIntervalSeconds)s"
    }

    func bootstrap() async {
        await refreshStatus()
        await loadRecents()
        await configureBackgroundServices()
    }

    func configureBackgroundServices() async {
        cancelBackgroundServices()
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        if backgroundNotificationsEnabled {
            await requestNotificationAuthorizationIfNeeded()
        }
        if watchDesktopEnabled || watchScreenshotsEnabled {
            desktopWatcherTask = Task { [weak self] in
                await self?.runFolderWatcher(for: .desktop)
            }
        }
        if watchDownloadsEnabled || watchPDFInboxEnabled {
            downloadsWatcherTask = Task { [weak self] in
                await self?.runFolderWatcher(for: .downloads)
            }
        }
        if watchClipboardEnabled {
            clipboardWatcherTask = Task { [weak self] in
                await self?.runClipboardWatcher()
            }
        }
    }

    func refreshStatus() async {
        do {
            environmentStatus = try await bridge.checkEnvironment()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func summarizeClipboard() async {
        await runBusyTask { [self] in
            let result = try await self.bridge.summarizeClipboard(
                style: self.defaultStyle,
                length: self.defaultLength,
                instruction: self.nonEmptyInstruction()
            )
            self.latestSummary = result
            await self.loadRecents()
        }
    }

    func summarizeFile() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        await summarizeFileAtPath(url.path, presentAlert: true)
    }

    func review(_ target: ScanTarget) async {
        await runBusyTask { [self] in
            let result = try await self.bridge.scanFolder(path: target.defaultPath)
            switch target {
            case .downloads:
                self.downloadsRun = result
            case .desktop:
                self.desktopRun = result
            }
            await self.loadRecents()
        }
    }

    func applyAllSuggestions(for target: ScanTarget) async {
        guard let run = currentRun(for: target), !run.suggestions.isEmpty else {
            return
        }
        await applySuggestions(run.suggestions, sourceRoot: run.source_root, target: target)
    }

    func applySuggestion(_ suggestion: OrganizerSuggestion, for target: ScanTarget) async {
        await applySuggestions([suggestion], sourceRoot: target.defaultPath, target: target)
    }

    func loadRecents() async {
        do {
            recentResults = try await bridge.listRecentResults()
            if downloadsRun == nil {
                downloadsRun = recentResults.organizer_runs.first(where: { $0.source_root == ScanTarget.downloads.defaultPath })
            }
            if desktopRun == nil {
                desktopRun = recentResults.organizer_runs.first(where: { $0.source_root == ScanTarget.desktop.defaultPath })
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func currentRun(for target: ScanTarget) -> OrganizerRun? {
        switch target {
        case .downloads:
            return downloadsRun
        case .desktop:
            return desktopRun
        }
    }

    func copy(_ value: String) {
        ignoredClipboardFingerprint = fingerprint(for: value)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
    }

    func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func recordServiceSummary(_ result: SummaryResult) async {
        latestSummary = result
        lastNotice = "選択テキストを要約し、クリップボードにコピーしました。"
        copy(result.summary_text)
        await loadRecents()
    }

    func applySuggestedTags(_ suggestion: OrganizerSuggestion, pathOverride: String? = nil) async {
        let targetPath = pathOverride ?? suggestion.source_path
        do {
            let appliedCount = try applyFinderTags(suggestion.suggested_tags, to: targetPath)
            if appliedCount > 0 {
                let fileName = URL(fileURLWithPath: targetPath).lastPathComponent
                let detail = "\(fileName) に \(suggestion.suggested_tags.joined(separator: ", ")) を付与しました。"
                lastNotice = detail
                appendBackgroundEvent(title: "Finder タグを適用", detail: detail)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func handleOpenedFiles(_ paths: [String]) async {
        let fileManager = FileManager.default
        let files = paths.filter { path in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return false
            }
            return !isDirectory.boolValue
        }

        guard !files.isEmpty else {
            lastError = "右クリック連携で受け取った項目に対応ファイルがありませんでした。"
            return
        }

        if files.count == 1, let first = files.first {
            await summarizeFileAtPath(first, presentAlert: true)
            return
        }

        await runBusyTask { [self] in
            for path in files {
                let result = try await self.bridge.summarizeFile(
                    path: path,
                    style: self.defaultStyle,
                    length: self.defaultLength,
                    instruction: self.nonEmptyInstruction()
                )
                self.latestSummary = result
            }
            self.lastNotice = "\(files.count) 件のファイルを要約しました。Recent Results を確認してください。"
            await self.loadRecents()
            self.presentAlert(
                title: "Apple Local Organizer",
                message: "\(files.count) 件のファイルを要約しました。Recent Results から確認できます。"
            )
        }
    }

    private func nonEmptyInstruction() -> String? {
        extraInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : extraInstruction
    }

    private func summarizeFileAtPath(_ path: String, presentAlert: Bool) async {
        await runBusyTask { [self] in
            let result = try await self.bridge.summarizeFile(
                path: path,
                style: self.defaultStyle,
                length: self.defaultLength,
                instruction: self.nonEmptyInstruction()
            )
            self.latestSummary = result
            self.lastNotice = "\(URL(fileURLWithPath: path).lastPathComponent) を要約しました。"
            await self.loadRecents()
            if presentAlert {
                self.presentAlert(
                    title: result.title,
                    message: truncated(result.summary_text, limit: 900)
                )
            }
        }
    }

    private func applySuggestions(
        _ suggestions: [OrganizerSuggestion],
        sourceRoot: String,
        target: ScanTarget
    ) async {
        await runBusyTask { [self] in
            let result = try await self.bridge.applySuggestions(
                sourceRoot: sourceRoot,
                suggestions: suggestions
            )
            let taggedCount = self.autoApplySuggestedTagsOnMove
                ? self.applySuggestedTagsAfterMove(items: result.items, suggestions: suggestions)
                : 0
            self.lastNotice = notice(for: result, taggedCount: taggedCount)
            let refreshed = try await self.bridge.scanFolder(path: target.defaultPath)
            switch target {
            case .downloads:
                self.downloadsRun = refreshed
            case .desktop:
                self.desktopRun = refreshed
            }
            await self.loadRecents()
        }
    }

    private func notice(for result: OrganizerApplyResult, taggedCount: Int) -> String {
        let tagSuffix = taggedCount > 0 ? "、\(taggedCount) 件へタグ適用しました。" : "。"
        if result.skipped_count == 0 {
            return "\(result.moved_count) 件を移動しました" + tagSuffix
        }
        return "\(result.moved_count) 件を移動、\(result.skipped_count) 件をスキップしました" + tagSuffix
    }

    private func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        return String(value.prefix(limit)) + "…"
    }

    private func cancelBackgroundServices() {
        desktopWatcherTask?.cancel()
        downloadsWatcherTask?.cancel()
        clipboardWatcherTask?.cancel()
        desktopWatcherTask = nil
        downloadsWatcherTask = nil
        clipboardWatcherTask = nil
    }

    private func runFolderWatcher(for target: ScanTarget) async {
        var knownSnapshot = captureFileSnapshot(at: target.defaultPath)
        if monitorEnabled(for: target) {
            await performBackgroundReview(for: target, changedFilesCount: 0, sendUserNotification: false)
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(max(10, watcherIntervalSeconds)))
            let currentSnapshot = captureFileSnapshot(at: target.defaultPath)
            let changedPaths = currentSnapshot.compactMap { path, modifiedAt -> String? in
                guard let previous = knownSnapshot[path] else { return path }
                return previous == modifiedAt ? nil : path
            }
            knownSnapshot = currentSnapshot
            if changedPaths.isEmpty {
                continue
            }
            await handleFolderChanges(changedPaths.sorted(), for: target)
        }
    }

    private func runClipboardWatcher() async {
        let board = NSPasteboard.general
        lastClipboardChangeCount = board.changeCount

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(max(10, watcherIntervalSeconds)))
            guard board.changeCount != lastClipboardChangeCount else {
                continue
            }
            lastClipboardChangeCount = board.changeCount
            guard let text = board.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty else {
                continue
            }
            let currentFingerprint = fingerprint(for: text)
            if currentFingerprint == ignoredClipboardFingerprint {
                ignoredClipboardFingerprint = nil
                lastClipboardFingerprint = currentFingerprint
                continue
            }
            guard environmentStatus.ai_supported,
                  text.count >= clipboardInsightMinimumLength,
                  currentFingerprint != lastClipboardFingerprint else {
                lastClipboardFingerprint = currentFingerprint
                continue
            }
            lastClipboardFingerprint = currentFingerprint
            await summarizeClipboardInsight(text)
        }
    }

    private func handleFolderChanges(_ changedPaths: [String], for target: ScanTarget) async {
        if target == .desktop, watchScreenshotsEnabled {
            for path in changedPaths where isScreenshotFile(path) {
                await summarizeBackgroundFile(
                    path,
                    titlePrefix: "スクリーンショットを要約",
                    instruction: "新着スクリーンショットを素早く把握できる短い日本語要約にしてください。"
                )
            }
        }
        if target == .downloads, watchPDFInboxEnabled {
            for path in changedPaths where path.lowercased().hasSuffix(".pdf") {
                await summarizeBackgroundFile(
                    path,
                    titlePrefix: "新着 PDF を要約",
                    instruction: "ダウンロード直後の PDF を素早く判断できる短い日本語要約にしてください。"
                )
            }
        }
        if monitorEnabled(for: target) {
            await performBackgroundReview(
                for: target,
                changedFilesCount: changedPaths.count,
                sendUserNotification: true
            )
        }
    }

    private func performBackgroundReview(
        for target: ScanTarget,
        changedFilesCount: Int,
        sendUserNotification: Bool
    ) async {
        do {
            let result = try await bridge.scanFolder(path: target.defaultPath)
            switch target {
            case .downloads:
                downloadsRun = result
            case .desktop:
                desktopRun = result
            }
            await loadRecents()
            let detail = changedFilesCount > 0
                ? "\(changedFilesCount) 件の新規変更を検知。整理候補 \(result.suggestions.count) 件。"
                : "整理候補 \(result.suggestions.count) 件。"
            lastNotice = "\(target.rawValue) を監視更新しました。"
            appendBackgroundEvent(title: "\(target.rawValue) を監視更新", detail: detail)
            if sendUserNotification {
                await sendNotification(title: "\(target.rawValue) を監視更新", body: detail)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func summarizeBackgroundFile(_ path: String, titlePrefix: String, instruction: String) async {
        guard environmentStatus.ai_supported else {
            return
        }
        do {
            let result = try await bridge.summarizeFile(
                path: path,
                style: "title-and-summary",
                length: "short",
                instruction: instruction
            )
            latestSummary = result
            await loadRecents()
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            let detail = "\(fileName): \(truncated(result.summary_text, limit: 140))"
            lastNotice = "\(titlePrefix): \(fileName)"
            appendBackgroundEvent(title: titlePrefix, detail: detail)
            await sendNotification(title: titlePrefix, body: detail)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func summarizeClipboardInsight(_ text: String) async {
        do {
            let result = try await bridge.summarizeText(
                text: text,
                style: "title-and-summary",
                length: "short",
                instruction: "クリップボードの内容を確認するため、要点と次の行動があれば短く日本語で示してください。"
            )
            latestSummary = result
            await loadRecents()
            let detail = truncated(result.summary_text, limit: 140)
            lastNotice = "クリップボードのインサイトを更新しました。"
            appendBackgroundEvent(title: "クリップボードを要約", detail: detail)
            await sendNotification(title: "クリップボードを要約", body: detail)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func monitorEnabled(for target: ScanTarget) -> Bool {
        switch target {
        case .downloads:
            return watchDownloadsEnabled
        case .desktop:
            return watchDesktopEnabled
        }
    }

    private func captureFileSnapshot(at rootPath: String) -> [String: TimeInterval] {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var snapshot: [String: TimeInterval] = [:]
        for item in items {
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }
            snapshot[item.path] = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        return snapshot
    }

    private func isScreenshotFile(_ path: String) -> Bool {
        let lowercased = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return lowercased.contains("screenshot") || lowercased.contains("スクリーンショット")
    }

    private func applySuggestedTagsAfterMove(items: [OrganizerMoveItem], suggestions: [OrganizerSuggestion]) -> Int {
        var taggedCount = 0
        let suggestionMap = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.source_path, $0) })
        for item in items {
            guard item.status == "moved",
                  let destinationPath = item.destination_path,
                  let suggestion = suggestionMap[item.source_path],
                  !suggestion.suggested_tags.isEmpty else {
                continue
            }
            do {
                let appliedCount = try applyFinderTags(suggestion.suggested_tags, to: destinationPath)
                if appliedCount > 0 {
                    taggedCount += 1
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        return taggedCount
    }

    private func applyFinderTags(_ tags: [String], to path: String) throws -> Int {
        guard #available(macOS 26.0, *) else {
            return 0
        }
        let cleanedTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanedTags.isEmpty else {
            return 0
        }
        var url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "AppleLocalOrganizer",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "タグ適用先のファイルが見つかりません: \(path)"]
            )
        }
        let existingTags = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        let mergedTags = mergedTags(existingTags + cleanedTags)
        guard mergedTags != existingTags else {
            return 0
        }
        var values = URLResourceValues()
        values.tagNames = mergedTags
        try url.setResourceValues(values)
        return mergedTags.count - existingTags.count
    }

    private func mergedTags(_ tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags where !result.contains(tag) {
            result.append(tag)
        }
        return result
    }

    private func appendBackgroundEvent(title: String, detail: String) {
        backgroundEvents.insert(
            BackgroundEvent(title: title, detail: detail, createdAt: Date()),
            at: 0
        )
        if backgroundEvents.count > 12 {
            backgroundEvents = Array(backgroundEvents.prefix(12))
        }
    }

    private func fingerprint(for text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.count)|\(cleaned.prefix(160))"
    }

    private func activeBackgroundServices() -> [String] {
        var labels: [String] = []
        if watchDesktopEnabled {
            labels.append("Desktop review")
        }
        if watchDownloadsEnabled {
            labels.append("Downloads review")
        }
        if watchScreenshotsEnabled {
            labels.append("Screenshot summary")
        }
        if watchPDFInboxEnabled {
            labels.append("PDF watcher")
        }
        if watchClipboardEnabled {
            labels.append("Clipboard insight")
        }
        if autoApplySuggestedTagsOnMove {
            labels.append("Auto tags on move")
        }
        return labels
    }

    private func requestNotificationAuthorizationIfNeeded() async {
        guard !didRequestNotificationAuthorization else {
            return
        }
        didRequestNotificationAuthorization = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func sendNotification(title: String, body: String) async {
        guard backgroundNotificationsEnabled else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func runBusyTask(_ task: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            lastError = nil
            try await task()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
