import DesktopBotCore
import Foundation

final class FolderOrganizerMCPServer {
    private let organizer: FolderOrganizer
    private let allowedRoots: [URL]
    private let defaultRoot: URL?
    private let moveDirectories: Bool
    private let output = FileHandle.standardOutput
    private var pendingPlans: [String: FolderOrganizationSummary] = [:]

    init(configuration: Configuration) {
        self.organizer = FolderOrganizer()
        self.allowedRoots = configuration.folderOrganizationURLs()
        self.defaultRoot = allowedRoots.first
        self.moveDirectories = configuration.folderOrganization?.moveDirectories ?? true
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
                if let response = try handle(request) {
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

    private func handle(_ request: [String: Any]) throws -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return id.map { error(id: $0, code: -32600, message: "Missing method") }
        }
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            guard let id else { return nil }
            return success(
                id: id,
                result: [
                    "protocolVersion": negotiatedVersion(params["protocolVersion"] as? String),
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": [
                        "name": "desktopbot-folder-organizer",
                        "version": "0.3.0"
                    ],
                    "instructions": """
                    Use folder_organize_preview first. Show the proposed moves to the user, then \
                    call folder_organize_apply only with the one-time confirmation token returned \
                    by that preview. The server only handles configured folders, only moves direct \
                    children, never deletes, never overwrites, and records applied runs locally.
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
            case "folder_organize_preview":
                let root = try allowedRoot(arguments["path"] as? String)
                let plan = try organizer.preview(
                    root: root,
                    moveDirectories: moveDirectories
                )
                let token = UUID().uuidString
                pendingPlans[token] = plan
                if pendingPlans.count > 20, let first = pendingPlans.keys.first {
                    pendingPlans.removeValue(forKey: first)
                }
                return jsonResult([
                    "confirmationToken": token,
                    "message": "Dry run only. Review every move before applying this one-time token.",
                    "plan": try jsonObject(plan)
                ])

            case "folder_organize_apply":
                guard let token = arguments["confirmation_token"] as? String,
                      !token.isEmpty else {
                    return toolError(
                        "confirmation_token must come from folder_organize_preview"
                    )
                }
                guard let plan = pendingPlans.removeValue(forKey: token) else {
                    return toolError(
                        "Unknown or expired confirmation token. Preview the folder again."
                    )
                }
                let summary = try organizer.apply(plan)
                return jsonResult([
                    "message": "Applied the reviewed plan. Nothing was deleted or overwritten.",
                    "result": try jsonObject(summary)
                ])

            default:
                return toolError("Unknown tool: \(name)")
            }
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func allowedRoot(_ requested: String?) throws -> URL {
        let candidate: URL
        if let requested, !requested.isEmpty {
            candidate = URL(
                fileURLWithPath: NSString(string: requested).expandingTildeInPath,
                isDirectory: true
            )
        } else if let defaultRoot {
            candidate = defaultRoot
        } else {
            throw DesktopBotError.commandFailed(
                "No folderOrganization.directories are configured."
            )
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard allowedRoots.contains(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL.path == resolved.path
        }) else {
            throw DesktopBotError.commandFailed(
                "Folder is not an exact configured organizer root: \(resolved.path)"
            )
        }
        return resolved
    }

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "folder_organize_preview",
                "description": """
                Preview a safe five-bucket organization of one configured folder. Classifies \
                screenshots, documents, generated assets, images, archives, and direct child \
                folders. Returns every proposed move plus a one-time confirmation token; changes \
                nothing.
                """,
                "inputSchema": objectSchema(
                    properties: [
                        "path": [
                            "type": "string",
                            "description": "Optional exact configured root. Defaults to the first configured folder."
                        ]
                    ]
                ),
                "annotations": readOnlyAnnotations()
            ],
            [
                "name": "folder_organize_apply",
                "description": """
                Apply exactly one previously previewed folder plan using its one-time confirmation \
                token. Moves direct children into managed subfolders. Never deletes, merges \
                directories, or overwrites an existing target.
                """,
                "inputSchema": objectSchema(
                    properties: [
                        "confirmation_token": [
                            "type": "string",
                            "description": "One-time token returned by folder_organize_preview."
                        ]
                    ],
                    required: ["confirmation_token"]
                ),
                "annotations": [
                    "title": "Apply reviewed folder organization",
                    "readOnlyHint": false,
                    "destructiveHint": true,
                    "idempotentHint": false,
                    "openWorldHint": false
                ]
            ]
        ]
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
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
