import SwiftUI
import Combine

// MARK: - Sections you can show/hide
private enum LibrarySection: String, CaseIterable, Identifiable {
    case playlists, artists, albums, songs, genres, downloads
    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: return "Playlists"
        case .artists:   return "Artists"
        case .albums:    return "Albums"
        case .songs:     return "Songs"
        case .genres:    return "Genres"
        case .downloads: return "Downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists:   return "music.microphone"
        case .albums:    return "square.stack"
        case .songs:     return "music.note"
        case .genres:    return "guitars"
        case .downloads: return "square.and.arrow.down"
        }
    }
}

private let kEnabledSectionsKey = "library.enabledSections"

struct LibraryView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    
    @State private var recentAlbums: [JellyfinAlbum] = []
    @State private var cancellables = Set<AnyCancellable>()
    
    // MARK: Patch: Section Editing State and Persistence
    @State private var isEditingSections = false
    @State private var enabledSections: Set<LibrarySection> = Set(LibrarySection.allCases)

    // ★ NEW: shared animation namespace for zoom transition
    @Namespace private var albumZoomNS
    
    private func loadEnabledSections() {
        guard let raw = UserDefaults.standard.array(forKey: kEnabledSectionsKey) as? [String] else {
            enabledSections = Set(LibrarySection.allCases) // default: all on
            return
        }
        enabledSections = Set(raw.compactMap { LibrarySection(rawValue: $0) })
    }

    private func saveEnabledSections() {
        let raw = enabledSections.map(\.rawValue)
        UserDefaults.standard.set(raw, forKey: kEnabledSectionsKey)
    }
    // END Patch: Section Editing State and Persistence
    
    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    private let accent = Color(red: 0.95, green: 0.2, blue: 0.3)
    
    // Context menu actions
    private enum AlbumAction { case play, shuffle, playNext, toggleFavorite, download }
    
    var body: some View {
        let titleStart = CategoryRow.hPad + CategoryRow.iconBoxWidth + CategoryRow.gapIconTitle
        
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                
                // MARK: Categories (PATCH: Replaced hardcoded list with logic)
                VStack(spacing: 0) {
                    let all = LibrarySection.allCases
                    // Which set to render?
                    let toRender: [LibrarySection] = isEditingSections ? all : all.filter { enabledSections.contains($0) }
                    
                    ForEach(Array(toRender.enumerated()), id: \.offset) { idx, section in
                        if isEditingSections {
                            // Editable row with checkbox
                            EditableCategoryRow(
                                title: section.title,
                                systemImage: section.systemImage,
                                accent: accent,
                                checked: enabledSections.contains(section)
                            ) {
                                if enabledSections.contains(section) {
                                    enabledSections.remove(section)
                                } else {
                                    enabledSections.insert(section)
                                }
                            }
                        } else {
                            // Normal nav rows (your original destinations)
                            switch section {
                            case .playlists:
                                NavigationLink(destination: AllPlaylistsView().environmentObject(apiService)) {
                                    CategoryRow(title: section.title, systemImage: section.systemImage, accent: accent)
                                }
                                .buttonStyle(.plain)

                            case .artists:
                                NavigationLink(destination: AlbumArtistsView().environmentObject(apiService)) {
                                    CategoryRow(title: section.title, systemImage: section.systemImage, accent: accent)
                                }
                                .buttonStyle(.plain)

                            case .albums:
                                NavigationLink(destination: AllAlbumsView().environmentObject(apiService)) {
                                    CategoryRow(title: section.title, systemImage: section.systemImage, accent: accent)
                                }
                                .buttonStyle(.plain)

                            case .songs:
                                NavigationLink(destination: AllSongsView().environmentObject(apiService)) {
                                    CategoryRow(title: section.title, systemImage: section.systemImage, accent: accent)
                                }
                                .buttonStyle(.plain)

                            case .genres:
                                NavigationLink(destination: AllGenresView().environmentObject(apiService)) {
                                    CategoryRow(title: section.title, systemImage: section.systemImage, accent: accent)
                                }
                                .buttonStyle(.plain)

                            case .downloads:
                                NavigationLink {
                                    DownloadsView()
                                        .environmentObject(apiService)
                                        .environmentObject(DownloadsAPI.shared)
                                } label: {
                                    CategoryRow(title: section.title, systemImage: section.systemImage, accent: accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Divider between rows
                        if idx < toRender.count - 1 {
                            InsetDivider(leading: titleStart)
                        }
                    }
                }
                .background(Color(.systemBackground))
                .overlay(InsetDivider(leading: titleStart), alignment: .bottom)
                // END Patch: Categories
                
                // MARK: Recently Added
                Text("Recently Added")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 15)
                
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(recentAlbums, id: \.id) { album in
                        NavigationLink(
                            // ★ DESTINATION: apply zoom on push
                            destination:
                                AlbumDetailView(album: album)
                                    .environmentObject(apiService)
                                    .navigationTransition(.zoom(sourceID: album.id, in: albumZoomNS))
                        ) {
                            // ★ SOURCE: mark the grid item as the transition source
                            AlbumGridItem(album: album)
                                .matchedTransitionSource(id: album.id, in: albumZoomNS)
                                .contentShape(Rectangle())
                                .contextMenu {
                                    // MARK: 2. Context Menu (Uses live state)
                                    Button { performAlbumAction(album, .play) }    label: { Label("Play", systemImage: "play.fill") }
                                    Button { performAlbumAction(album, .shuffle) } label: { Label("Shuffle", systemImage: "shuffle") }
                                    Button { performAlbumAction(album, .playNext) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }

                                    let favNow = isFavorite(album.id)
                                    Button { performAlbumAction(album, .toggleFavorite) } label: {
                                        Label(favNow ? "Unfavorite" : "Favorite",
                                              systemImage: favNow ? "star.fill" : "star")
                                    }

                                    Button { performAlbumAction(album, .download) } label: { Label("Download", systemImage: "arrow.down.circle") }
                                } preview: {
                                    AlbumContextMenuPreview(album: album)
                                        .environmentObject(apiService)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .navigationTitle("Library")
        // MARK: Patch: Update Toolbar
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditingSections {
                    Button {
                        saveEnabledSections()
                        withAnimation { isEditingSections = false }
                    } label: {
                        Image(systemName: "checkmark")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.foreground) // adapts: black on light, white on dark
                    }
                    .accessibilityLabel("Done")
                } else {
                    Menu {
                        Button {
                            withAnimation { isEditingSections = true }
                        } label: {
                            Label("Edit Sections", systemImage: "checklist")
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.foreground) // makes the checklist icon adaptive
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.foreground) // adaptive system color
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        // END Patch: Update Toolbar
        .onAppear {
            loadEnabledSections()
            fetchRecentAlbums()
        }
    }
    
    private func fetchRecentAlbums() {
        apiService.fetchRecentAlbums()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    print("Error fetching recent albums:", error.localizedDescription)
                }
            }, receiveValue: { fetchedAlbums in
                self.recentAlbums = fetchedAlbums
            })
            .store(in: &cancellables)
    }

    // MARK: 1. Updated Helper Functions
    private func isFavorite(_ albumId: String) -> Bool {
        recentAlbums.first(where: { $0.id == albumId })?.userData?.isFavorite == true
    }

    private func setFavorite(_ albumId: String, to newValue: Bool) {
        guard let i = recentAlbums.firstIndex(where: { $0.id == albumId }) else { return }
        var updated = recentAlbums[i]
        updated.userData = JellyfinUserData(isFavorite: newValue)
        recentAlbums[i] = updated
    }
    
    private func performAlbumAction(_ album: JellyfinAlbum, _ action: AlbumAction) {
        let albumId = album.id
        
        func playTracks(_ tracks: [JellyfinTrack]) {
            guard !tracks.isEmpty else { return }
            AudioPlayer.shared.play(tracks: tracks,
                                    startIndex: 0,
                                    albumArtist: album.albumArtists?.first?.name)
        }
        
        switch action {
        case .play:
            apiService.fetchTracks(for: albumId)
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { playTracks($0) })
                .store(in: &cancellables)
            
        case .shuffle:
            apiService.fetchTracks(for: albumId)
                .map { $0.shuffled() }
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { playTracks($0) })
                .store(in: &cancellables)
            
        case .playNext:
            apiService.fetchTracks(for: albumId)
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { tracks in
                    guard !tracks.isEmpty else { return }
                    if AudioPlayer.shared.currentTrack == nil {
                        playTracks(tracks)
                        return
                    }
                    for t in tracks.reversed() {
                        AudioPlayer.shared.queueNext(t)
                    }
                    print("Queued album '\(album.name)' to play next (\(tracks.count) tracks)")
                })
                .store(in: &cancellables)
            
        case .toggleFavorite:
            let favNow = isFavorite(albumId)
            setFavorite(albumId, to: !favNow)
            let call: AnyPublisher<Void, Error> = favNow
                ? apiService.unmarkItemFavorite(itemId: albumId)
                : apiService.markItemFavorite(itemId: albumId)
            call
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        self.apiService.fetchItemUserData(itemId: albumId)
                            .replaceError(with: JellyfinUserData(isFavorite: !favNow))
                            .receive(on: DispatchQueue.main)
                            .sink { self.setFavorite(albumId, to: $0.isFavorite == true) }
                            .store(in: &self.cancellables)
                    case .failure:
                        self.setFavorite(albumId, to: favNow)
                    }
                }, receiveValue: { _ in })
                .store(in: &cancellables)
                
        case .download:
            apiService.downloadAlbum(albumId: albumId)
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { urls in print("Downloaded \(urls.count) tracks") })
                .store(in: &cancellables)
        }
    }
}

// MARK: - Helper Views (Unchanged)

private struct AlbumContextMenuPreview: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    let album: JellyfinAlbum
    
    private func albumArtistName(_ album: JellyfinAlbum) -> String? {
        if let artist = album.albumArtists?.first?.name, !artist.isEmpty { return artist }
        return album.artistItems?.first?.name
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: apiService.imageURL(for: album.id)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle()
                        .fill(.secondary.opacity(0.2))
                        .overlay(ProgressView())
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text(album.name)
                .font(.headline)
                .lineLimit(2)
                .foregroundColor(.primary)

            if let artist = albumArtistName(album) {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
        .frame(width: 280)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}


private struct InsetDivider: View {
    var leading: CGFloat
    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}

private struct CategoryRow: View {
    let title: String
    let systemImage: String
    let accent: Color
    
    static let hPad: CGFloat      = 20
    static let iconBoxWidth: CGFloat = 26
    static let gapIconTitle: CGFloat = 12
    
    var body: some View {
        HStack(spacing: Self.gapIconTitle) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(accent)
                .frame(width: Self.iconBoxWidth, alignment: .center)
            
            Text(title)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
            
            Spacer(minLength: 0)
            
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 10)
        .padding(.horizontal, Self.hPad)
    }
}

// MARK: Patch: New Editable Row Helper
private struct EditableCategoryRow: View {
    let title: String
    let systemImage: String
    let accent: Color
    let checked: Bool
    let onToggle: () -> Void

    // Keep spacing aligned with CategoryRow
    static let hPad: CGFloat         = CategoryRow.hPad
    static let iconBoxWidth: CGFloat = CategoryRow.iconBoxWidth
    static let gapIconTitle: CGFloat = CategoryRow.gapIconTitle

    var body: some View {
        HStack(spacing: Self.gapIconTitle) {
            // Leading checkbox
            Button(action: onToggle) {
                let iconName = checked ? "checkmark.circle.fill" : "circle"
                if checked {
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 24, alignment: .center)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, alignment: .center)
                }
            }
            .buttonStyle(.plain)

            // Original icon
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(accent)
                .frame(width: CategoryRow.iconBoxWidth, alignment: .center)

            Text(title)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 10)
        .padding(.horizontal, CategoryRow.hPad)
    }
}
