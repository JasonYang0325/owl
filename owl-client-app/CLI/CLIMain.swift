import ArgumentParser
import Foundation

@main
struct OWLCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "owl",
        abstract: "OWL Browser CLI — control the running browser from the terminal.",
        version: "0.1.0",
        subcommands: [
            PageCommand.self,
            NavigateCommand.self,
            BackCommand.self,
            ForwardCommand.self,
            ReloadCommand.self,
            CookieCommand.self,
            ClearDataCommand.self,
            StorageCommand.self,
            BookmarkCommand.self,
            HistoryCommand.self,
            PermissionCommand.self,
            DownloadCommand.self,
            FindCommand.self,
            ZoomCommand.self,
            NavCommand.self,
            ConsoleCommand.self,
        ]
    )
}
