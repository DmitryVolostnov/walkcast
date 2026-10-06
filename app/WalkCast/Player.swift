import AVFoundation
import MediaPlayer
import Observation

/// Фоновое воспроизведение, экран блокировки, запоминание позиции по каждому эпизоду.
@Observable
final class Player {
    private(set) var current: Episode?
    private(set) var isPlaying = false
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var rate: Float = UserDefaults.standard.object(forKey: "rate") as? Float ?? 1.0 {
        didSet {
            UserDefaults.standard.set(rate, forKey: "rate")
            if isPlaying { player.rate = rate }
            updateNowPlaying()
        }
    }
    static let rates: [Float] = [1.0, 1.1, 1.25, 1.5]

    // Фоновая музыка — отдельная дорожка под голосом, можно выключить.
    // Плейлисты: Kevin MacLeod (incompetech.com, CC BY 4.0). Радио: SomaFM.
    struct MusicSource: Hashable {
        let id: String
        let title: String
        var stream: URL? = nil
    }
    static let musicSources = [
        MusicSource(id: "lounge", title: "Лаунж"),
        MusicSource(id: "calm", title: "Спокойно"),
        MusicSource(id: "groovesalad", title: "Groove Salad", stream: URL(string: "https://ice2.somafm.com/groovesalad-128-mp3")),
        MusicSource(id: "dronezone", title: "Drone Zone", stream: URL(string: "https://ice2.somafm.com/dronezone-128-mp3")),
    ]
    var musicOn: Bool = UserDefaults.standard.object(forKey: "musicOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(musicOn, forKey: "musicOn"); syncMusic() }
    }
    var musicVolume: Float = UserDefaults.standard.object(forKey: "musicVolume") as? Float ?? 0.12 {
        didSet { UserDefaults.standard.set(musicVolume, forKey: "musicVolume"); music.volume = musicVolume }
    }
    var musicSource: String = UserDefaults.standard.string(forKey: "musicSource2") ?? "lounge" {
        didSet { UserDefaults.standard.set(musicSource, forKey: "musicSource2"); loadedSource = nil; syncMusic() }
    }
    private let music = AVQueuePlayer()
    private var loadedSource: String?

    var currentChapter: Chapter? { current?.chapters.last { $0.start <= time + 0.5 } }

    private let player = AVPlayer()
    private var timeObserver: Any?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] t in
            guard let self, let ep = current else { return }
            time = t.seconds
            if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
            UserDefaults.standard.set(time, forKey: Self.positionKey(ep))
        }
        _ = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isPlaying = self?.player.rate ?? 0 > 0
            self?.syncMusic()
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let item = note.object as? AVPlayerItem, item !== player.currentItem {
                if music.items().last === item { enqueuePlaylist() }  // плейлист закончился — по новой
                return
            }
            guard let ep = current else { return }
            isPlaying = false
            syncMusic()
            UserDefaults.standard.set(true, forKey: Self.finishedKey(ep))
            UserDefaults.standard.set(0, forKey: Self.positionKey(ep))
        }
        setupRemoteCommands()
    }

    static func positionKey(_ ep: Episode) -> String { "pos-\(ep.id)" }
    static func finishedKey(_ ep: Episode) -> String { "done-\(ep.id)" }

    func progress(of ep: Episode) -> Double {
        if UserDefaults.standard.bool(forKey: Self.finishedKey(ep)) { return 1 }
        guard ep.duration > 0 else { return 0 }
        return UserDefaults.standard.double(forKey: Self.positionKey(ep)) / ep.duration
    }

    func play(_ ep: Episode) {
        if current?.id != ep.id {
            current = ep
            duration = ep.duration
            player.replaceCurrentItem(with: AVPlayerItem(url: ep.audioURL))
            let saved = UserDefaults.standard.double(forKey: Self.positionKey(ep))
            time = saved
            player.seek(to: CMTime(seconds: saved, preferredTimescale: 1))
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: rate)
        isPlaying = true
        syncMusic()
        updateNowPlaying()
    }

    func toggle() {
        guard let ep = current else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            syncMusic()
            updateNowPlaying()
        } else {
            play(ep)
        }
    }

    func skip(_ seconds: TimeInterval) { seek(to: time + seconds) }

    func seek(to t: TimeInterval) {
        time = max(0, min(t, duration))
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        updateNowPlaying()
    }

    private func syncMusic() {
        guard musicOn && isPlaying else { music.pause(); return }
        if loadedSource != musicSource {
            music.removeAllItems()
            loadedSource = musicSource
            if let url = Self.musicSources.first(where: { $0.id == musicSource })?.stream {
                music.insert(AVPlayerItem(url: url), after: nil)
            } else {
                enqueuePlaylist()
            }
        }
        music.volume = musicVolume
        music.play()
    }

    private func enqueuePlaylist() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(musicSource + "-") }
            .shuffled()
        for url in urls { music.insert(AVPlayerItem(url: url), after: nil) }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.toggleIf(false); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.toggleIf(true); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skip(30); return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-15); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func toggleIf(_ playing: Bool) { if isPlaying == playing { toggle() } }

    private func updateNowPlaying() {
        guard let ep = current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: ep.title,
            MPMediaItemPropertyArtist: "WalkCast",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
    }
}
