import SwiftUI
import Combine
import UIKit

// MARK: - Date Formatting Helpers (NEW/REPLACED)

private let iso8601Frac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let iso8601NoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func parsedDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    if let d = iso8601Frac.date(from: s) { return d }
    if let d = iso8601NoFrac.date(from: s) { return d }
    let fmts = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    ]
    for fmt in fmts {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = fmt
        if let d = df.date(from: s) { return d }
    }
    return nil
}

private func prettyMonth(_ key: String) -> String {
    let inDF = DateFormatter(); inDF.locale = .init(identifier: "en_US_POSIX"); inDF.dateFormat = "yyyy-MM"
    let outDF = DateFormatter(); outDF.dateFormat = "MMM yyyy"
    if let d = inDF.date(from: key) { return outDF.string(from: d) }
    return "Unknown"
}

// MARK: - Main View
struct AllAlbumsView: View {
    @EnvironmentObject var apiService: JellyfinAPIService

    @Namespace private var albumZoomNS

    // Data
    @State private var albumsRaw: [JellyfinAlbum] = []
    @State private var filteredAlbums: [JellyfinAlbum] = []
    @State private var sections: [(key: String, items: [JellyfinAlbum])] = []
    @State private var searchText: String = ""
    @State private var cancellables = Set<AnyCancellable>()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var scrollPosition: String?

    // UI prefs
    @AppStorage("AllAlbumsView.isGridView") private var isGridView: Bool = true
    @AppStorage("AllAlbumsView.favoritesOnly") private var favoritesOnly: Bool = false
    @AppStorage("AllAlbumsView.sortMode") private var sortModeRaw: Int = SortMode.title.rawValue
    
    // Define the accent color for the pill
    private let accentRed = Color(red: 0.95, green: 0.20, blue: 0.30)

    // UI constants
    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 8
    private let sectionScrollTopOffset: CGFloat = 80
    private let indexVisualWidth: CGFloat = 18
    private let indexRightPadding: CGFloat = 2

    // MARK: - Sort helpers
    private enum SortMode: Int, CaseIterable { case title, dateAdded, artistAZ, year }
    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .title }
    private func setSortMode(_ mode: SortMode) { sortModeRaw = mode.rawValue }

    private var showIndexBar: Bool { sortMode == .title || sortMode == .artistAZ }
    
    private let indexLetters: [String] =
        (65...90).compactMap { UnicodeScalar($0).map { String($0) } } + ["#"]

    private func firstIndexLetter(for s: String) -> String {
        guard let ch = s.unicodeScalars.first else { return "#" }
        let up = String(ch).uppercased()
        return up.range(of: "^[A-Z]$", options: .regularExpression) != nil ? up : "#"
    }
    
    private func albumArtistName(_ album: JellyfinAlbum) -> String? {
        if let a = album.albumArtists?.first?.name, !a.isEmpty { return a }
        if let a = album.artistItems?.first?.name,  !a.isEmpty { return a }
        return nil
    }

    // MARK: - Section builder
    private func makeSections(from list: [JellyfinAlbum], mode: SortMode)
    -> [(key: String, items: [JellyfinAlbum])] {
        switch mode {
        case .title:
            let groups = Dictionary(grouping: list) { firstIndexLetter(for: $0.name) }
            let keys = indexLetters.filter { groups[$0] != nil }
            return keys.map { k in (k, (groups[k] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })}
            
        case .artistAZ:
            let groups = Dictionary(grouping: list) {
                firstIndexLetter(for: albumArtistName($0) ?? "#")
            }
            let keys = indexLetters.filter { groups[$0] != nil }
            return keys.map { k in (k, (groups[k] ?? []).sorted {
                let a0 = albumArtistName($0) ?? ""
                let a1 = albumArtistName($1) ?? ""
                if a0.caseInsensitiveCompare(a1) != .orderedSame {
                    return a0.localizedCaseInsensitiveCompare(a1) == .orderedAscending
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })}
            
        case .dateAdded:
            let groups = Dictionary(grouping: list) { (a: JellyfinAlbum) -> String in
                guard let d = parsedDate(a.dateCreated) else { return "Unknown" }
                let comps = Calendar.current.dateComponents([.year, .month], from: d)
                let m = String(format: "%02d", comps.month ?? 0)
                return "\(comps.year ?? 0)-\(m)"
            }
            let keys = groups.keys.sorted { lhs, rhs in
                func keyDate(_ k: String) -> Date {
                    let df = DateFormatter()
                    df.locale = .init(identifier: "en_US_POSIX")
                    df.dateFormat = "yyyy-MM"
                    return df.date(from: k) ?? .distantPast
                }
                return keyDate(lhs) > keyDate(rhs)
            }
            return keys.map { k in
                let items = (groups[k] ?? []).sorted {
                    (parsedDate($0.dateCreated) ?? .distantPast) >
                    (parsedDate($1.dateCreated) ?? .distantPast)
                }
                return (k, items)
            }
            
        case .year:
            let groups = Dictionary(grouping: list) { (a: JellyfinAlbum) -> String in
                if let y = a.productionYear { return String(y) }
                return "Unknown"
            }
            let numeric = groups.keys.compactMap { Int($0) }.sorted()
            let orderedKeys = numeric.map(String.init) + (groups.keys.contains("Unknown") ? ["Unknown"] : [])
            return orderedKeys.map { k in (k, (groups[k] ?? []).sorted {
                let y0 = $0.productionYear ?? Int.max
                let y1 = $1.productionYear ?? Int.max
                if y0 != y1 { return y0 < y1 }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })}
        }
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
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search albums"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in applyFiltersAndSort() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortModeRaw) {
                        Label("Title",      systemImage: "textformat.abc").tag(SortMode.title.rawValue)
                        Label("Date Added", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90").tag(SortMode.dateAdded.rawValue)
                        Label("Artist A–Z", systemImage: "music.microphone").tag(SortMode.artistAZ.rawValue)
                        Label("Year",       systemImage: "calendar").tag(SortMode.year.rawValue)
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle(isOn: Binding(
                        get: { favoritesOnly },
                        set: { favoritesOnly = $0; applyFiltersAndSort() }
                    )) {
                        Label("Favorites Only", systemImage: "star.fill")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(favoritesOnly ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background {
                            if favoritesOnly {
                                Circle().fill(accentRed)
                            }
                        }
                }
                .onChange(of: sortModeRaw) { _ in applyFiltersAndSort() }

                Menu {
                    Picker("View", selection: $isGridView) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(true)
                        Label("List", systemImage: "list.bullet").tag(false)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .tint(.primary)
        .onAppear { fetchAlbums() }
    }

    @ViewBuilder
    private var mainContentView: some View {
        if favoritesOnly && filteredAlbums.isEmpty {
            EmptyFavoritesAlbumsState()
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .topTrailing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer().frame(height: 6)

                            HStack(spacing: 12) {
                                PillButton(icon: "play.fill", title: "Play") { playAlbums(shuffle: false) }
                                PillButton(icon: "shuffle", title: "Shuffle") { playAlbums(shuffle: true) }
                            }
                            .padding(.horizontal, horizontalPad)
                            .padding(.top, -4)
                            .padding(.bottom, 4)

                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(sections, id: \.key) { section in
                                    Color.clear
                                        .frame(height: 1)
                                        .offset(y: -sectionScrollTopOffset)
                                        .id("anchor-\(section.key)")

                                    Text(sortMode == .dateAdded ? prettyMonth(section.key) : section.key)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, horizontalPad)
                                        .padding(.trailing, indexVisualWidth + indexRightPadding)
                                        .padding(.vertical, 6)

                                    if isGridView {
                                        LazyVGrid(
                                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                                            spacing: 14
                                        ) {
                                            ForEach(section.items) { album in
                                                albumCell(album)
                                            }
                                        }
                                        .scrollTargetLayout()
                                        .padding(.horizontal, horizontalPad)
                                    } else {
                                        LazyVStack(alignment: .leading, spacing: 0) {
                                            ForEach(section.items) { album in
                                                albumCell(album)
                                                Divider()
                                                    .padding(.leading, horizontalPad + 30 + 10)
                                                    .padding(.trailing, indexVisualWidth + indexRightPadding)
                                            }
                                        }
                                        .scrollTargetLayout()
                                        .padding(.horizontal, horizontalPad)
                                    }
                                }
                            }
                        }
                    }
                    .scrollPosition(id: $scrollPosition)
                    .scrollIndicators(.automatic)

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
    
    // MARK: - Cells
    @ViewBuilder
    private func albumCell(_ album: JellyfinAlbum) -> some View {
        NavigationLink(destination:
            AlbumDetailView(album: album)
                .environmentObject(apiService)
                .navigationTransition(.zoom(sourceID: album.id, in: albumZoomNS))
        ) {
            if isGridView {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedCover(url: apiService.imageURL(for: album.id), cornerRadius: coverRadius)
                        .aspectRatio(1, contentMode: .fit)
                        .matchedTransitionSource(id: album.id, in: albumZoomNS)

                    // ✅ ADJUSTMENT: Grouped title/icons and added a Spacer
                    HStack {
                        HStack(spacing: 4) {
                            Text(album.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            if albumIsExplicit(album) {
                                Image(systemName: "e.square.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer(minLength: 0)

                        if album.userData?.isFavorite == true {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(accentRed)
                        }
                    }
                    
                    if let artist = albumArtistName(album) {
                        Text(artist)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 10) {
                    RoundedCover(url: apiService.imageURL(for: album.id), cornerRadius: 8)
                        .frame(width: 50, height: 50)
                        .matchedTransitionSource(id: album.id, in: albumZoomNS)

                    VStack(alignment: .leading, spacing: 2) {
                        // ✅ ADJUSTMENT: Grouped title/icons and added a Spacer
                        HStack {
                            HStack(spacing: 4) {
                                Text(album.name)
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                if albumIsExplicit(album) {
                                    Image(systemName: "e.square.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer(minLength: 0)
                            
                            if album.userData?.isFavorite == true {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(accentRed)
                            }
                        }

                        if let artist = albumArtistName(album) {
                            Text(artist)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
        }
        .id(album.id)
        .simultaneousGesture(TapGesture().onEnded {
            scrollPosition = album.id
        })
        .buttonStyle(.plain)
        .contextMenu {
            Button { albumPlay(album) }      label: { Label("Play",      systemImage: "play.fill") }
            Button { albumShuffle(album) }   label: { Label("Shuffle",   systemImage: "shuffle") }
            Button { albumQueueNext(album) } label: { Label("Play Next", systemImage: "text.insert") }

            let fav = album.userData?.isFavorite == true
            Button { albumToggleFavorite(album) } label: {
                Label(fav ? "Unfavorite" : "Favorite", systemImage: fav ? "star.fill" : "star")
            }

            Button { albumDownload(album) }  label: { Label("Download",  systemImage: "arrow.down.circle") }
        } preview: {
            AlbumContextPreviewTile(
                title: album.name,
                subtitle: albumArtistName(album) ?? "",
                imageURL: apiService.imageURL(for: album.id),
                corner: 14
            )
            .frame(width: 280)
        }
    }
    
    // ... (The rest of your file is unchanged) ...
    
    // MARK: - Data
    private func fetchAlbums() {
        isLoading = true
        errorMessage = nil
        apiService.fetchAlbums()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                isLoading = false
                if case .failure(let err) = completion {
                    errorMessage = "Failed to load albums: \(err.localizedDescription)"
                }
            }, receiveValue: { fetched in
                self.albumsRaw = fetched
                applyFiltersAndSort()
            })
            .store(in: &cancellables)
    }

    // MARK: - applyFiltersAndSort
    private func applyFiltersAndSort() {
        var base = searchText.isEmpty
            ? albumsRaw
            : albumsRaw.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                (albumArtistName($0) ?? "").localizedCaseInsensitiveContains(searchText)
            }

        if favoritesOnly {
            base = base.filter { $0.userData?.isFavorite == true }
        }

        switch sortMode {
        case .title:
            base.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .dateAdded:
            base.sort {
                (parsedDate($0.dateCreated) ?? .distantPast) >
                (parsedDate($1.dateCreated) ?? .distantPast)
            }
        case .artistAZ:
            base.sort {
                let a0 = albumArtistName($0) ?? ""
                let a1 = albumArtistName($1) ?? ""
                if a0.caseInsensitiveCompare(a1) != .orderedSame {
                    return a0.localizedCaseInsensitiveCompare(a1) == .orderedAscending
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .year:
            base.sort {
                let y0 = $0.productionYear ?? Int.max
                let y1 = $1.productionYear ?? Int.max
                if y0 != y1 { return y0 < y1 }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        filteredAlbums = base
        sections = makeSections(from: base, mode: sortMode)
    }

    // MARK: - Play helpers
    private func playAlbums(shuffle: Bool) {
        var all = sections.flatMap { $0.items }
        if shuffle { all.shuffle() }
        guard !all.isEmpty else { return }

        let group = DispatchGroup()
        var allTracks: [JellyfinTrack] = []
        for album in all {
            group.enter()
            apiService.fetchTracks(for: album.id)
                .replaceError(with: [])
                .receive(on: DispatchQueue.main)
                .sink { tracks in
                    allTracks.append(contentsOf: tracks)
                    group.leave()
                }
                .store(in: &cancellables)
        }
        group.notify(queue: .main) {
            guard !allTracks.isEmpty else { return }
            apiService.playTrack(tracks: allTracks, startIndex: 0, albumArtist: nil)
        }
    }
    
    // MARK: - Context menu actions
    private func albumPlay(_ album: JellyfinAlbum) {
        apiService.fetchTracks(for: album.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                apiService.playTrack(tracks: tracks, startIndex: 0, albumArtist: albumArtistName(album))
            }
            .store(in: &cancellables)
    }

    private func albumShuffle(_ album: JellyfinAlbum) {
        apiService.fetchTracks(for: album.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                var shuffled = tracks; shuffled.shuffle()
                apiService.playTrack(tracks: shuffled, startIndex: 0, albumArtist: albumArtistName(album))
            }
            .store(in: &cancellables)
    }

    private func albumQueueNext(_ album: JellyfinAlbum) {
        apiService.fetchTracks(for: album.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
            }
            .store(in: &cancellables)
    }

    private func albumToggleFavorite(_ album: JellyfinAlbum) {
        let isFav = album.userData?.isFavorite ?? false
        let call: AnyPublisher<Void, Error> = isFav
            ? apiService.unmarkItemFavorite(itemId: album.id)
            : apiService.markItemFavorite(itemId: album.id)

        call
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: {
                if let i = albumsRaw.firstIndex(where: { $0.id == album.id }) {
                    var updated = albumsRaw[i]
                    updated.userData = JellyfinUserData(isFavorite: !isFav)
                    albumsRaw[i] = updated
                    applyFiltersAndSort()
                }
            })
            .store(in: &cancellables)
    }

    private func albumDownload(_ album: JellyfinAlbum) {
    }


    // MARK: - Small helpers
    private func albumIsExplicit(_ a: JellyfinAlbum) -> Bool {
        if let tags = a.tags,
           tags.contains(where: { $0.caseInsensitiveCompare("Explicit") == .orderedSame }) { return true }
        return (a.isExplicit ?? false)
    }
}

// MARK: - Helper Views
fileprivate struct EmptyFavoritesAlbumsState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "star")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("No Favorited Albums")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("Mark albums as favorites from their detail page or by long-pressing them.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

final class RetryingImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    private var task: URLSessionDataTask?
    private var currentURL: URL?

    func load(from url: URL?, retries: Int = 2, delay: TimeInterval = 0.7) {
        guard currentURL != url else { return }
        currentURL = url
        image = nil
        isLoading = true
        attempt(url, remaining: retries, delay: delay)
    }

    private func attempt(_ url: URL?, remaining: Int, delay: TimeInterval) {
        guard let url else { self.finish(nil); return }
        task?.cancel()
        task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            if let data, let ui = UIImage(data: data) {
                DispatchQueue.main.async { self.finish(ui) }
            } else if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.attempt(url, remaining: remaining - 1, delay: delay)
                }
            } else {
                DispatchQueue.main.async { self.finish(nil) }
            }
        }
        task?.resume()
    }

    private func finish(_ ui: UIImage?) {
        self.image = ui
        self.isLoading = false
    }

    deinit { task?.cancel() }
}

struct RetryAsyncImage: View {
    let url: URL?
    var retries: Int = 2
    var delay: TimeInterval = 0.7
    @StateObject private var loader = RetryingImageLoader()

    var body: some View {
        ZStack {
            if let ui = loader.image {
                Image(uiImage: ui).resizable().scaledToFill()
            } else if loader.isLoading {
                ProgressView()
            } else {
                Color.gray.opacity(0.25)
                    .overlay(Image(systemName: "photo").foregroundColor(.secondary))
            }
        }
        .onAppear { loader.load(from: url, retries: retries, delay: delay) }
        .onChange(of: url) { newURL in loader.load(from: newURL, retries: retries, delay: delay) }
    }
}

fileprivate struct RoundedCover: View {
    let url: URL?
    let cornerRadius: CGFloat
    var body: some View {
        RetryAsyncImage(url: url)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

fileprivate struct AlbumContextPreviewTile: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let corner: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .empty: ZStack { Color.gray.opacity(0.2); ProgressView() }
                default: ZStack { Color.gray.opacity(0.2); Image(systemName: "photo").foregroundColor(.secondary) }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
        .background(Color(.systemBackground))
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
    var rightPadding: CGFloat = 2
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
        .onAppear {
            selectionGen.prepare()
            impactGen.prepare()
        }
    }
}
