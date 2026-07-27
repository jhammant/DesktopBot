import Foundation

public final class DesktopFileOrganizer: @unchecked Sendable {
    private let configuration: Configuration
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let auditLogURL: URL?

    public init(
        configuration: Configuration,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        auditLogURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DesktopBot/other-files-audit.jsonl")
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.now = now
        self.auditLogURL = auditLogURL
    }

    public func run(apply: Bool) throws -> OtherFilesRunSummary? {
        let policy = configuration.otherFiles ?? .default
        guard policy.enabled else {
            return nil
        }
        let source = configuration.sourceURL()
        let archive = configuration.otherFilesArchiveURL()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let screenshotDetector = ScreenshotDetector(configuration: configuration)
        let referenceDate = now()
        var analyses: [DesktopFileAnalysis] = []

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.isHidden != true,
                  !screenshotDetector.isScreenshot(url) else {
                continue
            }

            let modifiedAt = values.contentModificationDate ?? .distantPast
            let createdAt = values.creationDate ?? modifiedAt
            let lastTouched = max(createdAt, modifiedAt)
            let ageDays = max(
                0,
                Calendar.current.dateComponents(
                    [.day],
                    from: lastTouched,
                    to: referenceDate
                ).day ?? 0
            )
            let category = Self.category(forExtension: url.pathExtension.lowercased())
            var analysis = DesktopFileAnalysis(
                sourcePath: url.path,
                destinationPath: nil,
                fileName: url.lastPathComponent,
                ageDays: ageDays,
                category: category,
                decision: ageDays >= policy.minimumAgeDays ? .archive : .keep,
                reasons: ageDays >= policy.minimumAgeDays
                    ? [
                        "loose Desktop file is at least \(policy.minimumAgeDays)d old",
                        "classified by extension as \(category.rawValue)"
                    ]
                    : ["newer than \(policy.minimumAgeDays)d"]
            )

            if analysis.decision == .archive {
                let destination = uniqueDestination(
                    for: url,
                    category: category,
                    archiveRoot: archive,
                    referenceDate: createdAt
                )
                analysis.destinationPath = destination.path
                if apply {
                    do {
                        try fileManager.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.moveItem(at: url, to: destination)
                    } catch {
                        analysis.decision = .failed
                        analysis.reasons.append("move failed: \(error.localizedDescription)")
                    }
                }
            }
            analyses.append(analysis)
        }

        let summary = OtherFilesRunSummary(
            dryRun: !apply,
            sourceDirectory: source.path,
            archiveDirectory: archive.path,
            analyses: analyses
        )
        if apply, let auditLogURL {
            try appendAudit(summary, to: auditLogURL)
        }
        return summary
    }

    private func uniqueDestination(
        for source: URL,
        category: DesktopFileCategory,
        archiveRoot: URL,
        referenceDate: Date
    ) -> URL {
        let calendar = Calendar.current
        let directory = archiveRoot
            .appendingPathComponent(String(calendar.component(.year, from: referenceDate)))
            .appendingPathComponent(
                String(format: "%02d", calendar.component(.month, from: referenceDate))
            )
            .appendingPathComponent(category.rawValue)
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    private func appendAudit(_ summary: OtherFilesRunSummary, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(summary)
        data.append(0x0A)
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    public static func category(forExtension ext: String) -> DesktopFileCategory {
        switch ext {
        case "pdf", "doc", "docx", "rtf", "txt", "md", "pages", "epub":
            return .documents
        case "xls", "xlsx", "csv", "tsv", "numbers":
            return .spreadsheets
        case "ppt", "pptx", "key":
            return .presentations
        case "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar":
            return .archives
        case "dmg", "pkg", "iso":
            return .installers
        case "swift", "py", "js", "jsx", "ts", "tsx", "go", "rs", "rb", "php",
             "java", "kt", "kts", "c", "h", "cpp", "hpp", "cs", "sh", "zsh",
             "fish", "html", "css", "scss", "vue", "svelte":
            return .code
        case "json", "jsonl", "yaml", "yml", "toml", "xml", "sql", "sqlite",
             "db", "log":
            return .data
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "svg", "tiff", "bmp":
            return .images
        case "mp3", "wav", "m4a", "aac", "flac", "ogg":
            return .audio
        case "mp4", "mov", "m4v", "avi", "mkv", "webm":
            return .video
        case "otf", "ttf", "woff", "woff2":
            return .fonts
        case "webloc", "url":
            return .links
        default:
            return .other
        }
    }
}
