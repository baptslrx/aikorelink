import AppKit
import SwiftUI

/// `AikoRelink --selftest <dossier>` : faux disques + faux DaVinci (même API Python), vraie recherche, vraie réparation.
@MainActor
final class SelfTest {
    let outDir: URL
    private var failures: [String] = []
    private var report: [String] = []
    private let ci = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil

    init(outDir: URL) { self.outDir = outDir }

    func run() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            await steps()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { [weak self] in
            MainActor.assumeIsolated { self?.check(false, "le test a dépassé 2 min 30"); self?.finish() }
        }
    }

    private func log(_ s: String) { print(s); fflush(stdout); report.append(s) }
    private func check(_ ok: Bool, _ what: String) {
        log((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { failures.append(what); if ci { print("::error title=Test::\(what)") } }
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// Fichier WAV silencieux d'une durée donnée (pour que macOS puisse lire sa durée).
    static func wav(_ path: String, seconds: Double) {
        let rate = 8000, n = Int(Double(rate) * seconds)
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(n * 2); d.append(Data(count: n * 2))
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: path))
    }

    static func touch(_ path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: URL(fileURLWithPath: path))
    }

    private func steps() async {
        let fm = FileManager.default
        // Chemin réel (/private/var/…), comme le renvoie le parcours des disques
        let tmpReal = realpath(fm.temporaryDirectory.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) }
            ?? fm.temporaryDirectory.path
        let base = tmpReal + "/aikorelink-\(UUID().uuidString)"
        let newDisk = base + "/SSD_Rushs_2026"
        // Les rushs ont changé de disque (« T7 » → « SSD_Rushs_2026 »), certains ont été renommés
        Self.touch(newDisk + "/NTO/Interviews/A001_C001.MOV")
        Self.touch(newDisk + "/NTO/Interviews/A001_C002.MOV")
        Self.touch(newDisk + "/NTO/Interviews/A001_C003.MOV")
        Self.touch(newDisk + "/NTO/Plans/drone 04.mp4")          // ancien nom : drone_04.mp4
        Self.wav(newDisk + "/NTO/Son/interview_zynox.wav", seconds: 2.0)
        Self.wav(base + "/Ancien/Son/interview_zynox.wav", seconds: 5.0)   // même nom, mauvaise durée
        Self.touch(base + "/Autre projet/A001_C003.MOV")                   // même nom, ailleurs
        Self.touch(newDisk + "/node_modules/A001_C001.MOV")               // dossier ignoré

        let old = "/Volumes/T7/NTO"
        let clips: [[String: Any]] = [
            ["id": "c1", "name": "A001_C001.MOV", "path": old + "/Interviews/A001_C001.MOV", "frames": "250", "fps": "25"],
            ["id": "c2", "name": "A001_C002.MOV", "path": old + "/Interviews/A001_C002.MOV", "frames": "250", "fps": "25"],
            ["id": "c3", "name": "A001_C003.MOV", "path": old + "/Interviews/A001_C003.MOV", "frames": "250", "fps": "25"],
            ["id": "c4", "name": "drone_04.mp4", "path": old + "/Plans/drone_04.mp4", "frames": "", "fps": ""],
            ["id": "c5", "name": "interview_zynox.wav", "path": old + "/Son/interview_zynox.wav", "frames": "50", "fps": "25"],
            ["id": "c6", "name": "introuvable.mov", "path": old + "/Plans/introuvable.mov", "frames": "100", "fps": "25"],
            ["id": "c7", "name": "logo.png", "path": newDisk + "/logo.png", "frames": "1", "fps": "25"],   // en ligne
        ]
        Self.touch(newDisk + "/logo.png")

        // Faux module DaVinciResolveScript : mêmes fonctions que le vrai, journal des remplacements
        let fake = base + "/fake"
        try? fm.createDirectory(atPath: fake, withIntermediateDirectories: true)
        let clipsJSON = String(decoding: try! JSONSerialization.data(withJSONObject: clips), as: UTF8.self)
        let module = """
        import json, os
        LOG = os.path.join(os.path.dirname(__file__), "replaced.json")
        CLIPS = json.loads(r'''\(clipsJSON)''')
        class Clip:
            def __init__(self, d): self.d = d
            def GetClipProperty(self, key=None):
                p = {"Clip Name": self.d["name"], "File Path": self.d["path"], "Frames": self.d["frames"], "FPS": self.d["fps"], "Type": "Video"}
                return p if key is None else p.get(key)
            def GetName(self): return self.d["name"]
            def GetUniqueId(self): return self.d["id"]
            def ReplaceClip(self, path):
                log = json.load(open(LOG)) if os.path.exists(LOG) else {}
                log[self.d["id"]] = path
                json.dump(log, open(LOG, "w"))
                return os.path.exists(path)
        class Folder:
            def __init__(self, name, clips, subs): self.n, self.c, self.s = name, clips, subs
            def GetClipList(self): return self.c
            def GetSubFolderList(self): return self.s
            def GetName(self): return self.n
        class Pool:
            def GetRootFolder(self):
                cs = [Clip(d) for d in CLIPS]
                return Folder("Master", cs[:2], [Folder("Rushs", cs[2:], [])])
            def RelinkClips(self, clips, folder): return False
        class Project:
            def GetName(self): return "Interviews NTO"
            def GetMediaPool(self): return Pool()
        class PM:
            def GetCurrentProject(self): return Project()
        class App:
            def GetProjectManager(self): return PM()
        def scriptapp(name): return App()
        """
        try? module.write(toFile: fake + "/DaVinciResolveScript.py", atomically: true, encoding: .utf8)

        log("== Lecture du projet (API Python de DaVinci, simulée)")
        let model = RelinkModel()
        model.extraEnv = ["PYTHONPATH": fake]
        model.roots = [base]
        await model.connect()
        check(model.error == nil, "connexion : \(model.error ?? "ok")")
        check(model.projectName == "Interviews NTO" && model.clips.count == 7, "projet lu : \(model.projectName), \(model.clips.count) médias")
        check(model.offline.count == 6, "6 médias hors ligne repérés (\(model.offline.count))")

        log("== Recherche sur les disques")
        await model.search()
        for r in model.results {
            log("   \(r.clip.fileName) → \(r.choice?.file.path.replacingOccurrences(of: base, with: "…") ?? "rien") [\(r.confidence.label), \(r.choice?.score ?? 0)] \(r.choice?.reasons.joined(separator: ", ") ?? "")")
        }
        func res(_ id: String) -> MatchResult? { model.results.first { $0.clip.id == id } }
        check(res("c1")?.choice?.file.path == newDisk + "/NTO/Interviews/A001_C001.MOV" && res("c1")?.confidence == .sure,
              "même nom, autre disque : sûr (et le dossier node_modules est ignoré)")
        check(res("c3")?.choice?.file.path == newDisk + "/NTO/Interviews/A001_C003.MOV",
              "deux fichiers du même nom : le bon dossier gagne")
        check(res("c4")?.choice?.file.path == newDisk + "/NTO/Plans/drone 04.mp4", "fichier renommé « drone 04 » retrouvé")
        check(res("c5")?.choice?.file.path == newDisk + "/NTO/Son/interview_zynox.wav",
              "même nom mais mauvaise durée écarté (son de 2 s, pas 5 s)")
        check(res("c6")?.choice == nil && res("c6")?.selected == false, "fichier introuvable : rien de coché")

        await snapshot(RelinkView(model: model), name: "resultats")

        log("== Réparation dans DaVinci")
        await model.repair()
        let replaced = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fake + "/replaced.json")))) as? [String: String] ?? [:]
        check(replaced["c1"] == newDisk + "/NTO/Interviews/A001_C001.MOV" && replaced["c5"] != nil, "DaVinci a reçu les nouveaux chemins (\(replaced.count))")
        check(replaced["c6"] == nil, "le média introuvable n'est pas touché")
        check(model.summary.contains("réparé"), "message : \(model.summary)")
        await snapshot(RelinkView(model: model), name: "termine")
        try? fm.removeItem(atPath: base)

        log("== Sans DaVinci")
        let m2 = RelinkModel()
        m2.extraEnv = ["PYTHONPATH": "/nexiste/pas"]
        await m2.connect()
        check(m2.error != nil, "message clair si DaVinci ne répond pas : \(m2.error ?? "")")
        await snapshot(RelinkView(model: m2), name: "sans-davinci")
    }

    private func snapshot<V: View>(_ view: V, name: String) async {
        for dark in [true, false] {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = host
            w.orderFrontRegardless()
            await sleep(0.6)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = "\(name)-\(dark ? "sombre" : "clair").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(file))
                log("   capture \(file)")
            }
            w.orderOut(nil)
        }
    }

    private var finished = false
    private func finish() {
        guard !finished else { return }
        finished = true
        log(failures.isEmpty ? "\nTout est OK" : "\nÉCHECS :\n" + failures.joined(separator: "\n"))
        try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("rapport.txt"), atomically: true, encoding: .utf8)
        exit(failures.isEmpty ? 0 : 1)
    }
}
