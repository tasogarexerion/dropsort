import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DropSort")
                .font(.headline)

            statusBlock

            Text(state.backgroundServiceStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("クリップボードを要約") {
                Task { await state.summarizeClipboard() }
            }
            .disabled(!state.environmentStatus.ai_supported || state.isBusy)

            Button("ファイルを要約") {
                Task { await state.summarizeFile() }
            }
            .disabled(!state.environmentStatus.ai_supported || state.isBusy)

            Button("ファイルから文字をコピー") {
                Task { await state.copyExtractedTextFromFile() }
            }
            .disabled(!state.environmentStatus.ai_supported || state.isBusy)

            Divider()

            Button("ダウンロードをかんたん整理") {
                Task { await state.quickSort(.downloads) }
            }
            .disabled(state.isBusy)

            Button("デスクトップをかんたん整理") {
                Task { await state.quickSort(.desktop) }
            }
            .disabled(state.isBusy)

            Divider()

            Button("ダウンロードを確認") {
                state.presentWindow(
                    id: "review-downloads",
                    title: ScanTarget.downloads.windowTitle,
                    openWindow: openWindow
                ) {
                    await state.review(.downloads)
                }
            }

            Button("デスクトップを確認") {
                state.presentWindow(
                    id: "review-desktop",
                    title: ScanTarget.desktop.windowTitle,
                    openWindow: openWindow
                ) {
                    await state.review(.desktop)
                }
            }

            Button("最近の結果") {
                state.presentWindow(
                    id: "recent-results",
                    title: "最近の結果",
                    openWindow: openWindow
                )
            }

            Button("システム状況") {
                state.presentWindow(
                    id: "system-status",
                    title: "システム状況",
                    openWindow: openWindow
                )
            }

            SettingsLink {
                Text("設定")
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

            if !state.backgroundEvents.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("直近の処理")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(state.backgroundEvents.prefix(3))) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.footnote.weight(.semibold))
                            Text(event.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.environmentStatus.ai_supported ? "AI 利用可能" : "互換モード")
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
                Button("すべて移動") {
                    Task { await state.applyAllSuggestions(for: target) }
                }
                .disabled(run?.suggestions.isEmpty ?? true || state.isBusy)
                Button("再読み込み") {
                    Task { await state.review(target) }
                }
            }

            Text("提案先フォルダへ実際に移動するには `すべて移動` または各行の `今すぐ移動` を使います。")
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
                ContentUnavailableView("まだ整理候補を読み込んでいません", systemImage: "folder.badge.questionmark")
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
                Text(priorityText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(priorityColor)
                Text("\(Int(suggestion.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("提案先: \(suggestion.target_folder_name)\(suggestion.is_new_folder ? " (新規)" : "")")
                .font(.subheadline)
            Text(suggestion.reason_ja)
                .font(.body)
            Text(suggestion.evidence_summary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !suggestion.suggested_tags.isEmpty {
                HStack(spacing: 8) {
                    Text("タグ候補: \(suggestion.suggested_tags.joined(separator: ", "))")
                        .font(.footnote)
                    if let colorName = suggestion.suggested_tag_color {
                        Label(tagColorLabel(for: colorName), systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(finderColor(for: colorName))
                    }
                }
            }

            HStack {
                Button("今すぐ移動") {
                    Task { await state.applySuggestion(suggestion, for: target) }
                }
                .disabled(state.isBusy)
                Button("Finderで開く") {
                    state.revealInFinder(path: suggestion.source_path)
                }
                Button("フォルダ名をコピー") {
                    state.copy(suggestion.target_folder_name)
                }
                Button("理由をコピー") {
                    state.copy(suggestion.reason_ja)
                }
                if !suggestion.suggested_tags.isEmpty {
                    Button("タグを適用") {
                        Task { await state.applySuggestedTags(suggestion) }
                    }
                    Button("タグをコピー") {
                        state.copy(suggestion.suggested_tags.joined(separator: ", "))
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }

    private var priorityText: String {
            switch suggestion.priority {
        case 1:
            return "高"
        case 2:
            return "中"
        default:
            return "低"
        }
    }

    private var priorityColor: Color {
        switch suggestion.priority {
        case 1:
            return .red
        case 2:
            return .orange
        default:
            return .secondary
        }
    }

    private func finderColor(for colorName: String) -> Color {
        switch colorName.lowercased() {
        case "gray":
            return .gray
        case "green":
            return .green
        case "purple":
            return .purple
        case "blue":
            return .blue
        case "yellow":
            return .yellow
        case "red":
            return .red
        case "orange":
            return .orange
        default:
            return .secondary
        }
    }

    private func tagColorLabel(for colorName: String) -> String {
        switch colorName.lowercased() {
        case "gray":
            return "グレー"
        case "green":
            return "グリーン"
        case "purple":
            return "パープル"
        case "blue":
            return "ブルー"
        case "yellow":
            return "イエロー"
        case "red":
            return "レッド"
        case "orange":
            return "オレンジ"
        default:
            return colorName
        }
    }
}

struct RecentResultsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("最近の要約") {
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

                GroupBox("最近の整理結果") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.recentResults.organizer_runs) { run in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.source_root)
                                    .font(.headline)
                                Text("候補 \(run.suggestions.count) 件")
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
            Text("システム状況")
                .font(.title2.bold())
            LabeledContent("OS", value: state.environmentStatus.os_version)
            LabeledContent("シェル", value: state.environmentStatus.shell_supported ? "対応" : "非対応")
            LabeledContent("AI", value: state.environmentStatus.ai_supported ? "有効" : "無効")
            Text(state.backgroundServiceStatusText)
                .foregroundStyle(.secondary)
            Text(state.environmentStatus.reason)
                .foregroundStyle(.secondary)
            if !state.backgroundEvents.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("直近の処理")
                        .font(.headline)
                    ForEach(Array(state.backgroundEvents.prefix(5))) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.subheadline.weight(.semibold))
                            Text(event.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
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
            Section("要約の既定値") {
                Picker("スタイル", selection: $state.defaultStyle) {
                    Text("標準").tag("plain")
                    Text("箇条書き").tag("bullets")
                    Text("アクションのみ").tag("action-items")
                    Text("タイトル付き").tag("title-and-summary")
                }
                Picker("長さ", selection: $state.defaultLength) {
                    Text("短め").tag("short")
                    Text("標準").tag("medium")
                    Text("長め").tag("long")
                }
                TextField("追加の指示", text: $state.extraInstruction, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section("バックグラウンド") {
                Text("現在の preview では安定運用を優先し、常駐監視を停止しています。Quick Sort と右クリック操作を主導線にしています。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("デスクトップ監視", isOn: $state.watchDesktopEnabled)
                    .disabled(true)
                Toggle("ダウンロード監視", isOn: $state.watchDownloadsEnabled)
                    .disabled(true)
                Toggle("スクリーンショット要約", isOn: $state.watchScreenshotsEnabled)
                    .disabled(true)
                Toggle("PDF受信箱監視", isOn: $state.watchPDFInboxEnabled)
                    .disabled(true)
                Toggle("クリップボード要約", isOn: $state.watchClipboardEnabled)
                    .disabled(true)
                Toggle("通知", isOn: $state.backgroundNotificationsEnabled)
                    .disabled(true)
                Toggle("移動時にタグを自動適用", isOn: $state.autoApplySuggestedTagsOnMove)
                Stepper("クリップボード確認間隔: \(state.watcherIntervalSeconds)秒", value: $state.watcherIntervalSeconds, in: 10...300, step: 5)
                    .disabled(true)
                Stepper(
                    "クリップボード最小文字数: \(state.clipboardInsightMinimumLength)",
                    value: $state.clipboardInsightMinimumLength,
                    in: 80...2000,
                    step: 40
                )
                .disabled(true)
                Text(state.backgroundServiceStatusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("AI が使えない環境では互換モードで動作します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onChange(of: state.backgroundSettingsSignature) { _, _ in
            Task { await state.configureBackgroundServices() }
        }
        .padding()
        .frame(width: 460)
    }
}
