import Foundation

/// Everything this launcher was built and tested against. Bump these together
/// with a re-test; the version policy compares a player's game against them.
public enum Manifest {
    /// The game release this launcher is tested with.
    public static let game = GameRelease(
        version: GameVersion(major: 0, minor: 10, patch: 4, revision: "d"),
        zipName: "URR0104d.zip",
        url: URL(string: "https://www.markrjohnsongames.com/wp-content/uploads/2026/01/URR0104d.zip")!,
        sha256: "c24e86b2d8b6b27a33f53a085d0378112aab6954871608b76ac04cbf95125934",
        size: 29_266_757
    )

    /// The official game page: where players download the game themselves, and
    /// where the launcher looks for the current ZIP if the pinned URL moves.
    public static let gamePage = URL(string: "https://www.markrjohnsongames.com/games/ultima-ratio-regum/")!

    /// Apple's container runtime (https://github.com/apple/container).
    public static let container = ContainerRelease(
        version: ToolVersion(major: 1, minor: 6, patch: 1),
        pkgURL: URL(string: "https://github.com/apple/container/releases/download/1.6.1/container-1.6.1-installer-signed.pkg")!,
        pkgSHA256: "cd47846819f06478d067060efe21e516b562ac0a9af8eecad6d5fea0b556b200",
        signer: "Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)"
    )

    /// Resources given to the game's Linux VM.
    public static let vmMemory = "3G"
    public static let vmCPUs = 4
    public static let containerName = "urr-game"
    public static let imageRepository = "urr-runtime"
}

public struct GameRelease: Sendable {
    public let version: GameVersion
    public let zipName: String
    public let url: URL
    public let sha256: String
    public let size: Int64
}

public struct ContainerRelease: Sendable {
    public let version: ToolVersion
    public let pkgURL: URL
    public let pkgSHA256: String
    public let signer: String
}
