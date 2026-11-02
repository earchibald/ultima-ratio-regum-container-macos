import Foundation

/// A URR release number such as 0.10.4d: major.minor.patch plus an optional
/// letter revision.
public struct GameVersion: Hashable, Sendable, CustomStringConvertible, Codable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var revision: String

    public init(major: Int, minor: Int, patch: Int = 0, revision: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.revision = revision.lowercased()
    }

    /// Parses "0.10.4d", "v0.10.4d", "0.10.4" or "0.10".
    public init?(_ text: String) {
        let pattern = #/^[vV]?(\d+)\.(\d+)(?:\.(\d+))?([a-zA-Z]*)$/#
        guard let m = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern),
              let major = Int(m.1), let minor = Int(m.2) else { return nil }
        self.init(major: major, minor: minor, patch: m.3.flatMap { Int($0) } ?? 0, revision: String(m.4))
    }

    /// Parses the Windows executable's name: URR0104d.exe is 0.10.4d,
    /// URR0103.exe is 0.10.3, URR096.exe is 0.9.6.
    public init?(exeName: String) {
        let pattern = #/^URR(\d{3,4})([a-zA-Z]*)\.exe$/#.ignoresCase()
        guard let m = exeName.wholeMatch(of: pattern) else { return nil }
        let d = Array(m.1).compactMap { $0.wholeNumberValue }
        if d.count == 4 {
            self.init(major: d[0], minor: d[1] * 10 + d[2], patch: d[3], revision: String(m.2))
        } else {
            self.init(major: d[0], minor: d[1], patch: d[2], revision: String(m.2))
        }
    }

    /// Finds "Version 0.10.4d" in the game's Readme.txt.
    public init?(readme: String) {
        guard let m = readme.firstMatch(of: #/(?im)^\s*Version\s+([vV]?\d+\.\d+(?:\.\d+)?[a-zA-Z]*)\s*$/#) else { return nil }
        self.init(String(m.1))
    }

    public var description: String { "\(major).\(minor).\(patch)\(revision)" }
}

/// How a player's game version relates to the tested one.
///
/// Policy: the launcher is locked to a minor version.
/// - same version: run.
/// - different patch level or letter revision: warn, then run.
/// - different minor version: the player may choose to try it.
/// - different major version: refuse.
public enum VersionVerdict: Equatable, Sendable {
    case supported
    case patchDifference
    case minorDifference
    case majorDifference

    public init(found: GameVersion, tested: GameVersion) {
        if found.major != tested.major {
            self = .majorDifference
        } else if found.minor != tested.minor {
            self = .minorDifference
        } else if found.patch != tested.patch || found.revision != tested.revision {
            self = .patchDifference
        } else {
            self = .supported
        }
    }

    public var mayRun: Bool { self != .majorDifference }
    public var needsConsent: Bool { self == .minorDifference }

    public func explanation(found: GameVersion, tested: GameVersion) -> String {
        switch self {
        case .supported:
            return "Version \(found) is the version this launcher is tested with."
        case .patchDifference:
            return "Version \(found) differs from the tested \(tested) by a patch release. It should work; if something misbehaves, the tested version is \(tested)."
        case .minorDifference:
            return "Version \(found) is a different minor release than the tested \(tested). It may need launcher changes. You can try it anyway."
        case .majorDifference:
            return "Version \(found) is a different major release than the tested \(tested). This launcher can't run it; look for an updated launcher."
        }
    }
}

/// A plain major.minor.patch tool version (for Apple's container CLI).
public struct ToolVersion: Hashable, Sendable, CustomStringConvertible, Comparable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Finds the first x.y.z in text such as "container CLI version 1.6.1 (build: release)".
    public init?(in text: String) {
        guard let m = text.firstMatch(of: #/(\d+)\.(\d+)\.(\d+)/#),
              let a = Int(m.1), let b = Int(m.2), let c = Int(m.3) else { return nil }
        self.init(major: a, minor: b, patch: c)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (l: ToolVersion, r: ToolVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}
