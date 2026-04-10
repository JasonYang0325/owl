import ArgumentParser
import Foundation
import OWLBrowserLib

struct PageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "page",
        abstract: "Get information about the current page.",
        subcommands: [Info.self],
        defaultSubcommand: Info.self
    )

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print title, URL, and loading state of the active tab."
        )

        @Option(name: .long, help: "Tab index (default: active tab).")
        var tab: Int?

        func run() throws {
            var args: [String: String] = [:]
            if let tab { args["tab"] = String(tab) }

            do {
                let response = try CLISocketClient.send(command: "page.info", args: args)
                // Pretty-print the data as JSON
                if let data = response.data {
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
