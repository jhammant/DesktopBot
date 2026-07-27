import DesktopBotCore
import Foundation

struct LaunchAgent {
    static let label = "io.github.desktopbot.daily"

    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func install(hour: Int, minute: Int) throws -> (binary: URL, plist: URL) {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw DesktopBotError.commandFailed("Hour must be 0-23 and minute must be 0-59.")
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw DesktopBotError.commandFailed("Cannot locate the current desktopbot executable.")
        }

        let binDirectory = home.appendingPathComponent(".local/bin", isDirectory: true)
        let installedBinary = binDirectory.appendingPathComponent("desktopbot")
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        if executable.path != installedBinary.path {
            if fileManager.fileExists(atPath: installedBinary.path) {
                try fileManager.removeItem(at: installedBinary)
            }
            try fileManager.copyItem(at: executable, to: installedBinary)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: installedBinary.path
            )
        }

        if !fileManager.fileExists(atPath: Configuration.defaultURL.path) {
            try Configuration.default.write()
        }

        let logs = home.appendingPathComponent("Library/Logs/DesktopBot", isDirectory: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("\(Self.label).plist")
        let payload: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [installedBinary.path, "run", "--apply", "--quiet"],
            "StartCalendarInterval": ["Hour": hour, "Minute": minute],
            "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("daily.log").path,
            "StandardErrorPath": logs.appendingPathComponent("daily-error.log").path
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        )
        try data.write(to: plist, options: .atomic)

        try? launchctl(["bootout", "gui/\(getuid())", plist.path], allowFailure: true)
        try launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        return (installedBinary, plist)
    }

    func uninstall() throws -> URL {
        let plist = home
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(Self.label).plist")
        if fileManager.fileExists(atPath: plist.path) {
            try? launchctl(["bootout", "gui/\(getuid())", plist.path], allowFailure: true)
            try fileManager.removeItem(at: plist)
        }
        return plist
    }

    func status() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(Self.label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func launchctl(_ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || allowFailure else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DesktopBotError.commandFailed(
                "launchctl failed\(message.map { ": \($0)" } ?? ".")"
            )
        }
    }
}
