import Foundation

public enum ScreenshotCategory: String, Codable, Sendable {
    case coding
    case error
    case web
    case text
    case protected
    case visual
    case other
    case unreadable
}

public enum CleanupDecision: String, Codable, Sendable {
    case archive
    case keep
    case skip
    case failed
}

public struct ScreenshotFile: Sendable {
    public let url: URL
    public let createdAt: Date
    public let modifiedAt: Date
    public let size: Int64

    public init(url: URL, createdAt: Date, modifiedAt: Date, size: Int64) {
        self.url = url
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

public struct ScreenshotAnalysis: Codable, Sendable {
    public let sourcePath: String
    public var destinationPath: String?
    public let fileName: String
    public let ageDays: Int
    public let category: ScreenshotCategory
    public let score: Int
    public var decision: CleanupDecision
    public var reasons: [String]
    public let isExactDuplicate: Bool
    public let ocrTextPreview: String?

    public init(
        sourcePath: String,
        destinationPath: String? = nil,
        fileName: String,
        ageDays: Int,
        category: ScreenshotCategory,
        score: Int,
        decision: CleanupDecision,
        reasons: [String],
        isExactDuplicate: Bool,
        ocrTextPreview: String?
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.fileName = fileName
        self.ageDays = ageDays
        self.category = category
        self.score = score
        self.decision = decision
        self.reasons = reasons
        self.isExactDuplicate = isExactDuplicate
        self.ocrTextPreview = ocrTextPreview
    }
}

public struct RunSummary: Codable, Sendable {
    public let runID: String
    public let startedAt: Date
    public let dryRun: Bool
    public let sourceDirectory: String
    public let archiveDirectory: String
    public var analyses: [ScreenshotAnalysis]

    public init(
        runID: String,
        startedAt: Date,
        dryRun: Bool,
        sourceDirectory: String,
        archiveDirectory: String,
        analyses: [ScreenshotAnalysis]
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.dryRun = dryRun
        self.sourceDirectory = sourceDirectory
        self.archiveDirectory = archiveDirectory
        self.analyses = analyses
    }

    public var archiveCount: Int {
        analyses.filter { $0.decision == .archive }.count
    }

    public var keepCount: Int {
        analyses.filter { $0.decision == .keep }.count
    }

    public var failureCount: Int {
        analyses.filter { $0.decision == .failed }.count
    }
}

public enum DesktopFileCategory: String, Codable, Sendable {
    case documents
    case spreadsheets
    case presentations
    case archives
    case installers
    case code
    case data
    case images
    case audio
    case video
    case fonts
    case links
    case folders
    case other
}

public struct DesktopFileAnalysis: Codable, Sendable {
    public let sourcePath: String
    public var destinationPath: String?
    public let fileName: String
    public let ageDays: Int
    public let category: DesktopFileCategory
    public var decision: CleanupDecision
    public var reasons: [String]
}

public struct OtherFilesRunSummary: Codable, Sendable {
    public let dryRun: Bool
    public let sourceDirectory: String
    public let archiveDirectory: String
    public var analyses: [DesktopFileAnalysis]

    public var archiveCount: Int {
        analyses.filter { $0.decision == .archive }.count
    }

    public var keepCount: Int {
        analyses.filter { $0.decision == .keep }.count
    }

    public var failureCount: Int {
        analyses.filter { $0.decision == .failed }.count
    }
}

public struct DesktopRunReport: Codable, Sendable {
    public let screenshots: RunSummary
    public let otherFiles: OtherFilesRunSummary?
    public let organizedFolders: [FolderOrganizationSummary]?

    public init(
        screenshots: RunSummary,
        otherFiles: OtherFilesRunSummary?,
        organizedFolders: [FolderOrganizationSummary]? = nil
    ) {
        self.screenshots = screenshots
        self.otherFiles = otherFiles
        self.organizedFolders = organizedFolders
    }
}

public enum FolderOrganizationItemKind: String, Codable, Sendable {
    case file
    case directory
}

public enum FolderOrganizationCategory: String, Codable, Sendable {
    case screenshot
    case workDocument
    case personalDocument
    case configuration
    case generatedVisual
    case generatedContent
    case photo
    case media
    case archive
    case codeData
    case oldDesktop
    case generatedFolder
    case folder
    case other
}

public struct FolderOrganizationItem: Codable, Sendable {
    public let sourcePath: String
    public let destinationPath: String?
    public let fileName: String
    public let kind: FolderOrganizationItemKind
    public let category: FolderOrganizationCategory
    public var decision: CleanupDecision
    public var reasons: [String]

    public init(
        sourcePath: String,
        destinationPath: String?,
        fileName: String,
        kind: FolderOrganizationItemKind,
        category: FolderOrganizationCategory,
        decision: CleanupDecision,
        reasons: [String]
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.fileName = fileName
        self.kind = kind
        self.category = category
        self.decision = decision
        self.reasons = reasons
    }
}

public struct FolderOrganizationSummary: Codable, Sendable {
    public let runID: String
    public let startedAt: Date
    public let dryRun: Bool
    public let rootDirectory: String
    public let topLevelItemsBefore: Int
    public let topLevelItemsAfter: Int
    public var items: [FolderOrganizationItem]

    public init(
        runID: String,
        startedAt: Date,
        dryRun: Bool,
        rootDirectory: String,
        topLevelItemsBefore: Int,
        topLevelItemsAfter: Int,
        items: [FolderOrganizationItem]
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.dryRun = dryRun
        self.rootDirectory = rootDirectory
        self.topLevelItemsBefore = topLevelItemsBefore
        self.topLevelItemsAfter = topLevelItemsAfter
        self.items = items
    }

    public var moveCount: Int {
        items.filter { $0.decision == .archive }.count
    }

    public var skipCount: Int {
        items.filter { $0.decision == .skip || $0.decision == .keep }.count
    }

    public var failureCount: Int {
        items.filter { $0.decision == .failed }.count
    }
}

public enum DesktopBotError: LocalizedError {
    case invalidConfiguration(String)
    case fileAlreadyExists(String)
    case sourceDirectoryMissing(String)
    case unsupportedPlatform(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .fileAlreadyExists(let path):
            return "A file already exists at \(path)"
        case .sourceDirectoryMissing(let path):
            return "Source directory does not exist: \(path)"
        case .unsupportedPlatform(let message):
            return message
        case .commandFailed(let message):
            return message
        }
    }
}
