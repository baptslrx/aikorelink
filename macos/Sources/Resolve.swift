import AppKit

/// Dialogue avec DaVinci Resolve Studio par son API de scripts (Python, livré avec DaVinci).
enum Resolve {
    struct Project {
        let name: String
        let clips: [Clip]
    }

    enum Failure: Error, LocalizedError {
        case notInstalled, notRunning, noProject, scripting(String), python(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "DaVinci Resolve n'est pas installé dans Applications."
            case .notRunning: return "Ouvre DaVinci Resolve et ton projet, puis réessaie."
            case .noProject: return "Aucun projet ouvert dans DaVinci Resolve."
            case .scripting(let d):
                return "DaVinci refuse la connexion. Dans DaVinci : Préférences → Système → Général → « Script externe » : Local "
                    + "(version Studio nécessaire). \(d)"
            case .python(let d): return "Python n'a pas pu lancer le script : \(d)"
            }
        }
    }

    static let bundleID = "com.blackmagic-design.DaVinciResolve"

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let api = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
        let lib = (appURL?.path ?? "/Applications/DaVinci Resolve/DaVinci Resolve.app")
            + "/Contents/Libraries/Fusion/fusionscript.so"
        env["RESOLVE_SCRIPT_API"] = api
        env["RESOLVE_SCRIPT_LIB"] = lib
        env["PYTHONPATH"] = api + "/Modules/" + (env["PYTHONPATH"].map { ":" + $0 } ?? "")
        return env
    }

    /// Lance le script Python et renvoie sa réponse JSON.
    static func run(_ command: String, input: Data? = nil, python: String = "/usr/bin/python3",
                    extraEnv: [String: String] = [:]) throws -> [String: Any] {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("aikorelink_resolve.py")
        try Script.source.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script.path, command]
        p.environment = environment().merging(extraEnv) { _, new in new }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        do { try p.run() } catch { throw Failure.python(error.localizedDescription) }
        if let input { inp.fileHandleForWriting.write(input) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw Failure.python(errText.isEmpty ? "réponse vide" : String(errText.suffix(400)))
        }
        if let e = obj["error"] as? String {
            switch e {
            case "noresolve": throw isRunning ? Failure.scripting(obj["detail"] as? String ?? "") : Failure.notRunning
            case "noproject": throw Failure.noProject
            case "module": throw Failure.scripting(obj["detail"] as? String ?? "")
            default: throw Failure.python(e)
            }
        }
        return obj
    }

    static func loadProject(python: String = "/usr/bin/python3", extraEnv: [String: String] = [:]) throws -> Project {
        guard appURL != nil || !extraEnv.isEmpty else { throw Failure.notInstalled }
        let obj = try run("list", python: python, extraEnv: extraEnv)
        let raw = obj["clips"] as? [[String: Any]] ?? []
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        let clips: [Clip] = raw.compactMap { c in
            guard let id = c["id"] as? String, let path = c["path"] as? String, !path.isEmpty else { return nil }
            let fps = Double((c["fps"] as? String ?? "").replacingOccurrences(of: ",", with: "."))
            let frames = Double(c["frames"] as? String ?? "")
            var created: Date?
            if let ts = c["mtime"] as? Double { created = Date(timeIntervalSince1970: ts) }
            return Clip(id: id, name: c["name"] as? String ?? "", path: path, frames: frames, fps: fps, created: created,
                        bin: c["bin"] as? String ?? "")
        }
        return Project(name: obj["project"] as? String ?? "Projet", clips: clips)
    }

    /// Remplace le fichier de chaque média. Renvoie les identifiants réparés.
    static func relink(_ pairs: [(id: String, path: String)], python: String = "/usr/bin/python3",
                       extraEnv: [String: String] = [:]) throws -> (done: [String], failed: [String]) {
        let input = try JSONSerialization.data(withJSONObject: pairs.map { ["id": $0.id, "path": $0.path] })
        let obj = try run("relink", input: input, python: python, extraEnv: extraEnv)
        return (obj["done"] as? [String] ?? [], obj["failed"] as? [String] ?? [])
    }
}

/// Le script Python exécuté avec le module de DaVinci.
enum Script {
    static let source = #"""
import json, os, sys

def out(obj):
    print(json.dumps(obj))
    sys.exit(0)

def connect():
    try:
        import DaVinciResolveScript as dvr
    except Exception as e:
        out({"error": "module", "detail": str(e)})
    resolve = dvr.scriptapp("Resolve")
    if not resolve:
        out({"error": "noresolve"})
    project = resolve.GetProjectManager().GetCurrentProject()
    if not project:
        out({"error": "noproject"})
    return resolve, project

def walk(folder, path):
    for clip in folder.GetClipList() or []:
        yield clip, path
    for sub in folder.GetSubFolderList() or []:
        yield from walk(sub, path + [sub.GetName()])

def clip_id(clip):
    try:
        return clip.GetUniqueId()
    except Exception:
        return clip.GetMediaId()

def main():
    resolve, project = connect()
    pool = project.GetMediaPool()
    root = pool.GetRootFolder()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        clips = []
        for clip, path in walk(root, []):
            p = clip.GetClipProperty() or {}
            fp = p.get("File Path", "")
            if not fp:
                continue
            clips.append({"id": clip_id(clip), "name": p.get("Clip Name") or clip.GetName(), "path": fp,
                          "frames": str(p.get("Frames", "")), "fps": str(p.get("FPS", "")),
                          "type": p.get("Type", ""), "bin": "/".join(path)})
        out({"project": project.GetName(), "clips": clips})
    elif cmd == "relink":
        wanted = {m["id"]: m["path"] for m in json.load(sys.stdin)}
        done, failed = [], []
        for clip, _ in walk(root, []):
            cid = clip_id(clip)
            if cid not in wanted:
                continue
            new = wanted[cid]
            ok = False
            try:
                ok = bool(clip.ReplaceClip(new))
            except Exception:
                ok = False
            if not ok:
                try:
                    ok = bool(pool.RelinkClips([clip], os.path.dirname(new)))
                except Exception:
                    ok = False
            (done if ok else failed).append(cid)
        out({"done": done, "failed": failed})
    else:
        out({"error": "commande inconnue"})

main()
"""#
}
