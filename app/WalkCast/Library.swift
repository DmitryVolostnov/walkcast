import Foundation
import Observation

struct Chapter: Hashable, Decodable {
    let title: String
    let start: TimeInterval
}

struct Candidate: Hashable, Codable {
    let title: String
    let teaser: String
}

struct Episode: Identifiable, Hashable {
    let id: String            // "2026-10-06"
    let audioURL: URL
    var title: String
    var topics: [String]
    var duration: TimeInterval
    var chapters: [Chapter] = []
    var next: [Candidate] = []

    var date: Date? { Library.dateFormatter.date(from: id) }
}

/// Эпизоды из папки iCloud Drive/WalkCast. Файлы копируются в Documents,
/// чтобы играть офлайн и не держать security-scoped доступ во время прогулки.
@Observable
final class Library {
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private(set) var episodes: [Episode] = []
    private(set) var isSyncing = false
    private(set) var lastError: String?
    var hasFolder: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    private let bookmarkKey = "sourceFolderBookmark"
    private let localDir: URL = {
        let dir = URL.documentsDirectory.appending(path: "Episodes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { loadLocal() }

    func setFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        Task { await sync() }
    }

    @MainActor
    func sync() async {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey), !isSyncing else { return }
        isSyncing = true
        lastError = nil
        let localDir = localDir
        let result: Result<Void, Error> = await Task.detached {
            var stale = false
            let folder = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
            guard folder.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            defer { folder.stopAccessingSecurityScopedResource() }
            if stale, let fresh = try? folder.bookmarkData() {
                UserDefaults.standard.set(fresh, forKey: "sourceFolderBookmark")
            }
            try Self.copyNew(from: folder, to: localDir)
        }.result
        if case .failure(let error) = result { lastError = error.localizedDescription }
        loadLocal()
        isSyncing = false
    }

    /// Не скачанные из iCloud файлы видны как «.имя.icloud» — NSFileCoordinator докачивает их.
    private static func copyNew(from folder: URL, to localDir: URL) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: folder.path).map { name in
            name.hasPrefix(".") && name.hasSuffix(".icloud")
                ? String(name.dropFirst().dropLast(".icloud".count)) : name
        }
        // Папка в iCloud — источник правды: что удалено там, удаляется и здесь
        let remote = Set(names)
        for local in (try? fm.contentsOfDirectory(atPath: localDir.path)) ?? [] where !remote.contains(local) {
            try? fm.removeItem(at: localDir.appending(path: local))
        }
        for name in names where name.hasSuffix(".mp3") || name.hasSuffix(".json") {
            let dest = localDir.appending(path: name)
            if fm.fileExists(atPath: dest.path) && name.hasSuffix(".mp3") { continue }
            let src = folder.appending(path: name)
            var coordError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &coordError) { readURL in
                do {
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: readURL, to: dest)
                } catch { copyError = error }
            }
            if let e = coordError ?? copyError { throw e }
        }
    }

    func loadLocal() {
        let files = (try? FileManager.default.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil)) ?? []
        episodes = files.filter { $0.pathExtension == "mp3" }.map { mp3 in
            let id = mp3.deletingPathExtension().lastPathComponent
            var ep = Episode(id: id, audioURL: mp3, title: id, topics: [], duration: 0)
            if let data = try? Data(contentsOf: mp3.deletingPathExtension().appendingPathExtension("json")),
               let meta = try? JSONDecoder().decode(Meta.self, from: data) {
                ep.title = meta.title
                ep.topics = meta.topics
                ep.duration = meta.duration
                ep.chapters = meta.chapters ?? []
                ep.next = meta.next ?? []
            }
            return ep
        }.sorted { $0.id > $1.id }
    }

    // MARK: Выбор тем на завтра — Мак читает tomorrow.json из той же папки iCloud

    func picks(for ep: Episode) -> [Candidate] {
        guard let data = UserDefaults.standard.data(forKey: "picks-\(ep.id)") else { return [] }
        return (try? JSONDecoder().decode([Candidate].self, from: data)) ?? []
    }

    func savePicks(_ picks: [Candidate], after ep: Episode) {
        UserDefaults.standard.set(try? JSONEncoder().encode(picks), forKey: "picks-\(ep.id)")
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        let payload = try? JSONSerialization.data(withJSONObject: [
            "after": ep.id,
            "picks": picks.map { ["title": $0.title, "teaser": $0.teaser] },
        ], options: .prettyPrinted)
        Task.detached { [weak self] in
            do {
                var stale = false
                let folder = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
                guard folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileWriteNoPermission) }
                defer { folder.stopAccessingSecurityScopedResource() }
                let file = folder.appending(path: "tomorrow.json")
                var coordError: NSError?
                var writeError: Error?
                NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordError) { url in
                    do { try payload?.write(to: url) } catch { writeError = error }
                }
                if let e = coordError ?? writeError { throw e }
            } catch {
                await MainActor.run { self?.lastError = "Не удалось сохранить выбор: \(error.localizedDescription)" }
            }
        }
    }

    func delete(_ episode: Episode) {
        // удаляем и в iCloud, иначе следующая синхронизация вернёт выпуск
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let folder = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
               folder.startAccessingSecurityScopedResource() {
                for ext in ["mp3", "json", "md"] {
                    let url = folder.appending(path: "\(episode.id).\(ext)")
                    NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) {
                        try? FileManager.default.removeItem(at: $0)
                    }
                }
                folder.stopAccessingSecurityScopedResource()
            }
        }
        try? FileManager.default.removeItem(at: episode.audioURL)
        try? FileManager.default.removeItem(at: episode.audioURL.deletingPathExtension().appendingPathExtension("json"))
        loadLocal()
    }

    private struct Meta: Decodable {
        let title: String
        let topics: [String]
        let duration: TimeInterval
        let chapters: [Chapter]?
        let next: [Candidate]?
    }
}
