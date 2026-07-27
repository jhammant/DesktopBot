import DesktopBotCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class MCPServer {
    private let catalog: ScreenshotCatalog
    private let output = FileHandle.standardOutput

    init(configuration: Configuration) {
        self.catalog = ScreenshotCatalog(configuration: configuration)
    }

    func run() throws {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            do {
                let data = Data(line.utf8)
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    try write(errorResponse(id: NSNull(), code: -32600, message: "Invalid request"))
                    continue
                }
                if let response = try handle(request) {
                    try write(response)
                }
            } catch {
                try write(
                    errorResponse(
                        id: NSNull(),
                        code: -32700,
                        message: "Parse or server error: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func handle(_ request: [String: Any]) throws -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return id.map { errorResponse(id: $0, code: -32600, message: "Missing method") }
        }
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            guard let id else { return nil }
            let requestedVersion = params["protocolVersion"] as? String
            return successResponse(
                id: id,
                result: [
                    "protocolVersion": negotiatedVersion(requestedVersion),
                    "capabilities": [
                        "tools": ["listChanged": false]
                    ],
                    "serverInfo": [
                        "name": "desktopbot-screenshots",
                        "version": "0.3.0"
                    ],
                    "instructions": """
                    Use screenshot_latest when the user refers to their latest or recent screenshot. \
                    Use screenshot_search to find older OCR-indexed captures, then screenshot_get to \
                    inspect one. screenshot_archive only moves a Desktop screenshot into the local \
                    review archive; it never deletes files.
                    """
                ]
            )

        case "notifications/initialized", "notifications/cancelled":
            return nil

        case "ping":
            guard let id else { return nil }
            return successResponse(id: id, result: [:])

        case "tools/list":
            guard let id else { return nil }
            return successResponse(id: id, result: ["tools": toolDefinitions()])

        case "tools/call":
            guard let id else { return nil }
            guard let name = params["name"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return successResponse(id: id, result: callTool(name: name, arguments: arguments))

        default:
            guard let id else { return nil }
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "screenshot_latest":
                let offset = integer(arguments["offset"], default: 0, range: 0...20)
                let location = try optionalLocation(arguments["location"])
                guard let basic = try catalog.latest(offset: offset, location: location) else {
                    return textResult("No matching screenshots were found.")
                }
                let record = try catalog.get(identifier: basic.id, refreshOCR: true) ?? basic
                let includeImage = arguments["include_image"] as? Bool ?? true
                let maxDimension = integer(
                    arguments["max_dimension"],
                    default: 2_000,
                    range: 512...3_000
                )
                return try recordResult(
                    record,
                    includeImage: includeImage,
                    maxDimension: maxDimension
                )

            case "screenshot_list":
                let limit = integer(arguments["limit"], default: 20, range: 1...100)
                let location = try optionalLocation(arguments["location"])
                let category = try optionalCategory(arguments["category"])
                let records = try catalog.list(
                    limit: limit,
                    location: location,
                    category: category
                )
                return jsonResult(records.map { recordDictionary($0, ocrLimit: 500) })

            case "screenshot_search":
                guard let query = arguments["query"] as? String,
                      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return toolError("query must be a non-empty string")
                }
                let limit = integer(arguments["limit"], default: 10, range: 1...50)
                let records = try catalog.search(query: query, limit: limit)
                return jsonResult(records.map { recordDictionary($0, ocrLimit: 1_000) })

            case "screenshot_get":
                guard let identifier = arguments["id"] as? String, !identifier.isEmpty else {
                    return toolError("id must be a screenshot ID or exact path")
                }
                guard let record = try catalog.get(identifier: identifier, refreshOCR: true) else {
                    return toolError("Screenshot not found: \(identifier)")
                }
                let maxDimension = integer(
                    arguments["max_dimension"],
                    default: 2_000,
                    range: 512...3_000
                )
                return try recordResult(record, includeImage: true, maxDimension: maxDimension)

            case "screenshot_archive":
                guard let identifier = arguments["id"] as? String, !identifier.isEmpty else {
                    return toolError("id must be a screenshot ID or exact path")
                }
                let record = try catalog.archive(identifier: identifier)
                return jsonResult([
                    "archived": true,
                    "message": "Moved into the review archive; nothing was deleted.",
                    "screenshot": recordDictionary(record, ocrLimit: 1_000)
                ])

            default:
                return toolError("Unknown tool: \(name)")
            }
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "screenshot_latest",
                "description": """
                Get the newest macOS screenshot as an image plus locally extracted OCR text. \
                Use whenever the user says “my latest screenshot”, “this screenshot”, or refers \
                to a screen capture they just took instead of asking them to paste it.
                """,
                "inputSchema": objectSchema(
                    properties: [
                        "offset": [
                            "type": "integer",
                            "minimum": 0,
                            "maximum": 20,
                            "description": "0 is newest, 1 is the previous screenshot."
                        ],
                        "location": locationSchema(),
                        "include_image": [
                            "type": "boolean",
                            "default": true,
                            "description": "Return the actual image as MCP image content."
                        ],
                        "max_dimension": imageSizeSchema()
                    ]
                ),
                "annotations": readOnlyAnnotations()
            ],
            [
                "name": "screenshot_list",
                "description": "List recent Desktop and archived screenshots with IDs, dates, categories, paths, and OCR previews.",
                "inputSchema": objectSchema(
                    properties: [
                        "limit": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 100,
                            "default": 20
                        ],
                        "location": locationSchema(),
                        "category": [
                            "type": "string",
                            "enum": ScreenshotCategory.allMCPValues,
                            "description": "Optional classification filter."
                        ]
                    ]
                ),
                "annotations": readOnlyAnnotations()
            ],
            [
                "name": "screenshot_search",
                "description": "Search screenshot filenames and the local OCR index. Returns matching IDs and text previews; use screenshot_get to inspect an image.",
                "inputSchema": objectSchema(
                    properties: [
                        "query": [
                            "type": "string",
                            "minLength": 1,
                            "description": "Words or phrase to find in OCR text or filenames."
                        ],
                        "limit": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 50,
                            "default": 10
                        ]
                    ],
                    required: ["query"]
                ),
                "annotations": readOnlyAnnotations()
            ],
            [
                "name": "screenshot_get",
                "description": "Get one screenshot as an image plus full local OCR text using an ID returned by list/search/latest.",
                "inputSchema": objectSchema(
                    properties: [
                        "id": [
                            "type": "string",
                            "description": "Screenshot ID or exact local path."
                        ],
                        "max_dimension": imageSizeSchema()
                    ],
                    required: ["id"]
                ),
                "annotations": readOnlyAnnotations()
            ],
            [
                "name": "screenshot_archive",
                "description": "Move one screenshot from the Desktop into the dated DesktopBot review archive. Does not delete it and refuses paths outside the configured Desktop.",
                "inputSchema": objectSchema(
                    properties: [
                        "id": [
                            "type": "string",
                            "description": "Desktop screenshot ID or exact local path."
                        ]
                    ],
                    required: ["id"]
                ),
                "annotations": [
                    "title": "Archive Desktop screenshot",
                    "readOnlyHint": false,
                    "destructiveHint": false,
                    "idempotentHint": false,
                    "openWorldHint": false
                ]
            ]
        ]
    }

    private func recordResult(
        _ record: ScreenshotRecord,
        includeImage: Bool,
        maxDimension: Int
    ) throws -> [String: Any] {
        var content: [[String: Any]] = [
            [
                "type": "text",
                "text": try jsonString(recordDictionary(record, ocrLimit: 12_000))
            ]
        ]
        if includeImage {
            content.append(try imageContent(for: record.url, maxDimension: maxDimension))
        }
        return ["content": content, "isError": false]
    }

    private func imageContent(for url: URL, maxDimension: Int) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                      kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary
              ) else {
            throw DesktopBotError.commandFailed("Could not decode screenshot image.")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw DesktopBotError.commandFailed("Could not create MCP image payload.")
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw DesktopBotError.commandFailed("Could not encode MCP image payload.")
        }
        return [
            "type": "image",
            "data": (data as Data).base64EncodedString(),
            "mimeType": "image/jpeg"
        ]
    }

    private func recordDictionary(
        _ record: ScreenshotRecord,
        ocrLimit: Int
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": record.id,
            "fileName": record.fileName,
            "path": record.path,
            "createdAt": Self.iso8601(record.createdAt),
            "modifiedAt": Self.iso8601(record.modifiedAt),
            "sizeBytes": record.size,
            "location": record.location.rawValue
        ]
        if let category = record.category {
            value["category"] = category.rawValue
        }
        if let text = record.ocrText {
            value["ocrText"] = String(text.prefix(ocrLimit))
            value["ocrTextTruncated"] = text.count > ocrLimit
        }
        return value
    }

    private func textResult(_ text: String) -> [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": false
        ]
    }

    private func jsonResult(_ value: Any) -> [String: Any] {
        do {
            return textResult(try jsonString(value))
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func toolError(_ message: String) -> [String: Any] {
        [
            "content": [["type": "text", "text": message]],
            "isError": true
        ]
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func objectSchema(
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    private func locationSchema() -> [String: Any] {
        [
            "type": "string",
            "enum": ["any", "desktop", "archive"],
            "default": "any",
            "description": "Where to look for screenshots."
        ]
    }

    private func imageSizeSchema() -> [String: Any] {
        [
            "type": "integer",
            "minimum": 512,
            "maximum": 3_000,
            "default": 2_000,
            "description": "Maximum width or height of the returned JPEG."
        ]
    }

    private func readOnlyAnnotations() -> [String: Any] {
        [
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false
        ]
    }

    private func optionalLocation(_ value: Any?) throws -> ScreenshotLocation? {
        guard let value = value as? String, value != "any" else { return nil }
        guard let location = ScreenshotLocation(rawValue: value) else {
            throw DesktopBotError.commandFailed("location must be any, desktop, or archive")
        }
        return location
    }

    private func optionalCategory(_ value: Any?) throws -> ScreenshotCategory? {
        guard let value = value as? String else { return nil }
        guard let category = ScreenshotCategory(rawValue: value) else {
            throw DesktopBotError.commandFailed("Unknown screenshot category: \(value)")
        }
        return category
    }

    private func integer(_ value: Any?, default defaultValue: Int, range: ClosedRange<Int>) -> Int {
        let parsed = (value as? NSNumber)?.intValue ?? defaultValue
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    private func negotiatedVersion(_ requested: String?) -> String {
        let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
        guard let requested, supported.contains(requested) else {
            return "2025-11-25"
        }
        return requested
    }

    private func successResponse(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
    }

    private func write(_ response: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        data.append(0x0A)
        try output.write(contentsOf: data)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension ScreenshotCategory {
    static var allMCPValues: [String] {
        [
            ScreenshotCategory.coding,
            .error,
            .web,
            .text,
            .protected,
            .visual,
            .other,
            .unreadable
        ].map(\.rawValue)
    }
}
