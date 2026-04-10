import ArgumentParser
import Foundation
import OWLBrowserLib

struct BackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "back",
        abstract: "Go back in the active tab."
    )

    func run() throws {
        do {
            _ = try CLISocketClient.send(command: "back")
            print("Going back")
        } catch let error as CLISocketClient.CLIError {
            fputs("Error: \(error.description)\n", stderr)
            throw ExitCode(error.exitCode)
        }
    }
}

struct ForwardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forward",
        abstract: "Go forward in the active tab."
    )

    func run() throws {
        do {
            _ = try CLISocketClient.send(command: "forward")
            print("Going forward")
        } catch let error as CLISocketClient.CLIError {
            fputs("Error: \(error.description)\n", stderr)
            throw ExitCode(error.exitCode)
        }
    }
}

struct ReloadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload",
        abstract: "Reload the active tab."
    )

    func run() throws {
        do {
            _ = try CLISocketClient.send(command: "reload")
            print("Reloading")
        } catch let error as CLISocketClient.CLIError {
            fputs("Error: \(error.description)\n", stderr)
            throw ExitCode(error.exitCode)
        }
    }
}
