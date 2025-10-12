import SwiftUI
import Combine
import UIKit

// Build "Album · YEAR" for the preview (best-effort)
private func albumLine(for t: JellyfinTrack, albumCache: [String: JellyfinAlbum], parsedDate: (String?) -> Date?) -> String {
    guard let aid = t.albumId, let album = albumCache[aid] else { return "" }
    let name = album.name
    
    // Safely extract a year from typical album date fields
    func yearFromAlbum(_ a: JellyfinAlbum) -> String {
        if let y = a.productionYear, y > 0 { return String(y) }
        let iso = a.releaseDate ?? a.premiereDate ?? a.dateCreated
        if let d = parsedDate(iso) {
            return String(Calendar.current.component(.year, from: d))
        }
        return ""
    }
    
    let year = yearFromAlbum(album)
    return [name, year].filter { !$0.isEmpty }.joined(separator: " · ")
}


struct AllSongsView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @Environment(\.dismiss) private var dismiss

    // Data
    @State private var songs: [JellyfinTrack] = []
    @State private var filtered: [JellyfinTrack] = []
    @State private var searchText: String = ""
    @State private var cancellables = Set<AnyCancellable>()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var sections: [(key: String, items: [JellyfinTrack])] = []
    
    @State private var albumCache: [String: JellyfinAlbum] = [:]

    // Navigation
    @State private var navAlbum: JellyfinAlbum?

    // UI
    private let horizontalPad: CGFloat = 20
    private let coverSize: CGFloat = 48
    private let coverCorner: CGFloat = 8
    private let sectionScrollTopOffset: CGFloat = 80
    private let indexVisualWidth: CGFloat = 18
    private let indexRightPadding: CGFloat = 2
    private let accentRed = Color(red: 0.95, green: 0.20, blue: 0.30)

    // Persisted prefs
    @AppStorage("AllSongsView.sortMode") private var sortModeRaw: Int = SortMode.title.rawValue
    @AppStorage("AllSongsView.favoritesOnly") private var favoritesOnly: Bool = false

    private enum SortMode: Int, CaseIterable { case title, dateAdded, artist }
    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .title }

    // A–Z helpers
    private let indexLetters: [String] = (65...90).compactMap { UnicodeScalar($0).map { String($0) } } + ["#"]
    private var showIndexBar: Bool { sortMode == .title || sortMode == .artist }

    // Date parsing
    private static let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private func parsedDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = Self.iso8601Frac.date(from: s) { return d }
        if let d = Self.iso8601NoFrac.date(from: s) { return d }
        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        ]
        for fmt in fmts {
            let df = DateFormatter()
            df.locale = .init(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
    private func monthKey(_ d: Date) -> String {
        let df = DateFormatter(); df.locale = .init(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM"
        return df.string(from: d)
    }
    private func prettyMonth(_ key: String) -> String {
        let inDF = DateFormatter(); inDF.locale = .init(identifier: "en_US_POSIX"); inDF.dateFormat = "yyyy-MM"
        let outDF = DateFormatter(); outDF.dateFormat = "MMM yyyy"
        if let d = inDF.date(from: key) { return outDF.string(from: d) }
        return ""
    }

    private func firstIndexLetter(for s: String) -> String {
        guard let ch = s.unicodeScalars.first else { return "#" }
        let up = String(ch).uppercased()
        return up.range(of: "^[A-Z]$", options: .regularExpression) != nil ? up : "#"
    }
    private func primaryArtist(_ t: JellyfinTrack) -> String {
        (t.artists?.first).map { String($0) } ?? ""
    }

    // MARK: Section builder
    private func makeSections(from list: [JellyfinTrack], mode: SortMode)
    -> [(key: String, items: [JellyfinTrack])] {
        switch mode {
        case .title:
            let groups = Dictionary(grouping: list) { firstIndexLetter(for: tTitle($0)) }
            let keys = indexLetters.filter { groups[$0] != nil }
            return keys.map { k in
                let items = (groups[k] ?? []).sorted {
                    tTitle($0).localizedCaseInsensitiveCompare(tTitle($1)) == .orderedAscending
                }
                return (k, items)
            }

        case .artist:
            let groups = Dictionary(grouping: list) { firstIndexLetter(for: primaryArtist($0)) }
            let keys = indexLetters.filter { groups[$0] != nil }
            return keys.map { k in
                let items = (groups[k] ?? []).sorted {
                    let a0 = primaryArtist($0), a1 = primaryArtist($1)
                    if a0.caseInsensitiveCompare(a1) != .orderedSame {
                        return a0.localizedCaseInsensitiveCompare(a1) == .orderedAscending
                    }
                    return tTitle($0).localizedCaseInsensitiveCompare(tTitle($1)) == .orderedAscending
                }
                return (k, items)
            }

        case .dateAdded:
             return [("Recently Added", list)]
        }
    }

    private func tTitle(_ t: JellyfinTrack) -> String { t.name ?? "" }

    private var displayedTracks: [JellyfinTrack] {
        sections.flatMap { $0.items }
    }

    var body: some View {
        Group {
            if isLoading {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                VStack { Spacer(); Text(errorMessage).foregroundColor(.red); Spacer() }
            } else {
                mainContentView
            }
        }
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $favoritesOnly) {
                        Label("All Songs", systemImage: "music.note").tag(false)
                        Label("Favorites", systemImage: "star.fill").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(favoritesOnly ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background { if favoritesOnly { Circle().fill(accentRed) } }
                }
                .onChange(of: favoritesOnly) { _ in reloadSongs() }

                Menu {
                    Picker("Sort by", selection: $sortModeRaw) {
                        Label("Title",       systemImage: "").tag(SortMode.title.rawValue)
                        Label("Date Added", systemImage: "").tag(SortMode.dateAdded.rawValue)
                        Label("Artist A–Z", systemImage: "").tag(SortMode.artist.rawValue)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .onChange(of: sortModeRaw) { _ in reloadSongs() }
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in applySearch() }
        .tint(.primary)
        .onAppear { reloadSongs() }
        .navigationDestination(item: $navAlbum) { album in
            AlbumDetailView(album: album).environmentObject(apiService)
        }
    }

    @ViewBuilder
    private var mainContentView: some View {
        if favoritesOnly && filtered.isEmpty && !isLoading {
            EmptyFavoritesState()
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .topTrailing) {
                    // ✅ ADJUSTMENT 2: Replaced ScrollView with List
                    List {
                        Section {
                            HStack(spacing: 12) {
                                PillButton(icon: "play.fill", title: "Play")   { playSongs(shuffle: false) }
                                PillButton(icon: "shuffle",   title: "Shuffle"){ playSongs(shuffle: true)  }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 0, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                        ForEach(sections, id: \.key) { section in
                            // Section now contains the header as its first element
                            Section {
                                // The header is now a regular view inside the section content
                                Text((sortMode == .dateAdded && section.key.count > 7) ? prettyMonth(section.key) : section.key)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, horizontalPad)
                                    .padding(.trailing, indexVisualWidth + indexRightPadding)
                                    .padding(.vertical, 6)
                                    .id("anchor-\(section.key)") // ID for fast scroll
                                    .listRowInsets(EdgeInsets()) // Remove padding
                                    .listRowSeparator(.hidden)   // Hide separator
                                    .allowsHitTesting(false)     // Make it non-interactive

                                ForEach(section.items, id: \.id) { track in
                                    SongRow(
                                        track: track,
                                        horizontalPad: horizontalPad,
                                        coverSize: coverSize,
                                        coverCorner: coverCorner,
                                        onPlay: { playSingle(track) },
                                        apiService: apiService,
                                        favoritesOnlyBinding: $favoritesOnly,
                                        onQueueNext: { queueNext(track) },
                                        onCreateStation: { createStation(for: track) },
                                        onGoToAlbum: { goToAlbum(for: track) },
                                        onToggleFavorite: { toggleFavorite(track) },
                                        onDownload: { download(track) },
                                        previewDetail: albumLine(for: track, albumCache: albumCache, parsedDate: parsedDate)
                                    )
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden) // Separator is now handled inside SongRow
                                    .id(track.id)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)

                    if showIndexBar {
                        FastIndexBar(
                            letters: indexLetters,
                            topInset: 120,
                            bottomInset: 28,
                            visualWidth: indexVisualWidth,
                            touchWidth: 36,
                            fontSize: 9,
                            minRowHeight: 9,
                            rightPadding: indexRightPadding
                        ) { letter in
                            if sections.contains(where: { $0.key == letter }) {
                                var tx = Transaction(); tx.disablesAnimations = true
                                withTransaction(tx) { proxy.scrollTo("anchor-\(letter)", anchor: .top) }
                            }
                        }
                        .zIndex(1)
                    }
                }
            }
        }
    }
    
    // MARK: - Data
    private func reloadSongs() {
        isLoading = true
        errorMessage = nil

        let serverSort: JellyfinAPIService.SongServerSort = {
            switch sortMode {
            case .title:     return .title
            case .dateAdded: return .dateAdded
            case .artist:    return .artistAZ
            }
        }()

        apiService.fetchSongsAdvanced(sort: serverSort, favoritesOnly: favoritesOnly, limit: nil)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                isLoading = false
                if case .failure(let error) = completion {
                    errorMessage = "Failed to load songs: \(error.localizedDescription)"
                }
            }, receiveValue: { (songs: [JellyfinTrack]) in
                self.songs = songs
                self.applySearch()
                
                let ids = Set(songs.compactMap { $0.albumId })
                guard !ids.isEmpty else { return }
                
                apiService.fetchAlbums()
                    .map { albums in
                        albums.filter { ids.contains($0.id) }
                    }
                    .receive(on: DispatchQueue.main)
                    .sink(receiveCompletion: { _ in }, receiveValue: { subset in
                        self.albumCache = Dictionary(uniqueKeysWithValues: subset.map { ($0.id, $0) })
                        self.applySearch()
                    })
                    .store(in: &cancellables)
            })
            .store(in: &cancellables)
    }

    private func applySearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filtered = songs
        } else {
            filtered = songs.filter {
                tTitle($0).lowercased().contains(q) ||
                primaryArtist($0).lowercased().contains(q)
            }
        }
        sections = makeSections(from: filtered, mode: sortMode)
    }

    // MARK: - Play Helpers
    private func playSongs(shuffle: Bool) {
        var list = displayedTracks
        if shuffle { list.shuffle() }
        guard !list.isEmpty else { return }
        apiService.playTrack(tracks: list, startIndex: 0, albumArtist: nil)
    }

    private func playSingle(_ track: JellyfinTrack) {
        let list = displayedTracks
        guard !list.isEmpty else { return }
        let idx = list.firstIndex(where: { $0.id == track.id }) ?? 0
        apiService.playTrack(tracks: list, startIndex: idx, albumArtist: nil)
    }
    
    // MARK: - Actions
    private func queueNext(_ track: JellyfinTrack) {
        AudioPlayer.shared.queueNext(track)
    }
    
    private func createStation(for track: JellyfinTrack) {
        let seedId = track.serverId ?? track.id
        apiService.fetchInstantMix(itemId: seedId, limit: 80)
            .replaceError(with: [])
            .map { mix -> [JellyfinTrack] in
                var seen = Set<String>(), out: [JellyfinTrack] = []
                func add(_ t: JellyfinTrack) {
                    let key = t.serverId ?? t.id
                    if seen.insert(key).inserted { out.append(t) }
                }
                add(track); mix.forEach(add); return out
            }
            .receive(on: DispatchQueue.main)
            .sink { queue in
                guard !queue.isEmpty else { return }
                apiService.playTrack(tracks: queue, startIndex: 0, albumArtist: nil)
            }
            .store(in: &cancellables)
    }

    private func goToAlbum(for track: JellyfinTrack) {
        guard let albumId = track.albumId else { return }
        apiService.fetchAlbums()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { (albums: [JellyfinAlbum]) in
                if let album = albums.first(where: { $0.id == albumId }) {
                    self.navAlbum = album
                }
            })
            .store(in: &cancellables)
    }

    private func toggleFavorite(_ track: JellyfinTrack) {
        apiService.fetchItemUserData(itemId: track.id)
            .replaceError(with: JellyfinUserData(isFavorite: false))
            .flatMap { userData -> AnyPublisher<Void, Error> in
                (userData.isFavorite ?? false)
                ? apiService.unmarkItemFavorite(itemId: track.id)
                : apiService.markItemFavorite(itemId: track.id)
            }
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { })
            .store(in: &cancellables)
    }

    private func download(_ track: JellyfinTrack) {
        apiService.downloadTrack(trackId: track.serverId ?? track.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &cancellables)
    }
}

// MARK: - Row
fileprivate struct SongRow: View {
    let track: JellyfinTrack
    let horizontalPad: CGFloat
    let coverSize: CGFloat
    let coverCorner: CGFloat
    let onPlay: () -> Void

    @ObservedObject var apiService: JellyfinAPIService
    @Binding var favoritesOnlyBinding: Bool
    
    let onQueueNext: () -> Void
    let onCreateStation: () -> Void
    let onGoToAlbum: () -> Void
    let onToggleFavorite: () -> Void
    let onDownload: () -> Void
    
    let previewDetail: String

    @State private var isFavorite: Bool = false
    private let accentRed = Color(red: 0.95, green: 0.20, blue: 0.30)
    
    private let playNextTint  = Color(red: 97/255, green: 84/255, blue: 246/255)
    private let downloadTint  = Color(red: 0/255,  green: 136/255, blue: 255/255)

    private var isExplicit: Bool {
        if let tags = track.tags, tags.contains(where: { $0.caseInsensitiveCompare("Explicit") == .orderedSame }) {
            return true
        }
        return track.isExplicit
    }

    var body: some View {
        // ✅ ADJUSTMENT 1: Wrapped in a VStack to re-add the Divider
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedCover(url: imageURL, size: coverSize, corner: coverCorner)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(track.name ?? "Unknown Track")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)

                        if isExplicit {
                            Image(systemName: "e.square.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        }

                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(accentRed)
                        }
                    }

                    Text((track.artists?.first) ?? "Unknown Artist")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Menu { contextMenuItems } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .padding(.trailing, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, horizontalPad)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    onQueueNext()
                } label: {
                    Label("", systemImage: "text.insert")
                }
                .tint(playNextTint)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    onDownload()
                } label: {
                    Label("", systemImage: "arrow.down.circle")
                }
                .tint(downloadTint)
            }
            .contextMenu { contextMenuItems } preview: {
                SongContextPreviewRow(
                    title: track.name ?? "Unknown Track",
                    subtitle: (track.artists?.first) ?? "Unknown Artist",
                    detail: previewDetail,
                    imageURL: imageURL
                )
            }
            .onAppear {
                apiService.fetchItemUserData(itemId: track.id)
                    .replaceError(with: JellyfinUserData(isFavorite: false))
                    .sink { data in self.isFavorite = data.isFavorite ?? false }
                    .store(in: &Self.cancellables)
            }
            
            Divider()
                .padding(.leading, horizontalPad + coverSize + 12)
        }
    }

    private static var cancellables = Set<AnyCancellable>()

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(action: onQueueNext)       { Label("Play Next",      systemImage: "text.insert") }
        Button(action: onCreateStation)   { Label("Create Station", systemImage: "dot.radiowaves.left.and.right") }
        Button(action: onGoToAlbum)       { Label("Go to Album",    systemImage: "square.stack") }
        Button(action: {
            isFavorite.toggle()
            onToggleFavorite()
        }) { Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "star.fill" : "star") }
        Button(action: onDownload)        { Label("Download",       systemImage: "arrow.down.circle") }
    }

    private var imageURL: URL? {
        if let id = track.albumId, !id.isEmpty { return JellyfinAPIService.shared.imageURL(for: id) }
        return nil
    }
}

// MARK: - Helper Views
fileprivate struct EmptyFavoritesState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "star")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("No Favorited Songs")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("Mark songs as favorites by tapping the ellipsis (...) next to a song.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

fileprivate struct FastIndexBar: View {
    let letters: [String]
    let topInset: CGFloat
    let bottomInset: CGFloat
    var visualWidth: CGFloat = 18
    var touchWidth: CGFloat  = 36
    var fontSize: CGFloat    = 9
    var minRowHeight: CGFloat = 9
    var rightPadding: CGFloat = 6
    let onTapLetter: (String) -> Void
    
    @State private var dragIndex: Int?
    private let selectionGen = UISelectionFeedbackGenerator()
    private let impactGen = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            let totalHeight = max(geo.size.height - topInset - bottomInset, 0)
            let rowHeight   = max(totalHeight / CGFloat(max(letters.count, 1)), minRowHeight)

            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    Spacer().frame(height: topInset)
                    VStack(spacing: 0) {
                        ForEach(letters, id: \.self) { letter in
                            Text(letter)
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundColor(.red)
                                .frame(width: visualWidth, height: rowHeight)
                        }
                    }
                    Spacer().frame(height: bottomInset)
                }
                .frame(width: visualWidth, height: geo.size.height, alignment: .top)

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: touchWidth, height: geo.size.height)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let y = value.location.y - topInset
                                guard y >= 0, y <= totalHeight else { return }
                                let i = min(max(Int(y / rowHeight), 0), letters.count - 1)
                                if dragIndex != i {
                                    dragIndex = i
                                    selectionGen.selectionChanged()
                                    selectionGen.prepare()
                                    onTapLetter(letters[i])
                                }
                            }
                            .onEnded { _ in
                                dragIndex = nil
                                impactGen.impactOccurred(intensity: 0.6)
                                impactGen.prepare()
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(.trailing, rightPadding)
        .ignoresSafeArea(.keyboard)
        .onAppear { selectionGen.prepare(); impactGen.prepare() }
    }
}

fileprivate struct SongContextPreviewRow: View {
    let title: String
    let subtitle: String
    let detail: String?
    let imageURL: URL?

    private let artworkSide: CGFloat = 88
    private let artworkCorner: CGFloat = 12

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .empty: ZStack { Color.gray.opacity(0.2); ProgressView() }
                default: ZStack { Color.gray.opacity(0.2); Image(systemName: "music.note").foregroundColor(.secondary) }
                }
            }
            .frame(width: artworkSide, height: artworkSide)
            .clipShape(RoundedRectangle(cornerRadius: artworkCorner, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 300, idealWidth: 320)
        .background(Color(uiColor: .systemBackground))
    }
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
                    case .empty: ProgressView().scaleEffect(0.8)
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Image(systemName: "music.note").foregroundColor(.secondary)
                    @unknown default: EmptyView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

fileprivate struct PillButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    private let accent = Color(red: 0.95, green: 0.20, blue: 0.30)
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(accent)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.systemGray6))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
