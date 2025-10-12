import SwiftUI
import Combine
import UIKit

// MARK: - AlbumArtistsView

struct AlbumArtistsView: View {
    @EnvironmentObject var apiService: JellyfinAPIService

    // Data
    @State private var artists: [JellyfinArtistItem] = []
    @State private var filtered: [JellyfinArtistItem] = []
    @State private var sections: [(key: String, items: [JellyfinArtistItem])] = []

    // Favorites (no userData on model; we manage locally)
    @State private var favoriteById: [String: Bool] = [:]

    // UI state
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var scrollPosition: String? // artist.id anchor

    // Persisted filter
    @AppStorage("AlbumArtistsView.favoritesOnly") private var favoritesOnly: Bool = false
    
    // Define the accent color used by Apple Music's filters
    private let accentRed = Color(red: 0.95, green: 0.20, blue: 0.30)

    // Layout
    private let horizontalPad: CGFloat = 20
    private let avatarSize: CGFloat = 48
    private let sectionScrollTopOffset: CGFloat = 80
    private let indexVisualWidth: CGFloat = 18
    private let indexRightPadding: CGFloat = 2

    // A–Z index
    private let indexLetters: [String] =
        (65...90).compactMap { UnicodeScalar($0).map { String($0) } } + ["#"]

    private func firstIndexLetter(for name: String) -> String {
        guard let ch = name.unicodeScalars.first else { return "#" }
        let s = String(ch).uppercased()
        return (s.range(of: "^[A-Z]$", options: .regularExpression) != nil) ? s : "#"
    }

    private func makeSections(from list: [JellyfinArtistItem]) -> [(key: String, items: [JellyfinArtistItem])] {
        let groups = Dictionary(grouping: list) { firstIndexLetter(for: $0.name) }
        let keys = indexLetters.filter { groups[$0] != nil }
        return keys.map { k in
            (k, (groups[k] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })
        }
    }

    var body: some View {
        content
            .navigationTitle("Artists")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.automatic, for: .navigationBar)
            .toolbar { filterToolbar }
            .tint(.primary)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search artists"
            )
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .onChange(of: searchText) { _ in applyFilter() }
            .onChange(of: favoritesOnly) { _ in fetchArtists() }
            .onAppear { fetchArtists() }
    }

    // Split out to keep type-checker happy
    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack { Spacer(); ProgressView(); Spacer() }
        } else if let errorMessage {
            VStack { Spacer(); Text(errorMessage).foregroundColor(.red); Spacer() }
        } else if favoritesOnly && filtered.isEmpty {
            EmptyFavoritesArtistsState()
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            listWithIndex
        }
    }

    @ToolbarContentBuilder
    private var filterToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Filter", selection: $favoritesOnly) {
                    Label("All Artists", systemImage: "music.mic").tag(false)
                    Label("Favorites", systemImage: "star.fill").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 15, weight: .semibold)) // Give it a slight font boost
                    .foregroundColor(favoritesOnly ? .white : .primary)
                    .frame(width: 28, height: 28) // TWEAK: Set explicit frame for circle
                    .background {
                        if favoritesOnly {
                            Circle().fill(accentRed) // TWEAK: Use Circle explicitly
                        }
                    }
            }
        }
    }

    private var listWithIndex: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 6)

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections, id: \.key) { section in
                                Color.clear
                                    .frame(height: 1)
                                    .offset(y: -sectionScrollTopOffset)
                                    .id("anchor-\(section.key)")

                                Text(section.key)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, horizontalPad)
                                    .padding(.trailing, indexVisualWidth + indexRightPadding)
                                    .padding(.vertical, 4)

                                ForEach(section.items, id: \.id) { artist in
                                    artistRow(artist)
                                    Divider()
                                        .padding(.leading, horizontalPad + avatarSize + 12)
                                        // Divider padding to align with the rest of the row's right visual stop
                                        .padding(.trailing, 35)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .scrollPosition(id: $scrollPosition)

                FastIndexBar(
                    letters: indexLetters,
                    topInset: 120,
                    bottomInset: 28,
                    visualWidth: indexVisualWidth,
                    touchWidth: 36,
                    fontSize: 10,
                    minRowHeight: 9,
                    rightPadding: 6
                ) { letter in
                    if sections.contains(where: { $0.key == letter }) {
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) {
                            proxy.scrollTo("anchor-\(letter)", anchor: .top)
                        }
                    }
                }
                .zIndex(1)
            }
        }
    }

    // MARK: - Row
    @ViewBuilder
    private func artistRow(_ artist: JellyfinArtistItem) -> some View {
        let isFav = favoriteById[artist.id] ?? (favoritesOnly ? true : false)

        NavigationLink {
            ArtistDetailView(artist: artist).environmentObject(apiService)
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    AsyncImage(url: artistPrimaryURL(artist.id)) { phase in
                        switch phase {
                        case .empty:
                            ZStack { Circle().fill(Color.gray.opacity(0.25)); ProgressView().scaleEffect(0.8) }
                        case .success(let img):
                            img.resizable().scaledToFill()
                        case .failure:
                            ZStack {
                                Circle().fill(Color.gray.opacity(0.25))
                                Image(systemName: "person.crop.circle.fill").foregroundColor(.secondary)
                            }
                        @unknown default:
                            Circle().fill(Color.gray.opacity(0.25))
                        }
                    }
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())

                    Text(artist.name)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if isFav {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(accentRed)
                    }

                    Spacer()
                }
                .padding(.trailing, 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                    // Chevron's right padding is set to 15, aligning it with the divider end (35)
                    .padding(.trailing, 15)
            }
            .padding(.horizontal, horizontalPad)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .id(artist.id)
        .contextMenu {
            artistContextMenuItems(artist, isFavorite: isFav)
        } preview: {
            ArtistContextPreviewRow(
                title: artist.name,
                imageURL: artistPrimaryURL(artist.id)
            )
        }
        .onAppear {
            // lazily fetch user data to refine favorite badge
            apiService.fetchItemUserData(itemId: artist.id)
                .replaceError(with: JellyfinUserData(isFavorite: nil))
                .receive(on: DispatchQueue.main)
                .sink { data in
                    if let fav = data.isFavorite {
                        favoriteById[artist.id] = fav
                    }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Context Menu Items
    @ViewBuilder
    private func artistContextMenuItems(_ artist: JellyfinArtistItem, isFavorite: Bool) -> some View {
        Button {
            createArtistStation(artistId: artist.id, artistName: artist.name)
        } label: {
            Label("Create Station", systemImage: "dot.radiowaves.left.and.right")
        }

        Button {
            toggleFavorite(artist, currentIsFavorite: isFavorite)
        } label: {
            Label(isFavorite ? "Unfavorite" : "Favorite",
                  systemImage: isFavorite ? "star.fill" : "star")
        }
    }

    // MARK: - Data
    private func fetchArtists() {
        isLoading = true
        errorMessage = nil
        apiService.fetchAlbumArtistsAdvanced(favoritesOnly: favoritesOnly)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                isLoading = false
                if case .failure(let err) = completion {
                    errorMessage = "Failed to load artists: \(err.localizedDescription)"
                }
            }, receiveValue: { fetched in
                let sorted = fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.artists = sorted
                // seed favorites if we're in favoritesOnly mode
                if favoritesOnly {
                    for a in sorted { favoriteById[a.id] = true }
                }
                applyFilter()
            })
            .store(in: &cancellables)
    }

    private func applyFilter() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filtered = q.isEmpty ? artists : artists.filter { $0.name.lowercased().contains(q) }
        sections = makeSections(from: filtered)
    }

    // MARK: - Actions

    private func createArtistStation(artistId: String, artistName: String) {
        // 1) One “seed” track from the artist
        let seedPub = apiService.fetchArtistTopSongs(artistId: artistId, limit: 1)
            .map { $0.first }
            .replaceError(with: nil)
            .eraseToAnyPublisher()

        // 2) The Jellyfin instant mix
        let mixPub  = apiService.fetchInstantMix(itemId: artistId, limit: 80)
            .replaceError(with: [])
            .eraseToAnyPublisher()

        // 3) Combine → seed first, then mix, with de-dupe
        Publishers.Zip(seedPub, mixPub)
            .map { seed, mix -> [JellyfinTrack] in
                var seen = Set<String>()
                var out: [JellyfinTrack] = []

                func add(_ t: JellyfinTrack) {
                    // Assuming JellyfinTrack has properties 'serverId' and 'id'
                    let key = t.serverId ?? t.id
                    if !key.isEmpty && !seen.contains(key) {
                        seen.insert(key)
                        out.append(t)
                    }
                }

                if let s = seed { add(s) }
                mix.forEach(add)
                return out.isEmpty ? mix : out
            }
            .receive(on: DispatchQueue.main)
            .sink { queue in
                guard !queue.isEmpty else { return }
                apiService.playTrack(tracks: queue, startIndex: 0, albumArtist: artistName)
            }
            .store(in: &cancellables)
    }

    private func createStation(for artist: JellyfinArtistItem) {
        createArtistStation(artistId: artist.id, artistName: artist.name)
    }

    private func toggleFavorite(_ artist: JellyfinArtistItem, currentIsFavorite: Bool) {
        let call: AnyPublisher<Void, Error> = currentIsFavorite
            ? apiService.unmarkItemFavorite(itemId: artist.id)
            : apiService.markItemFavorite(itemId: artist.id)

        call
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: {
                favoriteById[artist.id] = !currentIsFavorite
                if favoritesOnly && currentIsFavorite {
                    artists.removeAll { $0.id == artist.id }
                    applyFilter()
                }
            })
            .store(in: &cancellables)
    }

    // MARK: - Image helpers (Primary > fallback)
    private func artistPrimaryURL(_ id: String) -> URL? {
        return apiService.imageURL(for: id, imageType: "Primary") ?? apiService.imageURL(for: id)
    }
}

// MARK: - Helper Views

// ---

fileprivate struct EmptyFavoritesArtistsState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "star")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("No Favorited Artists")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("Mark artists as favorites from their page or by long-pressing them.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

fileprivate struct ArtistContextPreviewRow: View {
    let title: String
    let imageURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .empty: ZStack { Circle().fill(Color.gray.opacity(0.2)); ProgressView() }
                default: ZStack { Circle().fill(Color.gray.opacity(0.2)); Image(systemName: "person.crop.circle.fill").foregroundColor(.secondary) }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .systemBackground))
    }
}

fileprivate struct FastIndexBar: View {
    let letters: [String]
    let topInset: CGFloat
    let bottomInset: CGFloat
    var visualWidth: CGFloat = 18
    var touchWidth: CGFloat  = 36
    var fontSize: CGFloat    = 10
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
        .onAppear {
            selectionGen.prepare()
            impactGen.prepare()
        }
    }
}
