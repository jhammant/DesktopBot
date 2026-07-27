import Foundation
import Testing
@testable import DesktopBotCore

struct MachineFileIndexTests {
    @Test
    func exposesMetadataOnlyInsideConfiguredHome() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-home-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: home) }

        let file = home.appendingPathComponent("notes.txt")
        let contents = String(repeating: "introductory material ", count: 80)
            + "needle appears in this relevant section "
            + String(repeating: "trailing material ", count: 80)
        try Data(contents.utf8).write(to: file)
        let index = MachineFileIndex(home: home)

        let record = try #require(try index.info(paths: [file.path]).first)
        #expect(record.name == "notes.txt")
        #expect(record.kind == .file)
        #expect((record.size ?? 0) > 1_000)

        let excerpt = try index.excerpt(
            path: file.path,
            query: "needle",
            maximumCharacters: 500
        )
        #expect(excerpt.excerpts.joined().contains("needle"))
        #expect(excerpt.returnedCharacterCount <= 500)
        #expect(excerpt.truncated)

        #expect(throws: DesktopBotError.self) {
            try index.info(paths: ["/etc/hosts"])
        }
    }

    @Test
    func explicitMountedRootCanBeAllowListed() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-roots-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let share = root.appendingPathComponent("Team Share", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createDirectory(at: share, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let remoteFile = share.appendingPathComponent("roadmap.md")
        try Data("remote roadmap".utf8).write(to: remoteFile)

        let index = MachineFileIndex(home: home, allowedRoots: [home, share])
        let result = try #require(try index.info(paths: [remoteFile.path]).first)

        #expect(result.name == "roadmap.md")
    }

    @Test
    func hiddenTextNeedsANarrowExplicitRoot() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-hidden-\(UUID().uuidString)", isDirectory: true)
        let secrets = home.appendingPathComponent(".private", isDirectory: true)
        try manager.createDirectory(at: secrets, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: home) }
        let file = secrets.appendingPathComponent("settings.json")
        try Data("{\"token\":\"not-returned\"}".utf8).write(to: file)

        let broad = MachineFileIndex(home: home)
        #expect(throws: DesktopBotError.self) {
            try broad.excerpt(path: file.path)
        }

        let narrow = MachineFileIndex(home: home, allowedRoots: [home, secrets])
        let excerpt = try narrow.excerpt(path: file.path)
        #expect(excerpt.excerpts.joined().contains("not-returned"))
    }

    @Test
    func priorityDirectoryRanksFirst() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-priority-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let files = root.appendingPathComponent("Files", isDirectory: true)
        let dev = files.appendingPathComponent("dev", isDirectory: true)
        let documents = files.appendingPathComponent("documents", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createDirectory(at: dev, withIntermediateDirectories: true)
        try manager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try Data("needle-priority-content".utf8).write(
            to: dev.appendingPathComponent("report.md")
        )
        try Data("docs".utf8).write(to: documents.appendingPathComponent("report.md"))

        let index = MachineFileIndex(
            home: home,
            allowedRoots: [files],
            priorityDirectories: [dev]
        )
        let results = try index.search(query: "report", nameOnly: true, limit: 10)

        #expect(results.count == 2)
        #expect(results.first?.path.hasPrefix(dev.path) == true)

        if manager.isExecutableFile(atPath: "/opt/homebrew/bin/rg")
            || manager.isExecutableFile(atPath: "/usr/local/bin/rg")
            || manager.isExecutableFile(atPath: "/usr/bin/rg") {
            let contentResults = try index.search(
                query: "needle-priority-content",
                limit: 10
            )
            #expect(contentResults.first?.path.hasPrefix(dev.path) == true)
        }
    }
}
