import Foundation

struct RequestEnvelope: Encodable, Sendable {
    let type: String
    let payload: [String: String]

    init(type: String, payload: [String: String] = [:]) {
        self.type = type
        self.payload = payload
    }
}

struct ResponseEnvelope<ResultType: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let result: ResultType?
    let error: ErrorPayload?
}

struct ErrorPayload: Decodable, Error, Sendable {
    let message: String
}

struct EnvironmentStatus: Codable, Sendable {
    let shell_supported: Bool
    let ai_supported: Bool
    let reason: String
    let os_version: String
}

struct SummaryResult: Codable, Identifiable, Sendable {
    let title: String
    let style: String
    let length: String
    let summary_text: String
    let source_kind: String
    let created_at: String

    var id: String { "\(created_at)-\(title)" }
}

struct OrganizerSuggestion: Codable, Identifiable, Sendable {
    let source_path: String
    let target_folder_name: String
    let is_new_folder: Bool
    let reason_ja: String
    let evidence_summary: String
    let confidence: Double

    var id: String { source_path }
}

struct OrganizerRun: Codable, Identifiable, Sendable {
    let source_root: String
    let started_at: String
    let suggestions: [OrganizerSuggestion]

    var id: String { "\(started_at)-\(source_root)" }
}

struct OrganizerMoveItem: Codable, Identifiable, Sendable {
    let source_path: String
    let destination_path: String?
    let target_folder_name: String
    let status: String
    let message: String

    var id: String { "\(source_path)-\(destination_path ?? status)" }
}

struct OrganizerApplyResult: Codable, Sendable {
    let source_root: String
    let applied_at: String
    let moved_count: Int
    let skipped_count: Int
    let items: [OrganizerMoveItem]
}

struct RecentResults: Codable, Sendable {
    let summaries: [SummaryResult]
    let organizer_runs: [OrganizerRun]
}

enum ScanTarget: String, Sendable {
    case downloads = "Downloads"
    case desktop = "Desktop"

    var defaultPath: String {
        "\(NSHomeDirectory())/\(rawValue)"
    }

    var windowTitle: String {
        switch self {
        case .downloads:
            return "Review Downloads"
        case .desktop:
            return "Review Desktop"
        }
    }
}
