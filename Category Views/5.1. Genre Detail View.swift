import SwiftUI
import Combine

struct GenreDetailView: View {
    let genre: JellyfinGenre

    @EnvironmentObject var apiService: JellyfinAPIService
    @Environment(\.dismiss) private var dismiss

    // Data
    @State private var albumsRaw: [JellyfinAlbum] = []
    @State private var filteredAlbums: [JellyfinAlbum] = []
    @State private var searchText: String = ""
    @State private var cancellables = Set<AnyCancellable>()
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Persisted UI prefs
    @AppStorage("GenreDetailView.isGridView") private var isGridView: Bool = true
    @AppStorage("GenreDetailView.favoritesOnly") private var favoritesOnly: Bool = false

    // UI
    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 8
    private let titleSize: CGFloat = 12
    private let artistSize: CGFloat = 11

    // Sorting
    private enum SortMode: Int, CaseIterable { case title, dateAdded, artistAZ, year }
    @AppStorage("GenreDetailView.sortMode") private var sortModeRaw: Int = SortMode.title.rawValue
    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .title }
    private func setSortMode(_ mode: SortMode) { sortModeRaw = mode.rawValue }

    var body: some View {
        Group {
            if isLoading {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                VStack { Spacer(); Text(errorMessage).foregroundColor(.red); Spacer() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Small spacer for breathing room under the large title
                        Spacer().frame(height: 8)

                        // Play / Shuffle pills
                        HStack(spacing: 12) {
                            PillButton(icon: "play.fill", title: "Play") {
                                playAlbums(shuffle: false)
                            }
                            PillButton(icon: "shuffle", title: "Shuffle") {
                                playAlbums(shuffle: true)
                            }
                        }
                        .padding(.horizontal, horizontalPad)

                        // Grid/List content
                        if favoritesOnly && filteredAlbums.isEmpty {
                            EmptyFavoritesState()
                                .padding(.top, 40)
                                .padding(.horizontal, horizontalPad)
                        } else {
                            if isGridView {
                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                                    ForEach(filteredAlbums) { album in
                                        albumCell(album)
                                    }
                                }
                                .padding(.horizontal, horizontalPad)
                            } else {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(filteredAlbums) { album in
                                        albumCell(album)
                                    }
                                }
                                .padding(.horizontal, horizontalPad)
                            }
                        }

                        Color.clear.frame(height: 120)
                    }
                    .padding(.top, -20)
                    .padding(.top, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle(genre.name)
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
        .onChange(of: searchText) { _ in
            applyFiltersAndSort()
        }
        .toolbar {
            // RIGHT side: your existing menus...
            ToolbarItemGroup(placement: .topBarTrailing) {
                // SORT + FILTER (with native ✓)
                Menu {
                    // SORT (checkmark on selected)
                    Picker("Sort by", selection: $sortModeRaw) {
                        Label("Title",        systemImage: "textformat.abc").tag(SortMode.title.rawValue)
                        Label("Date Added",   systemImage: "clock").tag(SortMode.dateAdded.rawValue)
                        Label("Artist A–Z",   systemImage: "person.text.rectangle").tag(SortMode.artistAZ.rawValue)
                        Label("Year",         systemImage: "calendar").tag(SortMode.year.rawValue)
                    }
                    .pickerStyle(.inline)

                    Divider()

                    // FILTER (checkmark on active)
                    Toggle(isOn: Binding(
                        get: { favoritesOnly },
                        set: { favoritesOnly = $0; applyFiltersAndSort() }
                    )) {
                        Label("Favorites Only", systemImage: "star.fill")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .onChange(of: sortModeRaw) { _ in
                    applyFiltersAndSort()
                }

                // VIEW MODE
                Menu {
                    Button(action: { isGridView = true }) {
                        Label("Grid", systemImage: isGridView ? "checkmark" : "")
                    }
                    Button(action: { isGridView = false }) {
                        Label("List", systemImage: !isGridView ? "checkmark" : "")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .tint(.primary)
        .onAppear { fetchAlbums() }
    }

    // MARK: - Album cell
    @ViewBuilder
    private func albumCell(_ album: JellyfinAlbum) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
                .environmentObject(apiService)
        } label: {
            if isGridView {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedCover(url: apiService.imageURL(for: album.id), cornerRadius: coverRadius)
                        .aspectRatio(1, contentMode: .fit)

                    HStack(spacing: 6) {
                        Text(album.name)
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if album.userData?.isFavorite == true {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.primary)
                        }
                    }

                    if let artist = albumArtistName(album) {
                        Text(artist)
                            .font(.system(size: artistSize))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 12) {
                    RoundedCover(url: apiService.imageURL(for: album.id), cornerRadius: 8)
                        .frame(width: 60, height: 60)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(album.name)
                                .font(.system(size: titleSize, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            if album.userData?.isFavorite == true {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.primary)
                            }
                        }

                        if let artist = albumArtistName(album) {
                            Text(artist)
                                .font(.system(size: artistSize))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .contextMenu { albumContextMenu(album) } preview: {
            AlbumContextPreviewTile(
                title: album.name,
                subtitle: albumArtistName(album) ?? "",
                imageURL: apiService.imageURL(for: album.id),
                corner: 14
            )
            .frame(width: 280)
        }
    }

    // MARK: - Data
    private func fetchAlbums() {
        isLoading = true
        errorMessage = nil
        apiService.fetchAlbumsByGenre(genre.name)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                isLoading = false
                if case .failure(let error) = completion {
                    errorMessage = "Failed to load \(genre.name) albums: \(error.localizedDescription)"
                }
            }, receiveValue: { fetched in
                self.albumsRaw = fetched
                applyFiltersAndSort()
            })
            .store(in: &cancellables)
    }

    // MARK: - Filter + Sort
    private func applyFiltersAndSort() {
        var base = searchText.isEmpty
        ? albumsRaw
        : albumsRaw.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || (albumArtistName($0) ?? "").localizedCaseInsensitiveContains(searchText)
        }

        if favoritesOnly {
            base = base.filter { $0.userData?.isFavorite == true }
        }

        switch sortMode {
        case .title:
            base.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .dateAdded:
            base.sort { ($0.dateCreated ?? "").localizedCaseInsensitiveCompare($1.dateCreated ?? "") == .orderedDescending } // Corrected Line
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
    }

    // MARK: - Play helpers
    private func playAlbums(shuffle: Bool) {
        var allTracks: [JellyfinTrack] = []
        let group = DispatchGroup()
        for album in filteredAlbums {
            group.enter()
            JellyfinAPIService.shared.fetchTracks(for: album.id)
                .sink(receiveCompletion: { _ in group.leave() },
                      receiveValue: { tracks in allTracks.append(contentsOf: tracks) })
                .store(in: &cancellables)
        }
        group.notify(queue: .main) {
            if shuffle { allTracks.shuffle() }
            apiService.playTrack(tracks: allTracks, startIndex: 0, albumArtist: nil)
        }
    }

    // MARK: - Small helpers
    private func albumArtistName(_ album: JellyfinAlbum) -> String? {
        if let arr = album.albumArtists, let first = arr.first?.name, !first.isEmpty { return first }
        if let arr = album.artistItems,  let first = arr.first?.name, !first.isEmpty { return first }
        return nil
    }

    // ===== Context Menu & Actions =====
    @ViewBuilder
    private func albumContextMenu(_ album: JellyfinAlbum) -> some View {
        Button { albumPlay(album) }      label: { Label("Play",      systemImage: "play.fill") }
        Button { albumShuffle(album) }   label: { Label("Shuffle",   systemImage: "shuffle") }
        Button { albumQueueNext(album) } label: { Label("Play Next", systemImage: "text.insert") }

        let isFav = (album.userData?.isFavorite ?? false)
        Button { albumToggleFavorite(album) } label: {
            Label(isFav ? "Undo Favorite" : "Favorite",
                  systemImage: isFav ? "star.fill" : "star")
        }

        Button { albumDownload(album) }  label: { Label("Download",  systemImage: "arrow.down.circle") }
    }

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
                for t in tracks.reversed() {
                    AudioPlayer.shared.queueNext(t)
                }
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
                if let idx = albumsRaw.firstIndex(where: { $0.id == album.id }) {
                    var updated = albumsRaw[idx]
                    updated.userData = JellyfinUserData(isFavorite: !isFav)
                    albumsRaw[idx] = updated
                    applyFiltersAndSort()
                }
            })
            .store(in: &cancellables)
    }

    private func albumDownload(_ album: JellyfinAlbum) {
        apiService.downloadAlbum(albumId: album.id)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let err) = completion {
                        print("❌ Album download failed:", err.localizedDescription)
                    }
                },
                receiveValue: { urls in
                    print("✅ Downloaded \(urls.count) files for album \(album.name)")
                }
            )
            .store(in: &cancellables)
    }
}

//
// MARK: - Local helper views (copied here so this file compiles standalone)
//

fileprivate struct RoundedCover: View {
    let url: URL?
    let cornerRadius: CGFloat
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.gray.opacity(0.25))
                    ProgressView().scaleEffect(0.9)
                }
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.gray.opacity(0.25))
                    .overlay(Image(systemName: "photo").foregroundColor(.secondary))
            @unknown default:
                Color.gray.opacity(0.25)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

fileprivate struct EmptyFavoritesState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("No results based on this filter.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .multilineTextAlignment(.center)
    }
}

fileprivate struct AlbumContextPreviewTile: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let corner: CGFloat
    private let previewWidth: CGFloat = 280

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
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: previewWidth, alignment: .leading)
    }
}

fileprivate struct PillButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    // Apple-Music-ish red
    private let accent = Color(red: 0.95, green: 0.20, blue: 0.30)

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(accent)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity) // stretch so both pills match width
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
