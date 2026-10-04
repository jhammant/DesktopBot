import Foundation
import Testing
@testable import DesktopBotCore

struct DesktopFileOrganizerTests {
    @Test
    func organizesOldLooseFilesButLeavesFoldersAndRecentFiles() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-files-\(UUID().uuidString)", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let archive = root.appendingPathComponent("Filing", isDirectory: true)
        try manager.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let oldPDF = desktop.appendingPathComponent("old notes.pdf")
        let recentZIP = desktop.appendingPathComponent("recent.zip")
        let folder = desktop.appendingPathComponent("Project", isDirectory: true)
        try Data("pdf".utf8).write(to: oldPDF)
        try Data("zip".utf8).write(to: recentZIP)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try manager.setAttributes(
            [
                .creationDate: now.addingTimeInterval(-40 * 86_400),
                .modificationDate: now.addingTimeInterval(-40 * 86_400)
            ],
            ofItemAtPath: oldPDF.path
        )
        try manager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 86_400)],
            ofItemAtPath: recentZIP.path
        )

        let config = Configuration(
            sourceDirectory: desktop.path,
            archiveDirectory: root.appendingPathComponent("Screenshots").path,
            otherFiles: OtherFilesConfiguration(
                enabled: true,
                minimumAgeDays: 30,
                archiveDirectory: archive.path
            )
        )
        let organizer = DesktopFileOrganizer(
            configuration: config,
            now: { now },
            auditLogURL: root.appendingPathComponent("audit.jsonl")
        )

        let preview = try #require(try organizer.run(apply: false))
        #expect(preview.archiveCount == 1)
        #expect(preview.keepCount == 1)
        #expect(preview.analyses.allSatisfy { $0.fileName != "Project" })
        #expect(manager.fileExists(atPath: oldPDF.path))

        let applied = try #require(try organizer.run(apply: true))
        let moved = try #require(applied.analyses.first { $0.fileName == "old notes.pdf" })
        #expect(!manager.fileExists(atPath: oldPDF.path))
        #expect(manager.fileExists(atPath: moved.destinationPath!))
        #expect(manager.fileExists(atPath: recentZIP.path))
        #expect(manager.fileExists(atPath: folder.path))
    }

    @Test
    func classifiesCommonFileTypes() {
        #expect(DesktopFileOrganizer.category(forExtension: "pdf") == .documents)
        #expect(DesktopFileOrganizer.category(forExtension: "zip") == .archives)
        #expect(DesktopFileOrganizer.category(forExtension: "dmg") == .installers)
        #expect(DesktopFileOrganizer.category(forExtension: "tsx") == .code)
        #expect(DesktopFileOrganizer.category(forExtension: "json") == .data)
    }

    @Test
    func optionallyArchivesOldTopLevelFoldersIntact() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-folder-files-\(UUID().uuidString)", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let archive = root.appendingPathComponent("Filing", isDirectory: true)
        let folder = desktop.appendingPathComponent("generated-output", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let nested = folder.appendingPathComponent("result.txt")
        try Data("preserve me".utf8).write(to: nested)
        defer { try? manager.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try manager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10 * 86_400)],
            ofItemAtPath: folder.path
        )
        let config = Configuration(
            sourceDirectory: desktop.path,
            archiveDirectory: root.appendingPathComponent("Screenshots").path,
            otherFiles: OtherFilesConfiguration(
                enabled: true,
                minimumAgeDays: 30,
                archiveDirectory: archive.path,
                includeDirectories: true,
                directoryMinimumAgeDays: 7
            )
        )
        let organizer = DesktopFileOrganizer(
            configuration: config,
            now: { now },
            auditLogURL: nil
        )

        let preview = try #require(try organizer.run(apply: false))
        let item = try #require(preview.analyses.first)
        #expect(item.category == .folders)
        #expect(item.decision == .archive)
        #expect(manager.fileExists(atPath: nested.path))

        let applied = try #require(try organizer.run(apply: true))
        let destination = try #require(applied.analyses.first?.destinationPath)
        #expect(!manager.fileExists(atPath: folder.path))
        #expect(
            manager.fileExists(
                atPath: URL(fileURLWithPath: destination)
                    .appendingPathComponent("result.txt").path
            )
        )
    }

    @Test
    func dropFolderStaysAndItsOldFilesGoToTheTrash() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-drop-\(UUID().uuidString)", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let drop = desktop.appendingPathComponent("tmp", isDirectory: true)
        let fakeTrash = root.appendingPathComponent("Trash", isDirectory: true)
        try manager.createDirectory(at: drop, withIntermediateDirectories: true)
        try manager.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldVideo = drop.appendingPathComponent("old-demo.mp4")
        let newVideo = drop.appendingPathComponent("new-demo.mp4")
        try Data("old".utf8).write(to: oldVideo)
        try Data("new".utf8).write(to: newVideo)
        for (url, days) in [(oldVideo, 9.0), (newVideo, 2.0), (drop, 30.0)] {
            try manager.setAttributes(
                [
                    .creationDate: now.addingTimeInterval(-days * 86_400),
                    .modificationDate: now.addingTimeInterval(-days * 86_400)
                ],
                ofItemAtPath: url.path
            )
        }

        let config = Configuration(
            sourceDirectory: desktop.path,
            archiveDirectory: root.appendingPathComponent("Screenshots").path,
            otherFiles: OtherFilesConfiguration(
                enabled: true,
                minimumAgeDays: 7,
                archiveDirectory: root.appendingPathComponent("Filing").path,
                includeDirectories: true,
                directoryMinimumAgeDays: 3,
                dropFolders: [DropFolderConfiguration(path: drop.path, maxAgeDays: 7)]
            )
        )
        let organizer = DesktopFileOrganizer(
            configuration: config,
            now: { now },
            auditLogURL: root.appendingPathComponent("audit.jsonl"),
            trashItem: { url in
                let target = fakeTrash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
        )

        let applied = try #require(try organizer.run(apply: true))

        #expect(manager.fileExists(atPath: drop.path))                 // the folder isn't archived
        #expect(!manager.fileExists(atPath: oldVideo.path))            // old file went to the Trash
        #expect(manager.fileExists(atPath: fakeTrash.appendingPathComponent("old-demo.mp4").path))
        #expect(manager.fileExists(atPath: newVideo.path))             // recent file stays
        #expect(applied.analyses.allSatisfy { $0.fileName != "tmp" })
        let trashed = try #require(applied.analyses.first { $0.fileName == "tmp/old-demo.mp4" })
        #expect(trashed.decision == .archive)
        #expect(trashed.reasons.first?.contains("Trash") == true)
    }

    @Test
    func dropFolderAgeMustBeAtLeastADay() {
        let config = Configuration(
            otherFiles: OtherFilesConfiguration(dropFolders: [DropFolderConfiguration(path: "~/Desktop/tmp", maxAgeDays: 0)])
        )
        #expect(throws: DesktopBotError.self) { try config.validated() }
    }
}
