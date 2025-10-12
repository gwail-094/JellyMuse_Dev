import SwiftUI
import Combine
import AVKit
import AVFoundation
import UIKit

struct ArtistDetailView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @Environment(\.dismiss) private var dismiss
    
    // MARK: A. Environment & New State
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase

    let artist: JellyfinArtistItem
    
    // Define the accent color for the star and play button
    private let accentRed = Color(red: 0.95, green: 0.20, blue: 0.30)

    // Data
    @State private var topSongs: [JellyfinTrack] = []
    @State private var albums: [JellyfinAlbum] = []
    @State private var similar: [JellyfinArtistItem] = []
    @State private var albumTitlesById: [String: String] = [:]
    // REMOVED DUPLICATE: @State private private var blacklistedAlbumIds: Set<String> = []
    
    // MARK: 1) Music Videos State
    @State private var musicVideos: [ArtistVideo] = []
    @State private var blacklistedAlbumIds: Set<String> = [] // <-- Keeping the correct, single declaration here

    // UI / state
    @State private var isFavorite = false
    @State private var isLoadingTop = false
    @State private var isLoadingAlbums = false
    @State private var isLoadingSimilar = false
    @State private var downloading: Set<String> = []
    @State private var cancellables = Set<AnyCancellable>()
    @State private var bottomInset: CGFloat = 0
    @State private var artistPlayer: AVPlayer? = nil
    @State private var animatedArtistURL: URL? = nil
    @Namespace private var albumZoomNS
    
    // MARK: 2) Videos API instance
    private let videosAPI = try? MusicVideosAPI(baseURLString: "http://192.168.1.169/videos/") // <<< KEPT INSTANCE

    // Layout
    private let horizontalPad: CGFloat = 20
    private let sectionLeading: CGFloat = 22
    private let sectionTitleSize: CGFloat = 22
    private let heroHeightRatio: CGFloat = 0.45
    
    // Padding needed to prevent vertical clipping during the context menu zoom animation
    private let carouselPadding: CGFloat = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                latestReleaseSection
                topSongsSection
                albumsSection
                musicVideosSection
                similarArtistsSection
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .scrollIndicators(.automatic)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: bottomInset)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                DualActionPill(
                    isFavorite: isFavorite,
                    accentRed: accentRed,
                    onToggleFavorite: { toggleFavorite() },
                    onCreateStation: { createArtistStation() }
                )
            }
        }
        .onAppear {
            isVisible = true

            loadAll()
            loadFavoriteState()
            fetchArtistAnimatedURL()

            // MARK: 3) Fetch using fetchFromIndex (REPLACED FETCH)
            videosAPI?
                .fetchFromIndex(indexFile: "musicvideos.json",
                                artistId: artist.id,
                                artistName: artist.name)
                .receive(on: DispatchQueue.main)
                .sink { self.musicVideos = $0 }
                .store(in: &cancellables)

            // resume if we already had a player, else create from URL
            if let p = artistPlayer {
                p.play()
            } else if animatedArtistURL != nil {
                setupArtistVideoIfAvailable()
            }
        }
        .onChange(of: animatedArtistURL) { _ in
            // create the player if we now have a URL (e.g., after tags load)
            if artistPlayer == nil {
                setupArtistVideoIfAvailable()
            }
        }
        .onDisappear {
            isVisible = false
            artistPlayer?.pause()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if isVisible { artistPlayer?.play() }
            case .inactive, .background:
                artistPlayer?.pause()
            @unknown default:
                break
            }
        }
    }

    // MARK: - Hero (Parallax Fixed)

    private var hero: some View {
        let heroHeight = UIScreen.main.bounds.height * heroHeightRatio

        return ParallaxHeader(minHeight: heroHeight) {
            GeometryReader { innerGeo in
                let minY = innerGeo.frame(in: .global).minY
                let overscrollAmount = max(0, minY)

                ZStack(alignment: .bottomLeading) {
                    // 1. Background media: prefer AnimatedArtist video, else static image
                    Group {
                        if animatedArtistURL != nil {
                            VideoPlayerView(
                                player: artistPlayer,
                                onReady: { /* no-op: no crossfade needed */ },
                                onFail:  { /* optional logging */ }
                            )
                            .background(Color.black)
                            .allowsHitTesting(false)
                        } else {
                            AsyncImage(url: apiService.imageURL(for: artist.id)) { phase in
                                switch phase {
                                case .empty: Color(.systemGray5)
                                case .success(let img): img.resizable().scaledToFill()
                                case .failure: Color(.systemGray5)
                                @unknown default: Color(.systemGray5)
                                }
                            }
                        }
                    }
                    .frame(width: innerGeo.size.width, height: innerGeo.size.height)
                    .clipped()
                      
                    // 2. Dark Gradient Overlay
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.8)],
                        startPoint: .center, endPoint: .bottom
                    )
                    .frame(width: innerGeo.size.width, height: innerGeo.size.height)
                      
                    // 3. Text/Button Overlay
                    VStack(alignment: .leading) {
                        Spacer()
                        HStack(alignment: .lastTextBaseline, spacing: 12) {
                            Text(artist.name)
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 12)

                            Button(action: shufflePlayArtist) {
                                ZStack {
                                    Circle().fill(accentRed).frame(width: 42, height: 42)
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                        .padding(.horizontal, horizontalPad)
                        .padding(.bottom, 16)
                    }
                    .frame(width: innerGeo.size.width, height: innerGeo.size.height)
                    .offset(y: -overscrollAmount)
                }
                .frame(width: innerGeo.size.width, height: innerGeo.size.height)
            }
        }
    }
    
    // MARK: - Latest Release (big card) - UPDATED FOR CONTEXT MENU

    @ViewBuilder
    private var latestReleaseSection: some View {
        let sorted = albumsSortedNewestFirst
        if let latest = sorted.first {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink {
                    AlbumDetailView(album: latest)
                        .environmentObject(apiService)
                        .navigationTransition(.zoom(sourceID: "album-art-latest-\(latest.id)", in: albumZoomNS))
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        AsyncImage(url: apiService.imageURL(for: latest.id)) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            case .empty: ZStack { Color.gray.opacity(0.25); ProgressView() }
                            default: ZStack { Color.gray.opacity(0.25); Image(systemName: "photo").foregroundColor(.secondary) }
                            }
                        }
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .matchedTransitionSource(id: "album-art-latest-\(latest.id)", in: albumZoomNS)

                        VStack(alignment: .leading, spacing: 4) {
                            // SUPERTITLE: Release Date
                            Text(releaseDateText(releaseDate(for: latest)))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)

                            // MARK: 4) TITLE + Explicit badge
                            HStack(spacing: 4) {
                                Text(latest.name)
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)

                                if latest.isExplicit {
                                    Image(systemName: "e.square.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                            }

                            // SUBTITLE: Song Count
                            let countText = songCountText(latest)
                            if !countText.isEmpty {
                                Text(countText)
                                    .font(.subheadline.weight(.regular))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // --- NEW: Add context menu for the latest release album ---
                .contextMenu(menuItems: {
                    Button { albumPlay(latest) }      label: { Label("Play",        systemImage: "play.fill") }
                    Button { albumShuffle(latest) }   label: { Label("Shuffle",     systemImage: "shuffle") }
                    Button { albumQueueNext(latest) } label: { Label("Play Next",   systemImage: "text.insert") }
                    Button {
                        albumToggleFavorite(latest)
                    } label: {
                        Label((latest.userData?.isFavorite ?? false) ? "Undo Favorite" : "Favorite",
                              systemImage: (latest.userData?.isFavorite ?? false) ? "star.fill" : "star")
                    }
                    Button { albumDownload(latest) }  label: { Label("Download",    systemImage: "arrow.down.circle") }
                }, preview: {
                    AlbumContextPreviewTile(
                        title: latest.name,
                        subtitle: primaryAlbumArtist(latest),
                        imageURL: apiService.imageURL(for: latest.id),
                        corner: 14
                    )
                })
            }
            .padding(.horizontal, sectionLeading)
        }
    }


    // MARK: - Top Songs (ADJUSTED)

    @ViewBuilder
    private var topSongsSection: some View {
        if !topSongs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ArtistSectionHeaderLink(title: "Top Songs") {
                    AllArtistTopSongsView(
                        artistName: artist.name,
                        tracks: topSongs,
                        albumTitlesById: albumTitlesById   // ✅ gives subtitles + searchable by album
                    )
                    .environmentObject(apiService)
                }

                TabView {
                    let pages = paged(topSongs, size: 4)
                    ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(page.enumerated()), id: \.element.id) { index, track in
                                VStack(spacing: 0) {
                                    topSongRow(track)
                                    if index < page.count - 1 {
                                        Divider()
                                            .background(Color.gray.opacity(0.3))
                                            .padding(.leading, 52)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, sectionLeading)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .frame(height: topSongsHeight)
            }
        }
    }

    private func topSongRow(_ track: JellyfinTrack) -> some View {
        let thumb = AsyncImage(url: smallCoverURL(for: track)) { phase in
            switch phase {
            case .empty:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.25))
                    ProgressView().scaleEffect(0.8)
                }
            case .success(let img): img.resizable().scaledToFill()
            case .failure:
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.25))
                    Image(systemName: "music.note").foregroundColor(.secondary)
                }
            @unknown default:
                Color(.systemGray5)
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 4))

        let title = track.name ?? "Unknown Track"
        let id = (track.serverId ?? track.id)

        let trackExplicit: Bool = {
            if let tags = track.tags {
                return tags.contains { $0.caseInsensitiveCompare("Explicit") == .orderedSame }
            }
            return track.isExplicit
        }()

        let albumObj = album(forId: track.albumId)
        let albumName = albumObj?.name ?? albumTitlesById[track.albumId ?? ""] ?? ""

        let yearText: String = {
            if let y = albumObj?.productionYear, y > 0 { return "· \(String(y))" }
            return ""
        }()

        return HStack(spacing: 10) {
            thumb

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if trackExplicit {
                        Image(systemName: "e.square.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }

                if !albumName.isEmpty {
                    HStack(spacing: 4) {
                        Text(albumName)
                        if !yearText.isEmpty {
                            Text(verbatim: yearText)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            
            // MARK: 3) Ellipsis button for actions
            Menu {
                Button { queueNext(track) }      label: { Label("Play Next", systemImage: "text.insert") }
                Button { createStation(from: track) } label: { Label("Create Station", systemImage: "badge.plus.radiowaves.right") }
                if (track.albumId ?? "").isEmpty == false { // Only show if albumId exists
                    Button { goToAlbum(track) }      label: { Label("Go to Album", systemImage: "square.stack") }
                }
                Button { favoriteTrack(track) }  label: { Label("Favorite", systemImage: "star") }
                Button { downloadOne(track) }    label: { Label("Download", systemImage: "arrow.down.circle") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.primary)
                    .contentShape(Rectangle())
            }

            if downloading.contains(id) {
                ProgressView()
            }
        }
        .frame(height: 46)
        .contentShape(Rectangle())
        .onTapGesture { playSingle(track) }
        .contextMenu(menuItems: {
            Button { queueNext(track) }  label: { Label("Play Next",       systemImage: "text.insert") }
            Button { addToQueue(track) } label: { Label("Add to Queue",  systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { downloadOne(track) } label: { Label("Download",      systemImage: "arrow.down.circle") }
            Button { goToAlbum(track) }  label: { Label("Go to Album",   systemImage: "square.stack.3d.up") }
        }, preview: {
            let coverURL = smallCoverURL(for: track)
            let albumObj = album(forId: track.albumId)
            let albumName = albumObj?.name ?? albumTitlesById[track.albumId ?? ""] ?? ""
            let yearText = (albumObj?.productionYear).flatMap { $0 > 0 ? "· \($0)" : "" } ?? ""
            let subtitle = [albumName, yearText].filter { !$0.isEmpty }.joined(separator: " ")

            TrackContextPreviewRow(
                title: track.name ?? "Unknown Track",
                subtitle: subtitle,
                imageURL: coverURL
            )
        })
    }

    private var topSongsHeight: CGFloat {
        let rowH: CGFloat = 46
        let rows = min(topSongs.count, 4)
        return CGFloat(rows) * rowH
    }

    // MARK: - Albums (ADJUSTED for scrollClipDisabled)

    @ViewBuilder
    private var albumsSection: some View {
        let sorted = albumsSortedNewestFirst

        if !sorted.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ArtistSectionHeaderLink(title: "Albums") {
                    AllArtistAlbumsView(
                        artistName: artist.name,
                        albums: albumsSortedNewestFirst
                    )
                    .environmentObject(apiService)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(sorted, id: \.id) { album in
                            NavigationLink {
                                AlbumDetailView(album: album)
                                    .environmentObject(apiService)
                                    .navigationTransition(.zoom(sourceID: "album-art-carousel\(album.id)", in: albumZoomNS))
                            } label: {
                                albumCard(album)
                                    .matchedTransitionSource(id: "album-art-carousel\(album.id)", in: albumZoomNS)
                            }
                            .buttonStyle(.plain)
                            .contextMenu(menuItems: {
                                Button { albumPlay(album) }      label: { Label("Play",        systemImage: "play.fill") }
                                Button { albumShuffle(album) }   label: { Label("Shuffle",     systemImage: "shuffle") }
                                Button { albumQueueNext(album) } label: { Label("Play Next",   systemImage: "text.insert") }
                                Button {
                                    albumToggleFavorite(album)
                                } label: {
                                    Label((album.userData?.isFavorite ?? false) ? "Undo Favorite" : "Favorite",
                                          systemImage: (album.userData?.isFavorite ?? false) ? "star.fill" : "star")
                                }
                                Button { albumDownload(album) }  label: { Label("Download",    systemImage: "arrow.down.circle") }
                            }, preview: {
                                AlbumContextPreviewTile(
                                    title: album.name,
                                    subtitle: primaryAlbumArtist(album),
                                    imageURL: apiService.imageURL(for: album.id),
                                    corner: 14
                                )
                            })
                        }
                    }
                    .padding(.horizontal, sectionLeading)
                }
                // --- FIX 3 UPDATED: Use scrollClipDisabled for iOS 17+ (Cleanest) ---
                .scrollClipDisabled(true)
                .padding(.bottom, -12) // Keep your original bottom padding adjustment if needed for spacing
            }
        }
    }
    
    // MARK: 4. Music Videos Section (ADJUSTED)
    @ViewBuilder
    private var musicVideosSection: some View {
        if !musicVideos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ArtistSectionHeaderLink(title: "Music Videos") {
                    AllArtistMusicVideosView(
                        artistName: artist.name,
                        musicVideos: musicVideos
                    )
                }
              
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(musicVideos) { video in
                            VStack(alignment: .leading, spacing: 6) {
                                AsyncImage(url: video.thumbnailURL) { phase in
                                    switch phase {
                                    case .success(let img): img.resizable().scaledToFill()
                                    case .empty: ZStack { Color.gray.opacity(0.25); ProgressView() }
                                    default: ZStack { Color.gray.opacity(0.25); Image(systemName: "play.rectangle").foregroundColor(.secondary) }
                                    }
                                }
                                .frame(width: 180, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                // Title — semibold
                                Text(video.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .frame(width: 180, alignment: .leading) // <--- FIX 2: Added frame
                                    .truncationMode(.tail)                  // <--- FIX 2: Added truncationMode

                                // Subtitle — release year (secondary, regular)
                                if !video.yearText.isEmpty {
                                    Text(video.yearText)
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .onTapGesture {
                                if let url = video.watchURL { UIApplication.shared.open(url) }
                            }
                        }
                    }
                    .padding(.horizontal, sectionLeading)
                }
            }
        }
    }

    private func albumCard(_ album: JellyfinAlbum) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            AsyncImage(url: apiService.imageURL(for: album.id)) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.25))
                        ProgressView().scaleEffect(0.9)
                    }
                case .success(let img): img.resizable().scaledToFill()
                case .failure:
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.25))
                        Image(systemName: "photo").foregroundColor(.secondary)
                    }
                @unknown default:
                    Color(.systemGray5)
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 4) {
                Text(album.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if album.isExplicit {
                    Image(systemName: "e.square.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }

            if let year = album.productionYear, year > 0 {
                Text(String(year))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 150)
        .contentShape(Rectangle())
    }

    // MARK: - Similar artists

    @ViewBuilder
    private var similarArtistsSection: some View {
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Similar Artists")
                    .font(.system(size: sectionTitleSize, weight: .semibold))
                    .padding(.leading, sectionLeading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(similar, id: \.id) { a in
                            NavigationLink {
                                ArtistDetailView(artist: a)
                                    .environmentObject(apiService)
                            } label: {
                                VStack(spacing: 8) {
                                    AsyncImage(url: apiService.imageURL(for: a.id)) { phase in
                                        switch phase {
                                        case .empty:
                                            ZStack { Circle().fill(Color.gray.opacity(0.25)); ProgressView().scaleEffect(0.8) }
                                        case .success(let img):
                                            img.resizable().scaledToFill()
                                        case .failure:
                                            Image(systemName: "person.crop.circle.fill")
                                                .resizable().scaledToFill().foregroundColor(.secondary)
                                        @unknown default:
                                            Color(.systemGray5)
                                        }
                                    }
                                    .frame(width: 96, height: 96)
                                    .clipShape(Circle())

                                    Text(a.name)
                                        .font(.footnote)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .frame(width: 92)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, sectionLeading)
                }
            }
        }
    }

    // MARK: - Release date + sorting helpers

    private func releaseDate(for a: JellyfinAlbum) -> Date? {
        // Parse ISO-8601 (with/without fractional seconds)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Prefer explicit ReleaseDate, then PremiereDate, then DateCreated
        if let iso = a.releaseDate, !iso.isEmpty, let d = f.date(from: iso) {
            return d
        }
        if let iso = a.premiereDate, !iso.isEmpty, let d = f.date(from: iso) {
            return d
        }
        if let y = a.productionYear, y > 0 {
            var comp = DateComponents()
            comp.year = y; comp.month = 1; comp.day = 1
            return Calendar.current.date(from: comp)
        }
        if let iso = a.dateCreated, !iso.isEmpty, let d = f.date(from: iso) {
            return d
        }
        return nil
    }

    private var albumsSortedNewestFirst: [JellyfinAlbum] {
        albums.sorted {
            let d0 = releaseDate(for: $0)
            let d1 = releaseDate(for: $1)
            switch (d0, d1) {
            case let (l?, r?): return l > r
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return ($0.name) < ($1.name)   // stable fallback
            }
        }
    }

    private func songCountText(_ a: JellyfinAlbum) -> String {
        let n = a.childCount ?? 0
        if n == 0 { return "" }
        return n == 1 ? "1 song" : "\(n) songs"
    }

    private func releaseDateText(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date).uppercased()
    }

    // MARK: - Blacklist Helpers (1)
    
    private func isBlacklistedTag(_ tag: String) -> Bool {
        let t = tag.lowercased()
        return t == "blacklist" || t == "blacklisthv"
    }

    private func isBlacklistedAlbum(_ a: JellyfinAlbum) -> Bool {
        let tags = a.tags ?? []
        return tags.contains(where: isBlacklistedTag)
    }

    private func applyBlacklistToTopSongs() {
        guard !blacklistedAlbumIds.isEmpty else { return }
        topSongs.removeAll { t in
            guard let aid = t.albumId, !aid.isEmpty else { return false } // keep singles / no-album
            return blacklistedAlbumIds.contains(aid)
        }
    }
    // MARK: - Helpers (rest)

    /// Do a quick HEAD to see if the mp4 exists on Nginx
    private func probeVideoExists(at url: URL, completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    private func setupArtistVideoIfAvailable() {
        guard artistPlayer == nil else { return }
        guard let url = animatedArtistURL else {
            artistPlayer?.pause()
            return
        }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0.3

        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .none
        p.automaticallyWaitsToMinimizeStalling = false

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            p.seek(to: .zero)
            p.play()
        }

        p.play()
        artistPlayer = p
    }

    private func album(forId id: String?) -> JellyfinAlbum? {
        guard let id else { return nil }
        return albums.first(where: { $0.id == id })
    }

    private func paged<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [] }
        var pages: [[T]] = []
        var i = 0
        while i < array.count {
            let end = min(i + size, array.count)
            pages.append(Array(array[i..<end]))
            i += size
        }
        return pages
    }

    private func smallCoverURL(for track: JellyfinTrack) -> URL? {
        if let aid = track.albumId, !aid.isEmpty { return apiService.imageURL(for: aid) }
        return apiService.imageURL(for: track.id)
    }
    
    private func primaryAlbumArtist(_ album: JellyfinAlbum) -> String {
        if let names = album.albumArtists?.compactMap({ $0.name }), !names.isEmpty {
            return names.joined(separator: ", ")
        }
        if let names = album.artistItems?.compactMap({ $0.name }), !names.isEmpty {
            return names.joined(separator: ", ")
        }
        return artist.name
    }

    // MARK: - Data (Updated)
    
    /// Fetch the artist tag from Jellyfin (Fields=Tags). Falls back to probing Nginx /artwork/<Artist>/artist.mp4
    private func fetchArtistAnimatedURL() {
        guard !apiService.userId.isEmpty,
              !apiService.serverURL.isEmpty,
              !apiService.authToken.isEmpty
        else { return }

        // Same style as your loadFavoriteState()
        var comps = URLComponents(string: "\(apiService.serverURL)Users/\(apiService.userId)/Items")
        comps?.queryItems = [
            URLQueryItem(name: "Ids", value: artist.id),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicArtist"),
            URLQueryItem(name: "Fields", value: "Tags"),
            URLQueryItem(name: "Recursive", value: "false")
        ]
        guard let url = comps?.url else { return }

        var req = URLRequest(url: url)
        req.addValue(apiService.authorizationHeader(withToken: apiService.authToken),
                     forHTTPHeaderField: "X-Emby-Authorization")

        URLSession.shared.dataTaskPublisher(for: req)
            .map(\.data)
            .decode(type: JellyfinItemsWithTagsResponse.self, decoder: JSONDecoder())
            .map { $0.items?.first?.tags ?? [] }
            .catch { err -> Just<[String]> in
                print("⚠️ fetchArtistAnimatedURL decode error:", err.localizedDescription)
                return Just([])
            }
            .receive(on: DispatchQueue.main)
            .sink { tags in
                print("Artist tags:", tags)

                // 1) Try the explicit AnimatedArtist= tag first
                if let urlFromTag = tags.compactMap({ tag -> URL? in
                    let lower = tag.lowercased()
                    guard lower.hasPrefix("animatedartist=") else { return nil }
                    let raw = String(tag.split(separator: "=", maxSplits: 1).last ?? "")
                    let enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
                    return URL(string: enc)
                }).first {
                    self.animatedArtistURL = urlFromTag
                    return
                }

                // 2) Fallback: probe Nginx artist.mp4 location
                let encodedName = artist.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artist.name
                if let fallbackURL = URL(string: "http://192.168.1.169/artwork/\(encodedName)/artist.mp4") {
                    self.probeVideoExists(at: fallbackURL) { exists in
                        if exists { self.animatedArtistURL = fallbackURL }
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Minimal response just to read Tags for a single item
    private struct JellyfinItemsWithTagsResponse: Decodable {
        let items: [Item]?
        struct Item: Decodable {
            let tags: [String]?
            enum CodingKeys: String, CodingKey { case tags = "Tags" }
        }
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }


    private func loadAll() {
        // --- TOP SONGS FETCH (UPDATED for Blacklist 1) ---
        isLoadingTop = true
        apiService.fetchArtistTopSongs(artistId: artist.id, limit: 24)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in isLoadingTop = false },
                      receiveValue: { incomingTracks in
                          self.topSongs = incomingTracks
                          self.applyBlacklistToTopSongs()
                      })
            .store(in: &cancellables)

        // --- ALBUMS FETCH (UPDATED for Blacklist 1) ---
        isLoadingAlbums = true
        apiService.fetchArtistAlbums(artistId: artist.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in isLoadingAlbums = false },
                      receiveValue: { fetched in
                          // 1) remember IDs of blacklisted albums
                          let banned = Set(fetched.filter { isBlacklistedAlbum($0) }.map { $0.id })
                          self.blacklistedAlbumIds = banned

                          // 2) keep only non-blacklisted albums for display
                          let visible = fetched.filter { !banned.contains($0.id) }
                          self.albums = visible

                          // 3) title map (for subtitles)
                          var map: [String: String] = [:]
                          for a in visible { map[a.id] = a.name }
                          self.albumTitlesById = map

                          // 4) also purge blacklisted tracks from Top Songs
                          self.applyBlacklistToTopSongs()
                      })
            .store(in: &cancellables)

        // --- SIMILAR ARTISTS FETCH (UPDATED for persistent order 2) ---
        isLoadingSimilar = true
        apiService.fetchSimilarArtists(artistId: artist.id, limit: 24)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in isLoadingSimilar = false },
                      receiveValue: { incoming in
                          // Persist order for this view lifetime (sort to be deterministic)
                          if self.similar.isEmpty {
                              self.similar = incoming.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                          }
                      })
            .store(in: &cancellables)
    }

    private func loadFavoriteState() {
        guard !apiService.userId.isEmpty,
              !apiService.serverURL.isEmpty,
              !apiService.authToken.isEmpty
        else { return }

        var comps = URLComponents(string: "\(apiService.serverURL)Users/\(apiService.userId)/Items")
        comps?.queryItems = [
            URLQueryItem(name: "Ids", value: artist.id),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicArtist"),
            URLQueryItem(name: "Fields", value: "UserData"),
            URLQueryItem(name: "Recursive", value: "false")
        ]
        guard let url = comps?.url else { return }

        var req = URLRequest(url: url)
        req.addValue(apiService.authorizationHeader(withToken: apiService.authToken),
                     forHTTPHeaderField: "X-Emby-Authorization")

        URLSession.shared.dataTaskPublisher(for: req)
            .map(\.data)
            .decode(type: JellyfinAlbumResponse.self, decoder: JSONDecoder())
            .map { $0.items?.first?.userData?.isFavorite ?? false }
            .replaceError(with: false)
            .receive(on: DispatchQueue.main)
            .sink { self.isFavorite = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Actions (New Helpers Added for Ellipsis Menu 3)

    private func favoriteTrack(_ track: JellyfinTrack) {
        let trackId = track.serverId ?? track.id
        apiService.markItemFavorite(itemId: trackId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { })
            .store(in: &cancellables)
    }

    private func createStation(from seed: JellyfinTrack) {
        let seedId = seed.serverId ?? seed.id
        apiService.fetchInstantMix(itemId: seedId, limit: 80)
            .replaceError(with: [])
            .map { mix -> [JellyfinTrack] in
                var seen = Set<String>(); var out: [JellyfinTrack] = []
                func add(_ t: JellyfinTrack) {
                    let key = t.serverId ?? t.id
                    if seen.insert(key).inserted { out.append(t) }
                }
                add(seed); mix.forEach(add)
                return out
            }
            .receive(on: DispatchQueue.main)
            .sink { queue in
                guard !queue.isEmpty else { return }
                apiService.playTrack(tracks: queue, startIndex: 0, albumArtist: artist.name)
            }
            .store(in: &cancellables)
    }

    private func shufflePlayArtist() {
        guard !topSongs.isEmpty else { return }
        var list = topSongs
        list.shuffle()
        apiService.playTrack(tracks: list, startIndex: 0, albumArtist: artist.name)
    }

    private func toggleFavorite() {
        let call: AnyPublisher<Void, Error> = isFavorite
            ? apiService.unmarkItemFavorite(itemId: artist.id)
            : apiService.markItemFavorite(itemId: artist.id)

        call
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: {
                self.isFavorite.toggle()
            })
            .store(in: &cancellables)
    }

    private func createArtistStation() {
        let seedTrack: JellyfinTrack? = topSongs.first ?? nil

        func start(with seed: JellyfinTrack) {
            let seedId = seed.serverId ?? seed.id
            apiService.fetchInstantMix(itemId: seedId, limit: 80)
                .replaceError(with: [])
                .map { mix -> [JellyfinTrack] in
                    var seen = Set<String>()
                    var out: [JellyfinTrack] = []

                    func addIfNew(_ t: JellyfinTrack) {
                        let key = t.serverId ?? t.id
                        if !seen.contains(key) {
                            seen.insert(key)
                            out.append(t)
                        }
                    }
                    addIfNew(seed)
                    for t in mix { addIfNew(t) }
                    return out
                }
                .receive(on: DispatchQueue.main)
                .sink { queue in
                    guard !queue.isEmpty else { return }
                    apiService.playTrack(tracks: queue, startIndex: 0, albumArtist: artist.name)
                }
                .store(in: &cancellables)
        }

        if let seedTrack {
            start(with: seedTrack)
        } else {
            apiService.fetchSongsByArtist(artistId: artist.id)
                .replaceError(with: [])
                .receive(on: DispatchQueue.main)
                .sink { tracks in
                    guard let seed = tracks.first else { return }
                    start(with: seed)
                }
                .store(in: &cancellables)
        }
    }


    private func playSingle(_ track: JellyfinTrack) {
        apiService.playTrack(tracks: [track], startIndex: 0, albumArtist: artist.name)
    }

    private func queueNext(_ track: JellyfinTrack)  { print("Queue next:", track.name ?? "(unknown)") }
    private func addToQueue(_ track: JellyfinTrack) { print("Add to queue:", track.name ?? "(unknown)") }

    private func downloadOne(_ track: JellyfinTrack) {
        let id = track.id
        if downloading.contains(id) { return }
        downloading.insert(id)

        apiService.downloadTrack(trackId: id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in
                self.downloading.remove(id)
            }, receiveValue: { _ in
                self.downloading.remove(id)
            })
            .store(in: &cancellables)
    }

    private func goToAlbum(_ track: JellyfinTrack) {
        if let aid = track.albumId { print("Go to album:", aid) }
    }
    
    // MARK: - Album actions (context menu)

    private func albumPlay(_ album: JellyfinAlbum) {
        apiService.fetchTracks(for: album.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                apiService.playTrack(tracks: tracks, startIndex: 0, albumArtist: artist.name)
            }
            .store(in: &cancellables)
    }

    private func albumShuffle(_ album: JellyfinAlbum) {
        apiService.fetchTracks(for: album.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                var shuffled = tracks
                shuffled.shuffle()
                apiService.playTrack(tracks: shuffled, startIndex: 0, albumArtist: artist.name)
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
                    // AudioPlayer.shared.queueNext(t)
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
            .sink(
                receiveCompletion: { _ in },
                receiveValue: {
                    self.apiService.fetchArtistAlbums(artistId: self.artist.id)
                        .replaceError(with: [])
                        .receive(on: DispatchQueue.main)
                        .sink { self.albums = $0 }
                        .store(in: &self.cancellables)
                }
            )
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


// MARK: - UI Helper Structs

fileprivate struct ParallaxHeader<Content: View>: View {
    let minHeight: CGFloat
    let content: () -> Content

    init(minHeight: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.minHeight = minHeight
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .global).minY
            let extra = max(0, minY)

            content()
                .frame(width: geo.size.width, height: minHeight + extra)
                .clipped()
                .offset(y: -extra)
        }
        .frame(height: minHeight)
    }
}

fileprivate struct DualActionPill: View {
    let isFavorite: Bool
    let accentRed: Color
    let onToggleFavorite: () -> Void
    let onCreateStation: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(isFavorite ? accentRed : .primary)
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(.plain)

            Button(action: onCreateStation) {
                Image(systemName: "badge.plus.radiowaves.right")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(.plain)
        }
        .clipShape(Capsule())
    }
}

fileprivate struct TrackContextPreviewRow: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let corner: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty:
                    ZStack { Color.gray.opacity(0.2); ProgressView() }
                default:
                    ZStack { Color.gray.opacity(0.2); Image(systemName: "music.note").foregroundColor(.secondary) }
                }
            }
            .frame(width: 42, height: 42) // <--- FIX 1: Shrunk from 56x56 to 42x42
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty:
                    ZStack { Color.gray.opacity(0.2); ProgressView() }
                default:
                    ZStack { Color.gray.opacity(0.2); Image(systemName: "photo").foregroundColor(.secondary) }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
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
