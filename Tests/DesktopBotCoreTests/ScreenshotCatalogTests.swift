import Foundation
import Testing
@testable import DesktopBotCore

private struct FixtureTextRecognizer: TextRecognizing {
    func recognizeText(in imageURL: URL) throws -> String {
        "Vite dev server running at http://localhost:5173 with a compile error"
    }
}

struct ScreenshotCatalogTests {
    @Test
    func searchesOCRAndArchivesByID() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("desktopbot-catalog-\(UUID().uuidString)", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try manager.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let screenshot = desktop.appendingPathComponent("Screenshot dev server.png")
        try Data("fixture".utf8).write(to: screenshot)
        let configuration = Configuration(
            sourceDirectory: desktop.path,
            archiveDirectory: archive.path
        )
        let catalog = ScreenshotCatalog(
            configuration: configuration,
            textRecognizer: FixtureTextRecognizer(),
            indexURL: root.appendingPathComponent("catalog.json")
        )

        let results = try catalog.search(query: "localhost compile", limit: 5)
        let match = try #require(results.first)
        #expect(match.category == .error)
        #expect(match.ocrText?.contains("localhost") == true)

        let archived = try catalog.archive(identifier: match.id)
        #expect(archived.location == .archive)
        #expect(archived.path.contains("/error/"))
        #expect(!manager.fileExists(atPath: screenshot.path))
        #expect(manager.fileExists(atPath: archived.path))
    }
}
