import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @AppStorage("defaultStyle") var defaultStyle = "bullets"
    @AppStorage("defaultLength") var defaultLength = "short"
    @AppStorage("extraInstruction") var extraInstruction = ""

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

    private let bridge = PythonBridge()

    func bootstrap() async {
        await refreshStatus()
        await loadRecents()
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
        await runBusyTask { [self] in
            let result = try await self.bridge.summarizeFile(
                path: url.path,
                style: self.defaultStyle,
                length: self.defaultLength,
                instruction: self.nonEmptyInstruction()
            )
            self.latestSummary = result
            await self.loadRecents()
        }
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
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
    }

    func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func nonEmptyInstruction() -> String? {
        extraInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : extraInstruction
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
            self.lastNotice = notice(for: result)
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

    private func notice(for result: OrganizerApplyResult) -> String {
        if result.skipped_count == 0 {
            return "\(result.moved_count) 件を移動しました。"
        }
        return "\(result.moved_count) 件を移動、\(result.skipped_count) 件をスキップしました。"
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
