import ArgumentParser
import Foundation
import OWLBrowserLib

struct NavigateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "navigate",
        abstract: "Navigate the active tab to a URL."
    )

    @Argument(help: "The URL to navigate to.")
    var url: String

    @Option(name: .long, help: "Tab index (default: active tab).")
    var tab: Int?

    func run() throws {
        var args: [String: String] = ["url": url]
        if let tab { args["tab"] = String(tab) }

        do {
            _ = try CLISocketClient.send(command: "navigate", args: args)
            print("Navigating to \(url)")
        } catch let error as CLISocketClient.CLIError {
            fputs("Error: \(error.description)\n", stderr)
            throw ExitCode(error.exitCode)
        }
    }
}
