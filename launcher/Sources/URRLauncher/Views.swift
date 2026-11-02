import AppKit
import SwiftUI
import UniformTypeIdentifiers
import URRCore

struct RootView: View {
    @Bindable var model: LauncherModel
    @State private var window: NSWindow?
    @State private var launcherFrame: NSRect?

    var body: some View {
        Group {
            if model.phase == .playing, let session = model.session {
                GameWebView(url: session.viewer) { message in handle(message) }
                    .ignoresSafeArea()
                    .background(.black)
            } else {
                LauncherView(model: model)
            }
        }
        .background(WindowAccessor { w in if window !== w { window = w } })
        .onChange(of: model.phase) { old, new in
            if new == .playing { launcherFrame = window?.frame }
            if old == .playing, new != .playing { restoreLauncherWindow() }
        }
        .onChange(of: model.gameSize) { _, size in if let size { fitWindow(to: size) } }
    }

    private func handle(_ message: [String: Any]) {
        switch message["event"] as? String {
        case "size":
            if let w = message["width"] as? Double, let h = message["height"] as? Double, w > 0, h > 0 {
                model.gameSize = CGSize(width: w, height: h)
            }
        case "error":
            model.append(LogEntry(.error, "viewer: \(message["reason"] ?? "unknown error")"))
        default:
            break
        }
    }

    /// Size the window to the game (one game pixel per point, so Retina
    /// screens show it at a crisp 2x) and keep its shape while resizing.
    private func fitWindow(to size: CGSize) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? size
        let chrome = window.frame.height - window.contentLayoutRect.height
        let scale = min(1, visible.width / size.width, (visible.height - chrome) / size.height)
        window.contentAspectRatio = size
        window.setContentSize(CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded()))
        window.center()
    }

    private func restoreLauncherWindow() {
        guard let window else { return }
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.contentAspectRatio = .zero
        window.resizeIncrements = NSSize(width: 1, height: 1)
        if let launcherFrame { window.setFrame(launcherFrame, display: true, animate: true) }
    }
}

struct LauncherView: View {
    @Bindable var model: LauncherModel
    @State private var tab = Tab.setup
    @State private var showLog = true
    @State private var dropTargeted = false

    enum Tab: String, CaseIterable { case setup = "Setup", news = "Developer blog" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == .setup || model.resources?.newsPage == nil {
                setup
            } else if let page = model.resources?.newsPage {
                NewsWebView(page: page)
            }
            if showLog {
                Divider()
                LogConsole(model: model)
                    .frame(height: 190)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.pathExtension.lowercased() == "zip" {
                    Task { @MainActor in model.importZip(url) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 3).padding(6)
                    .overlay(Text("Drop the game ZIP to use it").font(.title3.bold()).padding(10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8)))
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if model.resources?.newsPage != nil {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            ToolbarItem {
                Toggle(isOn: $showLog) { Label("Looking glass", systemImage: "terminal") }
                    .help("Show everything the launcher is doing")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ultima Ratio Regum").font(.system(size: 26, weight: .semibold, design: .serif))
                Text("by Mark R Johnson · runs in a small Linux VM on this Mac")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            playButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var playButton: some View {
        switch model.phase {
        case .ready:
            Button { model.play() } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 90) }
                .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        case .starting:
            ProgressView().controlSize(.small)
            Text("Starting…").foregroundStyle(.secondary)
        case .preparing:
            ProgressView().controlSize(.small)
            Text("Setting up…").foregroundStyle(.secondary)
        case .failed:
            Button("Try again") { model.prepare() }.controlSize(.large)
        case .playing:
            EmptyView()
        }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let prompt = model.prompt {
                    PromptCard(prompt: prompt, model: model)
                }
                if case .failed(let why) = model.phase {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .red, text: why)
                }
                if let lastExit = model.lastExit {
                    Banner(symbol: "info.circle.fill", tint: .secondary, text: lastExit)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Step.allCases) { step in
                        StepRow(step: step, state: model.steps[step] ?? .pending,
                                progress: step == .game ? model.downloadProgress : nil)
                        if step != Step.allCases.last { Divider().padding(.leading, 40) }
                    }
                }
                .background(.background.secondary, in: .rect(cornerRadius: 10))
                Text("Game files stay exactly as Mark R Johnson distributes them; saves are in \(model.paths.saves.path).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

struct StepRow: View {
    let step: Step
    let state: StepState
    let progress: Double?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.headline)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let progress { ProgressView(value: progress).frame(maxWidth: 320) }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var detail: String? {
        switch state {
        case .pending: return nil
        case .running(let d), .done(let d), .warning(let d), .waiting(let d), .failed(let d): return d
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .waiting: Image(systemName: "hand.raised.circle.fill").foregroundStyle(.blue)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    var body: some View {
        Label { Text(text).textSelection(.enabled) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}

/// A decision only the player can make, with the options laid out.
struct PromptCard: View {
    let prompt: Prompt
    let model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch prompt.kind {
            case .installContainer:
                Text("Install Apple's container runtime").font(.title3.bold())
                Text("The game runs in a small Linux VM managed by Apple's open-source container runtime (version \(Manifest.container.version.description)). The launcher downloads Apple's signed installer from GitHub, checks its signature, and installs it. macOS will ask for your password once.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install container \(Manifest.container.version.description)") { prompt.resolve(.yes) }
                        .buttonStyle(.borderedProminent)
                    Button("Not now") { prompt.resolve(.no) }
                    Spacer()
                    Link("About container", destination: URL(string: "https://github.com/apple/container")!)
                }
            case .gameSource(let reason):
                Text("Get the game").font(.title3.bold())
                Text("\(reason) Ultima Ratio Regum is free, made by Mark R Johnson. Download it from his site, or choose the ZIP you downloaded yourself (you can also drop it on this window).")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Download \(Manifest.game.zipName) (\(Manifest.game.size / 1_000_000) MB)") { prompt.resolve(.download) }
                        .buttonStyle(.borderedProminent)
                    Button("Choose ZIP…") { chooseZip() }
                    Spacer()
                    Link("Game page", destination: Manifest.gamePage)
                }
            case .untestedVersion(let version, let explanation):
                Text("Version \(version.description) hasn't been tested").font(.title3.bold())
                Text(explanation).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try \(version.description) anyway") { prompt.resolve(.yes) }
                        .buttonStyle(.borderedProminent)
                    Button("Choose a different ZIP") { prompt.resolve(.no) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.blue.opacity(0.35)))
    }

    private func chooseZip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose the Ultima Ratio Regum ZIP from markrjohnsongames.com"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { prompt.resolve(.zip(url)) }
    }
}

/// The "looking glass": every step, command and line of output.
struct LogConsole: View {
    let model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Looking glass").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.map(\.plain).joined(separator: "\n"), forType: .string)
                }
                Button("Show log file") { NSWorkspace.shared.activateFileViewerSelecting([model.logFile.url]) }
            }
            .buttonStyle(.borderless).font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.log) { entry in
                            Text(entry.plain)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(entry.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                .onChange(of: model.log.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func color(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .step: return .primary
        case .command: return .blue
        case .output, .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
