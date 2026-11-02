import Foundation
import URRCore

// urrctl: the launcher's setup steps from a terminal.
//
//   urrctl doctor                 run the setup checks; never installs or downloads
//   urrctl import ZIP [--yes]     install a game ZIP (--yes accepts an untested minor version)
//   urrctl play [--yes]           set up as needed and play in the browser
//   urrctl check ZIP              report a ZIP's version and what the launcher would do

let usage = """
usage: urrctl doctor
       urrctl import <game.zip> [--yes]
       urrctl play [--yes]
       urrctl check <game.zip>
"""

let args = Array(CommandLine.arguments.dropFirst())
let assumeYes = args.contains("--yes")
let positional = args.filter { !$0.hasPrefix("--") }
let interactive = isatty(STDIN_FILENO) == 1

func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func ask(_ question: String) -> Bool {
    if assumeYes { return true }
    guard interactive else { say("\(question) [no: not a terminal; pass --yes]"); return false }
    say("\(question) [y/N]")
    return (readLine() ?? "").lowercased().hasPrefix("y")
}

let paths = Paths()
let logFile = LogFile(paths: paths)
let log: LogSink = { entry in
    logFile.write(entry)
    say(entry.plain)
}

func hooks(allowInstall: Bool) -> LauncherHooks {
    LauncherHooks(
        step: { step, state in
            switch state {
            case .done(let d): say("[ok]   \(step.title): \(d)")
            case .warning(let d): say("[warn] \(step.title): \(d)")
            case .failed(let d): say("[FAIL] \(step.title): \(d)")
            case .waiting(let d): say("[wait] \(step.title): \(d)")
            case .running, .pending: break
            }
        },
        log: log,
        downloadProgress: { _ in },
        confirmInstallContainer: {
            allowInstall && ask("Install Apple's container runtime \(Manifest.container.version)? (macOS will ask for your password)")
        },
        chooseGameSource: { reason in
            say(reason)
            guard allowInstall else { return nil }
            if ask("Download Ultima Ratio Regum from \(Manifest.gamePage.absoluteString)?") { return .downloadOfficial }
            guard interactive else { return nil }
            say("Path to a game ZIP (empty to cancel):")
            let path = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : .zip(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        },
        confirmUntestedVersion: { version, explanation in
            say(explanation)
            return ask("Try version \(version) anyway?")
        }
    )
}

func resourcesOrExit() -> Resources {
    guard let r = Resources.locate() else {
        say("error: can't find the runtime files (runtime/Containerfile); run from the repository or set URR_RESOURCES")
        exit(2)
    }
    return r
}

func run() async -> Int32 {
    switch positional.first {
    case "doctor":
        let launcher = Launcher(paths: paths, resources: resourcesOrExit(), hooks: hooks(allowInstall: false))
        do { try await launcher.prepare(); say("Ready to play."); return 0 } catch { return 1 }

    case "check" where positional.count == 2:
        let library = GameLibrary(paths: paths, log: log)
        do {
            let staged = try await library.stage(zip: URL(fileURLWithPath: positional[1]))
            say("version \(staged.version) (\(staged.exeName)); official release: \(staged.officialRelease ? "yes" : "no")")
            say(staged.verdict.explanation(found: staged.version, tested: Manifest.game.version))
            library.cleanScratch()
            return staged.verdict.mayRun ? 0 : 3
        } catch {
            say("error: \(error.localizedDescription)")
            return 1
        }

    case "import" where positional.count == 2:
        let launcher = Launcher(paths: paths, resources: resourcesOrExit(), hooks: hooks(allowInstall: true))
        do {
            return try await launcher.importGame(from: URL(fileURLWithPath: positional[1])) ? 0 : 3
        } catch {
            say("error: \(error.localizedDescription)")
            return 1
        }

    case "play":
        let launcher = Launcher(paths: paths, resources: resourcesOrExit(), hooks: hooks(allowInstall: true))
        do {
            try await launcher.prepare()
            let session = try await launcher.play(geometry: (1512, 944))
            say("Game viewer: \(session.viewer.absoluteString)")
            _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/open"), [session.viewer.absoluteString], log: { _ in })
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT)
            source.setEventHandler { Task { await session.stop() } }
            source.resume()
            let status = await session.wait()
            say("The game exited (status \(status)).")
            return status
        } catch {
            return 1
        }

    default:
        say(usage)
        return 64
    }
}

let status = await run()
exit(status)
