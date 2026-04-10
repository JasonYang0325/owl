import ArgumentParser
import Foundation
import OWLBrowserLib

struct ConsoleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "console",
        abstract: "Console log messages from the active page.",
        subcommands: [ListMessages.self],
        defaultSubcommand: ListMessages.self
    )

    // MARK: - console list

    struct ListMessages: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List console messages (default: last 50)."
        )

        @Option(name: .long, help: "Filter by level: error, warning, info, verbose.")
        var level: String?

        @Option(name: .long, help: "Maximum messages to return (1-1000, default: 50).")
        var limit: Int = 50

        func run() throws {
            // Validate limit
            let clampedLimit = max(1, min(1000, limit))

            var args: [String: String] = [
                "limit": String(clampedLimit),
            ]
            if let level {
                let normalized = level.lowercased()
                guard ["error", "warning", "info", "verbose"].contains(normalized) else {
                    fputs("Error: Invalid level '\(level)'. Use: error, warning, info, verbose.\n", stderr)
                    throw ExitCode.failure
                }
                args["level"] = normalized
            }

            do {
                let response = try CLISocketClient.send(command: "console.list", args: args)
                if let result = response.data?["result"] {
                    print(result)
                } else if let data = response.data {
                    let jsonData = try JSONSerialization.data(
                        withJSONObject: data,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    if let jsonString = String(data: jsonData, encoding: .utf8) {
                        print(jsonString)
                    }
                }
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }
}
