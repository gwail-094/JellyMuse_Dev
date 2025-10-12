import SwiftUI
import Combine
import UIKit // for UIApplication.open
import SDWebImageSwiftUI // <— Add this import

// MARK: - Route Type
private enum NewRoute: Hashable {
    case album(id: String)
    case playlist(id: String)
}

// MARK: - Banner Text Style
private let bannerBadgeFontSize: CGFloat = 10
private let bannerBadgeFontWeight: Font.Weight = .semibold

private let bannerTitleFontSize: CGFloat = 18
private let bannerTitleFontWeight: Font.Weight = .regular

private let bannerSubtitleFontSize: CGFloat = 18
private let bannerSubtitleFontWeight: Font.Weight = .regular

// MARK: - Unified Models
enum NewFeedKind { case album, playlist }
struct NewFeedItem: Identifiable, Hashable {
    let id: String
    let kind: NewFeedKind
    let title: String
    let subtitle: String
    let badge: String
    let date: Date
    let imageURL: URL?

    func hash(into h: inout Hasher) { h.combine(id) }
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
}

// MARK: - Cards used by carousels
struct AlbumCard: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let artist: String
    let artworkURL: URL?
    let date: Date?
    let sourceId: String?   // ← add this

    init(title: String, artist: String, artworkURL: URL?, date: Date?, sourceId: String? = nil) {
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.date = date
        self.sourceId = sourceId
    }
}

struct SongCard: Identifiable, Hashable { // Changed from private
    let id = UUID()
    let artist: String
    let title: String
    let artworkURL: URL?
    let date: Date?
}

// MARK: - Cover Art Archive (for ListenBrainz items)
private func coverArtURL(releaseMBID: String?, releaseGroupMBID: String?) -> URL? {
    if let id = releaseMBID { return URL(string: "https://coverartarchive.org/release/\(id)/front?size=250") }
    if let id = releaseGroupMBID { return URL(string: "https://coverartarchive.org/release-group/\(id)/front?size=250") }
    return nil
}

// MARK: - YouTube Music helpers
private let YTM_APPSTORE_URL = URL(string: "itms-apps://itunes.apple.com/app/id1017492454")!

private func ytmWatchURL(videoID: String) -> (app: URL, web: URL) {
    let app = URL(string: "youtubemusic://watch?v=\(videoID)")!
    let web = URL(string: "https://music.youtube.com/watch?v=\(videoID)")!
    return (app, web)
}

private func ytmSearchURL(query: String) -> (app: URL, web: URL) {
    let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let app = URL(string: "youtubemusic://search?q=\(q)")!
    let web = URL(string: "https://music.youtube.com/search?q=\(q)")!
    return (app, web)
}

func openInYouTubeMusic(artist: String, title: String, videoID: String? = nil) {
    DispatchQueue.main.async {
        if let id = videoID {
            let (app, web) = ytmWatchURL(videoID: id)
            if UIApplication.shared.canOpenURL(app) {
                UIApplication.shared.open(app, options: [:], completionHandler: nil)
            } else {
                UIApplication.shared.open(web, options: [:], completionHandler: nil)
            }
            return
        }
        let (app, web) = ytmSearchURL(query: "\(artist) \(title)")
        if UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app, options: [:], completionHandler: nil)
        } else {
            UIApplication.shared.open(web, options: [:]) { _ in
                // Optional hard fallback:
                // UIApplication.shared.open(YTM_APPSTORE_URL)
            }
        }
    }
}

// MARK: - Image Resizing Helpers
// Ask Apple artwork endpoints for a specific square size (e.g. 120, 300)
@inline(__always)
private func appleArtwork(_ url: URL?, square: Int) -> URL? {
    guard var s = url?.absoluteString else { return url }
    // Covers common "/{w}x{h}" pattern in Apple RSS
    s = s.replacingOccurrences(of: "/{w}x{h}", with: "/\(square)x\(square)")
    return URL(string: s)
}

// SDWebImage downsample context helper for the exact pixel size you're drawing
@inline(__always)
private func thumbContext(px: Int) -> [SDWebImageContextOption: Any] {
    [.imageThumbnailPixelSize : CGSize(width: px, height: px)]
}

// MARK: - Latest Songs (list-style horizontal grid)
private struct LatestSongsCarousel: View {
    let title: String
    let items: [SongCard]
    let onTap: (SongCard) -> Void

    let gridLayout = [
        GridItem(.fixed(50)),
        GridItem(.fixed(50)),
        GridItem(.fixed(50)),
        GridItem(.fixed(50))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: -12) {   // ← tightened
            if !title.isEmpty {
                HStack(spacing: 6) {
                    Text(title).font(.title2).bold()
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: gridLayout, spacing: 0) {
                    ForEach(Array(items.prefix(16).enumerated()), id: \.element.id) { (idx, item) in
                        VStack(alignment: .leading, spacing: 0) {
                            Button { onTap(item) } label: {
                                HStack(spacing: 8) {
                                    let px = Int(44 * UIScreen.main.scale)
                                    let tinyURL = appleArtwork(item.artworkURL, square: 120) ?? item.artworkURL
                                    WebImage(url: tinyURL,
                                             options: [.scaleDownLargeImages, .continueInBackground, .highPriority],
                                             context: thumbContext(px: px))
                                        .resizable()
                                        .indicator(.activity)
                                        .transition(.fade)
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.callout).lineLimit(1)
                                        Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "ellipsis").font(.body)
                                }
                                .padding(.trailing, 16)
                                .frame(width: 300, alignment: .leading)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if (idx + 1) % 4 != 0 && idx < min(items.count, 16) - 1 {
                                Divider()
                                    .padding(.leading, 52)
                                    .padding(.trailing, 16)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - One-row square album carousel
private struct OneRowAlbumCarousel: View {
    let title: String
    let items: [AlbumCard]
    let onTap: (AlbumCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                HStack {
                    Text(title).font(.title2).bold()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items.prefix(19)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack {
                                Rectangle().fill(Color(.systemGray5))
                                let px = Int(150 * UIScreen.main.scale)
                                let sizedURL = appleArtwork(item.artworkURL, square: 300) ?? item.artworkURL

                                WebImage(
                                    url: sizedURL,
                                    options: [.scaleDownLargeImages, .continueInBackground],
                                    context: thumbContext(px: px)
                                )
                                .resizable()
                                .indicator(.activity)
                                .transition(.fade)
                                .scaledToFill()
                            }
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                Text(item.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 150, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(item) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
    }
}

private struct OneRowSongCarousel: View {
    let title: String
    let items: [SongCard]
    let onTap: (SongCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                HStack {
                    Text(title).font(.title2).bold()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items.prefix(24)) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack {
                                Rectangle().fill(Color(.systemGray5))
                                let px = Int(150 * UIScreen.main.scale)
                                let sizedURL = appleArtwork(item.artworkURL, square: 300) ?? item.artworkURL
                                WebImage(
                                    url: sizedURL,
                                    options: [.scaleDownLargeImages, .continueInBackground],
                                    context: thumbContext(px: px)
                                )
                                .resizable()
                                .indicator(.activity)
                                .transition(.fade)
                                .scaledToFill()
                            }
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            Text(item.title)
                                .font(.subheadline).fontWeight(.semibold)
                                .lineLimit(1)
                            Text(item.artist)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 150, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(item) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Top banners carousel (3:2 "Banner" images with visible shadow)
private struct NewTopCarousel: View {
    let items: [NewFeedItem]
    var onTap: (NewFeedItem) -> Void

    private static let bannerWidth: CGFloat = 300
    private static let bannerAspect: CGFloat = 2.0 / 3.0 // height/width for 3:2

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.badge)
                            .font(.system(size: bannerBadgeFontSize, weight: bannerBadgeFontWeight))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)

                        Text(item.title)
                            .font(.system(size: bannerTitleFontSize, weight: bannerTitleFontWeight))
                            .lineLimit(2)

                        Text(item.subtitle)
                            .font(.system(size: bannerSubtitleFontSize, weight: bannerSubtitleFontWeight))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black)
                                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)

                            WebImage(url: item.imageURL, options: [.progressiveLoad, .continueInBackground]) // Changed options
                                .resizable()
                                .indicator(.activity)
                                .transition(.fade)
                                .scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .compositingGroup()
                        .frame(
                            width: Self.bannerWidth,
                            height: Self.bannerWidth * Self.bannerAspect
                        )
                        .padding(.top, 6)
                    }
                    .frame(width: Self.bannerWidth, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(item) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }
}


// MARK: - New View Model (Renamed to NewScreenViewModel)
class NewScreenViewModel: ObservableObject { // Renamed from NewViewModel
    @Published var isLoaded: Bool = false
    @Published var screenIsLoading: Bool = false // Add this state for the full-screen loader
    @Published var hasLoadedOnce: Bool = false   // Add this flag to prevent re-fetching
    
    @Published var feed: [NewFeedItem] = []
    @Published var freshCards: [SongCard] = []
    @Published var newAlbums: [AlbumCard] = []
    @Published var updatedPlaylists: [AlbumCard] = []
    @Published var editorialAlbums: [AlbumCard] = []
    @Published var everybodySongCards: [SongCard] = []
    @Published var globalSongCards: [SongCard] = []
    @Published var upcomingAlbums: [AlbumCard] = []

    @Published var feedError: String?
    @Published var freshError: String?
    @Published var newAlbumsError: String?
    @Published var updatedPlaylistsError: String?
    @Published var editorialError: String?
    @Published var everybodySongsError: String?
    @Published var trendingSongsError: String?
    @Published var upcomingError: String?

    @Published var diag_lbSource = ""
    @Published var diag_lbURL = ""
    @Published var diag_lbHTTP = 0
    @Published var diag_lbBytes = 0
    @Published var diag_lbCount = 0
    @Published var diag_lastError: String?
    @Published var diag_openedURL: String?
    
    let apiService: JellyfinAPIService
    private let artworkService = AppleArtworkService.shared // Added missing property
    let lbUsername: String
    private var cancellables = Set<AnyCancellable>()
    private var bag = Set<AnyCancellable>() // For feed
    
    private let heroLimit = 12
    private let playlistLimit = 6
    private let blacklistedAlbumTags: Set<String> = ["blacklist", "blacklisthv"]
    private let blacklistedPlaylistTags: Set<String> = ["replay", "mfy"]


    init(api: JellyfinAPIService, lbUsername: String) {
        self.apiService = api
        self.lbUsername = lbUsername
    }

    @MainActor
    func loadAllOnce() async {
        guard !hasLoadedOnce else { return } // Only load once
        screenIsLoading = true
        let group = DispatchGroup()

        group.enter()
        loadFeed { group.leave() }
        group.enter()
        loadFreshReleases { group.leave() }
        group.enter()
        loadNewAlbums(days: 120, limit: 20) { group.leave() }
        group.enter()
        loadUpdatedPlaylists(limit: 20) { group.leave() }
        group.enter()
        loadEditorialTopAlbums(limit: 19) { group.leave() }
        group.enter()
        loadGlobalSongs(limit: 24) { group.leave() }
        group.enter()
        loadUpcomingAlbums(limit: 10) { group.leave() }
        group.enter()
        loadEverybodySongs(limit: 16) { group.leave() }

        group.notify(queue: .main) {
            // Prefetch images for the first screen
            let firstScreenURLs: [URL] = (
                // banners
                self.feed.compactMap { $0.imageURL } +
                // first 8 small song arts (120x)
                self.freshCards.prefix(8).compactMap { appleArtwork($0.artworkURL, square: 120) ?? $0.artworkURL } +
                // first 6 album tiles (300x)
                self.newAlbums.prefix(6).compactMap { $0.artworkURL } +
                // first 6 playlist tiles
                self.updatedPlaylists.prefix(6).compactMap { $0.artworkURL }
            )
            self.prefetch(firstScreenURLs)
            
            self.screenIsLoading = false
            self.isLoaded = true
            self.hasLoadedOnce = true
        }
    }
    
    // MARK: - Loaders (adapted to include onDone closure)
    private func loadFreshReleases(onDone: (() -> Void)? = nil) {
        freshError = nil
        freshCards = []

        let lb = ListenBrainzAPI(username: lbUsername)
        lb.freshReleases()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recs, _ in          // ← capture self
                guard let self = self else { return }
                let cards = recs.map {
                    SongCard(
                        artist: $0.artist,
                        title: $0.title,
                        artworkURL: self.coverArtURL(      // ← use self.
                            releaseMBID: $0.releaseMBID,
                            releaseGroupMBID: $0.releaseGroupMBID
                        ),
                        date: $0.releaseDate
                    )
                }
                self.freshCards = cards
                if cards.isEmpty {
                    self.freshError = "No fresh releases found in the last 4 months for \(self.lbUsername)."
                }
                onDone?()
            }
            .store(in: &cancellables)
    }

    private func loadNewAlbums(days: Int = 120, limit: Int = 20, onDone: (() -> Void)? = nil) {
        newAlbumsError = nil
        newAlbums = []

        ListenBrainzAPI(username: lbUsername)
            .freshAlbumReleases(days: days, limit: limit)
            .receive(on: DispatchQueue.main)
            .sink { releases, _ in // Fixed publisher signature
                let cards = releases.map { r in
                    AlbumCard(title: r.title, artist: r.artist, artworkURL: nil, date: r.releaseDate)
                }
                self.newAlbums = cards
                if cards.isEmpty {
                    self.newAlbumsError = "No new album releases in the last \(days/30) months."
                    onDone?() // Called onDone
                    return
                }
                // fetch artworks (don’t block gate)
                for idx in cards.indices {
                    let artist = cards[idx].artist
                    let title  = cards[idx].title
                    self.artworkService.albumArtwork(artist: artist, album: title)
                        .receive(on: DispatchQueue.main)
                        .sink { url in
                            guard let url = url else { return }
                            if idx < self.newAlbums.count,
                               self.newAlbums[idx].title == title,
                               self.newAlbums[idx].artist == artist {
                                let sized = appleArtwork(url, square: 300) ?? url
                                self.newAlbums[idx] = AlbumCard(title: title, artist: artist, artworkURL: sized, date: self.newAlbums[idx].date)
                            }
                        }
                        .store(in: &self.cancellables)
                }
                onDone?() // Called onDone
            }
            .store(in: &cancellables)
    }
    
    private func loadUpcomingAlbums(limit: Int = 10, onDone: (() -> Void)? = nil) {
        upcomingError = nil
        upcomingAlbums = []

        ListenBrainzAPI(username: lbUsername)
            .upcomingAlbumReleases(limit: limit)
            .receive(on: DispatchQueue.main)
            .sink { releases, _ in // Fixed publisher signature
                let cards = releases.map { r in
                    AlbumCard(title: r.title, artist: r.artist, artworkURL: nil, date: r.releaseDate)
                }
                self.upcomingAlbums = cards
                if cards.isEmpty {
                    self.upcomingError = "No upcoming albums curated for \(self.lbUsername)." // Added self.
                    onDone?() // Called onDone
                    return
                }
                for idx in cards.indices {
                    let artist = cards[idx].artist
                    let title  = cards[idx].title
                    self.artworkService.albumArtwork(artist: artist, album: title)
                        .receive(on: DispatchQueue.main)
                        .sink { url in
                            guard let url = url else { return }
                            if idx < self.upcomingAlbums.count,
                               self.upcomingAlbums[idx].title == title,
                               self.upcomingAlbums[idx].artist == artist {
                                let sized = appleArtwork(url, square: 300) ?? url
                                self.upcomingAlbums[idx] = AlbumCard(title: title, artist: artist, artworkURL: sized, date: self.upcomingAlbums[idx].date)
                            }
                        }
                        .store(in: &self.cancellables)
                }
                onDone?() // Called onDone
            }
            .store(in: &cancellables)
    }

    private func loadEverybodySongs(limit: Int = 16, onDone: (() -> Void)? = nil) {
        everybodySongsError = nil
        everybodySongCards = []

        AppleRSSAPI.globalTopSongs(finalLimit: limit)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion { self.everybodySongsError = err.localizedDescription }
                onDone?()
            }, receiveValue: { songs in
                self.everybodySongCards = songs.map {
                    SongCard(
                        artist: $0.artistName,
                        title: $0.title,
                        artworkURL: $0.artworkURL,
                        date: $0.releaseDate
                    )
                }
                if songs.isEmpty {
                    self.everybodySongsError = "No global listening data right now."
                }
            })
            .store(in: &cancellables)
    }

    private func loadGlobalSongs(limit: Int = 24, onDone: (() -> Void)? = nil) {
        trendingSongsError = nil
        globalSongCards = []

        AppleRSSAPI.globalTopSongs(finalLimit: limit)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion { self.trendingSongsError = err.localizedDescription }
                onDone?()
            }, receiveValue: { songs in
                self.globalSongCards = songs.map {
                    SongCard(
                        artist: $0.artistName,
                        title: $0.title,
                        artworkURL: $0.artworkURL,
                        date: $0.releaseDate
                    )
                }
                if songs.isEmpty {
                    self.trendingSongsError = "No global trending songs right now."
                }
            })
            .store(in: &cancellables)
    }

    private func loadUpdatedPlaylists(limit: Int = 20, onDone: (() -> Void)? = nil) {
        updatedPlaylistsError = nil
        updatedPlaylists = []

        apiService.fetchPlaylistsAdvanced(sort: .dateAdded, descending: true, filter: .all, limit: 100)
            .map { (playlists: [JellyfinAlbum]) -> [AlbumCard] in
                let filtered = playlists.filter { pl in
                    let tagSet = Set((pl.tags ?? []).map { $0.lowercased() })
                    return !tagSet.contains("replay") && tagSet.isDisjoint(with: self.blacklistedPlaylistTags)
                }
                let cards: [AlbumCard] = filtered.map { pl in
                    AlbumCard(
                        title: pl.name,
                        artist: "Playlist",
                        artworkURL: self.imageURL(for: pl.id, type: "Primary", maxWidth: 300, aspectRatio: nil, quality: 75), // Changed maxWidth and added quality
                        date: self.parseJellyfinDate(from: pl),
                        sourceId: pl.id          // ← keep the Jellyfin id here
                    )
                }
                return Array(cards.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
            }
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion { self.updatedPlaylistsError = err.localizedDescription }
                onDone?()
            }, receiveValue: { (cards: [AlbumCard]) in
                self.updatedPlaylists = cards
                if cards.isEmpty {
                    self.updatedPlaylistsError = "No recently updated playlists."
                }
            })
            .store(in: &cancellables)
    }

    private func loadEditorialTopAlbums(limit: Int = 19, onDone: (() -> Void)? = nil) {
        editorialError = nil
        editorialAlbums = []

        AppleRSSAPI.topAlbums(limit: limit)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion { self.editorialError = err.localizedDescription }
                onDone?()
            }, receiveValue: { albums in
                self.editorialAlbums = albums.map {
                    AlbumCard(
                        title: $0.title,
                        artist: $0.artistName,
                        artworkURL: $0.artworkURL,
                        date: $0.releaseDate
                    )
                }
                if albums.isEmpty {
                    self.editorialError = "No local editorial picks available for your region."
                    self.editorialAlbums = []
                }
            })
            .store(in: &cancellables)
    }

    private func loadFeed(onDone: (() -> Void)? = nil) {
        feedError = nil

        let albumsPublisher = apiService.fetchAlbums()
            .map { (albums: [JellyfinAlbum]) -> [JellyfinAlbum] in
                let sorted = albums.sorted { a, b in self.parseJellyfinDate(from: a) > self.parseJellyfinDate(from: b) }
                return Array(sorted.prefix(self.heroLimit))
            }
            .eraseToAnyPublisher()
        
        let playlistsPublisher = apiService.fetchPlaylistsAdvanced(sort: .dateAdded, descending: true, filter: .all, limit: playlistLimit)

        Publishers.Zip(albumsPublisher, playlistsPublisher)
            .map { (albums: [JellyfinAlbum], playlists: [JellyfinAlbum]) -> [NewFeedItem] in
                // self.sourceAlbums = albums // This line is no longer needed in VM
                let albumItems = self.mapAlbumsToFeedItems(albums)
                let playlistItems = self.mapPlaylistsToFeedItems(playlists)
                let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
                let merged = (day % 2 == 0) ? (albumItems + playlistItems) : (playlistItems + albumItems)
                return merged.sorted { $0.date > $1.date }
            }
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion { self.feedError = err.localizedDescription }
                onDone?()
            }, receiveValue: { items in
                self.feed = items
            })
            .store(in: &bag)
    }

    private func mapAlbumsToFeedItems(_ albums: [JellyfinAlbum]) -> [NewFeedItem] {
        albums.compactMap { album in
            let tagSet = Set((album.tags ?? []).map { $0.lowercased() })
            guard tagSet.isDisjoint(with: blacklistedAlbumTags) else { return nil }

            let releaseDate = parseJellyfinDate(from: album)
            let badge: String = {
                if let days = Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day, days > 14 { return "ALBUM" }
                return "NEW ALBUM"
            }()

            let subtitle: String = {
                if let names = album.artistItems?.compactMap({ $0.name }), !names.isEmpty { return names.joined(separator: ", ") }
                if let names = album.albumArtists?.compactMap({ $0.name }), !names.isEmpty { return names.joined(separator: ", ") }
                return "Unknown Artist"
            }()

            return NewFeedItem(
                id: album.id,
                kind: .album,
                title: album.name,
                subtitle: subtitle,
                badge: badge,
                date: releaseDate,
                imageURL: imageURL(for: album.id, type: "Banner", maxWidth: 1500, aspectRatio: "3:2", quality: 85) // Added quality
            )
        }
    }

    private func mapPlaylistsToFeedItems(_ playlists: [JellyfinAlbum]) -> [NewFeedItem] {
        playlists.compactMap { pl in
            let tagSet = Set((pl.tags ?? []).map { $0.lowercased() })
            guard tagSet.isDisjoint(with: blacklistedPlaylistTags) else { return nil }

            return NewFeedItem(
                id: pl.id,
                kind: .playlist,
                title: pl.name,
                subtitle: "Playlist",
                badge: "UPDATED PLAYLIST",
                date: parseJellyfinDate(from: pl),
                imageURL: imageURL(for: pl.id, type: "Menu", maxWidth: 1500, aspectRatio: "3:2")
            )
        }
    }

    // MARK: - Helpers (local to the VM file)

    private func prefetch(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        SDWebImagePrefetcher.shared.prefetchURLs(urls)
    }

    private func coverArtURL(releaseMBID: String?, releaseGroupMBID: String?) -> URL? {
        if let id = releaseMBID { return URL(string: "https://coverartarchive.org/release/\(id)/front?size=250") }
        if let id = releaseGroupMBID { return URL(string: "https://coverartarchive.org/release-group/\(id)/front?size=250") }
        return nil
    }
    
    @inline(__always)
    func imageURL(for itemId: String,
                  type: String = "Primary",
                  maxWidth: Int = 600,
                  aspectRatio: String? = nil,
                  quality: Int = 90) -> URL? {
        guard !apiService.serverURL.isEmpty else { return nil }
        var c = URLComponents(string: "\(apiService.serverURL)Items/\(itemId)/Images/\(type)")
        var items: [URLQueryItem] = [
            .init(name: "maxWidth", value: "\(maxWidth)"),
            .init(name: "quality", value: "\(quality)"),
            .init(name: "format", value: "jpg"),
            .init(name: "enableImageEnhancers", value: "false"),
            .init(name: "api_key", value: apiService.authToken)
        ]
        if let ar = aspectRatio { items.append(.init(name: "aspectRatio", value: ar)) }
        c?.queryItems = items
        return c?.url
    }

    private func parseJellyfinDate(from item: JellyfinAlbum) -> Date {
        let iso = ISO8601DateFormatter()
        for opts in [
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
            ISO8601DateFormatter.Options([.withFullDate])
        ] {
            iso.formatOptions = opts
            for s in [item.premiereDate, item.releaseDate, item.dateCreated].compactMap({ $0 }) {
                if let d = iso.date(from: s) { return d }
            }
        }
        if let year = item.productionYear,
           let d = Calendar.current.date(from: DateComponents(year: year)) { return d }
        return .distantPast
    }
}


// MARK: - Main View
struct NewView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @AppStorage("lb_username") private var lbUsername: String = "fwail_094"

    @StateObject private var vm: NewScreenViewModel // Updated to NewScreenViewModel

    // Init for NewView to initialize the ViewModel
    init(apiService: JellyfinAPIService? = nil, lb: String? = nil) {
        // SwiftUI init trick so @StateObject can be created with env later:
        _vm = StateObject(wrappedValue: NewScreenViewModel(api: (apiService ?? JellyfinAPIService.shared), // Updated to NewScreenViewModel
                                                     lbUsername: lb ?? "fwail_094"))
    }

    @State private var navPath: [NewRoute] = []   // <— add this

    var body: some View {
        NavigationStack(path: $navPath) {         // <— bind the path
            Group {
                if !vm.isLoaded || vm.screenIsLoading { // Use vm.isLoaded and vm.screenIsLoading
                    // FULL-SCREEN LOADER
                    ZStack {
                        Color(.systemBackground).ignoresSafeArea()
                        ProgressView("Loading…")
                            .progressViewStyle(.circular)
                            .font(.headline)
                    }
                } else {
                    // YOUR EXISTING SCROLLVIEW CONTENT
                    content // <— Use the @ViewBuilder helper here
                }
            }
            .navigationTitle("New")
            .navigationDestination(for: NewRoute.self) { route in // <— destinations
                switch route {
                case .album(let id):
                    AlbumDetailRouteView(itemId: id) // ← wrapper
                case .playlist(let id):
                    PlaylistDetailRouteView(itemId: id) // ← wrapper
                }
            }
            .task { await vm.loadAllOnce() } // <— Call loadAllOnce from the VM
            .refreshable { // optional pull-to-refresh
                vm.isLoaded = false
                vm.hasLoadedOnce = false // Reset this too for pull-to-refresh
                await vm.loadAllOnce()
            }
        }
        .environmentObject(apiService) // ensure VM has same instance if you injected
    }

    // @ViewBuilder for your ScrollView content
    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // 1. Banners
                if !vm.feed.isEmpty {
                    NewTopCarousel(items: vm.feed) { item in
                        switch item.kind {
                        case .album:
                            navPath.append(.album(id: item.id))
                        case .playlist:
                            navPath.append(.playlist(id: item.id))
                        }
                    }
                    .padding(.top, 16)
                }

                // 2. Latest Songs rows
                VStack(alignment: .leading, spacing: 8) {
                    if !vm.freshCards.isEmpty {
                        LatestSongsCarousel(
                            title: "Latest Songs",
                            items: vm.freshCards.sorted { $0.date ?? .distantPast > $1.date ?? .distantPast }
                        ) { card in
                            openInYouTubeMusic(artist: card.artist, title: card.title)
                        }
                    } else if let error = vm.freshError { // Show specific error if no data
                        Text(error)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .padding(.horizontal)
                    }
                }

                // 3. New Releases
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("New Releases").font(.title2).bold()
                        Image(systemName: "chevron.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)

                    if !vm.newAlbums.isEmpty {
                        let rows = [GridItem(.fixed(180), spacing: 12), GridItem(.fixed(180), spacing: 12)]
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: rows, spacing: 12) {
                                ForEach(vm.newAlbums) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        ZStack {
                                            Rectangle().fill(Color(.systemGray5))
                                            let px = Int(150 * UIScreen.main.scale)
                                            let sizedURL = appleArtwork(item.artworkURL, square: 300) ?? item.artworkURL

                                            WebImage(
                                                url: sizedURL,
                                                options: [.scaleDownLargeImages, .continueInBackground],
                                                context: thumbContext(px: px)
                                            ) // Changed options and added context
                                            .resizable()
                                            .indicator(.activity)
                                            .transition(.fade)
                                            .scaledToFill()
                                        }
                                        .frame(width: 150, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                                            Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .frame(width: 150, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        openInYouTubeMusic(artist: item.artist, title: item.title)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 2 * 180 + 12)
                            .padding(.bottom, 8)
                        }
                    } else if let error = vm.newAlbumsError { // Show specific error if no data
                        Text(error)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .padding(.horizontal)
                    }
                } // Fixed else if placement

                // 4. Updated Playlists
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Updated Playlists").font(.title2).bold()
                        Image(systemName: "chevron.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)

                    if !vm.updatedPlaylists.isEmpty {
                        let rows = [GridItem(.fixed(180), spacing: 12), GridItem(.fixed(180), spacing: 12)]
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: rows, spacing: 12) {
                                ForEach(vm.updatedPlaylists) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        ZStack {
                                            Rectangle().fill(Color(.systemGray5))
                                            let px = Int(150 * UIScreen.main.scale)
                                            let sizedURL = appleArtwork(item.artworkURL, square: 300) ?? item.artworkURL
                                            WebImage(
                                                url: sizedURL,
                                                options: [.scaleDownLargeImages, .continueInBackground],
                                                context: thumbContext(px: px)
                                            ) // Changed options and added context
                                            .resizable()
                                            .indicator(.activity)
                                            .transition(.fade)
                                            .scaledToFill()
                                        }
                                        .frame(width: 150, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title)
                                                .font(.subheadline).fontWeight(.semibold)
                                                .lineLimit(1)
                                            Text(item.artist)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(width: 150, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let id = item.sourceId {           // ← use the id we stored
                                            navPath.append(.playlist(id: id))  // ← push detail route
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 2 * 180 + 12)
                            .padding(.bottom, 4)
                        }
                    } else if let error = vm.updatedPlaylistsError { // Show specific error if no data
                        Text(error)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .padding(.horizontal)
                    }
                }

                // 5. Everybody's listening to…
                VStack(alignment: .leading, spacing: -12) {   // ← tightened
                    HStack(spacing: 6) {
                        Text("Everyone's Listening To…").font(.title2).bold()
                        Image(systemName: "chevron.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)

                    if !vm.everybodySongCards.isEmpty {
                        LatestSongsCarousel(
                            title: "", // keep empty to hide internal header
                            items: vm.everybodySongCards
                        ) { card in
                            openInYouTubeMusic(artist: card.artist, title: card.title)
                        }
                    } else if let error = vm.everybodySongsError {
                        Text(error)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .padding(.horizontal)
                    }
                }

                // 6. Local Trends
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Local Trends").font(.title2).bold()
                        Spacer()
                        Image(systemName: "chevron.right").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    if !vm.editorialAlbums.isEmpty {
                        OneRowAlbumCarousel(
                            title: "", // Empty title to hide header inside component
                            items: vm.editorialAlbums
                        ) { card in
                            openInYouTubeMusic(artist: card.artist, title: card.title)
                        }
                    } else if let error = vm.editorialError { // Show specific error if no data
                        Text(error)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .padding(.horizontal)
                    } else {
                        Text("No local editorial picks available for your region.").foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 60).padding(.horizontal)
                    }
                }
                    
                // 7. Trending Songs
                VStack(alignment: .leading, spacing: -12) {   // ← tightened
                    HStack(spacing: 6) {
                        Text("Trending Songs").font(.title2).bold()
                        Image(systemName: "chevron.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)

                    if !vm.globalSongCards.isEmpty {
                        LatestSongsCarousel(
                            title: "", // keep empty to hide internal header
                            items: vm.globalSongCards
                        ) { card in
                            openInYouTubeMusic(artist: card.artist, title: card.title)
                        }
                    } else if let error = vm.trendingSongsError {
                        Text(error)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .padding(.horizontal)
                    }
                }

                // 8. Upcoming
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Upcoming").font(.title2).bold()
                        Image(systemName: "chevron.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)

                    if !vm.upcomingAlbums.isEmpty {
                        OneRowAlbumCarousel(
                            title: "", // Empty title to hide header inside component
                            items: Array(vm.upcomingAlbums.prefix(10))
                        ) { card in
                            openInYouTubeMusic(artist: card.artist, title: card.title)
                        }
                        .padding(.top, -4) // tiny extra pull-up to match other rows
                    } else if let error = vm.upcomingError { // Show specific error if no data
                        Text(error)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .padding(.horizontal)
                    } else {
                        Text("No upcoming albums right now.").foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 60).padding(.horizontal)
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics (optional UI)
    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics").font(.footnote).fontWeight(.semibold)
            Group {
                Text("LB source: \(vm.diag_lbSource)")
                Text("LB HTTP: \(vm.diag_lbHTTP) (\(vm.diag_lbBytes) bytes)")
                Text("LB items: \(vm.diag_lbCount)")
                if let u = vm.diag_openedURL { Text("Last opened URL: \(u)").lineLimit(1) }
                if let e = vm.diag_lastError { Text("Last error: \(e)").foregroundStyle(.secondary) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
        }
    }
}


// MARK: - Routing wrappers that fetch by ID, then show your real detail UIs
private struct AlbumDetailRouteView: View {
    let itemId: String
    @EnvironmentObject var apiService: JellyfinAPIService
    @State private var album: JellyfinAlbum?
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading album…")
            } else if let error = error {
                Text(error).foregroundColor(.secondary)
            } else if let album = album {
                // Use your *existing* detail screen init here:
                AlbumDetailView(album: album)   // ← this matches your real initializer
                    .environmentObject(apiService)
            }
        }
        .task { await fetchAlbum() }
    }

    @MainActor private func fetchAlbum() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let url = URL(string: "\(apiService.serverURL)Items/\(itemId)?api_key=\(apiService.authToken)") else {
                throw URLError(.badURL)
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(JellyfinAlbum.self, from: data)
            self.album = decoded
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PlaylistDetailRouteView: View { // Modified
    let itemId: String
    @EnvironmentObject var apiService: JellyfinAPIService

    var body: some View {
        PlaylistDetailView(playlistId: itemId) // Updated to match real initializer
            .environmentObject(apiService)
    }
}
