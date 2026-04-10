import ArgumentParser
import Foundation
import OWLBrowserLib

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Manage browsing history.",
        subcommands: [Search.self, Delete.self, Clear.self]
    )

    // MARK: - history search

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search browsing history."
        )

        @Argument(help: "Search query (substring match on URL/title).")
        var query: String

        @Option(name: .long, help: "Maximum results to return (default: 20).")
        var limit: Int = 20

        func run() throws {
            let args: [String: String] = [
                "query": query,
                "max_results": String(limit),
            ]
            do {
                let response = try CLISocketClient.send(command: "history.search", args: args)
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

    // MARK: - history delete

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a URL from history."
        )

        @Argument(help: "The URL to delete from history.")
        var url: String

        func run() throws {
            do {
                let response = try CLISocketClient.send(
                    command: "history.delete",
                    args: ["url": url]
                )
                if response.ok {
                    print("History entry deleted")
                }
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }

    // MARK: - history clear

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clear browsing history."
        )

        @Option(name: .long, help: "Clear since: relative (1h/7d/30m), ISO 8601, or Unix timestamp.")
        var since: String?

        func run() throws {
            var args: [String: String] = [:]
            if let since {
                guard let ts = parseTime(since) else {
                    fputs("Error: Invalid time format '\(since)'. Use: 1h, 7d, 30m, ISO 8601, or Unix timestamp.\n", stderr)
                    throw ExitCode.failure
                }
                args["start_time"] = String(ts)
                args["end_time"] = String(Date().timeIntervalSince1970)
            }

            do {
                let response = try CLISocketClient.send(command: "history.clear", args: args)
                if response.ok {
                    if since != nil {
                        print("History cleared since \(since!)")
                    } else {
                        print("All history cleared")
                    }
                }
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }
}
