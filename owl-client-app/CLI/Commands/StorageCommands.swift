import ArgumentParser
import Foundation
import OWLBrowserLib

struct StorageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "Inspect browser storage usage.",
        subcommands: [Usage.self],
        defaultSubcommand: Usage.self
    )

    // MARK: - storage usage

    struct Usage: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show storage usage per origin."
        )

        func run() throws {
            do {
                let response = try CLISocketClient.send(command: "storage.usage")
                if let result = response.data?["result"] {
                    // result is pre-encoded JSON from the router; print directly
                    // to avoid double-encoding
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
