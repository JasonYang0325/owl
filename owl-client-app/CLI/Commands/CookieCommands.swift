import ArgumentParser
import Foundation
import OWLBrowserLib

struct CookieCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cookie",
        abstract: "Manage browser cookies.",
        subcommands: [List.self, Delete.self]
    )

    // MARK: - cookie list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List cookie domains and counts."
        )

        @Option(name: .long, help: "Filter by domain substring.")
        var domain: String?

        func run() throws {
            var args: [String: String] = [:]
            if let domain { args["domain"] = domain }

            do {
                let response = try CLISocketClient.send(command: "cookie.list", args: args)
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

    // MARK: - cookie delete

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete all cookies for a domain."
        )

        @Argument(help: "The domain to delete cookies for.")
        var domain: String

        func run() throws {
            do {
                let response = try CLISocketClient.send(
                    command: "cookie.delete",
                    args: ["domain": domain]
                )
                if let data = response.data, let deleted = data["deleted"] {
                    print("Deleted \(deleted) cookie(s) for \(domain)")
                }
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }
}
