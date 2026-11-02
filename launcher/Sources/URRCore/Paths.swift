import Foundation

/// Where the launcher keeps things. Everything lives under one folder in
/// Application Support (override with URR_HOME), plus a log folder.
public struct Paths: Sendable {
    public let home: URL
    public let logs: URL

    public init(home: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        if let home {
            self.home = home
        } else if let override = env["URR_HOME"], !override.isEmpty {
            self.home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.home = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ultima Ratio Regum", isDirectory: true)
        }
        logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Ultima Ratio Regum", isDirectory: true)
    }

    /// The official game files, unmodified, as extracted from the ZIP.
    public var game: URL { home.appendingPathComponent("Game", isDirectory: true) }
    /// What was imported, from where, and any version consent given.
    public var gameRecord: URL { home.appendingPathComponent("game.json") }
    /// Saves and preferences (mounted at /data in the VM). Shared with the
    /// native backend, so saves move freely between the two.
    public var saves: URL { home.appendingPathComponent("Saves", isDirectory: true) }
    public var downloads: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    public var scratch: URL { home.appendingPathComponent("Temp", isDirectory: true) }

    public func prepare() throws {
        for dir in [home, saves, downloads, scratch, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Appends log entries to a dated file in ~/Library/Logs/Ultima Ratio Regum.
public final class LogFile: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle?
    private let lock = NSLock()
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public init(paths: Paths) {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        url = paths.logs.appendingPathComponent("launcher-\(day.string(from: Date())).log")
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    public func write(_ entry: LogEntry) {
        let line = "\(stamp.string(from: entry.date)) \(entry.plain)\n"
        lock.lock()
        try? handle?.write(contentsOf: Data(line.utf8))
        lock.unlock()
    }
}

/// Finds the files the launcher ships with: the runtime build context (the
/// folder holding runtime/Containerfile and game/), the news page and an
/// optional bundled copy of the official game ZIP.
public struct Resources: Sendable {
    public let runtimeContext: URL
    public let newsPage: URL?
    public let bundledGameZip: URL?

    public init(runtimeContext: URL, newsPage: URL?, bundledGameZip: URL?) {
        self.runtimeContext = runtimeContext
        self.newsPage = newsPage
        self.bundledGameZip = bundledGameZip
    }

    /// In the app: Contents/Resources. From the command line: URR_RESOURCES,
    /// else the repository containing the current directory or executable.
    public static func locate() -> Resources? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["URR_RESOURCES"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL { candidates.append(res) }
        for start in [URL(fileURLWithPath: fm.currentDirectoryPath),
                      URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()] {
            var dir = start
            for _ in 0..<8 {
                candidates.append(dir)
                dir = dir.deletingLastPathComponent()
            }
        }
        for base in candidates {
            for ctx in [base.appendingPathComponent("runtime-context"), base] {
                guard fm.fileExists(atPath: ctx.appendingPathComponent("runtime/Containerfile").path) else { continue }
                let news = [base.appendingPathComponent("news/index.html"),
                            base.appendingPathComponent("news/dist/index.html")].first { fm.fileExists(atPath: $0.path) }
                let zip = base.appendingPathComponent("Game/\(Manifest.game.zipName)")
                return Resources(runtimeContext: ctx, newsPage: news,
                                 bundledGameZip: fm.fileExists(atPath: zip.path) ? zip : nil)
            }
        }
        return nil
    }
}
