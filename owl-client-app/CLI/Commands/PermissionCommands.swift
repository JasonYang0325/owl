import ArgumentParser
import Foundation
import OWLBrowserLib

struct PermissionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permission",
        abstract: "Manage site permissions.",
        subcommands: [Get.self, Set.self, List.self]
    )

    // MARK: - permission get

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Get a permission status for an origin."
        )

        @Argument(help: "Origin (e.g. https://example.com).")
        var origin: String

        @Argument(help: "Permission type: camera, microphone, geolocation, notifications.")
        var type: String

        func run() throws {
            let args: [String: String] = [
                "origin": origin,
                "type": type,
            ]
            do {
                let response = try CLISocketClient.send(command: "permission.get", args: args)
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

    // MARK: - permission set

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a permission status for an origin."
        )

        @Argument(help: "Origin (e.g. https://example.com).")
        var origin: String

        @Argument(help: "Permission type: camera, microphone, geolocation, notifications.")
        var type: String

        @Argument(help: "Status: granted, denied, ask.")
        var status: String

        func run() throws {
            let args: [String: String] = [
                "origin": origin,
                "type": type,
                "status": status,
            ]
            do {
                _ = try CLISocketClient.send(command: "permission.set", args: args)
                print("Permission set: \(origin) \(type) = \(status)")
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        }
    }

    // MARK: - permission list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all stored permissions."
        )

        func run() throws {
            do {
                let response = try CLISocketClient.send(command: "permission.list")
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
