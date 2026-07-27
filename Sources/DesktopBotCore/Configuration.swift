import Foundation

public struct OtherFilesConfiguration: Codable, Sendable {
    public var enabled: Bool
    public var minimumAgeDays: Int
    public var archiveDirectory: String

    public init(
        enabled: Bool = true,
        minimumAgeDays: Int = 30,
        archiveDirectory: String = "~/Documents/DesktopBot Filing"
    ) {
        self.enabled = enabled
        self.minimumAgeDays = minimumAgeDays
        self.archiveDirectory = archiveDirectory
    }

    public static var `default`: OtherFilesConfiguration {
        OtherFilesConfiguration()
    }
}

public struct MachineFilesConfiguration: Codable, Sendable {
    public var allowedRoots: [String]
    public var priorityDirectories: [String]?
    public var allowTextExcerpts: Bool
    public var maximumExcerptCharacters: Int

    public init(
        allowedRoots: [String] = ["~"],
        priorityDirectories: [String]? = ["~/dev"],
        allowTextExcerpts: Bool = true,
        maximumExcerptCharacters: Int = 12_000
    ) {
        self.allowedRoots = allowedRoots
        self.priorityDirectories = priorityDirectories
        self.allowTextExcerpts = allowTextExcerpts
        self.maximumExcerptCharacters = maximumExcerptCharacters
    }

    public static var `default`: MachineFilesConfiguration {
        MachineFilesConfiguration()
    }
}

public struct FolderOrganizationConfiguration: Codable, Sendable {
    public var enabled: Bool
    public var directories: [String]
    public var moveDirectories: Bool

    public init(
        enabled: Bool = true,
        directories: [String] = ["~/Desktop/Cleanup"],
        moveDirectories: Bool = true
    ) {
        self.enabled = enabled
        self.directories = directories
        self.moveDirectories = moveDirectories
    }

    public static var `default`: FolderOrganizationConfiguration {
        FolderOrganizationConfiguration()
    }
}

public struct Configuration: Codable, Sendable {
    public var sourceDirectory: String
    public var archiveDirectory: String
    public var minimumAgeDays: Int
    public var genericScreenshotAgeDays: Int
    public var duplicateMinimumAgeDays: Int
    public var cleanupThreshold: Int
    public var maxOCRImagesPerRun: Int
    public var performOCR: Bool
    public var supportedExtensions: [String]
    public var screenshotNamePrefixes: [String]
    public var codingKeywords: [String]
    public var errorKeywords: [String]
    public var keepKeywords: [String]
    public var otherFiles: OtherFilesConfiguration?
    public var machineFiles: MachineFilesConfiguration?
    public var folderOrganization: FolderOrganizationConfiguration?

    public init(
        sourceDirectory: String = "~/Desktop",
        archiveDirectory: String = "~/Pictures/DesktopBot Review",
        minimumAgeDays: Int = 1,
        genericScreenshotAgeDays: Int = 7,
        duplicateMinimumAgeDays: Int = 0,
        cleanupThreshold: Int = 70,
        maxOCRImagesPerRun: Int = 100,
        performOCR: Bool = true,
        supportedExtensions: [String] = ["png", "jpg", "jpeg", "heic", "tiff", "webp"],
        screenshotNamePrefixes: [String] = [
            "screenshot",
            "screen shot",
            "cleanshot",
            "shottr",
            "xnapper"
        ],
        codingKeywords: [String] = [
            "localhost",
            "node_modules",
            "npm ",
            "pnpm ",
            "yarn ",
            "git ",
            "github",
            "terminal",
            "console",
            "function ",
            "const ",
            "let ",
            "import ",
            "export ",
            "class ",
            "struct ",
            "def ",
            "src/",
            ".tsx",
            ".jsx",
            ".swift",
            ".py",
            ".js",
            ".ts",
            "pull request",
            "commit"
        ],
        errorKeywords: [String] = [
            "error",
            "exception",
            "traceback",
            "stack trace",
            "failed",
            "failure",
            "fatal",
            "warning:",
            "cannot find",
            "undefined",
            "segmentation fault"
        ],
        keepKeywords: [String] = [
            "recovery code",
            "recovery phrase",
            "seed phrase",
            "secret key",
            "private key",
            "api key",
            "password",
            "passcode",
            "verification code",
            "one-time code",
            "two-factor",
            "2fa",
            "invoice",
            "receipt",
            "boarding pass",
            "flight",
            "ticket",
            "passport",
            "driving licence",
            "driver's license",
            "order number",
            "serial number",
            "license key"
        ],
        otherFiles: OtherFilesConfiguration? = .default,
        machineFiles: MachineFilesConfiguration? = .default,
        folderOrganization: FolderOrganizationConfiguration? = .default
    ) {
        self.sourceDirectory = sourceDirectory
        self.archiveDirectory = archiveDirectory
        self.minimumAgeDays = minimumAgeDays
        self.genericScreenshotAgeDays = genericScreenshotAgeDays
        self.duplicateMinimumAgeDays = duplicateMinimumAgeDays
        self.cleanupThreshold = cleanupThreshold
        self.maxOCRImagesPerRun = maxOCRImagesPerRun
        self.performOCR = performOCR
        self.supportedExtensions = supportedExtensions
        self.screenshotNamePrefixes = screenshotNamePrefixes
        self.codingKeywords = codingKeywords
        self.errorKeywords = errorKeywords
        self.keepKeywords = keepKeywords
        self.otherFiles = otherFiles
        self.machineFiles = machineFiles
        self.folderOrganization = folderOrganization
    }

    public static var `default`: Configuration {
        Configuration()
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/desktopbot/config.json")
    }

    public func validated() throws -> Configuration {
        guard minimumAgeDays >= 0 else {
            throw DesktopBotError.invalidConfiguration("minimumAgeDays must be zero or greater")
        }
        guard genericScreenshotAgeDays >= minimumAgeDays else {
            throw DesktopBotError.invalidConfiguration(
                "genericScreenshotAgeDays must be at least minimumAgeDays"
            )
        }
        guard duplicateMinimumAgeDays >= 0 else {
            throw DesktopBotError.invalidConfiguration(
                "duplicateMinimumAgeDays must be zero or greater"
            )
        }
        guard (0...200).contains(cleanupThreshold) else {
            throw DesktopBotError.invalidConfiguration("cleanupThreshold must be between 0 and 200")
        }
        guard maxOCRImagesPerRun >= 0 else {
            throw DesktopBotError.invalidConfiguration("maxOCRImagesPerRun must be zero or greater")
        }
        guard !sourceDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopBotError.invalidConfiguration("sourceDirectory cannot be empty")
        }
        guard !archiveDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopBotError.invalidConfiguration("archiveDirectory cannot be empty")
        }
        if let otherFiles {
            guard otherFiles.minimumAgeDays >= 0 else {
                throw DesktopBotError.invalidConfiguration(
                    "otherFiles.minimumAgeDays must be zero or greater"
                )
            }
            guard !otherFiles.archiveDirectory
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DesktopBotError.invalidConfiguration(
                    "otherFiles.archiveDirectory cannot be empty"
                )
            }
        }
        if let machineFiles {
            guard !machineFiles.allowedRoots.isEmpty,
                  machineFiles.allowedRoots.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                throw DesktopBotError.invalidConfiguration(
                    "machineFiles.allowedRoots must contain at least one non-empty path"
                )
            }
            guard (500...50_000).contains(machineFiles.maximumExcerptCharacters) else {
                throw DesktopBotError.invalidConfiguration(
                    "machineFiles.maximumExcerptCharacters must be between 500 and 50000"
                )
            }
            if let priorityDirectories = machineFiles.priorityDirectories {
                guard priorityDirectories.allSatisfy({
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) else {
                    throw DesktopBotError.invalidConfiguration(
                        "machineFiles.priorityDirectories cannot contain empty paths"
                    )
                }
            }
        }
        if let folderOrganization {
            guard !folderOrganization.directories.isEmpty,
                  folderOrganization.directories.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                throw DesktopBotError.invalidConfiguration(
                    "folderOrganization.directories must contain at least one non-empty path"
                )
            }
        }
        return self
    }

    public func sourceURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        Self.expand(path: sourceDirectory, home: home)
    }

    public func archiveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        Self.expand(path: archiveDirectory, home: home)
    }

    public func otherFilesArchiveURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        Self.expand(
            path: otherFiles?.archiveDirectory ?? OtherFilesConfiguration.default.archiveDirectory,
            home: home
        )
    }

    public func machineFileRootURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        (machineFiles ?? .default).allowedRoots.map {
            Self.expand(path: $0, home: home)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
    }

    public func machineFilePriorityURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        ((machineFiles ?? .default).priorityDirectories ?? ["~/dev"]).map {
            Self.expand(path: $0, home: home)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
    }

    public func folderOrganizationURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        (folderOrganization?.directories ?? []).map {
            Self.expand(path: $0, home: home)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
    }

    public static func load(from url: URL = defaultURL) throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return try Configuration.default.validated()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Configuration.self, from: data).validated()
    }

    public func write(to url: URL = defaultURL, overwrite: Bool = false) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path), !overwrite {
            throw DesktopBotError.fileAlreadyExists(url.path)
        }
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private static func expand(path: String, home: URL) -> URL {
        if path == "~" {
            return home.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
