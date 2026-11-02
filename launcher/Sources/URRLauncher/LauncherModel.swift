import AppKit
import Foundation
import Observation
import URRCore

/// A question the setup needs the player to answer, shown as a card.
struct Prompt: Identifiable {
    enum Kind {
        case installContainer
        case gameSource(reason: String)
        case untestedVersion(GameVersion, explanation: String)
    }
    enum Answer: Equatable { case yes, no, download, zip(URL), installedSeparately }

    let id = UUID()
    let kind: Kind
    let resolve: (Answer) -> Void
}

@MainActor
@Observable
final class LauncherModel {
    enum Phase: Equatable {
        case preparing
        case ready
        case failed(String)
        case starting
        case playing
    }

    var phase: Phase = .preparing
    var steps: [Step: StepState] = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .pending) })
    var prompt: Prompt?
    var downloadProgress: Double?
    /// Downloading the container installer for Apple's Installer app.
    var fetchingInstaller = false
    var log: [LogEntry] = []
    var lastExit: String?
    var session: GameSession?
    /// The game's framebuffer size, reported by the viewer page.
    var gameSize: CGSize?

    let paths = Paths()
    let resources = Resources.locate()
    let logFile: LogFile
    private var launcher: Launcher?
    private let devViewer = ProcessInfo.processInfo.environment["URR_DEV_VIEWER_URL"].flatMap(URL.init(string:))

    init() {
        logFile = LogFile(paths: paths)
    }

    // MARK: hooks (called from background tasks)

    private func makeHooks() -> LauncherHooks {
        LauncherHooks(
            step: { step, state in Task { @MainActor in self.steps[step] = state } },
            log: { entry in Task { @MainActor in self.append(entry) } },
            downloadProgress: { p in Task { @MainActor in self.downloadProgress = p >= 1 ? nil : p } },
            confirmInstallContainer: {
                switch await self.ask(.installContainer) {
                case .yes: return .automatic
                case .installedSeparately: return .installedSeparately
                default: return .declined
                }
            },
            chooseGameSource: { reason in
                switch await self.ask(.gameSource(reason: reason)) {
                case .download: return .downloadOfficial
                case .zip(let url): return .zip(url)
                default: return nil
                }
            },
            confirmUntestedVersion: { version, explanation in
                await self.ask(.untestedVersion(version, explanation: explanation)) == .yes
            }
        )
    }

    private func ask(_ kind: Prompt.Kind) async -> Prompt.Answer {
        await withCheckedContinuation { (c: CheckedContinuation<Prompt.Answer, Never>) in
            Task { @MainActor in
                // A card can be answered by a button and by its own polling
                // (container installed elsewhere); only the first answer counts.
                var answered = false
                self.prompt = Prompt(kind: kind) { answer in
                    guard !answered else { return }
                    answered = true
                    self.prompt = nil
                    c.resume(returning: answer)
                }
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    func append(_ entry: LogEntry) {
        logFile.write(entry)
        log.append(entry)
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    // MARK: actions

    func prepare() {
        guard phase != .starting, phase != .playing else { return }
        phase = .preparing
        lastExit = nil
        for step in Step.allCases { steps[step] = .pending }
        if let devViewer {
            append(LogEntry(.warning, "URR_DEV_VIEWER_URL is set: skipping setup and using \(devViewer.absoluteString)"))
            for step in Step.allCases { steps[step] = .done("skipped (development viewer)") }
            phase = .ready
            return
        }
        guard let resources else {
            phase = .failed("The launcher's runtime files are missing from the app. Reinstall the app.")
            return
        }
        let launcher = Launcher(paths: paths, resources: resources, hooks: makeHooks())
        self.launcher = launcher
        Task {
            do {
                try await launcher.prepare()
                self.phase = .ready
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func play() {
        guard phase == .ready else { return }
        phase = .starting
        gameSize = nil
        let geometry = Self.availableGeometry()
        Task {
            do {
                let session: GameSession
                if let devViewer {
                    session = .external(devViewer)
                } else {
                    guard let launcher else { return }
                    session = try await launcher.play(geometry: geometry)
                }
                self.session = session
                self.phase = .playing
                let status = await session.wait()
                self.session = nil
                self.lastExit = status == 0 ? "The game closed." : "The game stopped with status \(status). The log below has the details."
                self.steps[.play] = status == 0 ? .pending : .failed("exited with status \(status)")
                self.phase = .ready
            } catch {
                self.phase = .ready
                self.lastExit = error.localizedDescription
            }
        }
    }

    /// Downloads and verifies Apple's container package, then opens it in
    /// Apple's Installer, which asks for the password itself. Setup notices
    /// when the install lands (see PromptCard).
    func openContainerInstaller() {
        guard !fetchingInstaller else { return }
        fetchingInstaller = true
        Task {
            defer { fetchingInstaller = false }
            do {
                let pkg = try await ContainerRuntime.downloadVerifiedPackage(paths: paths) { entry in
                    Task { @MainActor in self.append(entry) }
                }
                append(LogEntry(.command, "open \(pkg.path)"))
                NSWorkspace.shared.open(pkg)
            } catch {
                append(LogEntry(.error, error.localizedDescription))
            }
        }
    }

    func stopGame() {
        guard let session else { return }
        append(LogEntry(.step, "Stopping the game"))
        Task { await session.stop() }
    }

    /// File > Import Game ZIP… : replace the installed game.
    func importZip(_ url: URL) {
        if let prompt, case .gameSource = prompt.kind {
            prompt.resolve(.zip(url))
            return
        }
        guard let resources, phase != .starting, phase != .playing else { return }
        let launcher = Launcher(paths: paths, resources: resources, hooks: makeHooks())
        Task {
            steps[.game] = .running("checking \(url.lastPathComponent)")
            do {
                _ = try await launcher.importGame(from: url)
            } catch {
                steps[.game] = .failed(error.localizedDescription)
                append(LogEntry(.error, error.localizedDescription))
            }
            prepare()
        }
    }

    /// Stops the game before the app quits, so its VM doesn't linger.
    func shutdown() async {
        if let session { await session.stop() }
    }

    /// The space the game window can use, in points: the main screen minus
    /// the menu bar, Dock and a title bar. The game sizes itself from this as
    /// it would from a real screen resolution.
    static func availableGeometry() -> (Int, Int) {
        let frame = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return (Int(frame.width), Int(frame.height) - 32)
    }
}
