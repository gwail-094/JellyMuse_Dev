//
//  SearchFilter.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 03.09.2025.
//

import SwiftUI
import Combine

enum SearchRoute: Hashable {
    case genre(String)                  // genre name
    case artist(id: String, name: String) // artist id + name
    case replay
}

// MARK: - Filter tabs (chips)
enum SearchFilter: String, CaseIterable, Identifiable {
    case top = "Top Results"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case playlists = "Playlists"
    case downloaded = "Downloaded"

    var id: String { rawValue }
}

// MARK: - Daily showcase model (stored once per day)
struct DailyShowcaseState: Codable, Equatable {
    struct ArtistRef: Codable, Equatable {
        let name: String
        let id: String
    }
    var dayKey: String              // "yyyy-MM-dd"
    var replayIndex: Int
    var genreKeys: [String]
    var artists: [ArtistRef] = []   // ← names + ids
}

struct GenreAsset: Identifiable, Hashable {
    let id: String                  // e.g., "Deutschrap"
    let title: String               // display title; can equal id
    let assetName: String           // asset name in the catalog
}

// MARK: - Model Helpers
extension JellyfinArtistItem {
    /// Minimal stub so views can navigate with just id+name.
    static func light(id: String, name: String) -> JellyfinArtistItem {
        JellyfinArtistItem(
            id: id,
            name: name,
            primaryImageTag: nil,
            imageTags: nil
        )
    }
}


// MARK: - ViewModel
@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var selected: SearchFilter = .top
    @Published var queryCommitted: Bool = false

    // Remote
    @Published var artists: [JellyfinSearchHint] = []
    @Published var albums:  [JellyfinSearchHint] = []
    @Published var songs:   [JellyfinSearchHint] = []
    @Published var lists:   [JellyfinSearchHint] = []
    @Published var allHints: [JellyfinSearchHint] = []

    // Local (downloaded)
    struct DownloadedHit: Identifiable, Hashable {
        enum Kind { case album, song, playlist }
        let id: String
        let title: String
        let subtitle: String?
        let kind: Kind
        let imageItemId: String
    }
    @Published var downloadedHits: [DownloadedHit] = []
    
    // Showcase Artist Model
    struct ArtistChip: Identifiable, Hashable {
        var id: String { artistId }   // <- stable, unique
        let name: String
        let artistId: String
        let imageURL: URL?
    }

    // Showcase properties
    @AppStorage("Search.DailyShowcase.v1") var storedShowcaseData: Data = Data()
    @Published var showcase: DailyShowcaseState?
    @Published var showcaseGenres: [GenreAsset] = []
    @Published var showcaseArtists: [ArtistChip] = []
    @Published var genreHeroURL: [String: URL] = [:] // genreName -> representative cover

    private var cancellables = Set<AnyCancellable>()
    private let api: JellyfinAPIService
    private let downloads: DownloadsAPI

    init(api: JellyfinAPIService, downloads: DownloadsAPI) {
        self.api = api
        self.downloads = downloads
    }
    
    private func assetName(for genreName: String) -> String {
        let noDiacritics = genreName.folding(options: .diacriticInsensitive, locale: .current)
        let cleaned = noDiacritics
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "genre_\(cleaned)"
    }
    
    // Ordered: songs(0) → artists(1) → albums(2)
    var topFlat: [JellyfinSearchHint] {
        func prio(_ t: String?) -> Int {
            switch t {
            case "Audio": return 0
            case "MusicArtist": return 1
            case "MusicAlbum": return 2
            default: return 3
            }
        }
        return allHints.sorted { prio($0.type) < prio($1.type) }
    }

    func performSearch(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            artists = []; albums = []; songs = []; lists = []; downloadedHits = []; allHints = []
            return
        }
        searchRemote(q)
        searchOffline(q)
    }

    private func searchRemote(_ q: String) {
        // unified hints call; we’ll split by type locally
        api.searchHints(query: q, include: [.artist, .album, .song, .playlist], limit: 40, startIndex: 0)
            .map { $0.SearchHints ?? [] }
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] hints in
                guard let self else { return }
                self.allHints = hints
                self.artists  = hints.filter { ($0.type ?? "") == "MusicArtist" }
                self.albums   = hints.filter { ($0.type ?? "") == "MusicAlbum" }
                self.songs    = hints.filter { ($0.type ?? "") == "Audio" }
                self.lists    = hints.filter { ($0.type ?? "") == "Playlist" }
            })
            .store(in: &cancellables)
    }

    private func searchOffline(_ q: String) {
        let term = q.lowercased()

        // Group downloaded tracks by albumId
        let groupedByAlbum = Dictionary(grouping: downloads.downloadedMeta.values) { meta in
            meta.albumId ?? ""
        }

        // Albums (use albumName from your meta; fall back to "Album")
        let aHits: [DownloadedHit] = groupedByAlbum.compactMap { (albumId, metas) -> DownloadedHit? in
            guard !albumId.isEmpty else { return nil }

            let albumTitle =
                metas.compactMap { $0.albumName?.trimmingCharacters(in: .whitespacesAndNewlines) }
                     .first { !$0.isEmpty }
                ?? "Album"

            guard albumTitle.lowercased().contains(term) else { return nil }

            return DownloadedHit(
                id: albumId,
                title: albumTitle,
                subtitle: "Downloaded Album",
                kind: .album,
                imageItemId: albumId
            )
        }

        // Songs (filter by track name)
        let sHits: [DownloadedHit] = downloads.downloadedMeta.values
            .filter { $0.name.lowercased().contains(term) }
            .map {
                DownloadedHit(
                    id: $0.id,
                    title: $0.name,
                    subtitle: ($0.artists?.first).map { "by \($0)" },
                    kind: .song,
                    imageItemId: $0.albumId ?? ""  // used to fetch album cover
                )
            }

        // Playlists (Downloaded)
        let pHits: [DownloadedHit] = Array(downloads.downloadedPlaylists.values)
            .filter { $0.name.lowercased().contains(term) }
            .map {
                DownloadedHit(
                    id: $0.id,
                    title: $0.name,
                    subtitle: "Downloaded Playlist",
                    kind: .playlist,
                    imageItemId: $0.id
                )
            }

        downloadedHits = aHits + sHits + pHits
    }
}

// MARK: - Showcase Extension & RNG
private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension SearchViewModel {
    
    func ensureDailyShowcase(genresCatalog _: [GenreAsset], totalTiles: Int = 10, maxArtists: Int = 4) {
        let today = Self.todayKey()

        // ✅ If we have today's saved state, use it as-is (no size check, no rebuild).
        if let saved = try? JSONDecoder().decode(DailyShowcaseState.self, from: storedShowcaseData),
           saved.dayKey == today, !saved.artists.isEmpty {

            self.showcase = saved
            self.showcaseGenres  = saved.genreKeys.map { GenreAsset(id: $0, title: $0, assetName: assetName(for: $0)) }
            self.showcaseArtists = saved.artists.map { .init(name: $0.name, artistId: $0.id, imageURL: nil) }

            // Only resolve remote heroes for genres that lack a local asset (doesn't change order/content)
            self.resolveGenreHeroImagesIfNeeded(for: saved.genreKeys)
            return
        }

        // --- 1. Gather artist candidates (as chips: name + id) ---
        let localArtistNames = Array(Set(
            downloads.downloadedMeta.values.compactMap { $0.artists?.first?.trimmed }
        )).filter { !$0.isEmpty }

        // If you have local names, resolve IDs via searchHints; else ask the server for artists.
        let artistChipsPublisher: AnyPublisher<[ArtistChip], Never>

        if !localArtistNames.isEmpty {
            // Resolve each local name to an artistId (imageURL stays nil → Backdrop-only rendering)
            let lookups = localArtistNames.map { name in
                api.searchHints(query: name, include: [.artist], limit: 1, startIndex: 0)
                    .map { resp -> ArtistChip in
                        let hint = resp.SearchHints?.first
                        let artistId = hint?.idRaw ?? hint?.id ?? ""
                        return ArtistChip(name: name, artistId: artistId, imageURL: nil)
                    }
                    .replaceError(with: ArtistChip(name: name, artistId: "", imageURL: nil))
            }
            artistChipsPublisher = Publishers.MergeMany(lookups).collect().eraseToAnyPublisher()
        } else {
            // Pull a pool of artists from the server; we only need name + id.
            artistChipsPublisher = api.fetchAlbumArtists()
                .map { items in
                    items.map { ArtistChip(name: $0.name, artistId: $0.id, imageURL: nil) }
                }
                .replaceError(with: [])
                .eraseToAnyPublisher()
        }

        // Set the failure type to Error to match the genres publisher
        let artistChipsPublisherE = artistChipsPublisher.setFailureType(to: Error.self)
        
        // Combine artist fetch with genre fetch and build the showcase state
        Publishers.Zip(artistChipsPublisherE, api.fetchMusicGenres(minAlbums: 4))
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] chipsPool, serverGenres in
                guard let self else { return }

                // Deterministic daily shuffle
                let today = Self.todayKey()
                let seed = Self.seedFrom(today: today)
                var g1 = SeededRNG(seed: seed &+ 0x1111)
                var g2 = SeededRNG(seed: seed &+ 0x2222)

                // De-dupe by name to avoid dup tiles; then shuffle
                let uniqueChips = Dictionary(grouping: chipsPool, by: { $0.name })
                    .compactMap { $0.value.first }
                let shuffledArtists = uniqueChips.shuffled(using: &g2)

                // Pick some artists every day (ensure we actually have some)
                let chosenArtists = Array(shuffledArtists.prefix(maxArtists))

                // Map and shuffle genres
                let allGenreAssets = serverGenres.map {
                    GenreAsset(id: $0.name, title: $0.name, assetName: self.assetName(for: $0.name))
                }
                let shuffledGenres = allGenreAssets.shuffled(using: &g1)

                // Lay out: fill with artists first; remaining slots by genres (leave room for Replay)
                let maxContent = max(0, totalTiles - 1)
                let usedByArtists = min(chosenArtists.count, maxContent)
                let desiredGenres = max(0, maxContent - usedByArtists)
                let chosenGenres = Array(shuffledGenres.prefix(desiredGenres))

                // Stable Replay slot
                var rgen = SeededRNG(seed: seed &+ 0x3333)
                let replayIndex = Int.random(in: 0...maxContent, using: &rgen)

                // Save minimal state (names + ids)
                let state = DailyShowcaseState(
                    dayKey: today,
                    replayIndex: replayIndex,
                    genreKeys: chosenGenres.map(\.id),
                    artists: chosenArtists.map { .init(name: $0.name, id: $0.artistId) } // ← store ids too
                )
                if let data = try? JSONEncoder().encode(state) { self.storedShowcaseData = data }

                // Publish to UI
                self.showcase = state
                self.showcaseGenres = chosenGenres
                self.showcaseArtists = chosenArtists // already contains ids

                // Fill genre hero URLs for any missing local assets
                self.resolveGenreHeroImagesIfNeeded(for: chosenGenres.map(\.id))
            })
            .store(in: &cancellables)
    }

    private func resolveGenreHeroImagesIfNeeded(for genreNames: [String]) {
        // If a local asset exists, we don't need a remote hero.
        let missing = genreNames.filter { UIImage(named: assetName(for: $0)) == nil }

        guard !missing.isEmpty else { return }

        let lookups = missing.map { name in
            api.fetchAlbumsByGenre(name, limit: 1)
                .map { albums -> (String, URL?) in
                    if let first = albums.first {
                        let url = JellyfinAPIService.shared.primaryImageURL(for: first.id, maxHeight: 300)
                        return (name, url)
                    } else {
                        return (name, nil)
                    }
                }
                .replaceError(with: (name, nil))
        }

        Publishers.MergeMany(lookups)
            .collect()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pairs in
                guard let self else { return }
                var updated = self.genreHeroURL
                for (name, url) in pairs { if let url { updated[name] = url } }
                self.genreHeroURL = updated
            }
            .store(in: &cancellables)
    }

    private func resolveArtistLogos(for names: [String]) {
        // This function is no longer needed as artist IDs are fetched and persisted.
    }

    // Helpers
    static func todayKey() -> String {
        let f = DateFormatter(); f.calendar = .current; f.locale = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
    static func seedFrom(today: String) -> UInt64 {
        UInt64(today.unicodeScalars.map { UInt64($0.value) }.reduce(0, +))
    }
}

// Tiny deterministic RNG for stable daily shuffles
fileprivate struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}


// MARK: - SearchView
struct SearchView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @EnvironmentObject var downloads: DownloadsAPI

    @StateObject private var vm: SearchViewModel
    
    @State private var path = NavigationPath()
    
    private func push(_ route: SearchRoute) {
        path.append(route)
    }

    init() {
        _vm = StateObject(wrappedValue:
            SearchViewModel(api: JellyfinAPIService.shared,
                            downloads: DownloadsAPI.shared))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if vm.queryCommitted {
                    resultsContent
                } else {
                    SearchExploreGrid(vm: vm, push: push)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(vm.queryCommitted ? .inline : .large)
            .searchable(text: $vm.query, placement: .automatic, prompt: "Artists, albums, songs…")
            .onSubmit(of: .search) {
                vm.performSearch(vm.query)
                vm.queryCommitted = !vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .onChange(of: vm.query) { newValue in
                if newValue.isEmpty {
                    vm.queryCommitted = false
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if vm.queryCommitted {
                    SearchChipBar(selected: $vm.selected)
                }
            }
            // Changed navigation destination to pass correct model types
            .navigationDestination(for: SearchRoute.self) { route in
                switch route {
                case .genre(let name):
                    GenreDetailView(genre: JellyfinGenre(rawId: name, name: name))

                case .artist(let id, let name):
                    ArtistDetailView(artist: JellyfinArtistItem.light(id: id, name: name)) // ← pass `artist:`

                case .replay:
                    ReplayView()
                }
            }
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        Group {
            switch vm.selected {
            case .top:        TopResultsSection(vm: vm)
            case .artists:    ArtistResults(vm: vm)
            case .albums:     AlbumResults(vm: vm)
            case .songs:      SongResults(vm: vm)
            case .playlists:  PlaylistResults(vm: vm)
            case .downloaded: DownloadedResults(vm: vm)
            }
        }
    }
}

// MARK: - Artist Tile Image Fallback View
private struct ArtistTileImage: View {
    let artistId: String

    private var backdropURL: URL? {
        JellyfinAPIService.shared.backdropImageURL(for: artistId, width: 540, height: 264)
    }

    var body: some View {
        Group {
            if let url = backdropURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Color(.systemGray5).overlay(ProgressView())
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color(.systemGray5) // Backdrop missing or failed
                    @unknown default:
                        Color(.systemGray5)
                    }
                }
            } else {
                Color(.systemGray5) // No URL
            }
        }
    }
}


// MARK: - Pre-search explore grid
private struct SearchExploreGrid: View {
    @ObservedObject var vm: SearchViewModel
    let push: (SearchRoute) -> Void

    private enum ExploreTile: Identifiable {
        case replay
        case genre(GenreAsset)
        case artist(SearchViewModel.ArtistChip)

        var id: String {
            switch self {
            case .replay:           return "replay"
            case .genre(let g):     return "genre:\(g.id)"
            case .artist(let chip): return "artist:\(chip.id)"
            }
        }
    }

    // Asset for Replay tile
    private let replayAssetNames = [
        "replay_tile_search",
    ]

    private func makeTiles(total: Int) -> [ExploreTile] {
        // use the saved, persisted order from today’s showcase
        let genres  = vm.showcaseGenres         // already ordered when saved
        let artists = vm.showcaseArtists        // already ordered when saved
        let content: [ExploreTile] = genres.map { .genre($0) } + artists.map { .artist($0) }

        // cap to leave room for Replay
        let capped = Array(content.prefix(max(0, total - 1)))

        // insert Replay at the persisted index (clamped)
        let idx = min(vm.showcase?.replayIndex ?? 0, capped.count)
        var tiles = capped
        tiles.insert(.replay, at: idx)
        return tiles
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12),
                          GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(makeTiles(total: 16)) { tile in
                    switch tile {
                    case .replay:
                        replayTile
                    case .genre(let g):
                        genreTile(g)
                    case .artist(let chip):
                        artistTile(chip)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onAppear {
            // refresh (will be no-op on same day)
            vm.ensureDailyShowcase(genresCatalog: [], totalTiles: 16)
        }
    }

    // MARK: tiles
    private var replayTile: some View {
        let dayKey = vm.showcase?.dayKey ?? SearchViewModel.todayKey()
        let seed   = SearchViewModel.seedFrom(today: dayKey)
        let idx    = Int(seed % UInt64(replayAssetNames.count))
        let replayImageName = replayAssetNames[idx]

        return Button { push(.replay) } label: {
            ZStack(alignment: .bottomLeading) {
                Image(replayImageName)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 88)
                    .clipped()
                Text("Replay")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(12)
                    .shadow(radius: 4, x: 0, y: 1)
            }
            .frame(height: 88)
            .background(Color.black.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Replay")
    }

    private func genreTile(_ g: GenreAsset) -> some View {
        Button { push(.genre(g.id)) } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let ui = UIImage(named: g.assetName, in: .main, compatibleWith: nil) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFill()
                    } else if let url = vm.genreHeroURL[g.id] {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            case .empty:               Color(.systemGray5).overlay(ProgressView())
                            default:                    Color(.systemGray5)
                            }
                        }
                    } else {
                        Color(.systemGray5).overlay(
                            Text(g.assetName)
                                .font(.caption2).foregroundColor(.secondary)
                                .padding(6)
                        )
                    }
                }
                .frame(height: 88)
                .clipped()

                Text(g.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(12)
                    .shadow(radius: 4, x: 0, y: 1)
            }
            .frame(height: 88)
            .background(Color.black.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(g.title)
    }

    private func artistTile(_ chip: SearchViewModel.ArtistChip) -> some View {
        Button {
            if !chip.artistId.isEmpty {
                push(.artist(id: chip.artistId, name: chip.name))
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if !chip.artistId.isEmpty {
                        ArtistTileImage(artistId: chip.artistId)   // Backdrop only
                    } else {
                        Color(.systemGray5)                         // no id => gray
                    }
                }
                .frame(height: 88)
                .clipped()

                Text(chip.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(12)
                    .shadow(radius: 4, x: 0, y: 1)
            }
            .frame(height: 88)
            .background(Color.black.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.name)
    }
}


// MARK: - Custom Chip Bar
private let appleMusicRed = Color(red: 0.95, green: 0.20, blue: 0.30)

private struct SearchChipBar: View {
    @Binding var selected: SearchFilter
    @Namespace private var pillNS

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SearchFilter.allCases) { scope in
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.85, blendDuration: 0.2)) {
                                selected = scope
                            }
                        } label: {
                            Text(scope.rawValue)
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .foregroundColor(selected == scope ? .white : .primary)
                                .background(
                                    ZStack {
                                        if selected == scope {
                                            Capsule()
                                                .fill(appleMusicRed)
                                                .matchedGeometryEffect(id: "chip-pill", in: pillNS)
                                        }
                                    }
                                )
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(scope) // for scrollTo
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .onChange(of: selected) { newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}


// MARK: - Result sections
private struct TopResultsSection: View {
    @ObservedObject var vm: SearchViewModel
    var body: some View {
        List(vm.topFlat, id: \.id) { hint in
            SearchHintRow(hint: hint, showSub: true)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct ArtistResults: View {
    @ObservedObject var vm: SearchViewModel
    var body: some View {
        List(vm.artists, id: \.id) { hint in
            SearchHintRow(hint: hint)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct AlbumResults: View {
    @ObservedObject var vm: SearchViewModel
    var body: some View {
        List(vm.albums, id: \.id) { hint in
            SearchHintRow(hint: hint)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct SongResults: View {
    @ObservedObject var vm: SearchViewModel
    var body: some View {
        List(vm.songs, id: \.id) { hint in
            SearchHintRow(hint: hint, showSub: true, trailingMenu: {
                AnyView(
                    Button {
                        JellyfinAPIService.shared.fetchTracks(for: hint.albumId ?? "")
                            .replaceError(with: [])
                            .sink { tracks in
                                if let t = tracks.first(where: { $0.name == hint.name }) {
                                    AudioPlayer.shared.queueNext(t)
                                }
                            }
                            .store(in: &SongResults.cancellables)
                    } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }
                )
            })
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private static var cancellables = Set<AnyCancellable>()
}

private struct PlaylistResults: View {
    @ObservedObject var vm: SearchViewModel
    var body: some View {
        List(vm.lists, id: \.id) { hint in
            SearchHintRow(hint: hint)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct DownloadedResults: View {
    @ObservedObject var vm: SearchViewModel
    @EnvironmentObject var downloads: DownloadsAPI
    @EnvironmentObject var apiService: JellyfinAPIService

    var body: some View {
        List(vm.downloadedHits, id: \.id) { hit in
            switch hit.kind {
            case .album:
                NavigationLink {
                    DownloadedAlbumDetailView(albumId: hit.id, fallbackName: hit.title)
                        .environmentObject(apiService)
                        .environmentObject(downloads)
                } label: {
                    LocalRow(title: hit.title, subtitle: hit.subtitle, image: .album(itemId: hit.imageItemId))
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))

            case .song:
                LocalRow(title: hit.title, subtitle: hit.subtitle, image: .song(albumId: hit.imageItemId))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = apiService.downloadedTrackURLs[hit.id] {
                            let t = JellyfinTrack(serverId: hit.id, name: hit.title, artists: nil, albumId: hit.imageItemId, indexNumber: nil, runTimeTicks: nil)
                            AudioPlayer.shared.play(tracks: [t], startIndex: 0, albumArtist: nil)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))

            case .playlist:
                NavigationLink {
                    DownloadedPlaylistDetailView(playlistId: hit.id)
                        .environmentObject(apiService)
                        .environmentObject(downloads)
                } label: {
                    LocalRow(title: hit.title, subtitle: hit.subtitle, image: .playlist(playlistId: hit.id))
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Rows
private struct SearchHintRow: View {
    let hint: JellyfinSearchHint
    var showSub: Bool = true
    var trailingMenu: (() -> AnyView)? = nil

    private var subtitle: String {
        switch (hint.type ?? "") {
        case "MusicArtist": return "Artist"
        case "MusicAlbum": return "Album"
        case "Audio":
            let artistName = (hint.artists?.first ?? "Unknown Artist")
            return "Song · \(artistName)"
        case "Playlist": return "Playlist"
        default: return hint.type ?? ""
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if (hint.type ?? "") == "MusicArtist" {
                CircleAvatar(url: imageURL, size: 48)
            } else {
                RoundedCover(url: imageURL, size: 48, corner: 8)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(hint.name ?? "Unknown")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if showSub {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let menuBuilder = trailingMenu {
                Menu {
                    menuBuilder()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
        .background(Color.clear)
        .onTapGesture {
            switch (hint.type ?? "") {
            case "MusicAlbum":
                if let id = hint.idRaw { pushToAlbum(id: id) }
            case "MusicArtist":
                if let id = hint.idRaw { pushToArtist(id: id) }
            case "Playlist":
                if let id = hint.idRaw { pushToPlaylist(id: id) }
            case "Audio":
                if let albumId = hint.albumId {
                    JellyfinAPIService.shared.fetchTracks(for: albumId)
                        .replaceError(with: [])
                        .sink { tracks in
                            if let t = tracks.first(where: { $0.name == hint.name }) {
                                JellyfinAPIService.shared.playTrack(tracks: [t], startIndex: 0, albumArtist: nil)
                            }
                        }
                        .store(in: &Self.cancellables)
                }
            default: break
            }
        }
    }

    private static var cancellables = Set<AnyCancellable>()

    private var imageURL: URL? {
        let itemId = hint.idRaw ?? hint.id ?? ""
        guard !itemId.isEmpty else { return nil }
        return JellyfinAPIService.shared.primaryImageURL(for: itemId, maxHeight: 300)
    }

    private func pushToAlbum(id: String) { NotificationCenter.default.post(name: .init("nav.push.album"), object: id) }
    private func pushToArtist(id: String) { NotificationCenter.default.post(name: .init("nav.push.artist"), object: id) }
    private func pushToPlaylist(id: String) { NotificationCenter.default.post(name: .init("nav.push.playlist"), object: id) }
}

private enum LocalImageRef {
    case album(itemId: String)
    case song(albumId: String)
    case playlist(playlistId: String)
}

private struct LocalRow: View {
    let title: String
    let subtitle: String?
    let image: LocalImageRef
    @EnvironmentObject var downloads: DownloadsAPI

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch image {
                case .album(let itemId):
                    RoundedCover(url: JellyfinAPIService.shared.primaryImageURL(for: itemId), size: 48, corner: 8)
                case .song(let albumId):
                    if albumId.isEmpty {
                        RoundedCover(url: nil, size: 48, corner: 8)
                    } else {
                        RoundedCover(url: JellyfinAPIService.shared.primaryImageURL(for: albumId), size: 48, corner: 8)
                    }
                case .playlist(let pid):
                    if let url = downloads.playlistCoverURL(playlistId: pid),
                       let ui = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedCover(url: nil, size: 48, corner: 8)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Fallback Image Views
private extension View {
    @ViewBuilder
    func eraseToAnyView() -> some View { self }
}

fileprivate struct RoundedCover: View {
    let url: URL?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.gray.opacity(0.25))
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().scaleEffect(0.8)
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "music.note").foregroundColor(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                Image(systemName: "music.note").foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

fileprivate struct CircleAvatar: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.25))
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: ProgressView().scaleEffect(0.8)
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Image(systemName: "person.crop.circle").foregroundColor(.secondary)
                    @unknown default: EmptyView()
                    }
                }
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle").foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
