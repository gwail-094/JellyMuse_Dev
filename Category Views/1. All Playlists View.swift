import SwiftUI
import Combine
import UIKit

struct AllPlaylistsView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @Environment(\.dismiss) private var dismiss

    // Data
    @State private var playlistsRaw: [JellyfinAlbum] = []
    @State private var filtered: [JellyfinAlbum] = []
    @State private var searchText: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cancellables = Set<AnyCancellable>()

    // Persisted UI prefs
    @AppStorage("AllPlaylistsView.isGridView") private var isGridView: Bool = true
    @AppStorage("AllPlaylistsView.sortMode") private var sortModeRaw: Int = SortMode.title.rawValue
    @AppStorage("AllPlaylistsView.favoritesOnly") private var favoritesOnly: Bool = false

    // Define the accent color used by Apple Music's filters
    private let accentRed = Color(red: 0.95, green: 0.20, blue: 0.30)

    // Blacklist (case-insensitive)
    private let hiddenTags: Set<String> = ["mfy", "replay", "amp"]

    private func isHidden(_ p: JellyfinAlbum) -> Bool {
        let lower = Set((p.tags ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        // hidden if there is any overlap with hiddenTags
        return !hiddenTags.isDisjoint(with: lower)
    }

    // UI
    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 12
    private let titleSize: CGFloat = 14

    // Sorting
    private enum SortMode: Int, CaseIterable { case title, dateAdded, recentlyPlayed }
    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .title }
    private func setSortMode(_ mode: SortMode) { sortModeRaw = mode.rawValue }

    // Grid
    private let grid = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if isLoading {
                    VStack { Spacer(); ProgressView(); Spacer() }
                } else if let errorMessage {
                    VStack { Spacer(); Text(errorMessage).foregroundColor(.red); Spacer() }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {

                            // Small breathing room under large title
                            Spacer().frame(height: 8)

                            // Content
                            if favoritesOnly && filtered.isEmpty {
                                EmptyFavoritesPlaylistsState()
                                    .padding(.top, 40)
                                    .padding(.horizontal, horizontalPad)
                            } else if isGridView {
                                LazyVGrid(columns: grid, spacing: 20) {
                                    ForEach(filtered, id: \.id) { p in
                                        let imgURL = apiService.imageURL(for: p.id)
                                        NavigationLink {
                                            PlaylistDetailView(playlistId: p.id).environmentObject(apiService)
                                        } label: {
                                            PlaylistTile(
                                                title: p.name,
                                                imageURL: imgURL,
                                                isFavorite: (p.userData?.isFavorite ?? false),
                                                coverRadius: coverRadius,
                                                titleSize: titleSize
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu(menuItems: { playlistContextMenu(for: p) }, preview: {
                                            PlaylistContextPreviewTile(
                                                title: p.name,
                                                imageURL: imgURL,
                                                corner: 30
                                            )
                                        })
                                    }
                                }
                                .padding(.horizontal, horizontalPad)
                            } else {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(filtered, id: \.id) { p in
                                        let imgURL = apiService.imageURL(for: p.id)
                                        NavigationLink {
                                            PlaylistDetailView(playlistId: p.id).environmentObject(apiService)
                                        } label: {
                                            VStack(spacing: 0) {
                                                HStack(spacing: 12) {
                                                    RoundedCover(url: imgURL, cornerRadius: 10)
                                                        .frame(width: 60, height: 60)
                                                        .aspectRatio(1, contentMode: .fill)

                                                    HStack(spacing: 6) {
                                                        Text(p.name)
                                                            .font(.system(size: 16, weight: .regular))
                                                            .foregroundColor(.primary)
                                                            .lineLimit(1)
                                                        if p.userData?.isFavorite == true {
                                                            Image(systemName: "star.fill")
                                                                .font(.system(size: 10, weight: .bold))
                                                                .foregroundColor(.red)
                                                        }
                                                    }
                                                    Spacer()
                                                    Image(systemName: "chevron.right")
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundColor(.secondary)
                                                }
                                                .contentShape(Rectangle())
                                                .padding(.vertical, 8)

                                                Divider()
                                                    .padding(.leading, 72)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu(menuItems: { playlistContextMenu(for: p) }, preview: {
                                            PlaylistContextPreviewTile(
                                                title: p.name,
                                                imageURL: imgURL,
                                                corner: 30
                                            )
                                        })
                                    }
                                }
                                .padding(.horizontal, horizontalPad)
                            }

                            // Space for your floating mini-player/menu bar
                            Color.clear.frame(height: 24)
                        }
                    }
                    .scrollIndicators(.visible)
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Sort + Favorites menu (checkmarks + black icons)
                Menu {
                    // Sort (shows a ✓ on the selected one)
                    Picker("Sort by", selection: $sortModeRaw) {
                        HStack {
                            Image(systemName: "textformat.abc").foregroundStyle(.black)
                            Text("Title")
                        }.tag(SortMode.title.rawValue)

                        HStack {
                            Image(systemName: "calendar.badge.clock").foregroundStyle(.black)
                            Text("Date Added")
                        }.tag(SortMode.dateAdded.rawValue)

                        HStack {
                            Image(systemName: "memories").foregroundStyle(.black)
                            Text("Recently Played")
                        }.tag(SortMode.recentlyPlayed.rawValue)
                    }

                    Divider()

                    // Favorites filter (shows a ✓ when on)
                    Toggle(isOn: Binding(
                        get: { favoritesOnly },
                        set: { favoritesOnly = $0; fetchPlaylists() } // refetch when toggled
                    )) {
                        HStack {
                            Image(systemName: "star.fill").foregroundStyle(.black)
                            Text("Favorites Only")
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        // TWEAK: Conditional Red Pill Background
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(favoritesOnly ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background {
                            if favoritesOnly {
                                Circle().fill(accentRed)
                            }
                        }
                }
                .tint(.primary) // Set the default icon color
                .onChange(of: sortModeRaw) { _ in
                    fetchPlaylists()  // refetch when sort changes
                }


                // View mode menu (grid/list with checkmark + black icons)
                Menu {
                    Picker("Layout", selection: $isGridView) {
                        HStack {
                            Image(systemName: "square.grid.2x2").foregroundStyle(.black)
                            Text("Grid")
                        }.tag(true)

                        HStack {
                            Image(systemName: "list.bullet").foregroundStyle(.black)
                            Text("List")
                        }.tag(false)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(.primary)
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search playlists"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in
            applyClientFilter()
        }
        .onAppear { fetchPlaylists() }
    }

    // MARK: - Playlist Context Menu
    @ViewBuilder
    private func playlistContextMenu(for playlist: JellyfinAlbum) -> some View {
        Button(action: { handlePlay(playlist) }) {
            Label("Play", systemImage: "play")
        }
        Button(action: { handleShuffle(playlist) }) {
            Label("Shuffle", systemImage: "shuffle")
        }
        let isFav = (playlist.userData?.isFavorite ?? false)
        Button(action: { handleToggleFavorite(playlist, isCurrentlyFavorite: isFav) }) {
            Label(isFav ? "Undo Favorite" : "Favorite",
                  systemImage: isFav ? "star.fill" : "star")
        }
        Button(action: { handleDownload(playlist) }) {
            Label("Download", systemImage: "arrow.down.circle")
        }
    }

    // MARK: - Actions
    private func handleDownload(_ playlist: JellyfinAlbum) {
        apiService.downloadPlaylist(playlistId: playlist.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                }
            }, receiveValue: { localFiles in
                print("✅ Downloaded \(localFiles.count) tracks for \(playlist.name)")
            })
            .store(in: &cancellables)
    }

    private func handleToggleFavorite(_ playlist: JellyfinAlbum, isCurrentlyFavorite: Bool) {
        let op: AnyPublisher<Void, Error> = isCurrentlyFavorite
            ? apiService.unmarkItemFavorite(itemId: playlist.id)
            : apiService.markItemFavorite(itemId: playlist.id)

        op.receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion {
                    self.errorMessage = "Favorite failed: \(err.localizedDescription)"
                }
            }, receiveValue: {
                func flip(_ p: JellyfinAlbum) -> JellyfinAlbum {
                    // Build using the legacy 7-parameter initializer your model currently provides.
                    JellyfinAlbum(
                        id: p.id,
                        name: p.name,
                        artistItems: p.artistItems,
                        productionYear: p.productionYear,
                        genres: p.genres,
                        albumArtists: p.albumArtists,
                        userData: JellyfinUserData(isFavorite: !isCurrentlyFavorite)
                    )
                }
                self.playlistsRaw = self.playlistsRaw.map { $0.id == playlist.id ? flip($0) : $0 }
                self.applyClientFilter()
            })
            .store(in: &cancellables)
    }

    private func handlePlay(_ playlist: JellyfinAlbum) {
        fetchTracksAndPlay(playlist: playlist, shuffle: false)
    }

    private func handleShuffle(_ playlist: JellyfinAlbum) {
        fetchTracksAndPlay(playlist: playlist, shuffle: true)
    }

    private func fetchTracksAndPlay(playlist: JellyfinAlbum, shuffle: Bool) {
        apiService.fetchPlaylistTracks(playlistId: playlist.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion {
                    self.errorMessage = "Failed to load playlist tracks: \(err.localizedDescription)"
                }
            }, receiveValue: { tracks in
                var list = tracks
                if shuffle { list.shuffle() }
                guard !list.isEmpty else { return }
                self.apiService.playTrack(tracks: list, startIndex: 0, albumArtist: nil)
            })
            .store(in: &cancellables)
    }

    // MARK: - Data
    private func fetchPlaylists() {
        isLoading = true
        errorMessage = nil

        let serverSort: JellyfinAPIService.PlaylistServerSort = {
            switch sortMode {
            case .title:         return .title
            case .dateAdded:     return .dateAdded
            case .recentlyPlayed: return .recentlyPlayed
            }
        }()

        let filter: JellyfinAPIService.PlaylistServerFilter = favoritesOnly ? .favorites : .all

        apiService.fetchPlaylistsAdvanced(
            sort: serverSort,
            descending: (sortMode != .title),
            filter: filter
        )
        .receive(on: DispatchQueue.main)
        .sink(receiveCompletion: { completion in
            isLoading = false
            if case .failure(let error) = completion {
                errorMessage = "Failed to load playlists: \(error.localizedDescription)"
            }
        }, receiveValue: { fetched in
            // Filter out blacklisted tag playlists immediately
            playlistsRaw = fetched.filter { !isHidden($0) }
            applyClientFilter()
        })
        .store(in: &cancellables)
    }

    private func applyClientFilter() {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = playlistsRaw.filter { !isHidden($0) }  // <- keep blacklist here too
        filtered = term.isEmpty
            ? base
            : base.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }
}

// MARK: - Tile used in the grid (normal cell, shows favorite star inline)
fileprivate struct PlaylistTile: View {
    let title: String
    let imageURL: URL?
    let isFavorite: Bool
    let coverRadius: CGFloat
    let titleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedCover(url: imageURL, cornerRadius: coverRadius)
                .aspectRatio(1, contentMode: .fit)

            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: titleSize, weight: .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(red: 0.95, green: 0.20, blue: 0.30)) // Use custom red here too
                }
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Preview that shows ONLY during context menu
fileprivate struct PlaylistContextPreviewTile: View {
    let title: String
    let imageURL: URL?
    let corner: CGFloat

    private let horizontalInset: CGFloat = 15
    private let verticalInset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedCover(url: imageURL, cornerRadius: corner)
                .aspectRatio(1, contentMode: .fit)

            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, verticalInset)
        .background(
            RoundedRectangle(cornerRadius: corner + 6, style: .continuous)
                .fill(.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: corner + 6, style: .continuous)
                .stroke(.clear, lineWidth: 3)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
    }
}

// MARK: - Empty Favorites View
fileprivate struct EmptyFavoritesPlaylistsState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("No Favorited Playlists")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("You can favorite playlists from their detail page or by long-pressing on them.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .multilineTextAlignment(.center)
    }
}

// MARK: - Rounded Cover View
fileprivate struct RoundedCover: View {
    let url: URL?
    let cornerRadius: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.gray.opacity(0.25))
                    ProgressView().scaleEffect(0.9)
                }
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.gray.opacity(0.25))
                    .overlay(Image(systemName: "photo").foregroundColor(.secondary))
            @unknown default:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.gray.opacity(0.25))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
