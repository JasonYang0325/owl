import ArgumentParser
import Foundation
import OWLBrowserLib

struct BookmarkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bookmark",
        abstract: "Manage bookmarks.",
        subcommands: [Add.self, List.self, Remove.self]
    )

    // MARK: - bookmark add

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a bookmark."
        )

        @Argument(help: "The URL to bookmark.")
        var url: String

        @Argument(help: "Bookmark title (defaults to URL).")
        var title: String?

        func run() throws {
            let args: [String: String] = [
                "url": url,
                "title": title ?? url,
            ]
            do {
                let response = try CLISocketClient.send(command: "bookmark.add", args: args)
                if let result = response.data?["result"] {
                    print(result)
                } else {
                    print("Bookmark added")
                }
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }

    // MARK: - bookmark list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all bookmarks."
        )

        @Option(name: .long, help: "Filter by title/URL substring.")
        var query: String?

        func run() throws {
            var args: [String: String] = [:]
            if let query { args["query"] = query }

            do {
                let response = try CLISocketClient.send(command: "bookmark.list", args: args)
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

    // MARK: - bookmark remove

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a bookmark by ID."
        )

        @Argument(help: "The bookmark ID to remove.")
        var id: String

        func run() throws {
            do {
                let response = try CLISocketClient.send(
                    command: "bookmark.remove",
                    args: ["id": id]
                )
                if response.ok {
                    print("Bookmark removed")
                }
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }
}
