import Foundation
import PDFKit

public enum MachineFileKind: String, Codable, Sendable {
    case file
    case directory
}

public struct MachineFileRecord: Codable, Sendable {
    public let path: String
    public let name: String
    public let fileExtension: String
    public let kind: MachineFileKind
    public let typeDescription: String?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let size: Int64?
}

public struct FileInventoryEntry: Codable, Sendable {
    public let directory: String
    public let indexedItemCount: Int
}

public struct FileTextExcerpt: Codable, Sendable {
    public let path: String
    public let query: String?
    public let excerpts: [String]
    public let extractedCharacterCount: Int
    public let returnedCharacterCount: Int
    public let truncated: Bool
}

public final class MachineFileIndex: @unchecked Sendable {
    private let fileManager: FileManager
    private let home: URL
    private let allowedRoots: [URL]
    private let priorityDirectories: [URL]
    private let allowTextExcerpts: Bool
    private let maximumExcerptCharacters: Int

    public init(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowedRoots: [URL]? = nil,
        priorityDirectories: [URL] = [],
        allowTextExcerpts: Bool = true,
        maximumExcerptCharacters: Int = 12_000
    ) {
        self.fileManager = fileManager
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.allowedRoots = (allowedRoots ?? [home]).map {
            $0.resolvingSymlinksInPath().standardizedFileURL
        }
        self.priorityDirectories = priorityDirectories.map {
            $0.resolvingSymlinksInPath().standardizedFileURL
        }
        self.allowTextExcerpts = allowTextExcerpts
        self.maximumExcerptCharacters = maximumExcerptCharacters
    }

    public func search(
        query: String,
        nameOnly: Bool = false,
        scope: String? = nil,
        limit: Int = 30,
        includeLibrary: Bool = false,
        kind: MachineFileKind? = nil
    ) throws -> [MachineFileRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DesktopBotError.commandFailed("Search query cannot be empty.")
        }
        let searchRoots: [URL]
        if let scope {
            searchRoots = [try allowedURL(scope, mustBeDirectory: true)]
        } else {
            let priorities = priorityDirectories.filter {
                var isDirectory: ObjCBool = false
                return isAllowed($0)
                    && fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            let broadRoots = allowedRoots.filter {
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            var seenRoots = Set<String>()
            searchRoots = (priorities + broadRoots).filter {
                seenRoots.insert($0.path).inserted
            }
        }
        guard !searchRoots.isEmpty else {
            throw DesktopBotError.commandFailed("None of the configured file-search roots are mounted.")
        }
        let safeLimit = min(max(limit, 1), 100)
        let candidateLimit = min(max(safeLimit * 8, 100), 800)
        var paths: [String] = []
        for searchRoot in searchRoots {
            if isPriority(searchRoot) {
                if nameOnly {
                    paths.append(
                        contentsOf: fallbackNameSearch(
                            query: trimmed,
                            root: searchRoot,
                            limit: candidateLimit
                        )
                    )
                } else {
                    paths.append(
                        contentsOf: fallbackContentSearch(
                            query: trimmed,
                            root: searchRoot,
                            limit: candidateLimit
                        )
                    )
                }
            }
            var arguments = ["-0", "-onlyin", searchRoot.path]
            if nameOnly {
                arguments.append(contentsOf: ["-name", trimmed])
            } else {
                arguments.append(trimmed)
            }
            let spotlightPaths = try runMDFind(
                arguments: arguments,
                limit: candidateLimit
            )
            paths.append(contentsOf: spotlightPaths)
            if nameOnly, spotlightPaths.isEmpty, searchRoot != home {
                paths.append(
                    contentsOf: fallbackNameSearch(
                        query: trimmed,
                        root: searchRoot,
                        limit: candidateLimit
                    )
                )
            }
        }
        var seen = Set<String>()
        var rankedRecords: [(record: MachineFileRecord, score: Int)] = []
        for (resultRank, path) in paths.enumerated() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard isAllowed(url), seen.insert(url.path).inserted else { continue }
            if !includeLibrary, isLibraryOrHidden(url) { continue }
            guard let record = try? metadata(for: url) else { continue }
            if let kind, record.kind != kind { continue }
            var score = -resultRank
            if isPriority(url) { score += 100_000 }
            if record.name.localizedCaseInsensitiveContains(trimmed) {
                score += 10_000
            }
            rankedRecords.append((record, score))
        }
        return rankedRecords
            .sorted {
                if $0.score == $1.score {
                    return ($0.record.modifiedAt ?? .distantPast)
                        > ($1.record.modifiedAt ?? .distantPast)
                }
                return $0.score > $1.score
            }
            .prefix(safeLimit)
            .map(\.record)
    }

    public func info(paths: [String]) throws -> [MachineFileRecord] {
        guard !paths.isEmpty, paths.count <= 20 else {
            throw DesktopBotError.commandFailed("Provide between 1 and 20 paths.")
        }
        return try paths.map {
            try metadata(for: allowedURL($0, mustBeDirectory: false))
        }
    }

    public func inventory() throws -> [FileInventoryEntry] {
        let relativeDirectories = [
            "Desktop",
            "Documents",
            "Downloads",
            "Pictures",
            "Movies",
            "Music",
            "Developer",
            "dev"
        ]
        var directories = relativeDirectories.map {
            home.appendingPathComponent($0, isDirectory: true)
        }
        directories.append(contentsOf: allowedRoots.filter { $0 != home })
        var seen = Set<String>()
        return try directories.compactMap { directory in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(directory.path).inserted else {
                return nil
            }
            let count = try runMDCount(
                arguments: [
                    "-count",
                    "-onlyin",
                    directory.path,
                    "kMDItemFSName == '*'"
                ]
            )
            return FileInventoryEntry(
                directory: directory.path,
                indexedItemCount: count
            )
        }
    }

    public func excerpt(
        path: String,
        query: String? = nil,
        maximumCharacters: Int = 4_000
    ) throws -> FileTextExcerpt {
        guard allowTextExcerpts else {
            throw DesktopBotError.commandFailed(
                "Text excerpts are disabled in the DesktopBot configuration."
            )
        }
        let url = try allowedURL(path, mustBeDirectory: false)
        guard !isSensitiveDefaultExclusion(url) else {
            throw DesktopBotError.commandFailed(
                "Text extraction from ~/Library or dot-directories requires adding that narrower path as an explicit allowed root."
            )
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw DesktopBotError.commandFailed("Text excerpts require a regular file.")
        }
        guard (values.fileSize ?? 0) <= 50_000_000 else {
            throw DesktopBotError.commandFailed("Refusing to extract text from a file larger than 50 MB.")
        }

        let outputLimit = min(
            max(maximumCharacters, 500),
            maximumExcerptCharacters
        )
        let text = try extractText(from: url)
        let excerpts = Self.relevantExcerpts(
            from: text,
            query: query,
            maximumCharacters: outputLimit
        )
        let returnedCount = excerpts.reduce(0) { $0 + $1.count }
        return FileTextExcerpt(
            path: url.path,
            query: query,
            excerpts: excerpts,
            extractedCharacterCount: text.count,
            returnedCharacterCount: returnedCount,
            truncated: returnedCount < text.count
        )
    }

    private func metadata(for url: URL) throws -> MachineFileRecord {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .localizedTypeDescriptionKey,
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else {
            throw DesktopBotError.commandFailed("Symbolic links are not exposed by the file index.")
        }
        let kind: MachineFileKind
        if values.isDirectory == true {
            kind = .directory
        } else if values.isRegularFile == true {
            kind = .file
        } else {
            throw DesktopBotError.commandFailed("Path is not a regular file or directory: \(url.path)")
        }
        return MachineFileRecord(
            path: url.path,
            name: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            kind: kind,
            typeDescription: values.localizedTypeDescription,
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate,
            size: values.fileSize.map(Int64.init)
        )
    }

    private func allowedURL(_ path: String, mustBeDirectory: Bool) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isAllowed(url) else {
            throw DesktopBotError.commandFailed(
                "Path is outside the machine-files MCP allow-listed roots."
            )
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DesktopBotError.commandFailed("Path does not exist: \(url.path)")
        }
        if mustBeDirectory, !isDirectory.boolValue {
            throw DesktopBotError.commandFailed("Search scope is not a directory: \(url.path)")
        }
        return url
    }

    private func isAllowed(_ url: URL) -> Bool {
        allowedRoots.contains {
            url.path == $0.path || url.path.hasPrefix($0.path + "/")
        }
    }

    private func isPriority(_ url: URL) -> Bool {
        priorityDirectories.contains {
            url.path == $0.path || url.path.hasPrefix($0.path + "/")
        }
    }

    private func isLibraryOrHidden(_ url: URL) -> Bool {
        if url.path == home.path || url.path.hasPrefix(home.path + "/") {
            let relative = String(url.path.dropFirst(home.path.count))
            if relative == "/Library" || relative.hasPrefix("/Library/") {
                return true
            }
            return relative.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        return url.pathComponents.contains { $0.hasPrefix(".") && $0 != "." }
    }

    private func isSensitiveDefaultExclusion(_ url: URL) -> Bool {
        if allowedRoots.contains(where: {
            $0 != home && (url.path == $0.path || url.path.hasPrefix($0.path + "/"))
        }) {
            return false
        }
        return isLibraryOrHidden(url)
    }

    private func fallbackNameSearch(query: String, root: URL, limit: Int) -> [String] {
        var results = (
            try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )?
            .filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
            .map(\.path) ?? []
        if results.count >= limit {
            return Array(results.prefix(limit))
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return results
        }
        var seen = Set(results)
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if url.lastPathComponent.localizedCaseInsensitiveContains(query),
               seen.insert(url.path).inserted {
                results.append(url.path)
                if results.count >= limit { break }
            }
            if visited >= 50_000 { break }
        }
        return results
    }

    private func fallbackContentSearch(query: String, root: URL, limit: Int) -> [String] {
        let executableCandidates = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg"
        ]
        guard let executable = executableCandidates.first(where: {
            fileManager.isExecutableFile(atPath: $0)
        }) else {
            return []
        }
        var terms = [query]
        terms.append(
            contentsOf: query
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { $0.count >= 3 }
        )
        var results: [String] = []
        var seen = Set<String>()
        for term in terms {
            let remaining = limit - results.count
            guard remaining > 0 else { break }
            let matches = runNullDelimitedProcess(
                executable: executable,
                arguments: [
                    "--files-with-matches",
                    "--null",
                    "--ignore-case",
                    "--fixed-strings",
                    "--no-messages",
                    "--max-filesize",
                    "5M",
                    "--glob",
                    "!.git/**",
                    "--glob",
                    "!node_modules/**",
                    "--glob",
                    "!.build/**",
                    "--glob",
                    "!dist/**",
                    "--glob",
                    "!build/**",
                    "--glob",
                    "!vendor/**",
                    "--",
                    term,
                    root.path
                ],
                limit: remaining
            )
            for match in matches where seen.insert(match).inserted {
                results.append(match)
            }
        }
        return results
    }

    private func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let plainTextExtensions: Set<String> = [
            "txt", "md", "markdown", "log", "csv", "tsv", "json", "jsonl",
            "yaml", "yml", "toml", "xml", "sql", "swift", "py", "js", "jsx",
            "ts", "tsx", "go", "rs", "rb", "php", "java", "kt", "kts", "c",
            "h", "cpp", "hpp", "cs", "sh", "zsh", "fish", "css", "scss",
            "vue", "svelte"
        ]
        if plainTextExtensions.contains(ext) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if let text = String(data: data, encoding: .utf8) {
                return String(text.prefix(2_000_000))
            }
            if let text = String(data: data, encoding: .utf16) {
                return String(text.prefix(2_000_000))
            }
            throw DesktopBotError.commandFailed("The file is not valid UTF-8 or UTF-16 text.")
        }
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else {
                throw DesktopBotError.commandFailed("Could not open the PDF.")
            }
            var text = ""
            for pageIndex in 0..<document.pageCount {
                if let pageText = document.page(at: pageIndex)?.string {
                    text += pageText + "\n"
                }
                if text.count >= 2_000_000 { break }
            }
            guard !text.isEmpty else {
                throw DesktopBotError.commandFailed(
                    "The PDF has no embedded text; it may need OCR."
                )
            }
            return String(text.prefix(2_000_000))
        }
        if ["rtf", "rtfd", "html", "htm", "doc", "docx", "odt"].contains(ext) {
            return try textutilText(from: url)
        }
        throw DesktopBotError.commandFailed(
            "Bounded excerpts are not supported for .\(ext.isEmpty ? "(no extension)" : ext) files."
        )
    }

    private func textutilText(from url: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            throw DesktopBotError.commandFailed("macOS textutil could not extract text.")
        }
        return String(text.prefix(2_000_000))
    }

    private static func relevantExcerpts(
        from text: String,
        query: String?,
        maximumCharacters: Int
    ) -> [String] {
        let cleanedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleanedQuery, !cleanedQuery.isEmpty else {
            return [String(text.prefix(maximumCharacters))]
        }

        let source = text as NSString
        var searchTerms = [cleanedQuery]
        searchTerms.append(
            contentsOf: cleanedQuery
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { $0.count >= 3 }
        )
        let perExcerpt = max(100, maximumCharacters / 3)
        var ranges: [NSRange] = []
        for term in searchTerms {
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0, ranges.count < 3 {
                let match = source.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                if match.location == NSNotFound { break }
                let start = max(0, match.location - perExcerpt / 3)
                let length = min(perExcerpt, source.length - start)
                let proposed = NSRange(location: start, length: length)
                if !ranges.contains(where: { NSIntersectionRange($0, proposed).length > length / 2 }) {
                    ranges.append(proposed)
                }
                let next = match.location + max(match.length, 1)
                searchRange = NSRange(location: next, length: source.length - next)
            }
            if ranges.count >= 3 { break }
        }
        if ranges.isEmpty {
            return [String(text.prefix(maximumCharacters))]
        }
        return ranges.map {
            source.substring(with: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func runMDFind(arguments: [String], limit: Int) throws -> [String] {
        try runNullDelimitedProcessThrowing(
            executable: "/usr/bin/mdfind",
            arguments: arguments,
            limit: limit
        )
    }

    private func runNullDelimitedProcess(
        executable: String,
        arguments: [String],
        limit: Int
    ) -> [String] {
        (try? runNullDelimitedProcessThrowing(
            executable: executable,
            arguments: arguments,
            limit: limit
        )) ?? []
    }

    private func runNullDelimitedProcessThrowing(
        executable: String,
        arguments: [String],
        limit: Int
    ) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        var data = Data()
        var separatorCount = 0
        while true {
            let chunk = try output.fileHandleForReading.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            separatorCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0 { count += 1 }
            }
            if separatorCount >= limit {
                process.terminate()
                break
            }
        }
        process.waitUntilExit()

        return data
            .split(separator: 0, omittingEmptySubsequences: true)
            .prefix(limit)
            .compactMap { String(data: Data($0), encoding: .utf8) }
    }

    private func runMDCount(arguments: [String]) throws -> Int {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let count = Int(text) else {
            throw DesktopBotError.commandFailed("Spotlight could not count indexed files.")
        }
        return count
    }
}
