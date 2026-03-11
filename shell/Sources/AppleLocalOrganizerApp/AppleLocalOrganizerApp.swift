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

        WindowGroup("Review Downloads", id: "review-downloads") {
            ReviewView(target: .downloads)
                .environmentObject(state)
                .task {
                    if state.currentRun(for: .downloads) == nil {
                        await state.review(.downloads)
                    }
                }
        }

        WindowGroup("Review Desktop", id: "review-desktop") {
            ReviewView(target: .desktop)
                .environmentObject(state)
                .task {
                    if state.currentRun(for: .desktop) == nil {
                        await state.review(.desktop)
                    }
                }
        }

        WindowGroup("Recent Results", id: "recent-results") {
            RecentResultsView()
                .environmentObject(state)
                .task {
                    await state.loadRecents()
                }
        }

        WindowGroup("System Status", id: "system-status") {
            StatusView()
                .environmentObject(state)
                .task {
                    await state.refreshStatus()
                }
        }

        Settings {
            PreferencesView()
                .environmentObject(state)
        }
    }
}
