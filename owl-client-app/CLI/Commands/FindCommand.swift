import ArgumentParser
import Foundation
import OWLBrowserLib

struct FindCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find text in the current page."
    )

    @Argument(help: "Text to search for.")
    var query: String?

    @Flag(name: .long, help: "Stop the current find session.")
    var stop = false

    @Flag(name: .long, help: "Search backward.")
    var backward = false

    @Flag(name: .long, help: "Case-sensitive search.")
    var matchCase = false

    func run() throws {
        if stop {
            do {
                _ = try CLISocketClient.send(command: "find.stop")
                print("Find stopped")
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
            return
        }

        guard let query, !query.isEmpty else {
            fputs("Error: Provide a search query or use --stop.\n", stderr)
            throw ExitCode.failure
        }

        var args: [String: String] = ["query": query]
        if backward { args["forward"] = "0" }
        if matchCase { args["match_case"] = "1" }

        do {
            let response = try CLISocketClient.send(command: "find", args: args)
            if let data = response.data {
                let jsonData = try JSONSerialization.data(
                    withJSONObject: data,
                    options: [.prettyPrinted, .sortedKeys]
                )
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    print(jsonString)
                }
            } else {
                print("Find started for \"\(query)\"")
            }
        } catch let error as CLISocketClient.CLIError {
            fputs("Error: \(error.description)\n", stderr)
            throw ExitCode(error.exitCode)
        }
    }
}
