import Foundation

public struct ScreenshotRules: Sendable {
    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func analyze(
        file: ScreenshotFile,
        now: Date,
        recognizedText: String?,
        isExactDuplicate: Bool
    ) -> ScreenshotAnalysis {
        let ageDays = max(
            0,
            Calendar.current.dateComponents([.day], from: file.createdAt, to: now).day ?? 0
        )
        let normalizedText = (recognizedText ?? "").lowercased()
        let preview = Self.preview(recognizedText)
        var reasons: [String] = []

        let keepMatches = matchingKeywords(configuration.keepKeywords, in: normalizedText)
        if !keepMatches.isEmpty {
            reasons.append("OCR found keep-safe text: \(keepMatches.prefix(3).joined(separator: ", "))")
            let reachedMaximumAge = configuration.protectedMaximumAgeDays
                .map { ageDays >= $0 } ?? false
            if let maximumAge = configuration.protectedMaximumAgeDays, reachedMaximumAge {
                reasons.append(
                    "protected capture reached \(maximumAge)d maximum; moving to recoverable archive"
                )
            }
            return ScreenshotAnalysis(
                sourcePath: file.url.path,
                fileName: file.url.lastPathComponent,
                ageDays: ageDays,
                category: .protected,
                importance: .sensitive,
                score: reachedMaximumAge ? 200 : 0,
                decision: reachedMaximumAge ? .archive : .keep,
                reasons: reasons,
                isExactDuplicate: isExactDuplicate,
                ocrTextPreview: preview
            )
        }

        let errorMatches = matchingKeywords(configuration.errorKeywords, in: normalizedText)
        let codingMatches = matchingKeywords(configuration.codingKeywords, in: normalizedText)
        let category: ScreenshotCategory
        if !errorMatches.isEmpty {
            category = .error
        } else if !codingMatches.isEmpty {
            category = .coding
        } else if Self.looksLikeWebContent(normalizedText) {
            category = .web
        } else if recognizedText == nil {
            category = .unreadable
        } else if normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
            category = .visual
        } else if normalizedText.count >= 80 {
            category = .text
        } else {
            category = .other
        }
        let importantMatches = matchingKeywords(
            configuration.importantKeywords ?? Configuration.defaultImportantKeywords,
            in: normalizedText
        )
        let importance: ScreenshotImportance
        if !importantMatches.isEmpty {
            importance = .important
            reasons.append(
                "OCR found importance signal: "
                    + importantMatches.prefix(3).joined(separator: ", ")
            )
        } else if isExactDuplicate {
            importance = .routine
        } else {
            switch category {
            case .coding, .error, .web, .text:
                importance = .useful
            case .protected:
                importance = .sensitive
            case .visual, .other, .unreadable:
                importance = .routine
            }
        }

        var score = 0

        if isExactDuplicate, ageDays >= configuration.duplicateMinimumAgeDays {
            score += 100
            reasons.append("exact duplicate and at least \(configuration.duplicateMinimumAgeDays)d old")
        }

        if ageDays >= configuration.genericScreenshotAgeDays {
            score += 55
            reasons.append("at least \(configuration.genericScreenshotAgeDays)d old")
        } else if ageDays >= configuration.minimumAgeDays {
            score += 30
            reasons.append("at least \(configuration.minimumAgeDays)d old")
        } else {
            reasons.append("newer than \(configuration.minimumAgeDays)d")
        }

        score += 15
        reasons.append("matches a configured screenshot filename")

        switch category {
        case .error:
            score += 30
            reasons.append("OCR looks like an error/debugging capture")
        case .coding:
            score += 30
            reasons.append("OCR looks coding-related")
        case .web:
            score += 30
            reasons.append("OCR looks like a website/browser capture")
        case .text:
            score += 30
            reasons.append("OCR contains substantial readable text")
        case .visual:
            reasons.append("little or no OCR text; treating as a visual reference")
        case .other:
            reasons.append("OCR text is not clearly coding-related")
        case .unreadable:
            reasons.append("OCR was unavailable or failed")
        case .protected:
            break
        }

        let oldEnough = ageDays >= configuration.minimumAgeDays
            || (isExactDuplicate && ageDays >= configuration.duplicateMinimumAgeDays)
        let decision: CleanupDecision =
            oldEnough && score >= configuration.cleanupThreshold ? .archive : .keep
        if decision == .keep {
            reasons.append("score \(score) is below threshold \(configuration.cleanupThreshold)")
        } else {
            reasons.append("score \(score) meets threshold \(configuration.cleanupThreshold)")
        }

        return ScreenshotAnalysis(
            sourcePath: file.url.path,
            fileName: file.url.lastPathComponent,
            ageDays: ageDays,
            category: category,
            importance: importance,
            score: score,
            decision: decision,
            reasons: reasons,
            isExactDuplicate: isExactDuplicate,
            ocrTextPreview: preview
        )
    }

    private func matchingKeywords(_ keywords: [String], in normalizedText: String) -> [String] {
        guard !normalizedText.isEmpty else { return [] }
        return keywords.filter { normalizedText.contains($0.lowercased()) }
    }

    private static func preview(_ text: String?) -> String? {
        guard let text else { return nil }
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return "" }
        return String(singleLine.prefix(240))
    }

    private static func looksLikeWebContent(_ normalizedText: String) -> Bool {
        guard !normalizedText.isEmpty else { return false }
        let browserSignals = [
            "http://",
            "https://",
            "www.",
            "sign in",
            "log in",
            "privacy policy",
            "accept cookies",
            "search results"
        ]
        if browserSignals.contains(where: normalizedText.contains) {
            return true
        }
        return normalizedText.range(
            of: #"\b[a-z0-9][a-z0-9-]*\.(com|org|net|io|dev|app|co\.uk)\b"#,
            options: .regularExpression
        ) != nil
    }
}
