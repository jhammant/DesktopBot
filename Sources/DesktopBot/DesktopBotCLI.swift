import DesktopBotCore
import Foundation

@main
struct DesktopBotCLI {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(
                Data("desktopbot: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }

    private static func run() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        if !arguments.isEmpty {
            arguments.removeFirst()
        }

        switch command {
        case "run", "scan":
            try runCleanup(arguments: arguments, forceDryRun: command == "scan")
        case "init":
            try initializeConfiguration(arguments: arguments)
        case "install":
            try install(arguments: arguments)
        case "uninstall":
            try uninstall()
        case "status":
            status()
        case "index":
            try refreshIndex(arguments: arguments)
        case "organize", "organise":
            try organizeFolders(arguments: arguments)
        case "mcp":
            try runMCP(arguments: arguments)
        case "files-mcp":
            try MachineFilesMCPServer(
                configuration: loadConfiguration(arguments: arguments)
            ).run()
        case "organizer-mcp", "organiser-mcp":
            try FolderOrganizerMCPServer(
                configuration: loadConfiguration(arguments: arguments)
            ).run()
        case "mcp-config":
            printMCPConfig()
        case "help", "--help", "-h":
            printHelp()
        case "version", "--version":
            print("desktopbot 0.4.0")
        default:
            throw DesktopBotError.commandFailed(
                "Unknown command '\(command)'. Run 'desktopbot help' for usage."
            )
        }
    }

    private static func runCleanup(arguments: [String], forceDryRun: Bool) throws {
        let apply = arguments.contains("--apply") && !forceDryRun
        let quiet = arguments.contains("--quiet")
        let json = arguments.contains("--json")
        let configURL = value(after: "--config", in: arguments)
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? Configuration.defaultURL
        let configuration = try Configuration.load(from: configURL)
        let recognizer: any TextRecognizing = configuration.performOCR
            ? VisionTextRecognizer()
            : NoopTextRecognizer()
        let summary = try CleanupEngine(
            configuration: configuration,
            textRecognizer: recognizer
        ).run(apply: apply)
        let otherFiles = try DesktopFileOrganizer(
            configuration: configuration
        ).run(apply: apply)
        let organizedFolders = try runConfiguredFolderOrganization(
            configuration: configuration,
            apply: apply
        )
        let report = DesktopRunReport(
            screenshots: summary,
            otherFiles: otherFiles,
            organizedFolders: organizedFolders.isEmpty ? nil : organizedFolders
        )

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else if !quiet {
            printSummary(report)
        }

        let failureCount = summary.failureCount
            + (otherFiles?.failureCount ?? 0)
            + organizedFolders.reduce(0) { $0 + $1.failureCount }
        if failureCount > 0 {
            throw DesktopBotError.commandFailed(
                "\(failureCount) file operation(s) failed; no failed source files were removed."
            )
        }
    }

    private static func initializeConfiguration(arguments: [String]) throws {
        let overwrite = arguments.contains("--force")
        let config = Configuration.default
        try config.write(overwrite: overwrite)
        print("Wrote \(Configuration.defaultURL.path)")
        print("Edit it, then preview with: swift run desktopbot scan")
    }

    private static func install(arguments: [String]) throws {
        let hour = Int(value(after: "--hour", in: arguments) ?? "9") ?? -1
        let minute = Int(value(after: "--minute", in: arguments) ?? "0") ?? -1
        let result = try LaunchAgent().install(hour: hour, minute: minute)
        print("Installed \(result.binary.path)")
        print("Scheduled daily cleanup for \(String(format: "%02d:%02d", hour, minute)).")
        print("LaunchAgent: \(result.plist.path)")
        print("Files are moved into dated archives; nothing is permanently deleted.")
    }

    private static func uninstall() throws {
        let plist = try LaunchAgent().uninstall()
        print("Uninstalled daily job \(plist.path)")
        print("The config, audit log, installed binary, and archived screenshots were left intact.")
    }

    private static func status() {
        let loaded = LaunchAgent().status()
        print(loaded ? "DesktopBot daily job is loaded." : "DesktopBot daily job is not loaded.")
    }

    private static func refreshIndex(arguments: [String]) throws {
        let configuration = try loadConfiguration(arguments: arguments)
        let records = try ScreenshotCatalog(configuration: configuration).refreshIndex()
        let indexed = records.filter { $0.ocrText != nil }.count
        print("Indexed \(indexed) of \(records.count) discovered screenshots.")
        print(
            "Catalog: "
                + FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/DesktopBot/catalog.json")
                .path
        )
    }

    private static func organizeFolders(arguments: [String]) throws {
        let configuration = try loadConfiguration(arguments: arguments)
        let apply = arguments.contains("--apply")
        let json = arguments.contains("--json")
        let moveDirectories = !arguments.contains("--files-only")
        let explicitPath = positionalPath(in: arguments)
        let roots: [URL]
        if let explicitPath {
            roots = [
                URL(
                    fileURLWithPath: NSString(string: explicitPath).expandingTildeInPath,
                    isDirectory: true
                ).standardizedFileURL
            ]
        } else {
            roots = configuration.folderOrganizationURLs()
        }
        guard !roots.isEmpty else {
            throw DesktopBotError.commandFailed(
                "No folder supplied and folderOrganization.directories is empty."
            )
        }

        let organizer = FolderOrganizer()
        let summaries = try roots.map {
            try organizer.run(root: $0, apply: apply, moveDirectories: moveDirectories)
        }
        if json {
            if summaries.count == 1 {
                print(try encodedJSON(summaries[0]))
            } else {
                print(try encodedJSON(summaries))
            }
        } else {
            for (index, summary) in summaries.enumerated() {
                if index > 0 { print("") }
                printFolderSummary(summary)
            }
        }
        let failureCount = summaries.reduce(0) { $0 + $1.failureCount }
        if failureCount > 0 {
            throw DesktopBotError.commandFailed(
                "\(failureCount) folder organization move(s) failed; no target was overwritten."
            )
        }
    }

    private static func runConfiguredFolderOrganization(
        configuration: Configuration,
        apply: Bool
    ) throws -> [FolderOrganizationSummary] {
        guard let policy = configuration.folderOrganization, policy.enabled else {
            return []
        }
        let manager = FileManager.default
        let organizer = FolderOrganizer()
        var summaries: [FolderOrganizationSummary] = []
        for root in configuration.folderOrganizationURLs() {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            summaries.append(
                try organizer.run(
                    root: root,
                    apply: apply,
                    moveDirectories: policy.moveDirectories
                )
            )
        }
        return summaries
    }

    private static func runMCP(arguments: [String]) throws {
        let configuration = try loadConfiguration(arguments: arguments)
        try MCPServer(configuration: configuration).run()
    }

    private static func printMCPConfig() {
        let binary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/desktopbot")
            .path
        let quoted = shellQuote(binary)
        print("Codex (personal, shared by the app, CLI, and IDE extension):")
        print("  codex mcp add desktop-screenshots -- \(quoted) mcp")
        print("  codex mcp add machine-files -- \(quoted) files-mcp")
        print("  codex mcp add desktop-organizer -- \(quoted) organizer-mcp")
        print("")
        print("Claude Code (personal, available in every project):")
        print(
            "  claude mcp add --scope user --transport stdio "
                + "desktop-screenshots -- \(quoted) mcp"
        )
        print(
            "  claude mcp add --scope user --transport stdio "
                + "machine-files -- \(quoted) files-mcp"
        )
        print(
            "  claude mcp add --scope user --transport stdio "
                + "desktop-organizer -- \(quoted) organizer-mcp"
        )
    }

    private static func loadConfiguration(arguments: [String]) throws -> Configuration {
        let configURL = value(after: "--config", in: arguments)
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? Configuration.defaultURL
        return try Configuration.load(from: configURL)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func positionalPath(in arguments: [String]) -> String? {
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if argument == "--config" {
                skipNext = true
                continue
            }
            if !argument.hasPrefix("-") {
                return argument
            }
        }
        return nil
    }

    private static func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func printSummary(_ report: DesktopRunReport) {
        let summary = report.screenshots
        let mode = summary.dryRun ? "DRY RUN" : "APPLIED"
        print("DesktopBot \(mode)")
        print("Desktop: \(summary.sourceDirectory)")
        print("")
        print("Screenshots → \(summary.archiveDirectory)")

        if summary.analyses.isEmpty {
            print("No matching screenshot files found.")
        } else {
            for item in summary.analyses {
                let action = item.decision.rawValue.uppercased()
                print(
                    "\(action) [\(item.score)] [\(item.importance.rawValue)] "
                    + "[\(item.category.rawValue)] "
                    + "\(item.fileName) — \(item.reasons.joined(separator: "; "))"
                )
                if item.decision == .archive, let destination = item.destinationPath {
                    print("  → \(destination)")
                }
            }
        }

        print("")
        print(
            "Summary: \(summary.archiveCount) archive, "
            + "\(summary.keepCount) keep, \(summary.failureCount) failed."
        )
        if let files = report.otherFiles {
            print("")
            print("Other files → \(files.archiveDirectory)")
            if files.analyses.isEmpty {
                print("No loose non-screenshot files found.")
            } else {
                for item in files.analyses {
                    let action = item.decision.rawValue.uppercased()
                    print(
                        "\(action) [\(item.category.rawValue)] "
                            + "\(item.fileName) — \(item.reasons.joined(separator: "; "))"
                    )
                    if item.decision == .archive, let destination = item.destinationPath {
                        print("  → \(destination)")
                    }
                }
            }
            print(
                "Summary: \(files.archiveCount) file, "
                    + "\(files.keepCount) keep, \(files.failureCount) failed."
            )
        }
        if let folders = report.organizedFolders {
            for folder in folders {
                print("")
                printFolderSummary(folder)
            }
        }
        if summary.dryRun {
            print("No files changed. Run with '--apply' when the decisions look right.")
        }
    }

    private static func printFolderSummary(_ summary: FolderOrganizationSummary) {
        let mode = summary.dryRun ? "FOLDER DRY RUN" : "FOLDER APPLIED"
        print("\(mode): \(summary.rootDirectory)")
        for item in summary.items where item.decision != .skip {
            let action = item.decision == .archive
                ? (summary.dryRun ? "MOVE" : "MOVED")
                : item.decision.rawValue.uppercased()
            print(
                "\(action) [\(item.kind.rawValue)] [\(item.category.rawValue)] "
                    + "\(item.fileName)"
            )
            if let destination = item.destinationPath {
                print("  → \(destination)")
            }
        }
        print(
            "Before: \(summary.topLevelItemsBefore) visible root items; "
                + "after: \(summary.topLevelItemsAfter). "
                + "\(summary.moveCount) move, \(summary.skipCount) managed/skip, "
                + "\(summary.failureCount) failed."
        )
        if summary.dryRun {
            print("No files changed. Re-run with '--apply' to use this layout.")
        }
    }

    private static func printHelp() {
        print(
            """
            DesktopBot — local, OCR-assisted screenshot cleanup for macOS

            Usage:
              desktopbot scan [--config PATH] [--json]
                  Preview decisions. Never moves files.

              desktopbot run [--apply] [--config PATH] [--json] [--quiet]
                  Preview by default. With --apply, move selected screenshots and
                  old loose files into their dated archives.

              desktopbot init [--force]
                  Create ~/.config/desktopbot/config.json.

              desktopbot install [--hour 9] [--minute 0]
                  Install the current binary and a daily macOS LaunchAgent.

              desktopbot status
                  Report whether the daily LaunchAgent is loaded.

              desktopbot uninstall
                  Remove the daily LaunchAgent. Archived files are not deleted.

              desktopbot index [--config PATH]
                  OCR-index Desktop and archived screenshots for local search.

              desktopbot organize [PATH] [--apply] [--files-only] [--json]
                  Preview a five-bucket organization of a cluttered folder root.
                  Defaults to configured folders. With --apply, moves direct
                  children only; nothing is deleted or overwritten.

              desktopbot mcp [--config PATH]
                  Run the local screenshot MCP server over stdio.

              desktopbot files-mcp [--config PATH]
                  Run the read-only, Spotlight-backed file-search MCP server.

              desktopbot organizer-mcp [--config PATH]
                  Run the narrow preview-and-confirm folder organizer MCP server.

              desktopbot mcp-config
                  Print setup commands for Codex and Claude Code.

            Safety:
              DesktopBot never permanently deletes files. OCR runs locally
              through Apple Vision. Receipt, credential, travel, and recovery-code
              keywords are kept on the Desktop for manual review.
            """
        )
    }
}
