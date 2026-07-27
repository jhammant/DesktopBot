import AppKit
import Foundation
import Testing
@testable import DesktopBotCore

struct VisionOCRTests {
    @Test
    @MainActor
    func recognizesTextFromGeneratedScreenshot() throws {
        let image = NSImage(size: NSSize(width: 900, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 180).fill()
        ("fatal error at localhost" as NSString).draw(
            at: NSPoint(x: 30, y: 65),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 48, weight: .regular),
                .foregroundColor: NSColor.black
            ]
        )
        image.unlockFocus()

        let bitmap = try #require(
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        )
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktopbot-ocr-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try VisionTextRecognizer().recognizeText(in: url).lowercased()

        #expect(text.contains("fatal"))
        #expect(text.contains("localhost"))
    }
}
