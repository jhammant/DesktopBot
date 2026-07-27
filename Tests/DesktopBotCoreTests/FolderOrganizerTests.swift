import Foundation
import Testing
@testable import DesktopBotCore

struct FolderOrganizerTests {
    @Test
    func previewsAndAppliesFiveBucketOrganizationWithoutDeleting() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-organizer-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let screenshot = try write("Screenshot 2026-01-15.png", in: root)
        let files = [
            try write("org_chart.png", in: root),
            try write("linkedin-post.md", in: root),
            try write("Proposal.pdf", in: root),
            try write("family recipe.pdf", in: root),
            try write("Home.conf", in: root),
            try write("DSC07757.jpeg", in: root),
            try write("download.zip", in: root),
            try write("mystery.bin", in: root)
        ]
        let desktopFolder = root.appendingPathComponent("Desktop - old", isDirectory: true)
        let generatedFolder = root.appendingPathComponent("volta-prep", isDirectory: true)
        let ordinaryFolder = root.appendingPathComponent("Project", isDirectory: true)
        try manager.createDirectory(at: desktopFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: generatedFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: ordinaryFolder, withIntermediateDirectories: true)
        let managed = root.appendingPathComponent("Screenshots", isDirectory: true)
        try manager.createDirectory(at: managed, withIntermediateDirectories: true)

        let date = try #require(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 1, day: 15)
            )
        )
        try manager.setAttributes([.modificationDate: date], ofItemAtPath: screenshot.path)

        let organizer = FolderOrganizer(fileManager: manager, auditLogURL: nil)
        let preview = try organizer.preview(root: root)

        #expect(preview.dryRun)
        #expect(preview.topLevelItemsBefore == 13)
        #expect(preview.moveCount == 12)
        #expect(preview.skipCount == 1)
        #expect(manager.fileExists(atPath: screenshot.path))
        #expect(
            preview.items.first { $0.fileName == screenshot.lastPathComponent }?
                .destinationPath?.hasSuffix("Screenshots/2026-01/Screenshot 2026-01-15.png") == true
        )
        #expect(
            preview.items.first { $0.fileName == "Desktop - old" }?
                .destinationPath?.hasSuffix("Archive/Old Desktop/Desktop - old") == true
        )
        #expect(
            preview.items.first { $0.fileName == "volta-prep" }?
                .destinationPath?.hasSuffix("Generated/volta-prep") == true
        )
        #expect(
            preview.items.first { $0.fileName == "Project" }?
                .destinationPath?.hasSuffix("Archive/Folders/Project") == true
        )

        let applied = try organizer.apply(preview)
        #expect(!applied.dryRun)
        #expect(applied.failureCount == 0)
        #expect(applied.topLevelItemsAfter == 5)
        #expect(!manager.fileExists(atPath: screenshot.path))
        for file in files {
            #expect(!manager.fileExists(atPath: file.path))
        }
        #expect(!manager.fileExists(atPath: desktopFolder.path))
        #expect(!manager.fileExists(atPath: generatedFolder.path))
        #expect(!manager.fileExists(atPath: ordinaryFolder.path))
        #expect(
            manager.fileExists(
                atPath: root
                    .appendingPathComponent("Screenshots/2026-01/Screenshot 2026-01-15.png")
                    .path
            )
        )
        #expect(
            manager.fileExists(
                atPath: root.appendingPathComponent("Archive/Other Files/mystery.bin").path
            )
        )
    }

    @Test
    func plansAUniqueDestinationAndNeverOverwrites() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-collision-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("Images/Photos", isDirectory: true)
        try manager.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        _ = try write("photo.jpg", in: root)
        _ = try write("photo.jpg", in: photos)

        let organizer = FolderOrganizer(fileManager: manager, auditLogURL: nil)
        let preview = try organizer.preview(root: root)
        let photo = try #require(preview.items.first { $0.fileName == "photo.jpg" })
        #expect(photo.destinationPath?.hasSuffix("Images/Photos/photo-2.jpg") == true)

        let applied = try organizer.apply(preview)
        #expect(applied.failureCount == 0)
        #expect(manager.fileExists(atPath: photos.appendingPathComponent("photo.jpg").path))
        #expect(manager.fileExists(atPath: photos.appendingPathComponent("photo-2.jpg").path))
    }

    @Test
    func canLeaveDirectoriesAtTheRoot() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-files-only-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Project", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let preview = try FolderOrganizer(fileManager: manager, auditLogURL: nil)
            .preview(root: root, moveDirectories: false)
        #expect(preview.moveCount == 0)
        #expect(preview.skipCount == 1)
        #expect(preview.items.first?.reasons.contains("directory moves disabled") == true)
    }

    private func write(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }
}
