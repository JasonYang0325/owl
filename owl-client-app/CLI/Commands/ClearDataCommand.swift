import ArgumentParser
import Foundation
import OWLBrowserLib

struct ClearDataCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-data",
        abstract: "Clear browsing data (cookies, cache, storage)."
    )

    @Flag(name: .long, help: "Clear cookies.")
    var cookies = false

    @Flag(name: .long, help: "Clear cache.")
    var cache = false

    @Flag(name: .long, help: "Clear local storage.")
    var localStorage = false

    @Flag(name: .long, help: "Clear session storage.")
    var sessionStorage = false

    @Flag(name: .long, help: "Clear IndexedDB.")
    var indexedDb = false

    @Option(name: .long, help: "Start time: relative (1h/7d/30m), ISO 8601, or Unix timestamp.")
    var since: String?

    func run() throws {
        // Build data type mask
        var mask: UInt32 = 0
        if cookies        { mask |= 0x01 }
        if cache          { mask |= 0x02 }
        if localStorage   { mask |= 0x04 }
        if sessionStorage { mask |= 0x08 }
        if indexedDb      { mask |= 0x10 }
        // No flags = clear all
        if mask == 0 { mask = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 }

        let startTime: String
        if let since {
            guard let ts = parseTime(since) else {
                fputs("Error: Invalid time format '\(since)'. Use: 1h, 7d, 30m, ISO 8601, or Unix timestamp.\n", stderr)
                throw ExitCode.failure
            }
            startTime = String(ts)
        } else {
            startTime = "0"
        }

        let endTime = String(Date().timeIntervalSince1970)

        do {
            let response = try CLISocketClient.send(
                command: "clear-data",
                args: [
                    "types": String(mask),
                    "start_time": startTime,
                    "end_time": endTime,
                ]
            )
            if response.ok {
                print("Browsing data cleared successfully.")
            }
        } catch let error as CLISocketClient.CLIError {
            fputs("Error: \(error.description)\n", stderr)
            throw ExitCode(error.exitCode)
        }
    }
}
