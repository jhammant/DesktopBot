import Foundation

public struct ScreenshotDetector: Sendable {
    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func isScreenshot(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        guard configuration.supportedExtensions
            .map({ $0.lowercased() })
            .contains(fileExtension) else {
            return false
        }

        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return configuration.screenshotNamePrefixes.contains { prefix in
            name.hasPrefix(prefix.lowercased())
        }
    }

    public func files(in directory: URL) throws -> [ScreenshotFile] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DesktopBotError.sourceDirectoryMissing(directory.path)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isHiddenKey,
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        let urls = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        return try urls.compactMap { url in
            guard isScreenshot(url) else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isHidden != true else { return nil }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            return ScreenshotFile(
                url: url,
                createdAt: values.creationDate ?? modifiedAt,
                modifiedAt: modifiedAt,
                size: Int64(values.fileSize ?? 0)
            )
        }
    }
}
