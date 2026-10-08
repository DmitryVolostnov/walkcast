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
    /// nil — файл скачан и готов; иначе текст состояния («Скачивается из iCloud…»)
    var status: String? = nil

    var isReady: Bool { status == nil }
    var date: Date? { Library.dateFormatter.date(from: id) }
}

/// Эпизоды из папки iCloud Drive/WalkCast. Файлы копируются в Documents,
/// чтобы играть офлайн и не держать security-scoped доступ во время прогулки.
///
/// Главное правило: синхронизация никогда не блокируется надолго. Если файл ещё
/// не скачан из iCloud, мы просим систему его скачать, показываем карточку со
/// статусом и возвращаемся позже, а не висим со спиннером.
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
    private var pendingStatus: [String: String] = [:]
    private var retryTask: Task<Void, Never>?
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

    // MARK: Синхронизация

    @MainActor
    func sync() async {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey), !isSyncing else { return }
        isSyncing = true
        lastError = nil
        let localDir = localDir
        let result = await Task.detached { try Self.pull(bookmark: data, into: localDir) }.result
        switch result {
        case .success(let pending):
            pendingStatus = pending
        case .failure(let error):
            lastError = error.localizedDescription
        }
        loadLocal()
        isSyncing = false
        scheduleRetryIfNeeded()
    }

    /// Пока что-то ещё качается, пробуем снова каждые 20 секунд (только пока приложение открыто).
    @MainActor
    private func scheduleRetryIfNeeded() {
        retryTask?.cancel()
        guard !pendingStatus.isEmpty else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Возвращает статусы эпизодов, которые ещё не скачались: id → текст.
    private static func pull(bookmark: Data, into localDir: URL) throws -> [String: String] {
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        guard folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { folder.stopAccessingSecurityScopedResource() }
        if stale, let fresh = try? folder.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: "sourceFolderBookmark")
        }

        let fm = FileManager.default
        // Не скачанные файлы на некоторых системах видны как «.имя.icloud» — приводим к настоящему имени
        let names = try fm.contentsOfDirectory(atPath: folder.path).map { name in
            name.hasPrefix(".") && name.hasSuffix(".icloud")
                ? String(name.dropFirst().dropLast(".icloud".count)) : name
        }
        // Папка в iCloud — источник правды: что удалено там, удаляется и здесь
        let remote = Set(names)
        for local in (try? fm.contentsOfDirectory(atPath: localDir.path)) ?? [] where !remote.contains(local) {
            try? fm.removeItem(at: localDir.appending(path: local))
        }

        var pending: [String: String] = [:]
        // Сначала маленькие json (чтобы карточка появилась сразу), потом mp3
        let wanted = names.filter { $0.hasSuffix(".json") && $0 != "tomorrow.json" } + names.filter { $0.hasSuffix(".mp3") }
        for name in wanted {
            let dest = localDir.appending(path: name)
            if name.hasSuffix(".mp3") && fm.fileExists(atPath: dest.path) { continue }
            let src = folder.appending(path: name)
            let id = String(name.prefix(while: { $0 != "." }))
            switch fetch(src, to: dest, timeout: name.hasSuffix(".mp3") ? 60 : 10) {
            case .done:
                break
            case .downloading:
                if name.hasSuffix(".mp3") { pending[id] = "Скачивается из iCloud…" }
            case .failed(let message):
                if name.hasSuffix(".mp3") { pending[id] = "Не скачалось: \(message)" }
            }
        }
        return pending
    }

    private enum Fetch { case done, downloading, failed(String) }

    /// Копирует файл из iCloud, если он уже скачан; если нет — запускает скачивание
    /// и ждёт не дольше `timeout`. Никогда не блокируется бесконечно.
    private static func fetch(_ src: URL, to dest: URL, timeout: TimeInterval) -> Fetch {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let values = try? src.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey, .isUbiquitousItemKey])
            let isCloud = values?.isUbiquitousItem ?? false
            let status = values?.ubiquitousItemDownloadingStatus
            let ready = !isCloud || status == .current || status == .downloaded
            if ready {
                return copy(src, to: dest)
            }
            if let error = values?.ubiquitousItemDownloadingError {
                return .failed(error.localizedDescription)
            }
            try? FileManager.default.startDownloadingUbiquitousItem(at: src)
            if Date() > deadline { return .downloading }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static func copy(_ src: URL, to dest: URL) -> Fetch {
        let fm = FileManager.default
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [.withoutChanges], error: &coordError) { readURL in
            do {
                let tmp = dest.appendingPathExtension("part")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: readURL, to: tmp)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
            } catch { copyError = error }
        }
        if let e = coordError ?? copyError { return .failed(e.localizedDescription) }
        return .done
    }

    // MARK: Локальная библиотека

    func loadLocal() {
        let files = (try? FileManager.default.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil)) ?? []
        let ids = Set(files.filter { ["mp3", "json"].contains($0.pathExtension) }.map { $0.deletingPathExtension().lastPathComponent })
        episodes = ids.map { id in
            let mp3 = localDir.appending(path: "\(id).mp3")
            let hasAudio = FileManager.default.fileExists(atPath: mp3.path)
            var ep = Episode(id: id, audioURL: mp3, title: id, topics: [], duration: 0,
                             status: hasAudio ? nil : (pendingStatus[id] ?? "Скачивается из iCloud…"))
            if let data = try? Data(contentsOf: localDir.appending(path: "\(id).json")),
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
                let message = "Не удалось сохранить выбор: \(error.localizedDescription)"
                await MainActor.run { self?.lastError = message }
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
        pendingStatus[episode.id] = nil
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
