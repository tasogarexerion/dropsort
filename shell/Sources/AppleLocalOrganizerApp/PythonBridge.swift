import Foundation

actor PythonBridge {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func checkEnvironment() async throws -> EnvironmentStatus {
        try await send(RequestEnvelope(type: "CheckEnvironment"), as: EnvironmentStatus.self)
    }

    func summarizeClipboard(style: String, length: String, instruction: String?) async throws -> SummaryResult {
        var payload = ["style": style, "length": length]
        if let instruction, !instruction.isEmpty {
            payload["instruction"] = instruction
        }
        return try await send(RequestEnvelope(type: "SummarizeClipboard", payload: payload), as: SummaryResult.self)
    }

    func summarizeFile(path: String, style: String, length: String, instruction: String?) async throws -> SummaryResult {
        var payload = ["path": path, "style": style, "length": length]
        if let instruction, !instruction.isEmpty {
            payload["instruction"] = instruction
        }
        return try await send(RequestEnvelope(type: "SummarizeFile", payload: payload), as: SummaryResult.self)
    }

    func scanFolder(path: String) async throws -> OrganizerRun {
        try await send(RequestEnvelope(type: "ScanFolder", payload: ["path": path]), as: OrganizerRun.self)
    }

    func applySuggestions(sourceRoot: String, suggestions: [OrganizerSuggestion]) async throws -> OrganizerApplyResult {
        let compact = suggestions.map {
            ["source_path": $0.source_path, "target_folder_name": $0.target_folder_name]
        }
        let data = try encoder.encode(compact)
        guard let suggestionsJSON = String(data: data, encoding: .utf8) else {
            throw BridgeFailure.transport("Failed to encode organizer suggestions.")
        }
        return try await send(
            RequestEnvelope(
                type: "ApplyOrganizerSuggestions",
                payload: [
                    "source_root": sourceRoot,
                    "suggestions_json": suggestionsJSON,
                ]
            ),
            as: OrganizerApplyResult.self
        )
    }

    func listRecentResults() async throws -> RecentResults {
        try await send(RequestEnvelope(type: "ListRecentResults"), as: RecentResults.self)
    }

    private func send<ResultType: Decodable & Sendable>(_ request: RequestEnvelope, as type: ResultType.Type) async throws -> ResultType {
        let data = try encoder.encode(request)
        let runtime = pythonRuntime()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: runtime.executable)
            process.arguments = runtime.arguments + [runnerPath()]
            process.environment = mergedEnvironment()

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { [decoder] task in
                let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if task.terminationStatus != 0 && output.isEmpty {
                    let message = String(data: stderr, encoding: .utf8) ?? "Bridge execution failed."
                    continuation.resume(throwing: BridgeFailure.transport(message))
                    return
                }
                do {
                    let envelope = try decoder.decode(ResponseEnvelope<ResultType>.self, from: output)
                    if envelope.ok, let result = envelope.result {
                        continuation.resume(returning: result)
                    } else {
                        let message = envelope.error?.message ?? "Unknown bridge error."
                        continuation.resume(throwing: BridgeFailure.remote(message))
                    }
                } catch {
                    let message = String(data: output, encoding: .utf8) ?? "Bridge returned invalid JSON."
                    continuation.resume(throwing: BridgeFailure.decoding(message))
                }
            }

            do {
                try process.run()
                stdinPipe.fileHandleForWriting.write(data)
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                continuation.resume(throwing: BridgeFailure.transport(error.localizedDescription))
            }
        }
    }

    private func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let resources = bundledResourceRoot() {
            env["PYTHONHOME"] = resources.appendingPathComponent("python-runtime").path
            env["PYTHONPATH"] = resources.appendingPathComponent("python").path
            env["APPLE_LOCAL_AI_CORE"] = resources.appendingPathComponent("python").path
            env["APPLE_LOCAL_AI_RUNNER"] = resources.appendingPathComponent("bridge_runner.py").path
            env["PYTHONNOUSERSITE"] = "1"
        } else {
            if env["APPLE_LOCAL_AI_CORE"] == nil {
                env["APPLE_LOCAL_AI_CORE"] = repoCoreFallback()
            }
            if env["APPLE_LOCAL_AI_RUNNER"] == nil {
                env["APPLE_LOCAL_AI_RUNNER"] = developmentRunnerPath()
            }
        }
        return env
    }

    private func pythonRuntime() -> (executable: String, arguments: [String]) {
        if let runtime = bundledPythonExecutable() {
            return (runtime, [])
        }
        if let override = ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_PYTHON"], !override.isEmpty {
            return (override, [])
        }
        return ("/usr/bin/env", ["python3"])
    }

    private func runnerPath() -> String {
        if let resources = bundledResourceRoot() {
            return resources.appendingPathComponent("bridge_runner.py").path
        }
        if let override = ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_RUNNER"], !override.isEmpty {
            return override
        }
        if let path = Bundle.module.path(forResource: "bridge_runner", ofType: "py") {
            return path
        }
        return developmentRunnerPath()
    }

    private func repoCoreFallback() -> String {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.deletingLastPathComponent().appendingPathComponent("core/src"),
            cwd.appendingPathComponent("../core/src"),
            cwd.appendingPathComponent("../../core/src"),
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.standardized.path
            }
        }
        return "\(FileManager.default.currentDirectoryPath)/../core/src"
    }

    private func developmentRunnerPath() -> String {
        "\(FileManager.default.currentDirectoryPath)/Sources/AppleLocalOrganizerApp/Resources/bridge_runner.py"
    }

    private func bundledPythonExecutable() -> String? {
        guard let resources = bundledResourceRoot() else {
            return nil
        }
        let candidate = resources.appendingPathComponent("python-runtime/bin/python3").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private func bundledResourceRoot() -> URL? {
        if let resourceURL = Bundle.main.resourceURL {
            let runtime = resourceURL.appendingPathComponent("python-runtime/bin/python3").path
            let core = resourceURL.appendingPathComponent("python").path
            if FileManager.default.isExecutableFile(atPath: runtime),
               FileManager.default.fileExists(atPath: core) {
                return resourceURL
            }
        }
        return nil
    }
}

enum BridgeFailure: LocalizedError {
    case transport(String)
    case remote(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .transport(let message):
            return "Python bridge launch failed: \(message)"
        case .remote(let message):
            return message
        case .decoding(let message):
            return "Bridge response decoding failed: \(message)"
        }
    }
}
