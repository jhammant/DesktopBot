import Foundation

public enum ScreenshotArchiveNaming {
    public static func directory(
        archiveRoot: URL,
        referenceDate: Date,
        category: ScreenshotCategory,
        importance: ScreenshotImportance,
        groupByImportance: Bool
    ) -> URL {
        let calendar = Calendar.current
        var directory = archiveRoot
            .appendingPathComponent(String(calendar.component(.year, from: referenceDate)))
            .appendingPathComponent(
                String(format: "%02d", calendar.component(.month, from: referenceDate))
            )
        if groupByImportance {
            directory.appendPathComponent(importance.rawValue, isDirectory: true)
        }
        return directory.appendingPathComponent(category.rawValue, isDirectory: true)
    }

    public static func fileName(
        source: URL,
        referenceDate: Date,
        category: ScreenshotCategory,
        importance: ScreenshotImportance,
        recognizedText: String?,
        rename: Bool
    ) -> String {
        guard rename else { return source.lastPathComponent }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        var components = [
            formatter.string(from: referenceDate),
            importance.rawValue,
            category.rawValue
        ]
        if importance != .sensitive,
           let topic = safeTopic(from: recognizedText, category: category) {
            components.append(topic)
        }
        let stem = components.joined(separator: "-")
        let ext = source.pathExtension.lowercased()
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    public static func defaultImportance(
        for category: ScreenshotCategory
    ) -> ScreenshotImportance {
        switch category {
        case .protected:
            return .sensitive
        case .coding, .error, .web, .text:
            return .useful
        case .visual, .other, .unreadable:
            return .routine
        }
    }

    private static func safeTopic(
        from text: String?,
        category: ScreenshotCategory
    ) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let normalized = text.lowercased()
        let matches = normalized.matches(of: /[a-z][a-z0-9.+#_-]{2,24}/)
            .map { String($0.output) }
        var selected: [String] = []
        for token in matches {
            let slug = token
                .replacingOccurrences(
                    of: #"[^a-z0-9]+"#,
                    with: "-",
                    options: .regularExpression
                )
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard slug.count >= 3,
                  !stopWords.contains(slug),
                  !selected.contains(slug),
                  !looksSensitive(token: slug) else {
                continue
            }
            selected.append(slug)
            if selected.count == 4 { break }
        }
        guard !selected.isEmpty else { return nil }
        let topic = selected.joined(separator: "-")
        return topic == category.rawValue ? nil : topic
    }

    private static func looksSensitive(token: String) -> Bool {
        if token.count > 20 { return true }
        let digits = token.filter(\.isNumber).count
        let letters = token.filter(\.isLetter).count
        return digits >= 4 && letters >= 2
    }

    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "been", "before",
        "but", "can", "click", "could", "does", "error", "for", "from",
        "have", "here", "into", "just", "more", "not", "now", "page",
        "please", "screenshot", "that", "the", "their", "then", "there",
        "these", "this", "use", "using", "was", "were", "what", "when",
        "where", "which", "will", "with", "you", "your"
    ]
}
