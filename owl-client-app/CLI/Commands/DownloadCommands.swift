import ArgumentParser
import Foundation
import OWLBrowserLib

struct DownloadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Manage downloads.",
        subcommands: [List.self, Pause.self, Resume.self, Cancel.self]
    )

    // MARK: - download list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all downloads."
        )

        func run() throws {
            do {
                let response = try CLISocketClient.send(command: "download.list")
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

    // MARK: - download pause

    struct Pause: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pause a download."
        )

        @Argument(help: "The download ID to pause.")
        var id: UInt32

        func run() throws {
            do {
                _ = try CLISocketClient.send(
                    command: "download.pause",
                    args: ["id": String(id)]
                )
                print("Download \(id) paused")
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }

    // MARK: - download resume

    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Resume a paused download."
        )

        @Argument(help: "The download ID to resume.")
        var id: UInt32

        func run() throws {
            do {
                _ = try CLISocketClient.send(
                    command: "download.resume",
                    args: ["id": String(id)]
                )
                print("Download \(id) resumed")
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }

    // MARK: - download cancel

    struct Cancel: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Cancel a download."
        )

        @Argument(help: "The download ID to cancel.")
        var id: UInt32

        func run() throws {
            do {
                _ = try CLISocketClient.send(
                    command: "download.cancel",
                    args: ["id": String(id)]
                )
                print("Download \(id) cancelled")
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }
}
