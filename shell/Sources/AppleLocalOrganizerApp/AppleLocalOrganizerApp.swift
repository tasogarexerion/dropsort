import SwiftUI

@main
struct AppleLocalOrganizerApp: App {
    @NSApplicationDelegateAdaptor(AgentAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra("DropSort", systemImage: "sparkles.rectangle.stack") {
            MenuContentView()
                .environmentObject(state)
                .task {
                    await state.bootstrap()
                }
        }
        .menuBarExtraStyle(.window)

        WindowGroup("ダウンロードの整理候補", id: "review-downloads") {
            ReviewView(target: .downloads)
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
                .task {
                    if state.currentRun(for: .downloads) == nil {
                        await state.review(.downloads)
                    }
                }
        }

        WindowGroup("デスクトップの整理候補", id: "review-desktop") {
            ReviewView(target: .desktop)
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
                .task {
                    if state.currentRun(for: .desktop) == nil {
                        await state.review(.desktop)
                    }
                }
        }

        WindowGroup("選択フォルダの整理候補", id: "review-folder") {
            SelectedFolderReviewView()
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
        }

        WindowGroup("既存フォルダ名の日本語化候補", id: "rename-folders") {
            FolderRenameReviewView()
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
        }

        WindowGroup("ファイル名の日本語化候補", id: "rename-files") {
            FileRenameReviewView()
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
        }

        WindowGroup("要確認ファイル", id: "attention-files") {
            AttentionFilesReviewView()
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
        }

        WindowGroup("OCR インデックス", id: "ocr-index") {
            OCRIndexReviewView()
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
        }

        WindowGroup("最近の結果", id: "recent-results") {
            RecentResultsView()
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
                .task {
                    await state.loadRecents()
                }
        }

        WindowGroup("システム状況", id: "system-status") {
            StatusView()
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
                .task {
                    await state.refreshStatus()
                }
        }

        Settings {
            PreferencesView()
                .environmentObject(state)
                .background(WindowAccessor { window in
                    state.configurePresentation(for: window)
                })
        }
    }
}
