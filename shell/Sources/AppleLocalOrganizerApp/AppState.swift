import AppKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private let backgroundMonitoringEnabled = false

    @AppStorage("defaultStyle") var defaultStyle = "bullets"
    @AppStorage("defaultLength") var defaultLength = "short"
    @AppStorage("extraInstruction") var extraInstruction = ""
    @AppStorage("watchDesktopEnabled") var watchDesktopEnabled = false
    @AppStorage("watchDownloadsEnabled") var watchDownloadsEnabled = false
    @AppStorage("watchClipboardEnabled") var watchClipboardEnabled = false
    @AppStorage("watchScreenshotsEnabled") var watchScreenshotsEnabled = false
    @AppStorage("watchPDFInboxEnabled") var watchPDFInboxEnabled = false
    @AppStorage("backgroundNotificationsEnabled") var backgroundNotificationsEnabled = true
    @AppStorage("autoApplySuggestedTagsOnMove") var autoApplySuggestedTagsOnMove = true
    @AppStorage("watcherIntervalSeconds") var watcherIntervalSeconds = 30
    @AppStorage("clipboardInsightMinimumLength") var clipboardInsightMinimumLength = 240
    @AppStorage("backgroundStabilityProfileVersion") var backgroundStabilityProfileVersion = 0

    @Published var environmentStatus = EnvironmentStatus(
        shell_supported: true,
        ai_supported: false,
        reason: "環境を確認しています...",
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
    private var desktopEventStream: DirectoryEventStream?
    private var downloadsEventStream: DirectoryEventStream?
    private var desktopDebounceTask: Task<Void, Never>?
    private var downloadsDebounceTask: Task<Void, Never>?
    private var clipboardWatcherTask: Task<Void, Never>?
    private var backgroundTaskChain: Task<Void, Never>?
    private var pendingDesktopPaths = Set<String>()
    private var pendingDownloadsPaths = Set<String>()
    private var backgroundReviewInFlight = Set<ScanTarget>()
    private var backgroundReviewPending = Set<ScanTarget>()
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
        guard backgroundMonitoringEnabled else {
            return "この preview では常駐監視を停止しています。右クリック操作とかんたん整理を使ってください。"
        }
        let services = activeBackgroundServices()
        guard !services.isEmpty else {
            return "バックグラウンド機能はオフです。かんたん整理を使うか、設定で個別に有効化してください。"
        }
        var detail = "バックグラウンド: \(services.joined(separator: " / "))"
        if watchClipboardEnabled {
            detail += " • クリップボード確認 \(watcherIntervalSeconds)秒"
        }
        return detail
    }

    func bootstrap() async {
        applyStabilityProfileIfNeeded()
        await refreshStatus()
        await loadRecents()
        await configureBackgroundServices()
    }

    func configureBackgroundServices() async {
        cancelBackgroundServices()
        disableBackgroundMonitoringSettings()
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        guard backgroundMonitoringEnabled else {
            return
        }
        if backgroundNotificationsEnabled {
            await requestNotificationAuthorizationIfNeeded()
        }
        if watchDesktopEnabled || watchScreenshotsEnabled {
            startDirectoryWatcher(for: .desktop)
        }
        if watchDownloadsEnabled || watchPDFInboxEnabled {
            startDirectoryWatcher(for: .downloads)
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

    func copyExtractedTextFromFile() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        await copyExtractedTextFromPath(url.path, presentAlert: true)
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

    func quickSort(_ target: ScanTarget) async {
        await runBusyTask { [self] in
            let run = try await self.bridge.scanFolder(path: target.defaultPath)
            switch target {
            case .downloads:
                self.downloadsRun = run
            case .desktop:
                self.desktopRun = run
            }
            guard !run.suggestions.isEmpty else {
                self.lastNotice = "\(target.rawValue) は整理不要でした。"
                await self.loadRecents()
                return
            }
            let result = try await self.bridge.applySuggestions(
                sourceRoot: run.source_root,
                suggestions: run.suggestions
            )
            let taggedCount = self.autoApplySuggestedTagsOnMove
                ? self.applySuggestedTagsAfterMove(items: result.items, suggestions: run.suggestions)
                : 0
            self.lastNotice = "\(target.rawValue) をワンクリック整理しました。\(self.notice(for: result, taggedCount: taggedCount))"
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

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func bringWindowToFront(titled title: String) {
        activateApp()
        if let window = NSApp.windows.first(where: { $0.title == title }) {
            configurePresentation(for: window)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func presentWindow(
        id: String,
        title: String,
        openWindow: OpenWindowAction,
        followUp: (@MainActor () async -> Void)? = nil
    ) {
        activateApp()
        openWindow(id: id)
        Task { @MainActor in
            for attempt in 0..<5 {
                bringWindowToFront(titled: title)
                if attempt == 0 {
                    await followUp?()
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    func recordServiceSummary(_ result: SummaryResult) async {
        latestSummary = result
        lastNotice = "選択テキストを要約し、クリップボードにコピーしました。"
        copy(result.summary_text)
        await loadRecents()
    }

    func recordExtractedTextCopy(_ result: ExtractedTextResult, copiedText: String) {
        let fileLabel = result.title.isEmpty ? "ファイル" : result.title
        lastNotice = "\(fileLabel) の抽出テキストをクリップボードにコピーしました。"
        copy(copiedText)
    }

    func applySuggestedTags(_ suggestion: OrganizerSuggestion, pathOverride: String? = nil) async {
        let targetPath = pathOverride ?? suggestion.source_path
        do {
            let appliedCount = try applyFinderTags(
                suggestion.suggested_tags,
                colorName: suggestion.suggested_tag_color,
                to: targetPath
            )
            if appliedCount > 0 {
                let fileName = URL(fileURLWithPath: targetPath).lastPathComponent
                let colorSuffix = suggestion.suggested_tag_color.map { " / color: \($0)" } ?? ""
                let detail = "\(fileName) に \(suggestion.suggested_tags.joined(separator: ", "))\(colorSuffix) を付与しました。"
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
            self.lastNotice = "\(files.count) 件のファイルを要約しました。最近の結果を確認してください。"
            await self.loadRecents()
                self.presentAlert(
                title: "DropSort",
                message: "\(files.count) 件のファイルを要約しました。最近の結果から確認できます。"
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

    private func copyExtractedTextFromPath(_ path: String, presentAlert: Bool) async {
        await runBusyTask { [self] in
            let result = try await self.bridge.extractFileText(path: path)
            let extracted = result.extracted_text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !extracted.isEmpty else {
                throw NSError(
                    domain: "DropSort",
                    code: 422,
                    userInfo: [NSLocalizedDescriptionKey: "抽出できるテキストが見つかりませんでした。"]
                )
            }
            self.recordExtractedTextCopy(result, copiedText: extracted)
            if presentAlert {
                self.presentAlert(
                    title: result.title,
                    message: truncated(extracted, limit: 900)
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
        desktopEventStream?.stop()
        downloadsEventStream?.stop()
        desktopEventStream = nil
        downloadsEventStream = nil
        desktopDebounceTask?.cancel()
        downloadsDebounceTask?.cancel()
        clipboardWatcherTask?.cancel()
        backgroundTaskChain?.cancel()
        desktopDebounceTask = nil
        downloadsDebounceTask = nil
        clipboardWatcherTask = nil
        backgroundTaskChain = nil
        pendingDesktopPaths.removeAll()
        pendingDownloadsPaths.removeAll()
    }

    private func startDirectoryWatcher(for target: ScanTarget) {
        do {
            let stream = DirectoryEventStream(path: target.defaultPath) { [weak self] paths in
                guard let self else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.enqueueDirectoryEvents(paths, for: target)
                }
            }
            try stream.start()
            switch target {
            case .desktop:
                desktopEventStream = stream
            case .downloads:
                downloadsEventStream = stream
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func enqueueDirectoryEvents(_ paths: [String], for target: ScanTarget) {
        let filtered = paths.filter { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return false
            }
            return !isDirectory.boolValue
        }
        guard !filtered.isEmpty else {
            return
        }
        switch target {
        case .desktop:
            pendingDesktopPaths.formUnion(filtered)
            desktopDebounceTask?.cancel()
            desktopDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.flushDirectoryEvents(for: .desktop)
            }
        case .downloads:
            pendingDownloadsPaths.formUnion(filtered)
            downloadsDebounceTask?.cancel()
            downloadsDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.flushDirectoryEvents(for: .downloads)
            }
        }
    }

    private func flushDirectoryEvents(for target: ScanTarget) async {
        let changedPaths: [String]
        switch target {
        case .desktop:
            changedPaths = pendingDesktopPaths.sorted()
            pendingDesktopPaths.removeAll()
        case .downloads:
            changedPaths = pendingDownloadsPaths.sorted()
            pendingDownloadsPaths.removeAll()
        }
        guard !changedPaths.isEmpty else {
            return
        }
        await handleFolderChanges(changedPaths, for: target)
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
                  shouldAnalyzeClipboard(text),
                  currentFingerprint != lastClipboardFingerprint else {
                lastClipboardFingerprint = currentFingerprint
                continue
            }
            lastClipboardFingerprint = currentFingerprint
            enqueueBackgroundTask { [weak self] in
                await self?.summarizeClipboardInsight(text)
            }
        }
    }

    private func handleFolderChanges(_ changedPaths: [String], for target: ScanTarget) async {
        if target == .desktop,
           watchScreenshotsEnabled,
           let screenshotPath = changedPaths.first(where: isScreenshotFile) {
            enqueueBackgroundTask { [weak self] in
                await self?.summarizeBackgroundFile(
                    screenshotPath,
                    titlePrefix: "スクリーンショットを要約",
                    instruction: "新着スクリーンショットを素早く把握できる短い日本語要約にしてください。"
                )
            }
        }
        if target == .downloads,
           watchPDFInboxEnabled,
           let pdfPath = changedPaths.first(where: { $0.lowercased().hasSuffix(".pdf") }) {
            enqueueBackgroundTask { [weak self] in
                await self?.summarizeBackgroundFile(
                    pdfPath,
                    titlePrefix: "新着 PDF を要約",
                    instruction: "ダウンロード直後の PDF を素早く判断できる短い日本語要約にしてください。"
                )
            }
        }
        if monitorEnabled(for: target) {
            guard changedPaths.count <= 12 else {
                let detail = "\(changedPaths.count) 件の変更を検知しました。自動 review は抑止し、Quick Sort を待機します。"
                lastNotice = detail
                appendBackgroundEvent(title: "\(target.rawValue) の大量変更を検知", detail: detail)
                return
            }
            enqueueBackgroundTask { [weak self] in
                await self?.performBackgroundReview(
                    for: target,
                    changedFilesCount: changedPaths.count,
                    sendUserNotification: true
                )
            }
        }
    }

    private func performBackgroundReview(
        for target: ScanTarget,
        changedFilesCount: Int,
        sendUserNotification: Bool
    ) async {
        if backgroundReviewInFlight.contains(target) {
            backgroundReviewPending.insert(target)
            return
        }
        backgroundReviewInFlight.insert(target)
        defer {
            backgroundReviewInFlight.remove(target)
            if backgroundReviewPending.remove(target) != nil {
                Task { @MainActor [weak self] in
                    await self?.performBackgroundReview(
                        for: target,
                        changedFilesCount: 0,
                        sendUserNotification: false
                    )
                }
            }
        }
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
        guard backgroundMonitoringEnabled else {
            return false
        }
        switch target {
        case .downloads:
            return watchDownloadsEnabled
        case .desktop:
            return watchDesktopEnabled
        }
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
                let appliedCount = try applyFinderTags(
                    suggestion.suggested_tags,
                    colorName: suggestion.suggested_tag_color,
                    to: destinationPath
                )
                if appliedCount > 0 {
                    taggedCount += 1
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        return taggedCount
    }

    private func applyFinderTags(_ tags: [String], colorName: String?, to path: String) throws -> Int {
        guard #available(macOS 26.0, *) else {
            return 0
        }
        let cleanedTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let desiredLabelNumber = finderLabelNumber(for: colorName)
        guard !cleanedTags.isEmpty || desiredLabelNumber != nil else {
            return 0
        }
        var url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "DropSort",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "タグ適用先のファイルが見つかりません: \(path)"]
            )
        }
        let resourceValues = try url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
        let existingTags = resourceValues.tagNames ?? []
        let mergedTags = mergedTags(existingTags + cleanedTags)
        let existingLabelNumber = resourceValues.labelNumber
        if mergedTags == existingTags, desiredLabelNumber == nil || desiredLabelNumber == existingLabelNumber {
            return 0
        }
        var values = URLResourceValues()
        if !cleanedTags.isEmpty {
            values.tagNames = mergedTags
        }
        if let desiredLabelNumber {
            values.labelNumber = desiredLabelNumber
        }
        try url.setResourceValues(values)
        return max(mergedTags.count - existingTags.count, desiredLabelNumber == nil || desiredLabelNumber == existingLabelNumber ? 0 : 1)
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

    private func applyStabilityProfileIfNeeded() {
        guard backgroundStabilityProfileVersion < 2 else {
            return
        }
        disableBackgroundMonitoringSettings()
        watcherIntervalSeconds = max(watcherIntervalSeconds, 60)
        clipboardInsightMinimumLength = max(clipboardInsightMinimumLength, 480)
        backgroundStabilityProfileVersion = 2
        lastNotice = "安定運用のため監視は停止しました。かんたん整理と右クリック操作を使ってください。"
    }

    private func disableBackgroundMonitoringSettings() {
        watchDesktopEnabled = false
        watchDownloadsEnabled = false
        watchClipboardEnabled = false
        watchScreenshotsEnabled = false
        watchPDFInboxEnabled = false
    }

    func configurePresentation(for window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.isReleasedWhenClosed = false
    }

    private func enqueueBackgroundTask(_ operation: @escaping @MainActor () async -> Void) {
        let previous = backgroundTaskChain
        backgroundTaskChain = Task { @MainActor in
            _ = await previous?.result
            guard !Task.isCancelled else {
                return
            }
            await operation()
        }
    }

    private func shouldAnalyzeClipboard(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= clipboardInsightMinimumLength else {
            return false
        }
        return !looksLikeShellCommand(cleaned)
    }

    private func looksLikeShellCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let commandPrefixes = [
            "$ ", "% ", "cd ", "ls", "pwd", "git ", "gh ", "swift ", "python ", "python3 ",
            "open ", "brew ", "chmod ", "chown ", "cp ", "mv ", "rm ", "mkdir ", "touch ",
            "export ", "defaults ", "kill ", "pkill ", "./", "/users/", "~/"
        ]
        if commandPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= 4 {
            let shellLikeLines = lines.filter { line in
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !candidate.isEmpty else {
                    return false
                }
                return commandPrefixes.contains(where: { candidate.hasPrefix($0) })
                    || candidate.contains(" % ")
                    || candidate.contains(" command not found")
            }
            if !shellLikeLines.isEmpty {
                return true
            }
        }
        return false
    }

    private func activeBackgroundServices() -> [String] {
        guard backgroundMonitoringEnabled else {
            return []
        }
        var labels: [String] = []
        if watchDesktopEnabled {
            labels.append("Desktop review (FSEvents)")
        }
        if watchDownloadsEnabled {
            labels.append("Downloads review (FSEvents)")
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
        return labels
    }

    private func finderLabelNumber(for colorName: String?) -> Int? {
        switch colorName?.lowercased() {
        case "gray":
            return 1
        case "green":
            return 2
        case "purple":
            return 3
        case "blue":
            return 4
        case "yellow":
            return 5
        case "red":
            return 6
        case "orange":
            return 7
        default:
            return nil
        }
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
