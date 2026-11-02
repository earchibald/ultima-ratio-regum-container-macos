import CryptoKit
import Foundation

/// What is installed in Paths.game, and where it came from.
public struct InstalledGame: Codable, Sendable {
    public var version: GameVersion
    public var exeName: String
    public var zipName: String
    public var zipSHA256: String
    /// The ZIP's hash matched the official release this launcher pins.
    public var officialRelease: Bool
    public var importedAt: Date
    /// The player chose to try this version despite a minor-version difference.
    public var consentedVersion: GameVersion?
}

public enum GameLibraryError: LocalizedError {
    case notAGameZip(String)
    case missingFiles([String])
    case unknownVersion
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notAGameZip(let why): return "That doesn't look like an Ultima Ratio Regum download: \(why)"
        case .missingFiles(let names): return "The game ZIP is missing \(names.joined(separator: ", "))."
        case .unknownVersion: return "Couldn't find the game's version in its Readme.txt."
        case .refused(let why): return why
        }
    }
}

/// A checked but not yet installed game folder.
public struct StagedGame: Sendable {
    public let folder: URL
    public let version: GameVersion
    public let exeName: String
    public let zipName: String
    public let zipSHA256: String
    public let officialRelease: Bool
    public let verdict: VersionVerdict
    public let licenseNote: String?
}

public struct GameLibrary: Sendable {
    public let paths: Paths
    public let log: LogSink

    public init(paths: Paths, log: @escaping LogSink) {
        self.paths = paths
        self.log = log
    }

    public static let requiredFiles = ["Readme.txt", "8x8.png", "10x10.png", "12x12.png"]

    // MARK: installed game

    public func installed() -> InstalledGame? {
        guard let data = try? Data(contentsOf: paths.gameRecord),
              let record = try? Self.decoder.decode(InstalledGame.self, from: data),
              FileManager.default.fileExists(atPath: paths.game.appendingPathComponent(record.exeName).path)
        else { return nil }
        return record
    }

    public func save(_ record: InstalledGame) throws {
        try Self.encoder.encode(record).write(to: paths.gameRecord, options: .atomic)
    }

    // MARK: download

    /// Downloads the official ZIP. Tries the pinned URL, then looks on the
    /// official game page for the current URR*.zip link.
    public func downloadOfficial(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try paths.prepare()
        do {
            return try await download(Manifest.game.url, progress: progress)
        } catch {
            log(LogEntry(.warning, "pinned download failed (\(error.localizedDescription)); checking \(Manifest.gamePage.absoluteString)"))
        }
        let (data, _) = try await URLSession.shared.data(from: Manifest.gamePage)
        let html = String(decoding: data, as: UTF8.self)
        guard let m = html.firstMatch(of: #/href="(https:\/\/www\.markrjohnsongames\.com\/[^"]*\/URR[0-9]+[a-zA-Z]*\.zip)"/#),
              let url = URL(string: String(m.1)) else {
            throw GameLibraryError.notAGameZip("no game download link found on \(Manifest.gamePage.absoluteString)")
        }
        log(LogEntry(.info, "found \(url.lastPathComponent) on the game page"))
        return try await download(url, progress: progress)
    }

    func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        log(LogEntry(.command, "download \(url.absoluteString)"))
        let dest = paths.downloads.appendingPathComponent(url.lastPathComponent)
        let partial = dest.appendingPathExtension("part")
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let total = max(http.expectedContentLength, 1)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let out = try FileHandle(forWritingTo: partial)
        defer { try? out.close() }
        var chunk = Data()
        chunk.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReport: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 1 << 20 {
                try out.write(contentsOf: chunk)
                received += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                progress(Double(received) / Double(total))
                if received - lastReport >= 5 << 20 {
                    lastReport = received
                    log(LogEntry(.output, String(format: "%.1f of %.1f MB", Double(received) / 1e6, Double(total) / 1e6)))
                }
            }
        }
        try out.write(contentsOf: chunk)
        received += Int64(chunk.count)
        progress(1)
        log(LogEntry(.output, String(format: "downloaded %.1f MB to %@", Double(received) / 1e6, dest.path)))
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: partial, to: dest)
        return dest
    }

    // MARK: import

    /// Unpacks a game ZIP into a scratch folder and checks it. Nothing in the
    /// ZIP is modified.
    public func stage(zip: URL) async throws -> StagedGame {
        try paths.prepare()
        log(LogEntry(.info, "checking \(zip.path)"))
        let hash = try Self.sha256(of: zip)
        let official = hash == Manifest.game.sha256
        log(LogEntry(.output, "sha256 \(hash)" + (official ? " (matches the official \(Manifest.game.zipName))" : "")))

        let staging = paths.scratch.appendingPathComponent("staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let (status, output) = try await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, staging.path], log: log)
        guard status == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw GameLibraryError.notAGameZip(output.last ?? "it could not be unzipped")
        }
        guard let root = Self.findGameRoot(in: staging) else {
            try? FileManager.default.removeItem(at: staging)
            throw GameLibraryError.notAGameZip("no URR*.exe with a Readme.txt beside it")
        }
        let fm = FileManager.default
        let missing = Self.requiredFiles.filter { !fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            try? fm.removeItem(at: staging)
            throw GameLibraryError.missingFiles(missing)
        }
        let exe = try fm.contentsOfDirectory(atPath: root.path).first { GameVersion(exeName: $0) != nil }!
        let readme = (try? String(contentsOf: root.appendingPathComponent("Readme.txt"), encoding: .utf8))
            ?? (try? String(contentsOf: root.appendingPathComponent("Readme.txt"), encoding: .isoLatin1)) ?? ""
        guard let version = GameVersion(readme: readme) ?? GameVersion(exeName: exe) else {
            try? fm.removeItem(at: staging)
            throw GameLibraryError.unknownVersion
        }
        if let fromExe = GameVersion(exeName: exe), fromExe != version {
            log(LogEntry(.warning, "Readme.txt says \(version) but the program is named \(exe); using \(version)"))
        }
        let verdict = VersionVerdict(found: version, tested: Manifest.game.version)
        log(LogEntry(verdict == .supported ? .info : .warning, verdict.explanation(found: version, tested: Manifest.game.version)))
        let license = readme.firstMatch(of: #/(?s)\*\*\*\* COPYRIGHT INFORMATION \*\*\*\*\s*(.*?)\s*\*\*\*\*/#).map { String($0.1) }
        return StagedGame(folder: root, version: version, exeName: exe, zipName: zip.lastPathComponent,
                          zipSHA256: hash, officialRelease: official, verdict: verdict, licenseNote: license)
    }

    /// Moves a staged game into place, replacing any previous version. Saves are untouched.
    public func install(_ staged: StagedGame, consented: Bool) throws -> InstalledGame {
        guard staged.verdict.mayRun else {
            throw GameLibraryError.refused(staged.verdict.explanation(found: staged.version, tested: Manifest.game.version))
        }
        let fm = FileManager.default
        let old = paths.home.appendingPathComponent("Game.previous", isDirectory: true)
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: paths.game.path) { try fm.moveItem(at: paths.game, to: old) }
        try fm.moveItem(at: staged.folder, to: paths.game)
        try? fm.removeItem(at: old)
        cleanScratch()
        let record = InstalledGame(version: staged.version, exeName: staged.exeName, zipName: staged.zipName,
                                   zipSHA256: staged.zipSHA256, officialRelease: staged.officialRelease,
                                   importedAt: Date(), consentedVersion: consented ? staged.version : nil)
        try save(record)
        log(LogEntry(.info, "installed Ultima Ratio Regum \(staged.version) in \(paths.game.path)"))
        return record
    }

    public func cleanScratch() {
        try? FileManager.default.removeItem(at: paths.scratch)
    }

    // MARK: helpers

    static func findGameRoot(in dir: URL, depth: Int = 0) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        if names.contains(where: { GameVersion(exeName: $0) != nil }), names.contains("Readme.txt") { return dir }
        guard depth < 2 else { return nil }
        for name in names where !name.hasPrefix(".") && name != "__MACOSX" {
            var isDir: ObjCBool = false
            let sub = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue,
               let found = findGameRoot(in: sub, depth: depth + 1) { return found }
        }
        return nil
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
