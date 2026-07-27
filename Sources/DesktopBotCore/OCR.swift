import Foundation
import Vision

public protocol TextRecognizing: Sendable {
    func recognizeText(in imageURL: URL) throws -> String
}

public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognizeText(in imageURL: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-GB", "en-US"]

        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

public struct NoopTextRecognizer: TextRecognizing {
    public init() {}

    public func recognizeText(in imageURL: URL) throws -> String {
        ""
    }
}
