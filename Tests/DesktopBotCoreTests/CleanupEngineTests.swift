import Foundation
import Testing
@testable import DesktopBotCore

struct CleanupEngineTests {
    @Test
    func dryRunDoesNotMoveAndApplyArchives() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-tests-\(UUID().uuidString)", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try manager.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let screenshot = desktop.appendingPathComponent("Screenshot fixture.png")
        try Data("not-a-real-image-but-valid-for-file-policy".utf8).write(to: screenshot)

        let config = Configuration(
            sourceDirectory: desktop.path,
            archiveDirectory: archive.path,
            minimumAgeDays: 0,
            genericScreenshotAgeDays: 0,
            cleanupThreshold: 0,
            performOCR: false
        )
        let engine = CleanupEngine(
            configuration: config,
            textRecognizer: NoopTextRecognizer(),
            auditLogURL: root.appendingPathComponent("audit.jsonl")
        )

        let preview = try engine.run(apply: false)
        #expect(preview.archiveCount == 1)
        #expect(manager.fileExists(atPath: screenshot.path))
        #expect(!manager.fileExists(atPath: preview.analyses[0].destinationPath!))

        let applied = try engine.run(apply: true)
        #expect(applied.archiveCount == 1)
        #expect(!manager.fileExists(atPath: screenshot.path))
        #expect(manager.fileExists(atPath: applied.analyses[0].destinationPath!))
        #expect(applied.analyses[0].importance == .routine)
        #expect(
            applied.analyses[0].destinationPath?.contains("/routine/unreadable/") == true
        )
        #expect(
            URL(fileURLWithPath: applied.analyses[0].destinationPath!)
                .lastPathComponent.contains("-routine-unreadable") == true
        )
        #expect(manager.fileExists(atPath: root.appendingPathComponent("audit.jsonl").path))
    }
}
