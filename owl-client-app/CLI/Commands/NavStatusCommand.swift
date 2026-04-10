import ArgumentParser
import Foundation
import OWLBrowserLib

struct NavCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nav",
        abstract: "Navigation status and event history.",
        subcommands: [Status.self, Events.self]
    )

    // MARK: - nav status

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show current navigation state (loading/error/idle)."
        )

        func run() throws {
            do {
                let response = try CLISocketClient.send(command: "nav.status")
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

    // MARK: - nav events

    struct Events: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show recent navigation events."
        )

        @Option(name: .long, help: "Maximum events to return (1-100, default: 20).")
        var limit: Int = 20

        func run() throws {
            let args: [String: String] = [
                "limit": String(limit),
            ]
            do {
                let response = try CLISocketClient.send(command: "nav.events", args: args)
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
