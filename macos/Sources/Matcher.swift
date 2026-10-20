import Foundation

/// Un média du projet DaVinci.
struct Clip: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var path: String
    var frames: Double?
    var fps: Double?
    var created: Date?
    var bin: String = ""

    var duration: Double? {
        guard let f = frames, let r = fps, r > 0 else { return nil }
        return f / r
    }
    var fileName: String { (path as NSString).lastPathComponent }
    var isOffline: Bool { !path.isEmpty && !FileManager.default.fileExists(atPath: path) }
}

/// Un fichier trouvé sur les disques.
struct FileEntry: Equatable {
    let path: String
    let size: Int64
    let created: Date?
    var duration: Double?

    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
}

enum Confidence: String, Codable, Comparable {
    case none, check, likely, sure

    static func < (a: Confidence, b: Confidence) -> Bool {
        let order: [Confidence] = [.none, .check, .likely, .sure]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }

    var label: String {
        switch self {
        case .sure: return "Sûr"
        case .likely: return "Probable"
        case .check: return "À vérifier"
        case .none: return "Introuvable"
        }
    }
}

struct Candidate: Equatable {
    let file: FileEntry
    let score: Int
    let reasons: [String]
}

struct MatchResult: Identifiable, Equatable {
    let clip: Clip
    var candidates: [Candidate]
    var chosen: Int?            // index dans candidates
    var confidence: Confidence
    var selected: Bool          // coché pour la réparation

    var id: String { clip.id }
    var choice: Candidate? { chosen.flatMap { candidates.indices.contains($0) ? candidates[$0] : nil } }
}

enum Matcher {
    static let mediaExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mxf", "braw", "r3d", "ari", "avi", "mkv", "mts", "m2ts", "insv", "lrv", "webm", "dng",
        "wav", "mp3", "aif", "aiff", "m4a", "aac", "flac", "png", "jpg", "jpeg", "tif", "tiff", "psd", "exr", "dpx",
        "heic", "srt", "drt",
    ]

    /// Nom simplifié pour comparer « A001_C003.MOV » et « a001 c003.mov ».
    static func stem(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension.lowercased()
        return String(base.filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Parcours des disques

    static func defaultRoots() -> [String] {
        var roots: [String] = []
        if let vols = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for v in vols where !v.hasPrefix(".") {
                let p = "/Volumes/" + v
                // Le disque du système apparaît aussi dans /Volumes : on le remplace par le dossier personnel
                if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: p), dest == "/" { continue }
                roots.append(p)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for d in ["Movies", "Desktop", "Documents", "Downloads", "Pictures", "Music"] { roots.append(home + "/" + d) }
        return roots
    }

    private static let skipDirs: Set<String> = [
        "Library", "node_modules", ".git", ".Trashes", ".Spotlight-V100", ".fseventsd", "CacheClip", "Render Cache",
        ".DocumentRevisions-V100", "System", "Applications", "Optimized Media", "ProxyMedia",
    ]

    /// Liste tous les médias sous ces dossiers (s'arrête si `cancel` devient vrai).
    static func scan(_ roots: [String], progress: ((Int, String) -> Void)? = nil, cancel: () -> Bool = { false })
        -> [FileEntry] {
        var out: [FileEntry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey, .isPackageKey]
        for root in roots {
            guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
            else { continue }
            for case let url as URL in en {
                if cancel() { return out }
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true {
                    if skipDirs.contains(url.lastPathComponent) || v?.isPackage == true { en.skipDescendants() }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard mediaExtensions.contains(ext) else { continue }
                out.append(FileEntry(path: url.path, size: Int64(v?.fileSize ?? 0), created: v?.creationDate))
                if out.count % 500 == 0 { progress?(out.count, url.deletingLastPathComponent().path) }
            }
        }
        progress?(out.count, "")
        return out
    }

    // MARK: - Correspondances

    /// Nombre de dossiers en commun à la fin des deux chemins (« …/NTO/Rushs/A001.mov »).
    static func commonTail(_ a: String, _ b: String) -> Int {
        let pa = (a as NSString).deletingLastPathComponent.split(separator: "/").reversed()
        let pb = (b as NSString).deletingLastPathComponent.split(separator: "/").reversed()
        var n = 0
        for (x, y) in zip(pa, pb) {
            guard x.lowercased() == y.lowercased() else { break }
            n += 1
        }
        return n
    }

    static func score(_ clip: Clip, _ f: FileEntry) -> Candidate {
        var s = 0
        var why: [String] = []
        let clipName = clip.fileName
        if f.name.lowercased() == clipName.lowercased() {
            s += 50; why.append("même nom")
        } else if stem(f.name) == stem(clipName) && !stem(clipName).isEmpty {
            s += 35; why.append("nom presque identique")
        }
        if f.ext == (clipName as NSString).pathExtension.lowercased() { s += 10 }
        let tail = min(3, commonTail(clip.path, f.path))
        if tail > 0 { s += tail * 8; why.append("mêmes dossiers (\(tail))") }
        if let d1 = clip.duration, let d2 = f.duration {
            let frame = 1.0 / max(clip.fps ?? 25, 1)
            if abs(d1 - d2) <= frame * 1.5 {
                s += 30; why.append("même durée")
            } else if abs(d1 - d2) > 1 {
                s -= 40; why.append("durée différente")
            }
        }
        if let c1 = clip.created, let c2 = f.created, abs(c1.timeIntervalSince(c2)) < 3 {
            s += 15; why.append("même date de création")
        }
        return Candidate(file: f, score: s, reasons: why)
    }

    static func confidence(best: Int, second: Int?) -> Confidence {
        let margin = best - (second ?? 0)
        if best >= 72 && margin >= 15 { return .sure }
        if best >= 55 && margin >= 10 { return .likely }
        if best >= 35 { return .check }
        return .none
    }

    /// Fichiers qui pourraient correspondre (avant de mesurer les durées, coûteuses).
    static func shortlist(_ clip: Clip, byName: [String: [FileEntry]], byStem: [String: [FileEntry]],
                          byExt: [String: [FileEntry]]) -> [FileEntry] {
        var list = byName[clip.fileName.lowercased()] ?? []
        for f in byStem[stem(clip.fileName)] ?? [] where !list.contains(f) { list.append(f) }
        // Fichier renommé : même type et même date de création
        if list.isEmpty, let created = clip.created {
            let ext = (clip.fileName as NSString).pathExtension.lowercased()
            list = (byExt[ext] ?? []).filter { f in f.created.map { abs($0.timeIntervalSince(created)) < 3 } ?? false }
        }
        return Array(list.prefix(25))
    }

    /// Associe chaque média hors ligne au meilleur fichier trouvé.
    static func match(_ clips: [Clip], files: [FileEntry], durationOf: (String) -> Double? = { _ in nil }) -> [MatchResult] {
        let byName = Dictionary(grouping: files, by: { $0.name.lowercased() })
        let byStem = Dictionary(grouping: files, by: { stem($0.name) })
        let byExt = Dictionary(grouping: files, by: { $0.ext })
        var results: [MatchResult] = []
        for clip in clips {
            var shortlist = shortlist(clip, byName: byName, byStem: byStem, byExt: byExt)
            if clip.duration != nil {
                for i in shortlist.indices { shortlist[i].duration = durationOf(shortlist[i].path) }
            }
            let ranked = shortlist.map { score(clip, $0) }.sorted { $0.score > $1.score }
            let conf = ranked.isEmpty ? Confidence.none : confidence(best: ranked[0].score, second: ranked.dropFirst().first?.score)
            results.append(MatchResult(clip: clip, candidates: ranked, chosen: ranked.isEmpty ? nil : 0,
                                       confidence: conf, selected: conf >= .likely))
        }
        return learnFromMoves(results)
    }

    /// Si la plupart des médias d'un ancien dossier sont dans un même nouveau dossier, les autres y sont sûrement aussi.
    static func learnFromMoves(_ input: [MatchResult]) -> [MatchResult] {
        var moves: [String: [String: Int]] = [:]   // ancien dossier → nouveau dossier → nombre
        for r in input where r.confidence >= .likely {
            guard let c = r.choice else { continue }
            let from = (r.clip.path as NSString).deletingLastPathComponent
            let to = (c.file.path as NSString).deletingLastPathComponent
            moves[from, default: [:]][to, default: 0] += 1
        }
        return input.map { r in
            guard r.confidence < .sure else { return r }
            let from = (r.clip.path as NSString).deletingLastPathComponent
            guard let (to, n) = moves[from]?.max(by: { $0.value < $1.value }), n >= 2 else { return r }
            var out = r
            if let i = r.candidates.firstIndex(where: { ($0.file.path as NSString).deletingLastPathComponent == to }) {
                out.chosen = i
                if r.candidates[i].score >= 35 {
                    out.confidence = max(r.confidence, .likely)
                    out.selected = true
                }
            }
            return out
        }
    }
}
