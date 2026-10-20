import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct AikoRelinkMain {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let test = SelfTest(outDir: URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "screenshots"))
            app.setActivationPolicy(.regular)
            DispatchQueue.main.async { test.run() }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    let model = RelinkModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: RelinkView(model: model)))
        w.title = "AikoRelink"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 900, height: 640))
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.connect() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Durée d'un fichier audio / vidéo lisible par macOS (sinon nil : BRAW, R3D… se comparent sans durée).
func mediaDuration(_ path: String) -> Double? {
    let ext = (path as NSString).pathExtension.lowercased()
    guard ["mov", "mp4", "m4v", "wav", "mp3", "aif", "aiff", "m4a", "aac"].contains(ext) else { return nil }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let d = asset.duration
    guard d.isValid, !d.isIndefinite, d.seconds > 0 else { return nil }
    return d.seconds
}

@MainActor
final class RelinkModel: ObservableObject {
    enum Phase: Equatable { case connecting, ready, scanning, results, relinking, finished }

    @Published var phase: Phase = .connecting
    @Published var projectName = ""
    @Published var clips: [Clip] = []
    @Published var roots: [String] = Matcher.defaultRoots()
    @Published var results: [MatchResult] = []
    @Published var progress = ""
    @Published var error: String?
    @Published var summary = ""
    private var cancelled = false

    var python = "/usr/bin/python3"
    var extraEnv: [String: String] = [:]

    var offline: [Clip] { clips.filter(\.isOffline) }

    func connect() async {
        phase = .connecting
        error = nil
        let python = self.python, env = self.extraEnv
        let result = await Task.detached { () -> Result<Resolve.Project, Error> in
            do { return .success(try Resolve.loadProject(python: python, extraEnv: env)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let p):
            projectName = p.name
            clips = p.clips
            phase = .ready
        case .failure(let e):
            error = e.localizedDescription
            phase = .ready
        }
    }

    func search() async {
        let wanted = offline
        guard !wanted.isEmpty else { return }
        phase = .scanning
        cancelled = false
        progress = "Recherche sur les disques…"
        let roots = self.roots
        let found = await Task.detached { [weak self] () -> [MatchResult] in
            let files = Matcher.scan(roots, progress: { n, dir in
                Task { @MainActor in self?.progress = "\(n) médias parcourus… \((dir as NSString).lastPathComponent)" }
            }, cancel: { false })
            return Matcher.match(wanted, files: files, durationOf: mediaDuration)
        }.value
        results = found.sorted { ($0.confidence, $0.clip.name) > ($1.confidence, $1.clip.name) }
        phase = .results
    }

    var selectedCount: Int { results.filter { $0.selected && $0.choice != nil }.count }

    func repair() async {
        let pairs = results.compactMap { r -> (id: String, path: String)? in
            guard r.selected, let c = r.choice else { return nil }
            return (r.clip.id, c.file.path)
        }
        guard !pairs.isEmpty else { return }
        phase = .relinking
        let python = self.python, env = self.extraEnv
        let result = await Task.detached { () -> Result<(done: [String], failed: [String]), Error> in
            do { return .success(try Resolve.relink(pairs, python: python, extraEnv: env)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let r):
            summary = "\(r.done.count) média\(r.done.count > 1 ? "s" : "") réparé\(r.done.count > 1 ? "s" : "")"
                + (r.failed.isEmpty ? "" : ", \(r.failed.count) refusé\(r.failed.count > 1 ? "s" : "") par DaVinci")
                + ". Pense à enregistrer le projet (⌘S dans DaVinci)."
            results.removeAll { r.done.contains($0.clip.id) }
            await connect()
            phase = .finished
        case .failure(let e):
            error = e.localizedDescription
            phase = .results
        }
    }
}

// MARK: - Interface

struct RelinkView: View {
    @ObservedObject var model: RelinkModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let e = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Réessayer") { Task { await model.connect() } }
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            }
            switch model.phase {
            case .connecting:
                ProgressView("Connexion à DaVinci Resolve…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready, .finished:
                overview
            case .scanning:
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.progress).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .results, .relinking:
                resultsList
            }
        }
        .padding(22)
        .frame(minWidth: 820, minHeight: 560)
        .background(Theme.background(scheme))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.badge.plus").font(.system(size: 26)).foregroundStyle(Theme.accentText(scheme))
            VStack(alignment: .leading, spacing: 2) {
                Text("AikoRelink").font(.system(size: 20, weight: .semibold))
                Text(model.projectName.isEmpty ? "Retrouve les médias hors ligne de DaVinci Resolve"
                     : "Projet « \(model.projectName) » · \(model.clips.count) médias · \(model.offline.count) hors ligne")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.connect() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Relire le projet ouvert dans DaVinci")
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.summary.isEmpty && model.phase == .finished {
                Label(model.summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accentText(scheme)).font(.system(size: 13, weight: .medium))
            }
            if !model.projectName.isEmpty {
                if model.offline.isEmpty {
                    Label("Aucun média hors ligne dans ce projet.", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accentText(scheme))
                } else {
                    card("\(model.offline.count) média\(model.offline.count > 1 ? "s" : "") hors ligne") {
                        ForEach(model.offline.prefix(6)) { c in
                            HStack {
                                Image(systemName: "film").foregroundStyle(.red)
                                Text(c.fileName).font(.system(size: 12, weight: .medium))
                                Text(c.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if model.offline.count > 6 { Text("… et \(model.offline.count - 6) autres").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }
            }
            card("Où chercher") {
                ForEach(model.roots, id: \.self) { r in
                    HStack {
                        Image(systemName: r.hasPrefix("/Volumes/") ? "externaldrive" : "folder").foregroundStyle(.secondary)
                        Text(r.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 12))
                        Spacer()
                        Button { model.roots.removeAll { $0 == r } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                Button("Ajouter un dossier ou un disque…") { addRoot() }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Chercher les médias") { Task { await model.search() } }
                    .keyboardShortcut(.defaultAction).tint(Theme.accentUI)
                    .disabled(model.offline.isEmpty)
            }
        }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.results.filter { $0.choice != nil }.count) sur \(model.results.count) retrouvés")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Nouvelle recherche") { model.phase = .ready }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($model.results) { $r in ResultRow(result: $r) }
                }
            }
            HStack {
                Text("Les médias « Sûr » et « Probable » sont cochés. Vérifie les autres avant de réparer.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if model.phase == .relinking { ProgressView().controlSize(.small) }
                Button("Réparer \(model.selectedCount) média\(model.selectedCount > 1 ? "s" : "")") {
                    Task { await model.repair() }
                }
                .keyboardShortcut(.defaultAction).tint(Theme.accentUI)
                .disabled(model.selectedCount == 0 || model.phase == .relinking)
            }
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText(scheme))
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line(scheme)))
        }
    }

    private func addRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard p.runModal() == .OK else { return }
        for u in p.urls where !model.roots.contains(u.path) { model.roots.append(u.path) }
    }
}

struct ResultRow: View {
    @Binding var result: MatchResult
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $result.selected).labelsHidden().disabled(result.choice == nil)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.clip.fileName).font(.system(size: 13, weight: .semibold))
                    chip
                    Spacer()
                }
                Text(result.clip.path).font(.system(size: 11)).foregroundStyle(.red.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                if result.candidates.isEmpty {
                    Text("Aucun fichier ressemblant trouvé.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: Binding(get: { result.chosen ?? 0 }, set: { result.chosen = $0; result.selected = true })) {
                        ForEach(result.candidates.indices, id: \.self) { i in
                            Text("→ \(result.candidates[i].file.path)").tag(i)
                        }
                    }
                    .labelsHidden()
                    if let c = result.choice, !c.reasons.isEmpty {
                        Text(c.reasons.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface(scheme)))
    }

    private var chip: some View {
        let color: Color = {
            switch result.confidence {
            case .sure: return Theme.accentUI
            case .likely: return Color(red: 0.37, green: 0.83, blue: 0.6)
            case .check: return .orange
            case .none: return .red
            }
        }()
        return Text(result.confidence.label).font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.2))).foregroundStyle(color)
    }
}
