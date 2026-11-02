import Testing
@testable import URRCore

@Suite struct GameVersionParsing {
    @Test func readmeLine() {
        let readme = "Ultima Ratio Regum\n\"The Last Argument of Kings\"\nVersion 0.10.4d\nJnauary 2026\n"
        #expect(GameVersion(readme: readme) == GameVersion(major: 0, minor: 10, patch: 4, revision: "d"))
    }

    @Test(arguments: [
        ("URR0104d.exe", "0.10.4d"),
        ("URR0103.exe", "0.10.3"),
        ("urr096.exe", "0.9.6"),
        ("URR0110a.EXE", "0.11.0a"),
    ])
    func exeNames(name: String, expected: String) {
        #expect(GameVersion(exeName: name)?.description == expected)
    }

    @Test func rejectsOtherExecutables() {
        #expect(GameVersion(exeName: "python37.exe") == nil)
        #expect(GameVersion(exeName: "URR.exe") == nil)
    }

    @Test(arguments: ["0.10.4d", "v0.10.4d", "0.10.4D"])
    func plainVersions(text: String) {
        #expect(GameVersion(text) == GameVersion(major: 0, minor: 10, patch: 4, revision: "d"))
    }

    @Test func shortVersionHasZeroPatch() {
        #expect(GameVersion("0.11") == GameVersion(major: 0, minor: 11))
    }
}

@Suite struct VersionPolicy {
    let tested = GameVersion(major: 0, minor: 10, patch: 4, revision: "d")

    @Test func sameVersionRuns() {
        let v = VersionVerdict(found: tested, tested: tested)
        #expect(v == .supported && v.mayRun && !v.needsConsent)
    }

    @Test(arguments: ["0.10.4e", "0.10.4", "0.10.5", "0.10.3d"])
    func patchLevelWarns(found: String) {
        let v = VersionVerdict(found: GameVersion(found)!, tested: tested)
        #expect(v == .patchDifference && v.mayRun && !v.needsConsent)
    }

    @Test(arguments: ["0.11", "0.11.0a", "0.9.6"])
    func minorChangeNeedsConsent(found: String) {
        let v = VersionVerdict(found: GameVersion(found)!, tested: tested)
        #expect(v == .minorDifference && v.mayRun && v.needsConsent)
    }

    @Test(arguments: ["1.0", "1.10.4d"])
    func majorChangeFails(found: String) {
        let v = VersionVerdict(found: GameVersion(found)!, tested: tested)
        #expect(v == .majorDifference && !v.mayRun)
    }
}

@Suite struct ToolVersions {
    @Test func containerVersionLine() {
        #expect(ToolVersion(in: "container CLI version 1.6.1 (build: release, commit: aa8d76b)")
                == ToolVersion(major: 1, minor: 6, patch: 1))
    }
}
