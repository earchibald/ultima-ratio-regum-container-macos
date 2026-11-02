import Foundation

/// The setup steps shown to the player, in order.
public enum Step: String, CaseIterable, Sendable, Identifiable {
    case mac, game, runtime, services, image, play

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mac: return "This Mac"
        case .runtime: return "Apple container runtime"
        case .services: return "Linux VM services"
        case .game: return "Game files"
        case .image: return "Game runtime image"
        case .play: return "Start the game"
        }
    }
}

public enum StepState: Equatable, Sendable {
    case pending
    case running(String)
    case done(String)
    case warning(String)
    case waiting(String)
    case failed(String)
}

/// Where to get the game when none is installed.
public enum GameSource: Sendable {
    case downloadOfficial
    case zip(URL)
}

/// How the player wants Apple's container runtime installed.
public enum ContainerInstallChoice: Sendable {
    /// The launcher downloads, verifies and installs it (macOS asks for an admin password).
    case automatic
    /// The player installed it some other way (Terminal, Apple's Installer); look again.
    case installedSeparately
    case declined
}

/// Questions only the player can answer. The app shows them as cards in the
/// setup panel; urrctl asks on the terminal.
public struct LauncherHooks: Sendable {
    public var step: @Sendable (Step, StepState) -> Void
    public var log: LogSink
    public var downloadProgress: @Sendable (Double) -> Void
    /// Apple's container runtime is missing: how should it be installed?
    public var confirmInstallContainer: @Sendable () async -> ContainerInstallChoice
    /// No game installed (or the player asked to replace it): where from? nil cancels.
    public var chooseGameSource: @Sendable (_ reason: String) async -> GameSource?
    /// The game is a different minor version than tested: try it anyway?
    public var confirmUntestedVersion: @Sendable (_ found: GameVersion, _ explanation: String) async -> Bool

    public init(step: @escaping @Sendable (Step, StepState) -> Void,
                log: @escaping LogSink,
                downloadProgress: @escaping @Sendable (Double) -> Void,
                confirmInstallContainer: @escaping @Sendable () async -> ContainerInstallChoice,
                chooseGameSource: @escaping @Sendable (String) async -> GameSource?,
                confirmUntestedVersion: @escaping @Sendable (GameVersion, String) async -> Bool) {
        self.step = step
        self.log = log
        self.downloadProgress = downloadProgress
        self.confirmInstallContainer = confirmInstallContainer
        self.chooseGameSource = chooseGameSource
        self.confirmUntestedVersion = confirmUntestedVersion
    }
}

public struct SetupCancelled: LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
}

/// Runs the setup steps and starts the game.
public final class Launcher: @unchecked Sendable {
    public let paths: Paths
    public let resources: Resources
    let hooks: LauncherHooks
    var runtime: ContainerRuntime?
    var image: String?

    public init(paths: Paths, resources: Resources, hooks: LauncherHooks) {
        self.paths = paths
        self.resources = resources
        self.hooks = hooks
    }

    var library: GameLibrary { GameLibrary(paths: paths, log: hooks.log) }

    func begin(_ step: Step, _ detail: String) {
        hooks.step(step, .running(detail))
        hooks.log(LogEntry(.step, "\(step.title): \(detail)"))
    }

    /// Runs every step up to (not including) starting the game. Throws on the
    /// first step that can't complete; that step is marked failed.
    public func prepare() async throws {
        try paths.prepare()
        var current = Step.mac
        do {
            current = .mac; try checkMac()
            current = .game; try await ensureGame()
            current = .runtime; let runtime = try await ensureRuntime()
            current = .services; try await ensureServices(runtime)
            current = .image; try await ensureImage(runtime)
            hooks.step(.play, .pending)
        } catch {
            hooks.step(current, .failed(error.localizedDescription))
            hooks.log(LogEntry(.error, error.localizedDescription))
            throw error
        }
    }

    func checkMac() throws {
        begin(.mac, "checking")
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let summary = "macOS \(os.majorVersion).\(os.minorVersion), \(machine)"
        hooks.log(LogEntry(.output, summary))
        guard machine == "arm64" else {
            throw SetupCancelled(reason: "Apple's container runtime needs a Mac with Apple silicon (this is \(machine)).")
        }
        guard os.majorVersion >= 26 else {
            throw SetupCancelled(reason: "Apple's container runtime needs macOS 26 or later (this is \(summary)).")
        }
        hooks.step(.mac, .done(summary))
    }

    func ensureRuntime() async throws -> ContainerRuntime {
        begin(.runtime, "looking for the container command")
        var binary = ContainerRuntime.locate()
        var waiting = "Not installed"
        while binary == nil {
            hooks.step(.runtime, .waiting(waiting))
            switch await hooks.confirmInstallContainer() {
            case .declined:
                throw SetupCancelled(reason: "The game runs in a small Linux VM managed by Apple's container runtime, which isn't installed.")
            case .automatic:
                begin(.runtime, "installing container \(Manifest.container.version)")
                try await ContainerRuntime.install(paths: paths, log: hooks.log)
                binary = ContainerRuntime.locate()
                if binary == nil { throw ContainerError.notInstalled }
            case .installedSeparately:
                binary = ContainerRuntime.locate()
                if binary == nil {
                    waiting = "Still not found in \(ContainerRuntime.searchPaths.joined(separator: " or "))"
                    hooks.log(LogEntry(.warning, "container is still not installed"))
                }
            }
        }
        guard let binary else { throw ContainerError.notInstalled }
        let runtime = ContainerRuntime(binary: binary, log: hooks.log)
        let version = try await runtime.version()
        let tested = Manifest.container.version
        guard version.major == tested.major else { throw ContainerError.unsupportedVersion(version) }
        if version.minor != tested.minor {
            hooks.step(.runtime, .warning("container \(version) (tested with \(tested))"))
            hooks.log(LogEntry(.warning, "container \(version) is installed; this launcher is tested with \(tested)"))
        } else {
            hooks.step(.runtime, .done("container \(version) at \(binary.path)"))
        }
        self.runtime = runtime
        return runtime
    }

    func ensureServices(_ runtime: ContainerRuntime) async throws {
        begin(.services, "checking")
        if await runtime.servicesRunning() {
            hooks.step(.services, .done("running"))
            return
        }
        begin(.services, "starting (the first start downloads a Linux kernel)")
        try await runtime.startServices()
        hooks.step(.services, .done("running"))
    }

    func ensureGame() async throws {
        begin(.game, "checking installed game")
        if let record = library.installed() {
            let verdict = VersionVerdict(found: record.version, tested: Manifest.game.version)
            let explanation = verdict.explanation(found: record.version, tested: Manifest.game.version)
            switch verdict {
            case .supported:
                hooks.step(.game, .done("Version \(record.version)" + (record.officialRelease ? ", official release verified" : "")))
                return
            case .patchDifference:
                hooks.log(LogEntry(.warning, explanation))
                hooks.step(.game, .warning("Version \(record.version) (tested with \(Manifest.game.version))"))
                return
            case .minorDifference where record.consentedVersion == record.version:
                hooks.log(LogEntry(.warning, explanation))
                hooks.step(.game, .warning("Version \(record.version): untested, running at your request"))
                return
            case .minorDifference:
                hooks.step(.game, .waiting("Version \(record.version) is untested"))
                if await hooks.confirmUntestedVersion(record.version, explanation) {
                    var consented = record
                    consented.consentedVersion = record.version
                    try library.save(consented)
                    hooks.step(.game, .warning("Version \(record.version): untested, running at your request"))
                    return
                }
            case .majorDifference:
                hooks.log(LogEntry(.error, explanation))
            }
            try await acquireGame(reason: "Choose a game version this launcher supports (\(Manifest.game.version)).")
            return
        }
        if let bundled = resources.bundledGameZip {
            begin(.game, "unpacking the bundled official \(bundled.lastPathComponent)")
            if try await importGame(from: bundled) { return }
        }
        try await acquireGame(reason: "Ultima Ratio Regum isn't installed yet.")
    }

    /// Asks for a game source until one installs, or the player cancels.
    func acquireGame(reason: String) async throws {
        var reason = reason
        while true {
            hooks.step(.game, .waiting(reason))
            guard let source = await hooks.chooseGameSource(reason) else {
                throw SetupCancelled(reason: "No game files were chosen.")
            }
            do {
                let zip: URL
                switch source {
                case .downloadOfficial:
                    begin(.game, "downloading from markrjohnsongames.com")
                    zip = try await library.downloadOfficial(progress: hooks.downloadProgress)
                case .zip(let url):
                    zip = url
                }
                begin(.game, "checking \(zip.lastPathComponent)")
                if try await importGame(from: zip) { return }
                reason = "That version can't be used. Choose another ZIP."
            } catch {
                hooks.log(LogEntry(.error, error.localizedDescription))
                reason = error.localizedDescription
            }
        }
    }

    /// Stages, checks and installs a ZIP. Returns false if the version was refused or declined.
    public func importGame(from zip: URL) async throws -> Bool {
        let staged = try await library.stage(zip: zip)
        let explanation = staged.verdict.explanation(found: staged.version, tested: Manifest.game.version)
        if let license = staged.licenseNote {
            hooks.log(LogEntry(.info, "Game licence (from its Readme.txt): " + license.replacingOccurrences(of: "\n", with: " ")))
        }
        var consented = false
        switch staged.verdict {
        case .supported, .patchDifference:
            break
        case .minorDifference:
            hooks.step(.game, .waiting("Version \(staged.version) is untested"))
            guard await hooks.confirmUntestedVersion(staged.version, explanation) else {
                library.cleanScratch()
                return false
            }
            consented = true
        case .majorDifference:
            library.cleanScratch()
            hooks.log(LogEntry(.error, explanation))
            return false
        }
        let record = try library.install(staged, consented: consented)
        let detail = "Version \(record.version)" + (record.officialRelease ? ", official release verified" : "")
        hooks.step(.game, staged.verdict == .supported ? .done(detail) : .warning(detail + " (tested with \(Manifest.game.version))"))
        return true
    }

    func ensureImage(_ runtime: ContainerRuntime) async throws {
        begin(.image, "checking")
        if let override = ProcessInfo.processInfo.environment["URR_RUNTIME_IMAGE"], !override.isEmpty {
            image = override
            hooks.step(.image, .done("\(override) (URR_RUNTIME_IMAGE)"))
            return
        }
        let tag = try ContainerRuntime.imageTag(context: resources.runtimeContext)
        if await runtime.imageExists(tag) {
            image = tag
            hooks.step(.image, .done(tag))
            return
        }
        begin(.image, "building \(tag) — the first build takes a few minutes")
        try await runtime.buildImage(tag: tag, context: resources.runtimeContext)
        image = tag
        hooks.step(.image, .done(tag))
    }

    /// Starts the game. `geometry` is the virtual screen size the game sees;
    /// pass the space available for its window, in points.
    public func play(geometry: (Int, Int)) async throws -> GameSession {
        guard let runtime, let image else { throw SetupCancelled(reason: "Setup hasn't finished.") }
        begin(.play, "starting the game's VM")
        do {
            let session = try await runtime.runGame(image: image, paths: paths, geometry: geometry)
            hooks.step(.play, .done("running"))
            return session
        } catch {
            hooks.step(.play, .failed(error.localizedDescription))
            hooks.log(LogEntry(.error, error.localizedDescription))
            throw error
        }
    }
}
