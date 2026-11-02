import CryptoKit
import Foundation
import Network

public enum ContainerError: LocalizedError {
    case notInstalled
    case unsupportedVersion(ToolVersion)
    case badPackage(String)
    case gameDidNotStart([String])

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Apple's container runtime is not installed."
        case .unsupportedVersion(let v):
            return "container \(v) is installed, but this launcher needs container \(Manifest.container.version.major).x (tested with \(Manifest.container.version))."
        case .badPackage(let why):
            return "The container installer failed verification: \(why)"
        case .gameDidNotStart(let tail):
            return "The game's VM stopped before the game started." + (tail.isEmpty ? "" : "\n" + tail.suffix(6).joined(separator: "\n"))
        }
    }
}

/// Drives Apple's `container` CLI.
public struct ContainerRuntime: Sendable {
    public let binary: URL
    public let log: LogSink

    public static let searchPaths = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]

    public static func locate() -> URL? {
        let fm = FileManager.default
        var candidates = searchPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/container" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public init(binary: URL, log: @escaping LogSink) {
        self.binary = binary
        self.log = log
    }

    // MARK: install

    /// The same download, checks and install as `install`, as Terminal
    /// commands, for players who'd rather not give the launcher admin rights.
    public static var manualInstallCommand: String {
        let release = Manifest.container
        let pkg = release.pkgURL.lastPathComponent
        return """
        cd ~/Downloads &&
        curl -fLO \(release.pkgURL.absoluteString) &&
        echo "\(release.pkgSHA256)  \(pkg)" | shasum -a 256 -c - &&
        pkgutil --check-signature \(pkg) | grep "\(release.signer)" &&
        sudo installer -pkg \(pkg) -target /
        """
    }

    /// Downloads Apple's signed installer package, verifies its hash and
    /// signature, and installs it (macOS asks for an administrator password).
    public static func install(paths: Paths, log: @escaping LogSink) async throws {
        let pkg = try await downloadVerifiedPackage(paths: paths, log: log)
        log(LogEntry(.info, "installing container \(Manifest.container.version); macOS will ask for an administrator password"))
        let script = "do shell script \"/usr/sbin/installer -pkg \" & quoted form of \"\(pkg.path)\" & \" -target /\" with administrator privileges"
        try await Shell.check(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], log: log)
    }

    /// Downloads Apple's installer package and checks its sha256 and Developer
    /// ID signature; returns the package, ready for Apple's Installer.
    public static func downloadVerifiedPackage(paths: Paths, log: @escaping LogSink) async throws -> URL {
        try paths.prepare()
        let release = Manifest.container
        let pkg = paths.downloads.appendingPathComponent(release.pkgURL.lastPathComponent)
        log(LogEntry(.command, "download \(release.pkgURL.absoluteString)"))
        let (tmp, response) = try await URLSession.shared.download(from: release.pkgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: pkg)
        try FileManager.default.moveItem(at: tmp, to: pkg)
        let hash = try GameLibrary.sha256(of: pkg)
        log(LogEntry(.output, "sha256 \(hash)"))
        guard hash == release.pkgSHA256 else { throw ContainerError.badPackage("unexpected sha256 \(hash)") }
        let sig = try await Shell.run(URL(fileURLWithPath: "/usr/sbin/pkgutil"), ["--check-signature", pkg.path], log: log)
        guard sig.status == 0, sig.output.contains(where: { $0.contains(release.signer) }) else {
            throw ContainerError.badPackage("not signed by \(release.signer)")
        }
        log(LogEntry(.info, "\(pkg.lastPathComponent) verified: sha256 matches and signed by \(release.signer)"))
        return pkg
    }

    // MARK: checks

    public func version() async throws -> ToolVersion {
        let out = try await Shell.check(binary, ["--version"], log: log)
        guard let v = ToolVersion(in: out.joined(separator: " ")) else { throw ContainerError.notInstalled }
        return v
    }

    public func servicesRunning() async -> Bool {
        (try? await Shell.run(binary, ["system", "status"], log: log, quiet: true).status) == 0
    }

    /// Starts the container services; the first time, this downloads Apple's default Linux kernel.
    public func startServices() async throws {
        try await Shell.check(binary, ["system", "start", "--enable-kernel-install"], log: log)
    }

    // MARK: image

    /// The runtime image's tag is a hash of its build context, so any change
    /// to the Containerfile or scripts gets a fresh build.
    public static func imageTag(context: URL) throws -> String {
        let fm = FileManager.default
        var hasher = SHA256()
        let files = (fm.enumerator(at: context, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.path.replacingOccurrences(of: context.path + "/", with: "") }
            .filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
            .filter { $0.hasPrefix("runtime/") || ($0.hasPrefix("game/") && $0.hasSuffix(".py")) }
            .sorted()
        for rel in files {
            hasher.update(data: Data(rel.utf8))
            hasher.update(data: try Data(contentsOf: context.appendingPathComponent(rel)))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(Manifest.imageRepository):\(digest.prefix(12))"
    }

    public func imageExists(_ tag: String) async -> Bool {
        (try? await Shell.run(binary, ["image", "inspect", tag], log: log, quiet: true).status) == 0
    }

    public func buildImage(tag: String, context: URL) async throws {
        try await Shell.check(binary, ["build", "--progress", "plain", "--cpus", "4", "--memory", "4G",
                                       "-t", tag, "-f", context.appendingPathComponent("runtime/Containerfile").path,
                                       context.path], log: log)
        // The build runs in its own VM (4 GB); don't leave it running after.
        _ = try? await Shell.run(binary, ["builder", "stop"], log: log)
    }

    // MARK: game

    public func removeStaleGame() async {
        _ = try? await Shell.run(binary, ["delete", "--force", Manifest.containerName], log: log, quiet: true)
    }

    public func stopGame() async {
        _ = try? await Shell.run(binary, ["stop", "--time", "3", Manifest.containerName], log: log, quiet: true)
    }

    /// Starts the game's VM attached (its output streams into the log) and
    /// waits until the viewer answers.
    public func runGame(image: String, paths: Paths, geometry: (Int, Int)) async throws -> GameSession {
        await removeStaleGame()
        let port = try Self.freePort()
        let password = Self.vncPassword()
        // The password goes in an env file rather than on the command line.
        let envFile = paths.scratch.appendingPathComponent("game.env")
        try paths.prepare()
        try "URR_GEOMETRY=\(geometry.0)x\(geometry.1)\nURR_VNC_PASSWORD=\(password)\n"
            .write(to: envFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)

        let progress = GameStartWatcher()
        let cmd = try RunningCommand(executable: binary, arguments: [
            "run", "--rm", "--name", Manifest.containerName,
            "--memory", Manifest.vmMemory, "--cpus", String(Manifest.vmCPUs),
            "--publish", "127.0.0.1:\(port):6080",
            "--mount", "type=bind,source=\(paths.game.path),target=/opt/urr/game,readonly",
            "--mount", "type=bind,source=\(paths.saves.path),target=/data",
            "--env-file", envFile.path,
            image,
        ], environment: nil) { [log] line in
            progress.see(line)
            log(LogEntry(.output, line))
        }
        log(LogEntry(.command, cmd.display))

        let viewer = URL(string: "http://127.0.0.1:\(port)/")!
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if !cmd.isRunning {
                _ = await cmd.wait()
                try? FileManager.default.removeItem(at: envFile)
                throw ContainerError.gameDidNotStart(cmd.lastLines)
            }
            if progress.gameStarted, await Self.answers(viewer) {
                try? FileManager.default.removeItem(at: envFile)
                var page = URLComponents(url: viewer, resolvingAgainstBaseURL: false)!
                page.fragment = "password=\(password)"
                return GameSession(viewer: page.url!, command: cmd, runtime: self)
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        cmd.terminate()
        await stopGame()
        throw ContainerError.gameDidNotStart(cmd.lastLines + ["timed out waiting for the game's viewer"])
    }

    static func answers(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        return ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// VNC passwords are at most 8 characters.
    static func vncPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}

final class GameStartWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    func see(_ line: String) {
        if line.hasPrefix("urr: step game") { lock.lock(); started = true; lock.unlock() }
    }
    var gameStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
}

/// A running game: the viewer URL (with its one-time password in the
/// fragment) and the attached `container run` process.
public final class GameSession: @unchecked Sendable {
    public let viewer: URL
    private let command: RunningCommand?
    private let runtime: ContainerRuntime?

    init(viewer: URL, command: RunningCommand?, runtime: ContainerRuntime?) {
        self.viewer = viewer
        self.command = command
        self.runtime = runtime
    }

    /// A session for a viewer that is already running elsewhere (development).
    public static func external(_ viewer: URL) -> GameSession {
        GameSession(viewer: viewer, command: nil, runtime: nil)
    }

    /// Waits for the game to exit; returns its exit status.
    public func wait() async -> Int32 {
        guard let command else {
            while true { try? await Task.sleep(for: .seconds(3600)) }
        }
        return await command.wait()
    }

    public func stop() async {
        await runtime?.stopGame()
        command?.terminate()
    }
}
