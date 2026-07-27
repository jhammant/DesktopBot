import Foundation

public final class FolderOrganizer: @unchecked Sendable {
    public static let managedDirectoryNames: Set<String> = [
        "archive",
        "documents",
        "generated",
        "images",
        "screenshots"
    ]

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let auditLogURL: URL?

    public init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        auditLogURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DesktopBot/folder-organizer-audit.jsonl")
    ) {
        self.fileManager = fileManager
        self.now = now
        self.auditLogURL = auditLogURL
    }

    public func run(
        root: URL,
        apply: Bool,
        moveDirectories: Bool = true
    ) throws -> FolderOrganizationSummary {
        let plan = try preview(root: root, moveDirectories: moveDirectories)
        return apply ? try self.apply(plan) : plan
    }

    public func preview(
        root: URL,
        moveDirectories: Bool = true
    ) throws -> FolderOrganizationSummary {
        let root = try validatedRoot(root)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var reservedDestinations = Set<String>()
        var items: [FolderOrganizationItem] = []

        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            let name = url.lastPathComponent
            let normalizedName = name.lowercased()

            if values.isSymbolicLink == true {
                items.append(
                    skippedItem(
                        url: url,
                        kind: values.isDirectory == true ? .directory : .file,
                        reason: "symbolic links are never moved"
                    )
                )
                continue
            }
            if values.isDirectory == true,
               Self.managedDirectoryNames.contains(normalizedName) {
                items.append(
                    skippedItem(
                        url: url,
                        kind: .directory,
                        reason: "managed destination directory"
                    )
                )
                continue
            }

            let classification: Classification
            let kind: FolderOrganizationItemKind
            if values.isDirectory == true {
                kind = .directory
                guard moveDirectories else {
                    items.append(
                        skippedItem(url: url, kind: .directory, reason: "directory moves disabled")
                    )
                    continue
                }
                classification = classifyDirectory(name: name)
            } else if values.isRegularFile == true {
                kind = .file
                let date = values.contentModificationDate ?? values.creationDate ?? now()
                classification = classifyFile(url: url, referenceDate: date)
            } else {
                items.append(
                    skippedItem(url: url, kind: .file, reason: "unsupported filesystem item")
                )
                continue
            }

            let proposed = root
                .appendingPathComponent(classification.relativeDirectory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: kind == .directory)
            let destination = uniqueDestination(
                proposed,
                sourceName: name,
                isDirectory: kind == .directory,
                reserved: &reservedDestinations
            )
            items.append(
                FolderOrganizationItem(
                    sourcePath: url.path,
                    destinationPath: destination.path,
                    fileName: name,
                    kind: kind,
                    category: classification.category,
                    decision: .archive,
                    reasons: classification.reasons
                )
            )
        }

        return FolderOrganizationSummary(
            runID: UUID().uuidString,
            startedAt: now(),
            dryRun: true,
            rootDirectory: root.path,
            topLevelItemsBefore: urls.count,
            topLevelItemsAfter: urls.count,
            items: items
        )
    }

    public func apply(
        _ plan: FolderOrganizationSummary
    ) throws -> FolderOrganizationSummary {
        guard plan.dryRun else {
            throw DesktopBotError.commandFailed("Only a dry-run folder plan can be applied.")
        }
        let root = try validatedRoot(URL(fileURLWithPath: plan.rootDirectory))
        var appliedItems = plan.items

        for index in appliedItems.indices where appliedItems[index].decision == .archive {
            guard let destinationPath = appliedItems[index].destinationPath else {
                appliedItems[index].decision = .failed
                appliedItems[index].reasons.append("plan has no destination")
                continue
            }
            let source = URL(fileURLWithPath: appliedItems[index].sourcePath)
            let destination = URL(fileURLWithPath: destinationPath)
            guard isDirectChild(source, of: root), isDescendant(destination, of: root) else {
                appliedItems[index].decision = .failed
                appliedItems[index].reasons.append("path escaped the organized root")
                continue
            }
            guard fileManager.fileExists(atPath: source.path) else {
                appliedItems[index].decision = .failed
                appliedItems[index].reasons.append("source changed or no longer exists")
                continue
            }
            guard !fileManager.fileExists(atPath: destination.path) else {
                appliedItems[index].decision = .failed
                appliedItems[index].reasons.append("destination appeared after preview; refusing overwrite")
                continue
            }

            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                appliedItems[index].decision = .failed
                appliedItems[index].reasons.append("move failed: \(error.localizedDescription)")
            }
        }

        let after = try visibleTopLevelCount(root)
        let summary = FolderOrganizationSummary(
            runID: plan.runID,
            startedAt: plan.startedAt,
            dryRun: false,
            rootDirectory: root.path,
            topLevelItemsBefore: plan.topLevelItemsBefore,
            topLevelItemsAfter: after,
            items: appliedItems
        )
        if let auditLogURL {
            try appendAudit(summary, to: auditLogURL)
        }
        return summary
    }

    private func validatedRoot(_ input: URL) throws -> URL {
        let root = input.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DesktopBotError.sourceDirectoryMissing(root.path)
        }
        let home = fileManager.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard root.path != "/", root.path != home.path else {
            throw DesktopBotError.commandFailed(
                "Refusing to organize a filesystem root or the whole home directory."
            )
        }
        return root
    }

    private func classifyFile(url: URL, referenceDate: Date) -> Classification {
        let name = url.lastPathComponent
        let normalized = name.lowercased()
        let ext = url.pathExtension.lowercased()

        if isScreenshotName(normalized) {
            return Classification(
                relativeDirectory: "Screenshots/\(yearMonth(referenceDate))",
                category: .screenshot,
                reasons: ["screenshot-like filename", "grouped by modification month"]
            )
        }
        if containsAny(normalized, [
            "org_chart", "org-chart", "headcount", "role_context", "role-context"
        ]) {
            return Classification(
                relativeDirectory: "Generated/Org Charts",
                category: .generatedVisual,
                reasons: ["recognised generated organisation visual"]
            )
        }
        if containsAny(normalized, [
            "learnings-architecture", "learning-architecture", "linkedin-post"
        ]) {
            return Classification(
                relativeDirectory: "Generated/Learning Architecture",
                category: .generatedContent,
                reasons: ["recognised generated learning content"]
            )
        }
        if containsAny(normalized, [
            "diagram", "architecture", "wireframe", "mockup", "generated", "debug"
        ]), Self.imageExtensions.contains(ext) {
            return Classification(
                relativeDirectory: "Generated/Visuals",
                category: .generatedVisual,
                reasons: ["generated-visual filename and image type"]
            )
        }
        if Self.configurationExtensions.contains(ext) {
            return Classification(
                relativeDirectory: "Documents/Configuration",
                category: .configuration,
                reasons: ["configuration file extension"]
            )
        }
        if Self.documentExtensions.contains(ext)
            || Self.spreadsheetExtensions.contains(ext)
            || Self.presentationExtensions.contains(ext) {
            if containsAny(normalized, [
                "recipe", "personal", "holiday", "travel", "home", "family"
            ]) {
                return Classification(
                    relativeDirectory: "Documents/Personal",
                    category: .personalDocument,
                    reasons: ["document type and personal filename hint"]
                )
            }
            return Classification(
                relativeDirectory: "Documents/Work",
                category: .workDocument,
                reasons: ["document, spreadsheet, or presentation type"]
            )
        }
        if Self.imageExtensions.contains(ext) {
            return Classification(
                relativeDirectory: "Images/Photos",
                category: .photo,
                reasons: ["image type without screenshot or generated hints"]
            )
        }
        if Self.mediaExtensions.contains(ext) {
            return Classification(
                relativeDirectory: "Images/Media",
                category: .media,
                reasons: ["audio or video type"]
            )
        }
        if Self.archiveExtensions.contains(ext) || Self.installerExtensions.contains(ext) {
            return Classification(
                relativeDirectory: "Archive/Downloads",
                category: .archive,
                reasons: ["archive or installer type"]
            )
        }
        if Self.codeDataExtensions.contains(ext) {
            return Classification(
                relativeDirectory: "Generated/Code & Data",
                category: .codeData,
                reasons: ["source code or structured-data type"]
            )
        }
        return Classification(
            relativeDirectory: "Archive/Other Files",
            category: .other,
            reasons: ["unrecognised loose file preserved in catch-all archive"]
        )
    }

    private func classifyDirectory(name: String) -> Classification {
        let normalized = name.lowercased()
        if normalized.hasPrefix("desktop") || containsAny(normalized, ["old desktop", "desktop backup"]) {
            return Classification(
                relativeDirectory: "Archive/Old Desktop",
                category: .oldDesktop,
                reasons: ["desktop snapshot or backup directory"]
            )
        }
        if containsAny(normalized, [
            "prep", "generated", "output", "export", "render", "build", "draft", "claude"
        ]) {
            return Classification(
                relativeDirectory: "Generated",
                category: .generatedFolder,
                reasons: ["generated or work-in-progress directory hint"]
            )
        }
        return Classification(
            relativeDirectory: "Archive/Folders",
            category: .folder,
            reasons: ["unclassified directory preserved intact"]
        )
    }

    private func skippedItem(
        url: URL,
        kind: FolderOrganizationItemKind,
        reason: String
    ) -> FolderOrganizationItem {
        FolderOrganizationItem(
            sourcePath: url.path,
            destinationPath: nil,
            fileName: url.lastPathComponent,
            kind: kind,
            category: .other,
            decision: .skip,
            reasons: [reason]
        )
    }

    private func uniqueDestination(
        _ proposed: URL,
        sourceName: String,
        isDirectory: Bool,
        reserved: inout Set<String>
    ) -> URL {
        var candidate = proposed
        let sourceURL = URL(fileURLWithPath: sourceName)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = isDirectory ? "" : sourceURL.pathExtension
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path)
            || reserved.contains(candidate.standardizedFileURL.path) {
            let name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = proposed.deletingLastPathComponent()
                .appendingPathComponent(name, isDirectory: isDirectory)
            counter += 1
        }
        reserved.insert(candidate.standardizedFileURL.path)
        return candidate
    }

    private func visibleTopLevelCount(_ root: URL) throws -> Int {
        try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isHiddenKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).count
    }

    private func appendAudit(_ summary: FolderOrganizationSummary, to url: URL) throws {
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

    private func isDirectChild(_ url: URL, of root: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(rootPath + "/")
    }

    private func isScreenshotName(_ normalized: String) -> Bool {
        containsAny(normalized, [
            "screenshot",
            "screen shot",
            "cleanshot",
            "shottr",
            "xnapper"
        ])
    }

    private func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private func yearMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private struct Classification {
        let relativeDirectory: String
        let category: FolderOrganizationCategory
        let reasons: [String]
    }

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "rtf", "txt", "md", "pages", "epub"
    ]
    private static let spreadsheetExtensions: Set<String> = [
        "xls", "xlsx", "csv", "tsv", "numbers"
    ]
    private static let presentationExtensions: Set<String> = [
        "ppt", "pptx", "key"
    ]
    private static let configurationExtensions: Set<String> = [
        "conf", "config", "ini", "plist", "env"
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "gif", "webp", "svg", "tiff", "bmp"
    ]
    private static let mediaExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "ogg", "mp4", "mov", "m4v", "avi", "mkv", "webm"
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar"
    ]
    private static let installerExtensions: Set<String> = [
        "dmg", "pkg", "iso"
    ]
    private static let codeDataExtensions: Set<String> = [
        "swift", "py", "js", "jsx", "ts", "tsx", "go", "rs", "rb", "php",
        "java", "kt", "kts", "c", "h", "cpp", "hpp", "cs", "sh", "zsh",
        "fish", "html", "css", "scss", "vue", "svelte", "json", "jsonl",
        "yaml", "yml", "toml", "xml", "sql", "sqlite", "db", "log"
    ]
}
