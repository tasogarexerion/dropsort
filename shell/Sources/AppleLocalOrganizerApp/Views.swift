import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Local Organizer")
                .font(.headline)

            statusBlock

            Button("Summarize Clipboard") {
                Task { await state.summarizeClipboard() }
            }
            .disabled(!state.environmentStatus.ai_supported || state.isBusy)

            Button("Summarize File") {
                Task { await state.summarizeFile() }
            }
            .disabled(!state.environmentStatus.ai_supported || state.isBusy)

            Divider()

            Button("Review Downloads") {
                openWindow(id: "review-downloads")
                Task { await state.review(.downloads) }
            }

            Button("Review Desktop") {
                openWindow(id: "review-desktop")
                Task { await state.review(.desktop) }
            }

            Button("Recent Results") {
                openWindow(id: "recent-results")
            }

            Button("System Status") {
                openWindow(id: "system-status")
            }

            SettingsLink {
                Text("Preferences")
            }

            if let latestSummary = state.latestSummary {
                Divider()
                Text(latestSummary.title)
                    .font(.subheadline.bold())
                Text(latestSummary.summary_text)
                    .font(.footnote)
                    .lineLimit(5)
            }

            if let lastError = state.lastError {
                Divider()
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let lastNotice = state.lastNotice {
                Divider()
                Text(lastNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.environmentStatus.ai_supported ? "AI Ready" : "Compatibility Mode")
                .font(.subheadline.weight(.semibold))
            Text(state.environmentStatus.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct ReviewView: View {
    let target: ScanTarget
    @EnvironmentObject private var state: AppState

    var body: some View {
        let run = state.currentRun(for: target)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(target.windowTitle)
                    .font(.title2.bold())
                Spacer()
                Button("Apply All") {
                    Task { await state.applyAllSuggestions(for: target) }
                }
                .disabled(run?.suggestions.isEmpty ?? true || state.isBusy)
                Button("Refresh") {
                    Task { await state.review(target) }
                }
            }

            Text("提案先フォルダへ実際に移動するには `Apply All` または各行の `Move Now` を使います。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let run {
                Text(run.started_at)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                List(run.suggestions) { suggestion in
                    SuggestionRow(target: target, suggestion: suggestion)
                }
            } else {
                ContentUnavailableView("No review yet", systemImage: "folder.badge.questionmark")
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 420)
    }
}

struct SuggestionRow: View {
    let target: ScanTarget
    let suggestion: OrganizerSuggestion
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(URL(fileURLWithPath: suggestion.source_path).lastPathComponent)
                    .font(.headline)
                Spacer()
                Text("\(Int(suggestion.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("提案先: \(suggestion.target_folder_name)\(suggestion.is_new_folder ? " (new)" : "")")
                .font(.subheadline)
            Text(suggestion.reason_ja)
                .font(.body)
            Text(suggestion.evidence_summary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Move Now") {
                    Task { await state.applySuggestion(suggestion, for: target) }
                }
                .disabled(state.isBusy)
                Button("Open in Finder") {
                    state.revealInFinder(path: suggestion.source_path)
                }
                Button("Copy Folder Name") {
                    state.copy(suggestion.target_folder_name)
                }
                Button("Copy Reason") {
                    state.copy(suggestion.reason_ja)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }
}

struct RecentResultsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Recent Summaries") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.recentResults.summaries) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.summary_text)
                                    .font(.body)
                                Text("\(item.source_kind) • \(item.created_at)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                GroupBox("Recent Organizer Runs") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.recentResults.organizer_runs) { run in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.source_root)
                                    .font(.headline)
                                Text("\(run.suggestions.count) suggestions")
                                    .font(.body)
                                Text(run.started_at)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 520)
    }
}

struct StatusView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Status")
                .font(.title2.bold())
            LabeledContent("OS", value: state.environmentStatus.os_version)
            LabeledContent("Shell", value: state.environmentStatus.shell_supported ? "Supported" : "Unsupported")
            LabeledContent("AI", value: state.environmentStatus.ai_supported ? "Enabled" : "Disabled")
            Text(state.environmentStatus.reason)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(minWidth: 420, minHeight: 220)
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Picker("Default Style", selection: $state.defaultStyle) {
                Text("plain").tag("plain")
                Text("bullets").tag("bullets")
                Text("action-items").tag("action-items")
                Text("title-and-summary").tag("title-and-summary")
            }
            Picker("Default Length", selection: $state.defaultLength) {
                Text("short").tag("short")
                Text("medium").tag("medium")
                Text("long").tag("long")
            }
            TextField("Additional Instruction", text: $state.extraInstruction, axis: .vertical)
                .lineLimit(3...6)
            Text("AI が使えない環境では互換シェルとして動作します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 420)
    }
}
