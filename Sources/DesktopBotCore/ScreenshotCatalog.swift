import CryptoKit
import Foundation

public enum ScreenshotLocation: String, Codable, Sendable {
    case desktop
    case archive
}

public struct ScreenshotRecord: Codable, Sendable {
    public let id: String
    public var path: String
    public var fileName: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var size: Int64
    public var location: ScreenshotLocation
    public var category: ScreenshotCategory?
    public var ocrText: String?

    public init(
        id: String,
        path: String,
        fileName: String,
        createdAt: Date,
        modifiedAt: Date,
        size: Int64,
        location: ScreenshotLocation,
        category: ScreenshotCategory?,
        ocrText: String?
    ) {
        self.id = id
        self.path = path
        self.fileName = fileName
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.size = size
        self.location = location
        self.category = category
        self.ocrText = ocrText
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }
}

private struct ScreenshotIndex: Codable {
    let version: Int
    let records: [ScreenshotRecord]
}

public final class ScreenshotCatalog: @unchecked Sendable {
    private let configuration: Configuration
    private let fileManager: FileManager
    private let textRecognizer: any TextRecognizing
    private let indexURL: URL

    public init(
        configuration: Configuration,
        fileManager: FileManager = .default,
        textRecognizer: any TextRecognizing = VisionTextRecognizer(),
        indexURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DesktopBot/catalog.json")
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.textRecognizer = textRecognizer
        self.indexURL = indexURL
    }

    public func list(
        limit: Int = 20,
        location: ScreenshotLocation? = nil,
        category: ScreenshotCategory? = nil
    ) throws -> [ScreenshotRecord] {
        try discover()
            .filter { location == nil || $0.location == location }
            .filter { category == nil || $0.category == category }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.clampedLimit(limit))
            .map { $0 }
    }

    public func latest(
        offset: Int = 0,
        location: ScreenshotLocation? = nil
    ) throws -> ScreenshotRecord? {
        let records = try discover()
            .filter { location == nil || $0.location == location }
            .sorted { $0.createdAt > $1.createdAt }
        guard records.indices.contains(max(0, offset)) else { return nil }
        return records[max(0, offset)]
    }

    public func get(identifier: String, refreshOCR: Bool = true) throws -> ScreenshotRecord? {
        var records = try discover()
        let expanded = NSString(string: identifier).expandingTildeInPath
        guard let index = records.firstIndex(where: {
            $0.id == identifier
                || $0.path == identifier
                || $0.path == expanded
        }) else {
            return nil
        }
        guard refreshOCR, records[index].ocrText == nil else {
            return records[index]
        }

        do {
            let text = try textRecognizer.recognizeText(in: records[index].url)
            records[index].ocrText = text
            records[index].category = category(for: records[index], text: text)
            try writeIndex(records)
        } catch {
            records[index].category = records[index].category ?? .unreadable
        }
        return records[index]
    }

    public func search(query: String, limit: Int = 10) throws -> [ScreenshotRecord] {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return [] }
        let tokens = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return try refreshIndex()
            .compactMap { record -> (ScreenshotRecord, Int)? in
                let fileName = record.fileName.lowercased()
                let text = record.ocrText?.lowercased() ?? ""
                var score = 0
                if fileName.contains(normalized) { score += 120 }
                if text.contains(normalized) { score += 100 }
                score += tokens.filter { fileName.contains($0) }.count * 25
                score += tokens.filter { text.contains($0) }.count * 20
                guard score > 0 else { return nil }
                return (record, score)
            }
            .sorted {
                if $0.1 == $1.1 { return $0.0.createdAt > $1.0.createdAt }
                return $0.1 > $1.1
            }
            .prefix(Self.clampedLimit(limit))
            .map(\.0)
    }

    @discardableResult
    public func refreshIndex(maxOCRItems: Int? = nil) throws -> [ScreenshotRecord] {
        var records = try discover()
        var remaining = max(
            0,
            maxOCRItems ?? configuration.maxOCRImagesPerRun
        )
        for index in records.indices where records[index].ocrText == nil && remaining > 0 {
            remaining -= 1
            do {
                let text = try textRecognizer.recognizeText(in: records[index].url)
                records[index].ocrText = text
                records[index].category = category(for: records[index], text: text)
            } catch {
                records[index].category = records[index].category ?? .unreadable
            }
        }

        try writeIndex(records)
        return records
    }

    public func archive(identifier: String) throws -> ScreenshotRecord {
        guard let record = try get(identifier: identifier, refreshOCR: true) else {
            throw DesktopBotError.commandFailed("Screenshot not found: \(identifier)")
        }
        guard record.location == .desktop else {
            throw DesktopBotError.commandFailed("Only screenshots currently on the Desktop can be archived.")
        }

        let sourceRoot = configuration.sourceURL().resolvingSymlinksInPath()
        let source = record.url.resolvingSymlinksInPath()
        guard source.deletingLastPathComponent() == sourceRoot else {
            throw DesktopBotError.commandFailed("Refusing to move a file outside the configured Desktop folder.")
        }
        guard ScreenshotDetector(configuration: configuration).isScreenshot(source) else {
            throw DesktopBotError.commandFailed("The selected file no longer matches the screenshot policy.")
        }

        let category = record.category ?? .other
        let destination = uniqueDestination(
            for: source,
            category: category,
            referenceDate: record.createdAt
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: source, to: destination)

        let archived = ScreenshotRecord(
            id: Self.identifier(for: destination.path),
            path: destination.path,
            fileName: destination.lastPathComponent,
            createdAt: record.createdAt,
            modifiedAt: record.modifiedAt,
            size: record.size,
            location: .archive,
            category: record.category,
            ocrText: record.ocrText
        )
        var records = try discover().filter { $0.path != destination.path }
        records.append(archived)
        try writeIndex(records)
        return archived
    }

    private func discover() throws -> [ScreenshotRecord] {
        let cached = Dictionary(
            uniqueKeysWithValues: loadIndex().map { ($0.path, $0) }
        )
        var records = try ScreenshotDetector(configuration: configuration)
            .files(in: configuration.sourceURL())
            .map {
                makeRecord(
                    file: $0,
                    location: .desktop,
                    category: nil,
                    cached: cached[$0.url.path]
                )
            }

        let archiveRoot = configuration.archiveURL()
        if fileManager.fileExists(atPath: archiveRoot.path),
           let enumerator = fileManager.enumerator(
               at: archiveRoot,
               includingPropertiesForKeys: [
                   .isRegularFileKey,
                   .creationDateKey,
                   .contentModificationDateKey,
                   .fileSizeKey
               ],
               options: [.skipsHiddenFiles]
           ) {
            let supported = Set(configuration.supportedExtensions.map { $0.lowercased() })
            for case let url as URL in enumerator {
                guard supported.contains(url.pathExtension.lowercased()) else { continue }
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile == true else { continue }
                let modifiedAt = values.contentModificationDate ?? .distantPast
                let file = ScreenshotFile(
                    url: url,
                    createdAt: values.creationDate ?? modifiedAt,
                    modifiedAt: modifiedAt,
                    size: Int64(values.fileSize ?? 0)
                )
                let folderCategory = ScreenshotCategory(
                    rawValue: url.deletingLastPathComponent().lastPathComponent
                )
                records.append(
                    makeRecord(
                        file: file,
                        location: .archive,
                        category: folderCategory,
                        cached: cached[url.path]
                    )
                )
            }
        }
        return records
    }

    private func makeRecord(
        file: ScreenshotFile,
        location: ScreenshotLocation,
        category: ScreenshotCategory?,
        cached: ScreenshotRecord?
    ) -> ScreenshotRecord {
        let unchanged = cached?.modifiedAt == file.modifiedAt
            && cached?.size == file.size
        return ScreenshotRecord(
            id: Self.identifier(for: file.url.path),
            path: file.url.path,
            fileName: file.url.lastPathComponent,
            createdAt: file.createdAt,
            modifiedAt: file.modifiedAt,
            size: file.size,
            location: location,
            category: unchanged ? (cached?.category ?? category) : category,
            ocrText: unchanged ? cached?.ocrText : nil
        )
    }

    private func category(for record: ScreenshotRecord, text: String) -> ScreenshotCategory {
        let file = ScreenshotFile(
            url: record.url,
            createdAt: record.createdAt,
            modifiedAt: record.modifiedAt,
            size: record.size
        )
        return ScreenshotRules(configuration: configuration).analyze(
            file: file,
            now: Date(),
            recognizedText: text,
            isExactDuplicate: false
        ).category
    }

    private func loadIndex() -> [ScreenshotRecord] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder.desktopBot.decode(ScreenshotIndex.self, from: data),
              index.version == 1 else {
            return []
        }
        return index.records
    }

    private func writeIndex(_ records: [ScreenshotRecord]) throws {
        try fileManager.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let index = ScreenshotIndex(version: 1, records: records)
        let encoder = JSONEncoder.desktopBot
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(index)
        data.append(0x0A)
        try data.write(to: indexURL, options: .atomic)
    }

    private func uniqueDestination(
        for source: URL,
        category: ScreenshotCategory,
        referenceDate: Date
    ) -> URL {
        let calendar = Calendar.current
        let directory = configuration.archiveURL()
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

    private static func identifier(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), 100)
    }
}

private extension JSONDecoder {
    static var desktopBot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var desktopBot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
