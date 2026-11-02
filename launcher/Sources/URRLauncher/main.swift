import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum Shared { static let model = LauncherModel() }
@MainActor var model: LauncherModel { Shared.model }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also correct when run unbundled (swift run) during development.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Stop the game's VM before quitting.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard model.session != nil else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            app.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct URRLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Ultima Ratio Regum", id: "main") {
            RootView(model: model)
                .task { model.prepare() }
        }
        .defaultSize(width: 980, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Game ZIP…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.zip]
                    if panel.runModal() == .OK, let url = panel.url { model.importZip(url) }
                }
                .keyboardShortcut("o")
            }
            CommandMenu("Game") {
                Button("Play") { model.play() }
                    .keyboardShortcut("p")
                    .disabled(model.phase != .ready)
                Button("Stop Game") { model.stopGame() }
                    .keyboardShortcut(".")
                    .disabled(model.session == nil)
                Divider()
                Button("Run Setup Again") { model.prepare() }
                    .disabled(model.phase == .playing || model.phase == .starting)
                Button("Show Saves Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.saves])
                }
            }
        }
    }
}

URRLauncherApp.main()
