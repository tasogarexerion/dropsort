import AppKit
import Foundation

@MainActor
final class AgentAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Task { @MainActor in
            await AppState.shared.handleOpenedFiles(filenames)
        }
        sender.reply(toOpenOrPrint: .success)
    }
}
