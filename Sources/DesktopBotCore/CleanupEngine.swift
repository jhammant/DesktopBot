import CryptoKit
import Foundation

public final class CleanupEngine: @unchecked Sendable {
    private let configuration: Configuration
    private let fileManager: FileManager
    private let textRecognizer: any TextRecognizing
    private let now: @Sendable () -> Date
    private let auditLogURL: URL?

    public init(
        configuration: Configuration,
        fileManager: FileManager = .default,
        textRecognizer: any TextRecognizing = VisionTextRecognizer(),
        now: @escaping @Sendable () -> Date = Date.init,
        auditLogURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DesktopBot/audit.jsonl")
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.textRecognizer = textRecognizer
        self.now = now
        self.auditLogURL = auditLogURL
    }

    public func run(apply: Bool) throws -> RunSummary {
        let startedAt = now()
        let source = configuration.sourceURL()
        let archive = configuration.archiveURL()
        let detector = ScreenshotDetector(configuration: configuration)
        let rules = ScreenshotRules(configuration: configuration)
        let files = try detector.files(in: source)
            .sorted { $0.createdAt > $1.createdAt }
        let duplicatePaths = exactDuplicatePaths(in: files)
        var remainingOCR = configuration.maxOCRImagesPerRun
        var analyses: [ScreenshotAnalysis] = []

        for file in files {
            let ageDays = max(
                0,
                Calendar.current.dateComponents([.day], from: file.createdAt, to: startedAt).day ?? 0
            )
            let shouldAttemptOCR = configuration.performOCR
                && remainingOCR > 0
                && (
                    ageDays >= configuration.minimumAgeDays
                    || duplicatePaths.contains(file.url.path)
                )
            var recognizedText: String?
            var ocrFailure: String?
            if shouldAttemptOCR {
                remainingOCR -= 1
                do {
                    recognizedText = try textRecognizer.recognizeText(in: file.url)
                } catch {
                    ocrFailure = error.localizedDescription
                }
            }

            var analysis = rules.analyze(
                file: file,
                now: startedAt,
                recognizedText: recognizedText,
                isExactDuplicate: duplicatePaths.contains(file.url.path)
            )
            if let ocrFailure {
                analysis.reasons.append("OCR failed: \(ocrFailure)")
            } else if configuration.performOCR && !shouldAttemptOCR
                        && ageDays >= configuration.minimumAgeDays {
                analysis.reasons.append("OCR run limit reached")
            }

            if analysis.decision == .archive {
                let destination = uniqueDestination(
                    for: file,
                    category: analysis.category,
                    importance: analysis.importance,
                    recognizedText: recognizedText,
                    archiveRoot: archive,
                    referenceDate: file.createdAt
                )
                analysis.destinationPath = destination.path

                if apply {
                    do {
                        try fileManager.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.moveItem(at: file.url, to: destination)
                    } catch {
                        analysis.decision = .failed
                        analysis.reasons.append("move failed: \(error.localizedDescription)")
                    }
                }
            }
            analyses.append(analysis)
        }

        let summary = RunSummary(
            runID: UUID().uuidString.lowercased(),
            startedAt: startedAt,
            dryRun: !apply,
            sourceDirectory: source.path,
            archiveDirectory: archive.path,
            analyses: analyses
        )

        if apply, auditLogURL != nil {
            try appendAudit(summary)
        }
        return summary
    }

    private func exactDuplicatePaths(in files: [ScreenshotFile]) -> Set<String> {
        var newestByDigest: [String: ScreenshotFile] = [:]
        var duplicates = Set<String>()

        for file in files {
            guard let digest = try? sha256(of: file.url) else { continue }
            if let newest = newestByDigest[digest] {
                if file.createdAt <= newest.createdAt {
                    duplicates.insert(file.url.path)
                } else {
                    duplicates.insert(newest.url.path)
                    newestByDigest[digest] = file
                }
            } else {
                newestByDigest[digest] = file
            }
        }
        return duplicates
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func uniqueDestination(
        for file: ScreenshotFile,
        category: ScreenshotCategory,
        importance: ScreenshotImportance,
        recognizedText: String?,
        archiveRoot: URL,
        referenceDate: Date
    ) -> URL {
        let directory = ScreenshotArchiveNaming.directory(
            archiveRoot: archiveRoot,
            referenceDate: referenceDate,
            category: category,
            importance: importance,
            groupByImportance: configuration.groupScreenshotsByImportance ?? true
        )
        let name = ScreenshotArchiveNaming.fileName(
            source: file.url,
            referenceDate: referenceDate,
            category: category,
            importance: importance,
            recognizedText: recognizedText,
            rename: configuration.renameArchivedScreenshots ?? true
        )
        let original = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let desired = URL(fileURLWithPath: name)
        let stem = desired.deletingPathExtension().lastPathComponent
        let ext = desired.pathExtension
        var counter = 2
        while true {
            let suffix = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            let candidate = directory.appendingPathComponent(suffix)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func appendAudit(_ summary: RunSummary) throws {
        guard let logURL = auditLogURL else { return }
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(summary)
        data.append(0x0A)

        if !fileManager.fileExists(atPath: logURL.path) {
            try data.write(to: logURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }
}
