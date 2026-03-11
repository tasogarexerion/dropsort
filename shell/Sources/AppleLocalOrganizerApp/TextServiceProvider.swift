import AppKit
import Foundation

final class TextServiceProvider: NSObject {
    private final class ServiceResultBox: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SummaryResult?
        var extractedResults: [ExtractedTextResult] = []
        var errorMessage: String?
    }

    private let bridge = PythonBridge()

    @objc(summarizeSelectedText:userData:error:)
    func summarizeSelectedText(
        _ pasteboard: NSPasteboard,
        userData _: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        guard let selectedText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !selectedText.isEmpty else {
            error?.pointee = "選択テキストがありません。" as NSString
            return
        }

        let defaults = UserDefaults.standard
        let style = defaults.string(forKey: "defaultStyle") ?? "bullets"
        let length = defaults.string(forKey: "defaultLength") ?? "short"
        let instruction = defaults.string(forKey: "extraInstruction")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstruction = instruction?.isEmpty == false ? instruction : nil

        let box = ServiceResultBox()

        // macOS Services expects a synchronous result on the service pasteboard.
        Task.detached(priority: .userInitiated) { [bridge] in
            defer { box.semaphore.signal() }
            do {
                box.result = try await bridge.summarizeText(
                    text: selectedText,
                    style: style,
                    length: length,
                    instruction: normalizedInstruction
                )
            } catch {
                box.errorMessage = error.localizedDescription
            }
        }

        box.semaphore.wait()

        guard let result = box.result else {
            error?.pointee = (box.errorMessage ?? "選択テキストの要約に失敗しました。") as NSString
            return
        }

        pasteboard.clearContents()
        pasteboard.setString(result.summary_text, forType: .string)

        Task { @MainActor in
            await AppState.shared.recordServiceSummary(result)
        }
    }

    @objc(summarizeSelectedFiles:userData:error:)
    func summarizeSelectedFiles(
        _ pasteboard: NSPasteboard,
        userData _: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let files = filePaths(from: pasteboard)
        guard !files.isEmpty else {
            error?.pointee = "選択されたファイルがありません。" as NSString
            return
        }

        let defaults = UserDefaults.standard
        let style = defaults.string(forKey: "defaultStyle") ?? "bullets"
        let length = defaults.string(forKey: "defaultLength") ?? "short"
        let instruction = defaults.string(forKey: "extraInstruction")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstruction = instruction?.isEmpty == false ? instruction : nil

        let box = ServiceResultBox()

        Task.detached(priority: .userInitiated) { [bridge] in
            defer { box.semaphore.signal() }
            do {
                var latest: SummaryResult?
                var summaries: [String] = []
                for path in files {
                    let result = try await bridge.summarizeFile(
                        path: path,
                        style: style,
                        length: length,
                        instruction: normalizedInstruction
                    )
                    latest = result
                    let title = URL(fileURLWithPath: path).lastPathComponent
                    summaries.append("## \(title)\n\(result.summary_text)")
                }
                guard let latest else {
                    box.errorMessage = "要約対象のファイルがありませんでした。"
                    return
                }
                box.result = SummaryResult(
                    title: latest.title,
                    style: latest.style,
                    length: latest.length,
                    summary_text: summaries.joined(separator: "\n\n"),
                    source_kind: latest.source_kind,
                    created_at: latest.created_at
                )
            } catch {
                box.errorMessage = error.localizedDescription
            }
        }

        box.semaphore.wait()

        guard let result = box.result else {
            error?.pointee = (box.errorMessage ?? "ファイルの要約に失敗しました。") as NSString
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.summary_text, forType: .string)
        Task { @MainActor in
            await AppState.shared.recordServiceSummary(result)
        }
    }

    @objc(copyExtractedTextFromFiles:userData:error:)
    func copyExtractedTextFromFiles(
        _ pasteboard: NSPasteboard,
        userData _: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let files = filePaths(from: pasteboard)
        guard !files.isEmpty else {
            error?.pointee = "選択されたファイルがありません。" as NSString
            return
        }

        let box = ServiceResultBox()

        Task.detached(priority: .userInitiated) { [bridge] in
            defer { box.semaphore.signal() }
            do {
                var results: [ExtractedTextResult] = []
                for path in files {
                    results.append(try await bridge.extractFileText(path: path))
                }
                box.extractedResults = results
            } catch {
                box.errorMessage = error.localizedDescription
            }
        }

        box.semaphore.wait()

        guard box.errorMessage == nil else {
            error?.pointee = (box.errorMessage ?? "OCR テキスト抽出に失敗しました。") as NSString
            return
        }

        let extractedBlocks = box.extractedResults.compactMap { item -> String? in
            let text = item.extracted_text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            return "# \(item.title)\n\(text)"
        }
        guard !extractedBlocks.isEmpty else {
            error?.pointee = "抽出できるテキストが見つかりませんでした。" as NSString
            return
        }

        let combined = extractedBlocks.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)

        if let first = box.extractedResults.first {
            Task { @MainActor in
                AppState.shared.recordExtractedTextCopy(first, copiedText: combined)
            }
        }
    }

    private func filePaths(from pasteboard: NSPasteboard) -> [String] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        let legacyType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: legacyType) as? [String], !paths.isEmpty {
            return paths
        }
        if let fileURLString = pasteboard.string(forType: .fileURL),
           let url = URL(string: fileURLString), url.isFileURL {
            return [url.path]
        }
        return []
    }
}
