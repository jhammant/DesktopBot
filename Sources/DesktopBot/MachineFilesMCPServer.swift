import DesktopBotCore
import Foundation

final class MachineFilesMCPServer {
    private let index: MachineFileIndex
    private let output = FileHandle.standardOutput

    init(configuration: Configuration) {
        let policy = configuration.machineFiles ?? .default
        self.index = MachineFileIndex(
            allowedRoots: configuration.machineFileRootURLs(),
            priorityDirectories: configuration.machineFilePriorityURLs(),
            allowTextExcerpts: policy.allowTextExcerpts,
            maximumExcerptCharacters: policy.maximumExcerptCharacters
        )
    }

    func run() throws {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            do {
                guard let request = try JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                ) as? [String: Any] else {
                    try write(error(id: NSNull(), code: -32600, message: "Invalid request"))
                    continue
                }
                if let response = handle(request) {
                    try write(response)
                }
            } catch let caughtError {
                try write(
                    error(
                        id: NSNull(),
                        code: -32700,
                        message: "Parse or server error: \(caughtError.localizedDescription)"
                    )
                )
            }
        }
    }

    private func handle(_ request: [String: Any]) -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return id.map { error(id: $0, code: -32600, message: "Missing method") }
        }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            guard let id else { return nil }
            let requested = params["protocolVersion"] as? String
            return success(
                id: id,
                result: [
                    "protocolVersion": negotiatedVersion(requested),
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": [
                        "name": "desktopbot-machine-files",
                        "version": "0.3.0"
                    ],
                    "instructions": """
                    Use file_search for a small candidate list, then file_excerpt with the same \
                    query to retrieve only relevant local passages and conserve tokens. Search is \
                    limited to configured roots. No tool changes files. Prefer excerpts over whole \
                    documents; use the host’s normal file tools only when more context is needed.
                    """
                ]
            )
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            guard let id else { return nil }
            return success(id: id, result: [:])
        case "tools/list":
            guard let id else { return nil }
            return success(id: id, result: ["tools": toolDefinitions()])
        case "tools/call":
            guard let id else { return nil }
            guard let name = params["name"] as? String else {
                return error(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return success(id: id, result: callTool(name, arguments))
        default:
            guard let id else { return nil }
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "file_search":
                guard let query = arguments["query"] as? String,
                      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return toolError("query must be a non-empty string")
                }
                let mode = arguments["mode"] as? String ?? "smart"
                guard mode == "smart" || mode == "name" else {
                    return toolError("mode must be smart or name")
                }
                let kindValue = arguments["kind"] as? String ?? "any"
                let kind: MachineFileKind?
                switch kindValue {
                case "any": kind = nil
                case "file": kind = .file
                case "directory": kind = .directory
                default: return toolError("kind must be any, file, or directory")
                }
                let records = try index.search(
                    query: query,
                    nameOnly: mode == "name",
                    scope: arguments["scope"] as? String,
                    limit: integer(arguments["limit"], default: 15, range: 1...100),
                    includeLibrary: arguments["include_library"] as? Bool ?? false,
                    kind: kind
                )
                return jsonResult(records.map(recordDictionary))

            case "file_info":
                guard let paths = arguments["paths"] as? [String] else {
                    return toolError("paths must be an array of 1 to 20 strings")
                }
                return jsonResult(try index.info(paths: paths).map(recordDictionary))

            case "file_inventory":
                return jsonResult(
                    try index.inventory().map {
                        [
                            "directory": $0.directory,
                            "indexedItemCount": $0.indexedItemCount
                        ] as [String: Any]
                    }
                )

            case "file_excerpt":
                guard let path = arguments["path"] as? String, !path.isEmpty else {
                    return toolError("path must be an exact allow-listed file path")
                }
                let excerpt = try index.excerpt(
                    path: path,
                    query: arguments["query"] as? String,
                    maximumCharacters: integer(
                        arguments["max_chars"],
                        default: 4_000,
                        range: 500...50_000
                    )
                )
                return jsonResult([
                    "path": excerpt.path,
                    "query": excerpt.query.map { $0 as Any } ?? NSNull(),
                    "excerpts": excerpt.excerpts,
                    "extractedCharacterCount": excerpt.extractedCharacterCount,
                    "returnedCharacterCount": excerpt.returnedCharacterCount,
                    "truncated": excerpt.truncated
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
                "name": "file_search",
                "description": """
                Search macOS Spotlight across configured local or mounted roots. Smart mode can \
                match filenames, metadata, and indexed document contents; results stay compact \
                and contain paths and metadata only.
                """,
                "inputSchema": objectSchema(
                    properties: [
                        "query": [
                            "type": "string",
                            "minLength": 1,
                            "description": "Filename words, document-content words, or a Spotlight query."
                        ],
                        "mode": [
                            "type": "string",
                            "enum": ["smart", "name"],
                            "default": "smart",
                            "description": "Use name for filename-only matching."
                        ],
                        "scope": [
                            "type": "string",
                            "description": "Optional directory within the home folder, such as ~/Documents."
                        ],
                        "kind": [
                            "type": "string",
                            "enum": ["any", "file", "directory"],
                            "default": "any"
                        ],
                        "limit": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 100,
                            "default": 15
                        ],
                        "include_library": [
                            "type": "boolean",
                            "default": false,
                            "description": "Include ~/Library and dot-directories, which are noisy and may be sensitive."
                        ]
                    ],
                    required: ["query"]
                ),
                "annotations": readOnlyAnnotations()
            ],
            [
                "name": "file_info",
                "description": "Get filesystem metadata for up to 20 exact paths within the user’s home folder. Does not read file contents.",
                "inputSchema": objectSchema(
                    properties: [
                        "paths": [
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 20,
                            "items": ["type": "string"]
                        ]
                    ],
                    required: ["paths"]
                ),
                "annotations": readOnlyAnnotations()
            ],
            [
                "name": "file_inventory",
                "description": "Get Spotlight-indexed item counts for common home folders to provide a compact map of where files live.",
                "inputSchema": objectSchema(properties: [:]),
                "annotations": readOnlyAnnotations()
            ],
            [
                "name": "file_excerpt",
                "description": """
                Extract a bounded local text excerpt from one selected text, source, PDF, RTF, \
                HTML, Word, or OpenDocument file. With query, returns up to three passages around \
                matches instead of the whole document to reduce context-window and token use.
                """,
                "inputSchema": objectSchema(
                    properties: [
                        "path": [
                            "type": "string",
                            "description": "Exact path returned by file_search."
                        ],
                        "query": [
                            "type": "string",
                            "description": "Optional words or phrase used to select relevant passages."
                        ],
                        "max_chars": [
                            "type": "integer",
                            "minimum": 500,
                            "maximum": 50_000,
                            "default": 4_000,
                            "description": "Hard output character budget; configuration may impose a lower ceiling."
                        ]
                    ],
                    required: ["path"]
                ),
                "annotations": readOnlyAnnotations()
            ]
        ]
    }

    private func recordDictionary(_ record: MachineFileRecord) -> [String: Any] {
        var value: [String: Any] = [
            "path": record.path,
            "name": record.name,
            "extension": record.fileExtension,
            "kind": record.kind.rawValue
        ]
        if let type = record.typeDescription { value["type"] = type }
        if let date = record.createdAt { value["createdAt"] = iso8601(date) }
        if let date = record.modifiedAt { value["modifiedAt"] = iso8601(date) }
        if let size = record.size { value["sizeBytes"] = size }
        return value
    }

    private func objectSchema(
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var value: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { value["required"] = required }
        return value
    }

    private func readOnlyAnnotations() -> [String: Any] {
        [
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false
        ]
    }

    private func integer(_ value: Any?, default defaultValue: Int, range: ClosedRange<Int>) -> Int {
        let parsed = (value as? NSNumber)?.intValue ?? defaultValue
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    private func jsonResult(_ value: Any) -> [String: Any] {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return [
                "content": [
                    ["type": "text", "text": String(decoding: data, as: UTF8.self)]
                ],
                "isError": false
            ]
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

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func negotiatedVersion(_ requested: String?) -> String {
        let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
        guard let requested, supported.contains(requested) else {
            return "2025-11-25"
        }
        return requested
    }

    private func success(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
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
}
