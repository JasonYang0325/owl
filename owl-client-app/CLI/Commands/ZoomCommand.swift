import ArgumentParser
import Foundation
import OWLBrowserLib

struct ZoomCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zoom",
        abstract: "Get or set the page zoom level."
    )

    @Argument(help: "Zoom level to set (e.g. 0.0=100%, 1.0=zoom in, -1.0=zoom out). Omit to show current level.")
    var level: Double?

    func run() throws {
        if let level {
            // Set zoom level
            do {
                _ = try CLISocketClient.send(
                    command: "zoom.set",
                    args: ["level": String(level)]
                )
                print("Zoom level set to \(level)")
            } catch let error as CLISocketClient.CLIError {
                fputs("Error: \(error.description)\n", stderr)
                throw ExitCode(error.exitCode)
            }
        } else {
            // Get current zoom level
            do {
                let response = try CLISocketClient.send(command: "zoom.get")
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
