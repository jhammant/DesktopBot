import Foundation
import Testing
@testable import DesktopBotCore

struct RulesTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test
    func staleCodingScreenshotIsArchived() {
        let result = analyze(ageDays: 8, text: "npm test failed in src/server.ts")

        #expect(result.decision == .archive)
        #expect(result.category == .error)
        #expect(result.importance == .useful)
        #expect(result.score >= 70)
    }

    @Test
    func explicitImportanceSignalsCreateAnImportantCategory() {
        let result = analyze(
            ageDays: 2,
            text: "Production security incident: action required before deadline"
        )

        #expect(result.importance == .important)
        #expect(result.reasons.contains { $0.contains("importance signal") })
    }

    @Test
    func defaultsFavorFastButRecoverableArchiving() {
        #expect(Configuration.default.minimumAgeDays == 1)
        #expect(Configuration.default.genericScreenshotAgeDays == 7)
        #expect(Configuration.default.duplicateMinimumAgeDays == 0)
        #expect(Configuration.default.machineFiles?.priorityDirectories == ["~/dev"])
    }

    @Test
    func recentCodingScreenshotIsKept() {
        let result = analyze(ageDays: 0, text: "npm test failed in src/server.ts")

        #expect(result.decision == .keep)
        #expect(result.category == .error)
    }

    @Test
    func protectedTextAlwaysKeepsScreenshot() {
        let result = analyze(ageDays: 120, text: "Your recovery code is ABCD-EFGH")

        #expect(result.decision == .keep)
        #expect(result.category == .protected)
        #expect(result.importance == .sensitive)
        #expect(result.score == 0)
    }

    @Test
    func protectedScreenshotCanHaveARecoverableArchiveCeiling() {
        let config = Configuration(protectedMaximumAgeDays: 30)
        let old = analyze(
            ageDays: 31,
            text: "The development login page says password",
            configuration: config
        )
        let recent = analyze(
            ageDays: 29,
            text: "The development login page says password",
            configuration: config
        )

        #expect(old.decision == .archive)
        #expect(old.category == .protected)
        #expect(recent.decision == .keep)
    }

    @Test
    func oldGenericScreenshotIsArchived() {
        let result = analyze(ageDays: 8, text: "A generic paragraph of readable text")

        #expect(result.decision == .archive)
        #expect(result.category == .other)
    }

    @Test
    func exactDuplicateCanBeArchivedEarly() {
        let result = analyze(ageDays: 0, text: "visual reference", duplicate: true)

        #expect(result.decision == .archive)
        #expect(result.isExactDuplicate)
    }

    @Test
    func oneDayOldWebsiteScreenshotIsArchived() {
        let result = analyze(
            ageDays: 1,
            text: "Documentation and examples are available at https://example.dev/docs"
        )

        #expect(result.decision == .archive)
        #expect(result.category == .web)
    }

    @Test
    func oneDayOldTextHeavyScreenshotIsArchived() {
        let result = analyze(
            ageDays: 1,
            text: String(
                repeating: "This is a paragraph of useful text captured for temporary reference. ",
                count: 2
            )
        )

        #expect(result.decision == .archive)
        #expect(result.category == .text)
    }

    @Test
    func recentVisualScreenshotGetsAWeek() {
        let recent = analyze(ageDays: 1, text: "")
        let old = analyze(ageDays: 8, text: "")

        #expect(recent.decision == .keep)
        #expect(recent.category == .visual)
        #expect(old.decision == .archive)
    }

    @Test
    func screenshotDetectorRejectsOrdinaryImages() {
        let detector = ScreenshotDetector(configuration: .default)

        #expect(detector.isScreenshot(URL(fileURLWithPath: "/tmp/Screenshot 2026-01-01.png")))
        #expect(detector.isScreenshot(URL(fileURLWithPath: "/tmp/CleanShot 2026-01-01.jpg")))
        #expect(!detector.isScreenshot(URL(fileURLWithPath: "/tmp/holiday.png")))
        #expect(!detector.isScreenshot(URL(fileURLWithPath: "/tmp/Screenshot notes.txt")))
    }

    private func analyze(
        ageDays: Int,
        text: String?,
        duplicate: Bool = false,
        configuration: Configuration = .default
    ) -> ScreenshotAnalysis {
        let created = Calendar.current.date(byAdding: .day, value: -ageDays, to: now)!
        let file = ScreenshotFile(
            url: URL(fileURLWithPath: "/tmp/Screenshot test.png"),
            createdAt: created,
            modifiedAt: created,
            size: 100
        )
        return ScreenshotRules(configuration: configuration).analyze(
            file: file,
            now: now,
            recognizedText: text,
            isExactDuplicate: duplicate
        )
    }
}
