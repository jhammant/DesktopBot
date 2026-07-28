import Foundation
import Testing
@testable import DesktopBotCore

struct ScreenshotArchiveNamingTests {
    @Test
    func descriptiveNameUsesCategoryImportanceAndSafeTopic() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 12))
        )
        let name = ScreenshotArchiveNaming.fileName(
            source: URL(fileURLWithPath: "/tmp/Screenshot.png"),
            referenceDate: date,
            category: .error,
            importance: .important,
            recognizedText: "Vite dev server failed during a production incident",
            rename: true
        )

        #expect(name.contains("-important-error-vite-dev-server-failed.png"))
    }

    @Test
    func sensitiveNameNeverIncludesOCRText() {
        let name = ScreenshotArchiveNaming.fileName(
            source: URL(fileURLWithPath: "/tmp/Screenshot.png"),
            referenceDate: Date(timeIntervalSince1970: 2_000_000_000),
            category: .protected,
            importance: .sensitive,
            recognizedText: "Recovery code ABCD-EFGH and password hunter2",
            rename: true
        )

        #expect(name.contains("-sensitive-protected.png"))
        #expect(!name.lowercased().contains("recovery"))
        #expect(!name.lowercased().contains("password"))
        #expect(!name.lowercased().contains("abcd"))
    }

    @Test
    func importanceCreatesASeparateArchiveLevel() {
        let directory = ScreenshotArchiveNaming.directory(
            archiveRoot: URL(fileURLWithPath: "/tmp/archive"),
            referenceDate: Date(timeIntervalSince1970: 2_000_000_000),
            category: .web,
            importance: .useful,
            groupByImportance: true
        )

        #expect(directory.path.contains("/useful/web"))
    }
}
