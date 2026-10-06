import SwiftUI

@main
struct WalkCastApp: App {
    @State private var library = Library()
    @State private var player = Player()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await library.sync() } }
                }
        }
    }
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var pickingFolder = false
    @State private var showPlayer = false

    var body: some View {
        NavigationStack {
            Group {
                if library.episodes.isEmpty && !library.hasFolder {
                    ContentUnavailableView {
                        Label("Выбери папку", systemImage: "folder")
                    } description: {
                        Text("iCloud Drive → WalkCast. Туда Мак каждый вечер кладёт новый выпуск.")
                    } actions: {
                        Button("Выбрать папку") { pickingFolder = true }.buttonStyle(.borderedProminent)
                    }
                } else if library.episodes.isEmpty {
                    ContentUnavailableView("Пока пусто", systemImage: "headphones",
                                           description: Text(library.isSyncing ? "Загружаю из iCloud…" : "Первый выпуск появится после 19:00."))
                } else {
                    List {
                        ForEach(library.episodes) { ep in
                            Section {
                                EpisodeRow(episode: ep)
                                    .contentShape(Rectangle())
                                    .onTapGesture { player.play(ep); showPlayer = true }
                                    .swipeActions {
                                        Button("Удалить", role: .destructive) { library.delete(ep) }
                                    }
                            }
                        }
                        if let latest = library.episodes.first, !latest.next.isEmpty {
                            Section { TomorrowPicker(episode: latest) }
                        }
                    }
                    .listSectionSpacing(12)
                    .refreshable { await library.sync() }
                }
            }
            .navigationTitle("WalkCast")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Сменить папку", systemImage: "folder") { pickingFolder = true }
                        Button("Обновить", systemImage: "arrow.clockwise") { Task { await library.sync() } }
                    } label: {
                        if library.isSyncing { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.current != nil {
                    MiniPlayer().onTapGesture { showPlayer = true }
                }
            }
            .overlay(alignment: .top) {
                if let error = library.lastError {
                    Text(error).font(.footnote).padding(8).background(.red.opacity(0.15), in: .capsule)
                }
            }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.setFolder(url) }
        }
        .sheet(isPresented: $showPlayer) { PlayerView().presentationDragIndicator(.visible) }
    }
}

struct EpisodeRow: View {
    let episode: Episode
    @Environment(Player.self) private var player

    var body: some View {
        let progress = player.progress(of: episode)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(episode.date.map { $0.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "ru_RU"))) } ?? episode.id)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if progress >= 1 {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                } else if episode.duration > 0 {
                    Text("\(Int(episode.duration / 60)) мин").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(episode.title).font(.headline)
                .foregroundStyle(player.current?.id == episode.id ? Color.accentColor : .primary)
            ForEach(episode.topics.filter { !["Вступление", "Напоследок"].contains($0) }, id: \.self) { topic in
                Text("• \(topic)").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if progress > 0 && progress < 1 {
                ProgressView(value: progress).tint(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MiniPlayer: View {
    @Environment(Player.self) private var player

    var body: some View {
        HStack {
            Text(player.current?.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer()
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
    }
}

struct PlayerView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var player = player
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "figure.walk").font(.system(size: 48)).foregroundStyle(.tint).padding(.top, 32)
                Text(player.current?.title ?? "").font(.title2.bold()).multilineTextAlignment(.center)

                VStack(spacing: 4) {
                    Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }),
                           in: 0...max(player.duration, 1))
                    HStack {
                        Text(format(player.time))
                        Spacer()
                        Text("−" + format(player.duration - player.time))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                HStack(spacing: 48) {
                    Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 72))
                    }
                    Button { player.skip(30) } label: { Image(systemName: "goforward.30") }
                }
                .font(.largeTitle)

                Picker("Скорость", selection: $player.rate) {
                    ForEach(Player.rates, id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                }
                .pickerStyle(.segmented)

                MusicControls()

                if let ep = player.current, !ep.chapters.isEmpty {
                    ChapterList(episode: ep)
                }

                if let ep = player.current, !ep.next.isEmpty {
                    TomorrowPicker(episode: ep)
                }
            }
            .padding(24)
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct MusicControls: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        VStack(spacing: 12) {
            HStack {
                Toggle(isOn: $player.musicOn) {
                    Label("Фоновая музыка", systemImage: "music.note")
                }
            }
            if player.musicOn {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $player.musicVolume, in: 0...0.3)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                Picker("Музыка", selection: $player.musicSource) {
                    ForEach(Player.musicSources, id: \.id) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                Text(Player.musicSources.first { $0.id == player.musicSource }?.stream != nil ? "Интернет-радио SomaFM, нужен интернет" : "Kevin MacLeod, incompetech.com · CC BY 4.0")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }
}

struct ChapterList: View {
    let episode: Episode
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Темы").font(.headline).padding(.bottom, 8)
            ForEach(episode.chapters, id: \.self) { ch in
                let active = player.currentChapter == ch
                Button { player.seek(to: ch.start) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%d:%02d", Int(ch.start) / 60, Int(ch.start) % 60))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(ch.title).fontWeight(active ? .semibold : .regular)
                            .foregroundStyle(active ? Color.accentColor : .primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// «О чём поговорим завтра?» — до трёх тем, Мак учтёт их в следующем выпуске.
struct TomorrowPicker: View {
    let episode: Episode
    @Environment(Library.self) private var library
    @State private var selected: [Candidate] = []
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("О чём поговорим завтра?").font(.headline)
            Text(saved ? "Записала. Завтра будет про это." : "Выбери до трёх тем.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(episode.next, id: \.self) { c in
                let on = selected.contains(c)
                Button {
                    if on { selected.removeAll { $0 == c } } else if selected.count < 3 { selected.append(c) }
                    library.savePicks(selected, after: episode)
                    saved = !selected.isEmpty
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? Color.accentColor : .secondary).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(c.teaser).font(.caption).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(on ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!on && selected.count >= 3)
            }
        }
        .onAppear {
            selected = library.picks(for: episode)
            saved = !selected.isEmpty
        }
    }
}
