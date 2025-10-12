import SwiftUI
import Combine
import UIKit
import CoreImage
import SDWebImageSwiftUI
import AVKit
import AVFoundation

// MARK: - Explicit Badge Helpers
private struct ExplicitBadge: View {
    /// Match ArtistDetailView exactly
    var size: CGFloat = 10

    var body: some View {
        Image(systemName: "e.square.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Explicit")
    }
}

// FIX 1: Make isExplicit self-contained so it doesn't need hasTagCI in file scope
@inline(__always)
private func isExplicit(_ tags: [String]?) -> Bool {
    guard let tags else { return false }
    return tags.contains { $0.caseInsensitiveCompare("Explicit") == .orderedSame }
}

// MARK: - Contrast Helpers
private extension UIColor {
    /// WCAG-ish luminance (0...1)
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func ch(_ c: CGFloat) -> CGFloat {
            return (c <= 0.03928) ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
        }
        let R = ch(r), G = ch(g), B = ch(b)
        return 0.2126 * R + 0.7152 * G + 0.0722 * B
    }

    /// Blend toward black until luminance is at or below target (keeps hue-ish feel)
    func darkenedForWhiteText(targetLuminance: CGFloat = 0.12) -> UIColor {
        guard luminance > targetLuminance else { return self }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        getRed(&r, green: &g, blue: &b, alpha: &a)
        // binary search blend factor to reach the target luminance quickly
        var low: CGFloat = 0, high: CGFloat = 1, best: CGFloat = 0
        for _ in 0..<8 {
            let mid = (low + high) / 2
            let test = UIColor(red: r * (1 - mid), green: g * (1 - mid), blue: b * (1 - mid), alpha: a)
            if test.luminance > targetLuminance { low = mid } else { best = mid; high = mid }
        }
        return UIColor(red: r * (1 - best), green: g * (1 - best), blue: b * (1 - best), alpha: a)
    }
}

// MARK: - Animated Artwork Helper (shared)
@inline(__always)
func animatedSquareURL(from tags: [String]?) -> URL? {
    guard let tags else { return nil }
    for raw in tags {
        let lower = raw.lowercased()
        guard lower.hasPrefix("animatedartwork=") else { continue }
        let value = String(raw.split(separator: "=", maxSplits: 1).last ?? "")
        let enc = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        if let url = URL(string: enc), url.absoluteString.lowercased().contains("animated.mp4") {
            return url
        }
    }
    return nil
}

// MARK: - Deterministic Shuffle Helpers
// Daily seed string like "2025-09-29"
private var todayStamp: String {
    let d = Date()
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
}

// Convert that into a reproducible UInt64
private var dailySeed: UInt64 {
    var hasher = Hasher()
    hasher.combine(todayStamp)
    return UInt64(bitPattern: Int64(hasher.finalize()))
}

// Simple seeded RNG
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        // xorshift64*
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        x = x &* 0x2545F4914F6CDD1D
        state = x
        return x
    }
}

// Deterministic shuffle
private func deterministicShuffle<T>(_ arr: [T], seed: UInt64) -> [T] {
    var a = arr
    var g = SeededGenerator(seed: seed)
    a.shuffle(using: &g)
    return a
}

// NEW HELPER: Signature generation using only IDs
private func sigIDs(_ ids: [String], includeDailySeed: Bool = true) -> String {
    let s = ids.joined(separator: "|")
    return includeDailySeed ? "\(todayStamp):\(s)" : s
}

// MARK: - Top Picks Interleaving Helper
private enum _KindSlot { case album, playlist, artist }

private func interleavedOrderSlots(albums: Int, playlists: Int, artists: Int, seed: UInt64) -> [_KindSlot] {
    var slots: [_KindSlot] = Array(repeating: .album, count: albums)
    slots += Array(repeating: .playlist, count: playlists)
    slots += Array(repeating: .artist, count: artists)
    return deterministicShuffle(slots, seed: seed)
}

// MARK: - Clear, fade-in AVPlayerLayer host (no black flash)
private struct FadeInPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let isVisible: Bool   // drives the fade

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        v.playerLayer.backgroundColor = UIColor.clear.cgColor
        v.alpha = isVisible ? 1 : 0
        return v
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        // Crossfade ON TOP of whatever is underneath (your static image)
        UIView.animate(withDuration: 0.25) {
            uiView.alpha = isVisible ? 1 : 0
        }
    }

    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}


// MARK: - Main Home View
struct HomeView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @EnvironmentObject var audioPlayer: AudioPlayer
    private let feed = HomeFeedService()

    // Core Data States
    @State private var cards: [HomeCard] = []
    @State private var recentlyPlayed: [HomeFeedService.RecentItem] = []
    @State private var dailyGenreName: String?
    @State private var dailyGenreAlbums: [JellyfinAlbum] = []
    @State private var mfyPlaylists: [JellyfinAlbum] = []
    @State private var mfyArtistSubtitles: [String: String] = [:]
    @State private var moodPlaylists: [JellyfinAlbum] = []
    @State private var newReleases: [JellyfinAlbum] = []
    @State private var updatedPlaylist: JellyfinAlbum?
    @State private var moreLikeAnchor: JellyfinAlbum?
    @State private var moreLikeAlbums: [JellyfinAlbum] = []
    @State private var altGenreName: String?
    @State private var altGenreAlbums: [JellyfinAlbum] = []
    @State private var ampPlaylists: [JellyfinAlbum] = []
    @State private var replayPlaylists: [JellyfinAlbum] = []
    @State private var replayArtistSubtitles: [String: String] = [:]
    
    // 1) Add a tiny cache (persists per day)
    // Persist one day's Top Picks so order doesn't reshuffle on refresh/foreground.
    @AppStorage("topPicksCacheJSON") private var topPicksCacheJSON: String = ""

    // What we persist (tiny + stable)
    private struct TopPicksCache: Codable {
        let day: String      // e.g. "2025-09-29"
        let cards: [CachedCard] // just kind + id, we'll rebuild UI models from live data
    }
    private struct CachedCard: Codable {
        let kind: String  // "album" | "newest" | "playlist" | "artist"
        let id: String
    }
    
    // Loading/Error/Animation States
    @State private var hasLoadedRecent = false
    @State private var  isRefreshingRecent = false
    @State private var newRecentHeadID: String? = nil
    
    // Signature States for stability check (No longer need per-section isLoading/Error state)
    @State private var sigTopPicks = ""
    @State private var sigRecent = ""
    @State private var sigDaily = ""
    @State private var sigMFY = ""
    @State private var sigMood = ""
    @State private var sigNew = ""
    @State private var sigUpdated = ""
    @State private var sigMoreLike = ""
    @State private var sigAlt = ""
    @State private var sigAMP = ""
    @State private var sigReplay = ""
    
    @State private var recentError: String?
    @State private var dailyGenreError: String?
    @State private var mfyError: String?
    @State private var moodError: String?
    @State private var newError: String?
    @State private var updatedError: String?
    @State private var moreLikeError: String?
    @State private var altGenreError: String?
    @State private var ampError: String?
    @State private var replayError: String?

    @State private var cancellables = Set<AnyCancellable>()
    
    // Layout
    private let hPad: CGFloat = 20
    private let cardSpacing: CGFloat = 16
    private let cardWidth: CGFloat = 215

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                topPicksSection
                recentlyPlayedSection
                dailyGenreSection
                madeForYouSection
                moodSection
                newReleasesSection
                updatedPlaylistSection
                moreLikeSection
                altGenreSection
                featuredPlaylistsSection
                replaySection
            }
            .padding(.top, 16)
        }
        .navigationTitle("Home")
        .onAppear {
            startReachabilityProbe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jellyfinNowPlayingDidChange)) { _ in
            refreshRecentlyPlayedAnimated()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            startReachabilityProbe(initialDelay: 0.5) // re-check on foreground
        }
        .refreshable {
            loadAllSections(isPullToRefresh: true)
        }
    }

    // MARK: - View Sections as Computed Properties

    @ViewBuilder
    private var topPicksSection: some View {
        SectionHeader("Top Picks for You", bottomSpacing: -15)
            .padding(.horizontal, -3)

        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    switch card.kind {
                    case .album(let a), .newest(let a):
                        NavigationLink {
                            AlbumDetailLoader(albumId: a.id).environmentObject(apiService)
                        } label: {
                            PosterCard(
                                imageURL: apiService.imageURL(for: a.id),
                                animatedURL: animatedSquareURL(from: a.tags),
                                title: a.name,
                                artist: a.albumArtists?.first?.name ?? a.artistItems?.first?.name,
                                year: a.productionYear,
                                width: cardWidth,
                                isExplicit: isExplicit(a.tags)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            albumContextMenu(a)
                        } preview: {
                            HomeContextPreviewTile(
                                title: a.name,
                                subtitle: a.albumArtists?.first?.name ?? a.artistItems?.first?.name,
                                imageURL: apiService.imageURL(for: a.id)
                            )
                        }

                    case .playlist(let p):
                        NavigationLink {
                            PlaylistDetailView(playlistId: p.id).environmentObject(apiService)
                        } label: {
                            PosterCard(
                                imageURL: apiService.imageURL(for: p.id),
                                animatedURL: animatedSquareURL(from: p.tags),
                                title: p.name,
                                artist: p.artistItems?.first?.name,
                                year: p.productionYear,
                                width: cardWidth,
                                isExplicit: false
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            playlistContextMenu(p)
                        } preview: {
                            HomeContextPreviewTile(
                                title: p.name,
                                subtitle: p.artistItems?.first?.name ?? "Playlist",
                                imageURL: apiService.imageURL(for: p.id)
                            )
                        }

                    case .artist(let artist):
                        Button { playArtistMix(artist: artist) } label: {
                            PosterCard(
                                imageURL: bannerImageURL(for: artist.id),
                                animatedURL: nil,
                                title: "\(artist.name) & Similar Artists",
                                artist: nil,
                                year: nil,
                                width: cardWidth,
                                isExplicit: false
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { playArtistMix(artist: artist) } label: { Label("Play", systemImage: "play.fill") }
                        } preview: {
                            HomeContextPreviewTile(
                                title: "\(artist.name) Mix",
                                subtitle: "and similar artists",
                                imageURL: bannerImageURL(for: artist.id)
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        SectionHeader("Recently Played", bottomSpacing: -15)
            .padding(.horizontal, -3)

        if recentlyPlayed.isEmpty {
            Text("No recently played music").foregroundColor(.secondary).frame(height: 120).frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) {
                    ForEach(recentlyPlayed, id: \.id) { item in
                        let isNewHead = (item.id == newRecentHeadID)

                        NavigationLink {
                            switch item.kind {
                            case .album:
                                AlbumDetailLoader(albumId: item.id).environmentObject(apiService)
                            case .playlist:
                                PlaylistDetailView(playlistId: item.id).environmentObject(apiService)
                            }
                        } label: {
                            SmallSquareCard(
                                imageURL: apiService.imageURL(for: item.id),
                                title: item.name,
                                subtitle: item.subtitle,
                                size: 150,
                                isExplicit: isExplicit(item.tags)
                            )
                        }
                        .buttonStyle(.plain)
                        .transition(isNewHead ? .opacity : .identity)
                        .contextMenu {
                            let label = item.subtitle ?? item.name
                            idContextMenu(id: item.id, label: label)
                        } preview: {
                            HomeContextPreviewTile(
                                title: item.name,
                                subtitle: item.subtitle,
                                imageURL: apiService.imageURL(for: item.id)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            // Removed .scrollClipDisabled()
            .animation(.spring(response: 0.45, dampingFraction: 0.88), value: recentlyPlayed)
        }
    }

    @ViewBuilder
    private var dailyGenreSection: some View {
        if let g = dailyGenreName {
            SectionHeader("\(g)", bottomSpacing: -15)
                .padding(.horizontal, -3)
            if dailyGenreAlbums.isEmpty {
                Text("No albums found").foregroundColor(.secondary).frame(height: 120).frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: cardSpacing) {
                        ForEach(dailyGenreAlbums, id: \.id) { album in
                            NavigationLink {
                                AlbumDetailLoader(albumId: album.id).environmentObject(apiService)
                            } label: {
                                SmallSquareCard(
                                    imageURL: apiService.imageURL(for: album.id),
                                    title: album.name,
                                    subtitle: album.albumArtists?.first?.name,
                                    size: 150,
                                    isExplicit: isExplicit(album.tags)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                albumContextMenu(album)
                            } preview: {
                                HomeContextPreviewTile(
                                    title: album.name,
                                    subtitle: album.albumArtists?.first?.name,
                                    imageURL: apiService.imageURL(for: album.id)
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                // Removed .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private var madeForYouSection: some View {
        SectionHeader("Made For You", bottomSpacing: -15)
            .padding(.horizontal, -3)

        if mfyPlaylists.isEmpty {
            Text("No MFY playlists yet").foregroundColor(.secondary).frame(height: 120).frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) {
                    ForEach(mfyPlaylists, id: \.id) { p in
                        NavigationLink {
                            PlaylistDetailView(playlistId: p.id).environmentObject(apiService)
                        } label: {
                            PosterCard(
                                imageURL: apiService.imageURL(for: p.id),
                                animatedURL: animatedSquareURL(from: p.tags),
                                title: p.name,
                                artist: mfyArtistSubtitles[p.id] ?? "Playlist",
                                year: p.productionYear,
                                width: cardWidth,
                                isExplicit: false,
                                forceDarkBanner: false,
                                showTitle: false,
                                subtitleLineLimit: nil
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            playlistContextMenu(p)
                        } preview: {
                            HomeContextPreviewTile(
                                title: p.name,
                                subtitle: mfyArtistSubtitles[p.id] ?? "Playlist",
                                imageURL: apiService.imageURL(for: p.id)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8) // <<< ADDED VERTICAL PADDING FIX
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var moodSection: some View {
        SectionHeader("Find Your Mood", bottomSpacing: -15)
            .padding(.horizontal, -3)

        if moodPlaylists.isEmpty {
            Text("No mood playlists yet").foregroundColor(.secondary).frame(height: 120).frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) {
                    ForEach(moodPlaylists, id: \.id) { p in
                        NavigationLink {
                            PlaylistDetailView(playlistId: p.id).environmentObject(apiService)
                        } label: {
                            SmallSquareCard(
                                imageURL: apiService.imageURL(for: p.id),
                                title: p.name,
                                subtitle: "Playlist",
                                size: 150,
                                isExplicit: false
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            playlistContextMenu(p)
                        } preview: {
                            HomeContextPreviewTile(
                                title: p.name,
                                subtitle: "Playlist",
                                imageURL: apiService.imageURL(for: p.id)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            // Removed .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var newReleasesSection: some View {
        SectionHeader("New Releases for You", bottomSpacing: -15)
            .padding(.horizontal, -3)

        if newReleases.isEmpty {
            Text("No new releases found").foregroundColor(.secondary).frame(height: 120).frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) {
                    ForEach(newReleases, id: \.id) { album in
                        NavigationLink {
                            AlbumDetailLoader(albumId: album.id).environmentObject(apiService)
                        } label: {
                            SmallSquareCard(
                                imageURL: apiService.imageURL(for: album.id),
                                title: album.name,
                                subtitle: album.albumArtists?.first?.name ?? album.artistItems?.first?.name,
                                size: 150,
                                isExplicit: isExplicit(album.tags)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            albumContextMenu(album)
                        } preview: {
                            HomeContextPreviewTile(
                                title: album.name,
                                subtitle: album.albumArtists?.first?.name ?? album.artistItems?.first?.name,
                                imageURL: apiService.imageURL(for: album.id)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            // Removed .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var updatedPlaylistSection: some View {
        SectionHeader("Updated Playlist", bottomSpacing: -15)
            .padding(.horizontal, -3)

        Group {
            if let pl = updatedPlaylist {
                NavigationLink {
                    PlaylistDetailView(playlistId: pl.id).environmentObject(apiService)
                } label: {
                    TallPosterCard(
                        imageURL: bannerImageURL(for: pl.id, tag: pl.imageTags?["Banner"]), // 👈 USE TAG
                        blurb: pl.overview ?? ""
                    )
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let pl = updatedPlaylist { playlistContextMenu(pl) }
                } preview: {
                    if let pl = updatedPlaylist {
                        HomeContextPreviewTile(
                            title: pl.name,
                            subtitle: "Playlist",
                            imageURL: bannerImageURL(for: pl.id, tag: pl.imageTags?["Banner"]) // 👈 USE TAG
                        )
                    }
                }
            } else {
                Text("No updated playlist yet").foregroundColor(.secondary).frame(height: 180).frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var moreLikeSection: some View {
        if let anchor = moreLikeAnchor {
            HStack(spacing: 12) {
                WebImage(url: apiService.imageURL(for: anchor.id))
                    .resizable().indicator(.activity).transition(.fade)
                    .scaledToFill()
                    .frame(width: 41, height: 41)
                    .clipped()
                    .cornerRadius(6)
                    .shadow(radius: 2, y: 1)

                VStack(alignment: .leading, spacing: 0) {
                    Text("More Like").font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(anchor.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isExplicit(anchor.tags) { ExplicitBadge() }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, -15)

            if moreLikeAlbums.isEmpty {
                Text("No similar albums found").foregroundColor(.secondary).frame(height: 120).frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: cardSpacing) {
                        ForEach(moreLikeAlbums, id: \.id) { album in
                            NavigationLink {
                                AlbumDetailLoader(albumId: album.id).environmentObject(apiService)
                            } label: {
                                SmallSquareCard(
                                    imageURL: apiService.imageURL(for: album.id),
                                    title: album.name,
                                    subtitle: album.albumArtists?.first?.name ?? album.artistItems?.first?.name,
                                    size: 150,
                                    isExplicit: isExplicit(album.tags)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                albumContextMenu(album)
                            } preview: {
                                HomeContextPreviewTile(
                                    title: album.name,
                                    subtitle: album.albumArtists?.first?.name ?? album.artistItems?.first?.name,
                                    imageURL: apiService.imageURL(for: album.id)
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                // Removed .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private var altGenreSection: some View {
        if let g2 = altGenreName {
            SectionHeader("\(g2)", bottomSpacing: -15)
                .padding(.horizontal, -3)
            if altGenreAlbums.isEmpty {
                Text("No albums found").foregroundColor(.secondary).frame(height: 120).frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: cardSpacing) {
                        ForEach(altGenreAlbums, id: \.id) { album in
                            NavigationLink {
                                AlbumDetailLoader(albumId: album.id).environmentObject(apiService)
                            } label: {
                                SmallSquareCard(
                                    imageURL: apiService.imageURL(for: album.id),
                                    title: album.name,
                                    subtitle: album.albumArtists?.first?.name,
                                    size: 150,
                                    isExplicit: isExplicit(album.tags)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                albumContextMenu(album)
                            } preview: {
                                HomeContextPreviewTile(
                                    title: album.name,
                                    subtitle: album.albumArtists?.first?.name,
                                    imageURL: apiService.imageURL(for: album.id)
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                // Removed .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private var featuredPlaylistsSection: some View {
        InlineHeaderLink(title: "Featured Playlists", bottomSpacing: -15) {
            FeaturedPlaylistsAllView(playlists: ampPlaylists)
                .environmentObject(apiService)
        }
        .padding(.horizontal, -3)

        if ampPlaylists.isEmpty {
            Text("No AMP playlists yet").foregroundColor(.secondary).frame(height: 120).frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) {
                    ForEach(ampPlaylists, id: \.id) { p in
                        NavigationLink {
                            PlaylistDetailView(playlistId: p.id).environmentObject(apiService)
                        } label: {
                            SmallSquareCard(
                                imageURL: primaryImageURL(
                                    for: p.id,
                                    tag: p.imageTags?["Primary"] ?? p.imageTags?["Thumb"]
                                ),
                                title: p.name,
                                subtitle: "Playlist",
                                size: 150,
                                isExplicit: false
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            playlistContextMenu(p)
                        } preview: {
                            HomeContextPreviewTile(
                                title: p.name,
                                subtitle: "Playlist",
                                imageURL: primaryImageURL(
                                    for: p.id,
                                    tag: p.imageTags?["Primary"] ?? p.imageTags?["Thumb"]
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            // Removed .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var replaySection: some View {
        InlineHeaderLink(title: "Replay", bottomSpacing: -15) {
            ReplayView().environmentObject(apiService)
        }
        .padding(.horizontal, -3)

        if replayPlaylists.isEmpty {
            Text("No Replay playlists yet").foregroundColor(.secondary).frame(height: 120).frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) {
                    ForEach(replayPlaylists, id: \.id) { p in
                        NavigationLink {
                            PlaylistDetailView(playlistId: p.id).environmentObject(apiService)
                        } label: {
                            PosterCard(
                                imageURL: apiService.imageURL(for: p.id),
                                animatedURL: animatedSquareURL(from: p.tags),
                                title: p.name,
                                artist: replayArtistSubtitles[p.id] ?? "Playlist",
                                year: nil,
                                width: cardWidth,
                                isExplicit: false,
                                forceDarkBanner: true
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            playlistContextMenu(p)
                        } preview: {
                            HomeContextPreviewTile(
                                title: p.name,
                                subtitle: replayArtistSubtitles[p.id] ?? "Playlist",
                                imageURL: apiService.imageURL(for: p.id)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - Helpers

    /// Pings Jellyfin to check for connectivity before loading all sections.
    private func startReachabilityProbe(initialDelay: TimeInterval = 0.0) {
        guard !apiService.serverURL.isEmpty else { return }

        // fire immediately (after optional initial delay)
        func probeOnce() {
            var url = URL(string: apiService.serverURL)!
            if !apiService.serverURL.hasSuffix("/") { url = URL(string: apiService.serverURL + "/")! }
            let infoURL = URL(string: "System/Info/Public", relativeTo: url)!

            URLSession.shared.dataTask(with: infoURL) { _, resp, error in
                let ok = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
                if ok {
                    DispatchQueue.main.async {
                        // Once reachable, load everything silently.
                        self.loadAllSections()
                    }
                }
            }.resume()
        }

        if initialDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
                probeOnce()
            }
        } else {
            probeOnce()
        }
    }
    
    // MARK: - Top Picks actions

    // Common: a small util to get a decent "albumArtist" label
    private func displayArtistLabel(for a: JellyfinAlbum) -> String {
        a.albumArtists?.first?.name ?? a.artistItems?.first?.name ?? "Unknown Artist"
    }

    // ----- Albums -----
    private func playAlbum(_ album: JellyfinAlbum) {
        apiService.fetchTracks(for: album.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                audioPlayer.play(tracks: tracks, startIndex: 0, albumArtist: displayArtistLabel(for: album))
            }
            .store(in: &cancellables)
    }

    private func shuffleAlbum(_ album: JellyfinAlbum) {
        apiService.fetchTracks(for: album.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                var shuffled = tracks
                shuffled.shuffle()
                audioPlayer.play(tracks: shuffled, startIndex: 0, albumArtist: displayArtistLabel(for: album))
            }
            .store(in: &cancellables)
    }

    private func queueNextAlbum(_ album: JellyfinAlbum) {
        apiService.fetchTracks(for: album.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                // TODO: integrate with your queue system. Example:
                // audioPlayer.enqueueNext(tracks)
            }
            .store(in: &cancellables)
    }

    private func toggleFavoriteAlbum(_ album: JellyfinAlbum) {
        let isFav = album.userData?.isFavorite ?? false
        let call: AnyPublisher<Void, Error> = isFav
            ? apiService.unmarkItemFavorite(itemId: album.id)
            : apiService.markItemFavorite(itemId: album.id)

        call
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in },
                  receiveValue: {
                      // Optional: refresh Top Picks or the specific album's userData if you track it
                      loadAllSections()
                  })
            .store(in: &cancellables)
    }

    private func downloadAlbum(_ album: JellyfinAlbum) {
        apiService.downloadAlbum(albumId: album.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &cancellables)
    }

    // ----- Playlists -----
    private func playPlaylist(_ playlist: JellyfinAlbum) {
        // Most servers will return tracks for a playlist via the same endpoint.
        apiService.fetchTracks(for: playlist.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                let label = playlist.artistItems?.first?.name ?? "Playlist"
                audioPlayer.play(tracks: tracks, startIndex: 0, albumArtist: label)
            }
            .store(in: &cancellables)
    }

    private func shufflePlaylist(_ playlist: JellyfinAlbum) {
        apiService.fetchTracks(for: playlist.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                var shuffled = tracks
                shuffled.shuffle()
                let label = playlist.artistItems?.first?.name ?? "Playlist"
                audioPlayer.play(tracks: shuffled, startIndex: 0, albumArtist: label)
            }
            .store(in: &cancellables)
    }

    private func queueNextPlaylist(_ playlist: JellyfinAlbum) {
        apiService.fetchTracks(for: playlist.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                // TODO: integrate with your queue system.
                // audioPlayer.enqueueNext(tracks)
            }
            .store(in: &cancellables)
    }

    private func toggleFavoritePlaylist(_ playlist: JellyfinAlbum) {
        let isFav = playlist.userData?.isFavorite ?? false
        let call: AnyPublisher<Void, Error> = isFav
            ? apiService.unmarkItemFavorite(itemId: playlist.id)
            : apiService.markItemFavorite(itemId: playlist.id)

        call
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in },
                  receiveValue: {
                      // Optional: refresh
                      loadAllSections()
                  })
            .store(in: &cancellables)
    }

    private func downloadPlaylist(_ playlist: JellyfinAlbum) {
        // If you have a direct API on your service, prefer that:
        // apiService.downloadPlaylist(playlistId: playlist.id)

        // Fallback: fetch tracks and download one by one.
        apiService.fetchTracks(for: playlist.id)
            .replaceError(with: [])
            .flatMap { tracks -> AnyPublisher<Void, Never> in
                guard !tracks.isEmpty else { return Just(()).eraseToAnyPublisher() }
                let pubs = tracks.map { t in
                    apiService.downloadTrack(trackId: t.id)
                        .map { _ in }
                        .replaceError(with: ())
                }
                return Publishers.MergeMany(pubs).collect().map { _ in () }.eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in }
            .store(in: &cancellables)
    }

    // MARK: - Generic item actions (work for album or playlist IDs)
    private func playItem(id: String, label: String) {
        apiService.fetchTracks(for: id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                audioPlayer.play(tracks: tracks, startIndex: 0, albumArtist: label)
            }
            .store(in: &cancellables)
    }

    private func shuffleItem(id: String, label: String) {
        apiService.fetchTracks(for: id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                var s = tracks; s.shuffle()
                audioPlayer.play(tracks: s, startIndex: 0, albumArtist: label)
            }
            .store(in: &cancellables)
    }

    private func queueNextItem(id: String) {
        apiService.fetchTracks(for: id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                // TODO: hook into your queue system
                // audioPlayer.enqueueNext(tracks)
            }
            .store(in: &cancellables)
    }

    private func favoriteItem(id: String) {
        // If you prefer true toggling, fetch userData first; this keeps it simple.
        apiService.markItemFavorite(itemId: id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &cancellables)
    }

    private func downloadByItem(id: String) {
        // Generic downloader: fetch tracks then download each
        apiService.fetchTracks(for: id)
            .replaceError(with: [])
            .flatMap { tracks -> AnyPublisher<Void, Never> in
                guard !tracks.isEmpty else { return Just(()).eraseToAnyPublisher() }
                let pubs = tracks.map { t in
                    apiService.downloadTrack(trackId: t.id).map { _ in }.replaceError(with: ())
                }
                return Publishers.MergeMany(pubs).collect().map { _ in () }.eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in }
            .store(in: &cancellables)
    }

    // MARK: - Context Menu Builders
    @ViewBuilder private func albumContextMenu(_ a: JellyfinAlbum) -> some View {
        Button { playAlbum(a) }       label: { Label("Play",      systemImage: "play.fill") }
        Button { shuffleAlbum(a) }    label: { Label("Shuffle",   systemImage: "shuffle") }
        Button { queueNextAlbum(a) }  label: { Label("Play Next", systemImage: "text.insert") }
        Button { toggleFavoriteAlbum(a) } label: { Label("Favorite",  systemImage: "star") }
        Button { downloadAlbum(a) }       label: { Label("Download",  systemImage: "arrow.down.circle") }
    }

    @ViewBuilder private func playlistContextMenu(_ p: JellyfinAlbum) -> some View {
        Button { playPlaylist(p) }        label: { Label("Play",      systemImage: "play.fill") }
        Button { shufflePlaylist(p) }     label: { Label("Shuffle",   systemImage: "shuffle") }
        Button { queueNextPlaylist(p) }   label: { Label("Play Next", systemImage: "text.insert") }
        Button { toggleFavoritePlaylist(p) } label: { Label("Favorite",  systemImage: "star") }
        Button { downloadPlaylist(p) }    label: { Label("Download",  systemImage: "arrow.down.circle") }
    }

    @ViewBuilder private func idContextMenu(id: String, label: String) -> some View {
        Button { playItem(id: id, label: label) }  label: { Label("Play",      systemImage: "play.fill") }
        Button { shuffleItem(id: id, label: label) } label: { Label("Shuffle",   systemImage: "shuffle") }
        Button { queueNextItem(id: id) }           label: { Label("Play Next", systemImage: "text.insert") }
        Button { favoriteItem(id: id) }            label: { Label("Favorite",  systemImage: "star") }
        Button { downloadByItem(id: id) }          label: { Label("Download",  systemImage: "arrow.down.circle") }
    }
    
    // Helper to convert HomeCard ⟷ cache:

    private func toCached(_ c: HomeCard) -> CachedCard {
        switch c.kind {
        case .album(let a):   return .init(kind: "album",  id: a.id)
        case .newest(let a):  return .init(kind: "newest",   id: a.id)
        case .playlist(let p):return .init(kind: "playlist", id: p.id)
        case .artist(let ar): return .init(kind: "artist",   id: ar.id)
        }
    }

    // Rebuild cards from today's fetched pools; if any id is missing, we drop it.
    private func fromCached(_ cached: [CachedCard],
                            albumsById: [String:JellyfinAlbum],
                            playlistsById: [String:JellyfinAlbum],
                            artistsById: [String:JellyfinArtistItem]) -> [HomeCard] {
        cached.compactMap { cc in
            switch cc.kind {
            case "album":    if let a = albumsById[cc.id]    { return HomeCard(kind: .album(a)) }
            case "newest":   if let a = albumsById[cc.id]    { return HomeCard(kind: .newest(a)) }
            case "playlist": if let p = playlistsById[cc.id] { return HomeCard(kind: .playlist(p)) }
            case "artist":   if let ar = artistsById[cc.id]  { return HomeCard(kind: .artist(ar)) }
            default: break
            }
            return nil
        }
    }

    // NEW HELPER: does a track belong to the artist (by name, case-insensitive)?
    private func trackIsByArtist(_ t: JellyfinTrack, artistName: String) -> Bool {
        guard let names = t.artists else { return false }
        return names.contains { $0.caseInsensitiveCompare(artistName) == .orderedSame }
    }

    // Replacement for playArtistMix(artist:)
    private func playArtistMix(artist: JellyfinArtistItem) {
        let artistName = artist.name

        // 1) Pull Jellyfin's Instant Mix for the artist
        apiService.fetchInstantMix(itemId: artist.id, limit: 100)
            .catch { _ in Just<[JellyfinTrack]>([]) }
            // 2) Decide whether we need to fix the head of the queue
            .flatMap { [apiService] mix -> AnyPublisher<[JellyfinTrack], Never> in
                // If the mix already contains at least one track by this artist, just use it as-is
                if mix.contains(where: { trackIsByArtist($0, artistName: artistName) }) {
                    return Just(mix).eraseToAnyPublisher()
                }

                // Otherwise, fetch one track by the artist to play first
                let topOne = apiService.fetchArtistTopSongsSmart(artistId: artist.id, artistName: artistName, limit: 1)
                    .catch { _ in Just<[JellyfinTrack]>([]) }
                let fallbackAll = apiService.fetchSongsByArtist(artistId: artist.id)
                    .map { Array($0.prefix(1)) }
                    .catch { _ in Just<[JellyfinTrack]>([]) }

                // Prefer top song; if none, fall back to "any song by artist"
                return topOne.flatMap { top -> AnyPublisher<[JellyfinTrack], Never> in
                    if let first = top.first { return Just([first] + mix.dedupByID(excluding: first.id)).eraseToAnyPublisher() }
                    return fallbackAll.map { firsts in
                        guard let first = firsts.first else { return mix }
                        return [first] + mix.dedupByID(excluding: first.id)
                    }
                    .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                audioPlayer.play(tracks: tracks, startIndex: 0, albumArtist: artistName)
            }
            .store(in: &cancellables)
    }

    private func primaryImageURL(for itemId: String, tag: String?) -> URL? {
        if var comps = URLComponents(string: "\(apiService.serverURL)Items/\(itemId)/Images/Primary") {
            var qs: [URLQueryItem] = [
                .init(name: "X-Emby-Token", value: apiService.authToken),
                .init(name: "fillWidth", value: "600"),
                .init(name: "quality", value: "90")
            ]
            if let tag { qs.append(.init(name: "tag", value: tag)) } // 👈 cache-busting
            comps.queryItems = qs
            return comps.url
        }
        return apiService.imageURL(for: itemId)
    }

    private func bannerImageURL(for itemId: String) -> URL? {
        // Call the new overload with a nil tag to preserve old behavior
        bannerImageURL(for: itemId, tag: nil)
    }
    
    // Overload for cache-busting with an image tag
    private func bannerImageURL(for itemId: String, tag: String?) -> URL? {
        if var comps = URLComponents(string: "\(apiService.serverURL)Items/\(itemId)/Images/Banner") {
            var qs: [URLQueryItem] = [
                .init(name: "X-Emby-Token", value: apiService.authToken),
                .init(name: "fillWidth", value: "1400"),
                .init(name: "quality", value: "90")
            ]
            if let tag { qs.append(.init(name: "tag", value: tag)) } // 👈 cache-busting key
            comps.queryItems = qs
            if let url = comps.url { return url }
        }
        return apiService.imageURL(for: itemId) // fallback
    }

    private func hasTagCI(_ tags: [String]?, _ tag: String) -> Bool {
        guard let tags else { return false }
        return tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func isAlbumBlacklisted(_ a: JellyfinAlbum) -> Bool {
        hasTagCI(a.tags, "BlacklistHV")
    }

    // Only hide MFY and Replay in Top Picks
    private func shouldHideInTopPicks(_ p: JellyfinAlbum) -> Bool {
        hasTagCI(p.tags, "MFY") || hasTagCI(p.tags, "Replay")
    }

    private func shouldHideInFeatured(_ p: JellyfinAlbum) -> Bool {
        hasTagCI(p.tags, "Mood")
    }
    
    // START: MODIFIED fetchRandomPlaylists (Seeded Shuffle)
    private func fetchRandomPlaylists(limit: Int) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !apiService.serverURL.isEmpty,
              !apiService.userId.isEmpty,
              !apiService.authToken.isEmpty else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(apiService.serverURL)Users/\(apiService.userId)/Items")
        comps?.queryItems = [
            .init(name: "Limit", value: "250"),
            .init(name: "IncludeItemTypes", value: "Playlist"),
            .init(name: "Recursive", value: "true"),
            .init(name: "SortBy", value: "Name"),
            .init(name: "SortOrder", value: "Ascending"),
            .init(name: "Fields", value: "Overview,UserData,ProductionYear,DateCreated,Tags,ArtistItems,ImageTags") // Ensure ImageTags is fetched
        ]
        let url = comps!.url!

        var req = URLRequest(url: url)
        req.setValue(apiService.authorizationHeader(withToken: apiService.authToken),
                     forHTTPHeaderField: "X-Emby-Authorization")

        struct ItemsEnvelope<T: Decodable>: Decodable { let Items: [T]? }

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, resp in
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
                else { throw URLError(.badServerResponse) }
                return data
            }
            .decode(type: ItemsEnvelope<JellyfinAlbum>.self, decoder: JSONDecoder())
            .map { $0.Items ?? [] }
            .map { lists in
                lists.filter { p in
                    !(hasTagCI(p.tags, "MFY") || hasTagCI(p.tags, "Replay"))
                }
            }
            .map { lists in
                Array(deterministicShuffle(lists, seed: dailySeed).prefix(limit))
            }
            .eraseToAnyPublisher()
    }
    // END: MODIFIED fetchRandomPlaylists

    // NEW HELPER: Map a HomeCard to a stable id for dedup
    private func cardID(_ c: HomeCard) -> String {
        switch c.kind {
        case .album(let a), .newest(let a): return a.id
        case .playlist(let p):              return p.id
        case .artist(let ar):               return ar.id
        }
    }

    // NEW HELPER: Interleave two arrays
    private func interleave<T>(_ a: [T], _ b: [T]) -> [T] {
        var out: [T] = []
        let n = max(a.count, b.count)
        for i in 0..<n {
            if i < a.count { out.append(a[i]) }
            if i < b.count { out.append(b[i]) }
        }
        return out
    }

    // NEW HELPER: Deduplicate cards by their ID
    private func uniqueByCardID(_ cards: [HomeCard]) -> [HomeCard] {
        var seen = Set<String>()
        return cards.filter { seen.insert(cardID($0)).inserted }
    }


    // MARK: - Loads (Parallel and Signature-based)
    private func loadAllSections(isPullToRefresh: Bool = false) {
        if isPullToRefresh {
            // re-roll Top Picks on user-initiated refresh:
            self.topPicksCacheJSON = ""
        }
        
        let allPublishers: [AnyPublisher<Void, Never>] = [
            loadTopPicks().map { _ in }.eraseToAnyPublisher(),
            loadRecentlyPlayedPublisher().map { _ in }.eraseToAnyPublisher(),
            loadDailyGenrePublisher().map { _ in }.eraseToAnyPublisher(),
            loadDailyGenreAltPublisher().map { _ in }.eraseToAnyPublisher(),
            loadMFYPublisher().map { _ in }.eraseToAnyPublisher(),
            loadMoodPublisher().map { _ in }.eraseToAnyPublisher(),
            loadNewReleasesPublisher().map { _ in }.eraseToAnyPublisher(),
            loadUpdatedPlaylistPublisher().map { _ in }.eraseToAnyPublisher(),
            loadMoreLikePublisher().map { _ in }.eraseToAnyPublisher(),
            loadAMPPublisher().map { _ in }.eraseToAnyPublisher(),
            loadReplayPublisher().map { _ in }.eraseToAnyPublisher()
        ]
        
        Publishers.MergeMany(allPublishers)
            .collect()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                // All publishers have completed.
                self.hasLoadedRecent = true
            }
            .store(in: &cancellables)
    }

    // REPLACED: loadTopPicks() with the new caching and balancing version
    private func loadTopPicks() -> AnyPublisher<[HomeCard], Never> {
        // Desired composition
        let desiredAlbums     = 6
        let desiredPlaylists  = 6
        let desiredArtistsMin = 2
        let desiredArtistsMax = 3

        // Base (could include albums/newest/playlists/artists depending on your feed)
        let baseCards = feed.fetchTopPicksDaily()
            .map { items in
                items.filter { card in
                    switch card.kind {
                    case .album(let a), .newest(let a):
                        return !isAlbumBlacklisted(a)
                    case .playlist(let p):
                        return !shouldHideInTopPicks(p)
                    case .artist:
                        return true
                    }
                }
            }
            .catch { _ in Just<[HomeCard]>([]) }
            .eraseToAnyPublisher()

        // Extra randomized playlists to ensure we can hit the playlist quota
        let randomPlaylists = fetchRandomPlaylists(limit: 24) // over-fetch a little
            .map { lists in lists.map { HomeCard(kind: .playlist($0)) } }
            .catch { _ in Just<[HomeCard]>([]) }
            .eraseToAnyPublisher()

        return Publishers.CombineLatest(baseCards, randomPlaylists)
            .map { base, rpls -> [HomeCard] in
                // Split pools by kind
                var albumPool:   [JellyfinAlbum]      = []
                var newestPool:  [JellyfinAlbum]      = []
                var playlistPool:[JellyfinAlbum]      = []
                var artistPool:  [JellyfinArtistItem]   = []

                for c in base {
                    switch c.kind {
                    case .album(let a):   albumPool.append(a)
                    case .newest(let a):  newestPool.append(a)
                    case .playlist(let p):playlistPool.append(p)
                    case .artist(let ar): artistPool.append(ar)
                    }
                }
                // Bring in extra randomized playlists
                for c in rpls {
                    if case .playlist(let p) = c.kind { playlistPool.append(p) }
                }

                // De-dupe by id inside each pool
                func uniqAlbums(_ a: [JellyfinAlbum]) -> [JellyfinAlbum] {
                    var seen = Set<String>()
                    return a.filter { seen.insert($0.id).inserted }
                }
                func uniqArtists(_ a: [JellyfinArtistItem]) -> [JellyfinArtistItem] {
                    var seen = Set<String>()
                    return a.filter { seen.insert($0.id).inserted }
                }
                albumPool     = uniqAlbums(albumPool)
                newestPool    = uniqAlbums(newestPool)
                playlistPool  = uniqAlbums(playlistPool)
                artistPool    = uniqArtists(artistPool)

                // ——— Attempt to load persisted order for TODAY ———
                if let data = topPicksCacheJSON.data(using: .utf8),
                    let cached = try? JSONDecoder().decode(TopPicksCache.self, from: data),
                    cached.day == todayStamp {

                    // Build lookup maps from current pools
                    let albumsById    = Dictionary(uniqueKeysWithValues:
                                                          (albumPool + newestPool).map { ($0.id, $0) })
                    let playlistsById = Dictionary(uniqueKeysWithValues:
                                                          playlistPool.map { ($0.id, $0) })
                    let artistsById   = Dictionary(uniqueKeysWithValues:
                                                          artistPool.map { ($0.id, $0) })

                    let rebuilt = fromCached(cached.cards,
                                             albumsById: albumsById,
                                             playlistsById: playlistsById,
                                             artistsById: artistsById)
                    if !rebuilt.isEmpty {
                        return rebuilt // ✅ Use persisted order for today
                    }
                    // else fall through to (re)compose
                }

                // ——— Compose fresh (only when cache missing/invalid) ———

                // 1) choose albums: mix album/newest, still deterministic for the day
                let mixedAlbums = deterministicShuffle(albumPool + newestPool,
                                                       seed: dailySeed &+ 0x1111)
                let chosenAlbums = Array(mixedAlbums.prefix(desiredAlbums))

                // 2) choose playlists
                let mixedPlaylists = deterministicShuffle(playlistPool,
                                                          seed: dailySeed &+ 0x2222)
                let chosenPlaylists = Array(mixedPlaylists.prefix(desiredPlaylists))

                // 3) choose artists (2–3)
                let mixedArtists = deterministicShuffle(artistPool,
                                                        seed: dailySeed &+ 0x3333)
                let artistCount = min(max(desiredArtistsMin, mixedArtists.count >= 3 ? 3 : mixedArtists.count),
                                      desiredArtistsMax)
                let chosenArtists = Array(mixedArtists.prefix(artistCount))

                // 4) Final fixed order (interleaved + deterministic for the day)
                let slots = interleavedOrderSlots(
                    albums: chosenAlbums.count,
                    playlists: chosenPlaylists.count,
                    artists: chosenArtists.count,
                    seed: dailySeed &+ 0x4444
                )

                var ai = 0, pi = 0, ri = 0
                let final: [HomeCard] = slots.compactMap { slot in
                    // Note: '++' is not valid in Swift 5. I've used 'defer' for post-increment logic which is safer.
                    // However, in this simple loop structure, using a standard assignment after access is cleaner
                    // and achieves the same intent without needing to rewrite as a full for loop.
                    
                    switch slot {
                    case .album:
                        guard ai < chosenAlbums.count else { return nil }
                        let card = HomeCard(kind: .album(chosenAlbums[ai]))
                        ai += 1
                        return card

                    case .playlist:
                        guard pi < chosenPlaylists.count else { return nil }
                        let card = HomeCard(kind: .playlist(chosenPlaylists[pi]))
                        pi += 1
                        return card

                    case .artist:
                        guard ri < chosenArtists.count else { return nil }
                        let card = HomeCard(kind: .artist(chosenArtists[ri]))
                        ri += 1
                        return card
                    }
                }

                // Save cache for today
                let cached = TopPicksCache(
                    day: todayStamp,
                    cards: final.map(toCached)
                )
                if let data = try? JSONEncoder().encode(cached),
                    let json = String(data: data, encoding: .utf8) {
                    topPicksCacheJSON = json
                }

                return final
            }
            .handleEvents(receiveOutput: { merged in
                // Keep your signature/update diff logic
                let newSig = sigIDs(merged.map(cardID))
                if newSig != self.sigTopPicks {
                    self.sigTopPicks = newSig
                    DispatchQueue.main.async { self.cards = merged }
                }
            })
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    // REPLACED: loadRecentlyPlayed() for initial load
    private func loadRecentlyPlayed(initial: Bool) {
        // Now just starts the publisher and relies on the sink logic to update state
        loadRecentlyPlayedPublisher()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in
                // No action needed here, loadAllSections handles the global loading state.
            }, receiveValue: { _ in })
            .store(in: &cancellables)
    }

    // NEW PUBLISHER: loadRecentlyPlayedPublisher
    private func loadRecentlyPlayedPublisher() -> AnyPublisher<[HomeFeedService.RecentItem], Never> {
        return feed.fetchRecentlyPlayedMixed(limit: 12)
            .replaceError(with: [])
            .handleEvents(receiveOutput: { items in
                // Use sigIDs without daily seed
                let newSig = sigIDs(items.map(\.id), includeDailySeed: false)
                if newSig != self.sigRecent {
                    self.sigRecent = newSig
                    DispatchQueue.main.async {
                        self.recentlyPlayed = items
                    }
                }
            })
            .eraseToAnyPublisher()
    }

    // KEPT (modified): The animated refresh for Now Playing changes
    private func refreshRecentlyPlayedAnimated() {
        guard hasLoadedRecent, !isRefreshingRecent else { return }
        isRefreshingRecent = true

        feed.fetchRecentlyPlayedMixed(limit: 12)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in
                self.isRefreshingRecent = false
            }, receiveValue: { newItems in
                let newSig = sigIDs(newItems.map(\.id), includeDailySeed: false)
                
                guard newSig != self.sigRecent else { return }
                self.sigRecent = newSig

                guard let currentFirst = self.recentlyPlayed.first?.id,
                      let newFirst = newItems.first?.id,
                      newFirst != currentFirst else {
                    self.recentlyPlayed = newItems
                    return
                }

                // Build an updated list for animation
                var merged: [HomeFeedService.RecentItem] = []
                if let head = newItems.first { merged.append(head) }
                for it in self.recentlyPlayed where it.id != merged.first?.id {
                    merged.append(it)
                    if merged.count >= 12 { break }
                }

                self.newRecentHeadID = newFirst

                withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                    self.recentlyPlayed = merged
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if self.newRecentHeadID == newFirst { self.newRecentHeadID = nil }
                }
            })
            .store(in: &cancellables)
    }
    
    // NEW PUBLISHER: loadDailyGenre()
    private func loadDailyGenrePublisher() -> AnyPublisher<Void, Never> {
        // Define the explicit output type including labels
        typealias Output = (genre: String, albums: [JellyfinAlbum])
        
        return feed.fetchDailyGenre(minAlbums: 5, limit: 12)
            // Fix: ensure the catch block returns the exact labeled type
            .catch { err -> AnyPublisher<Output, Never> in
                DispatchQueue.main.async { self.dailyGenreError = err.localizedDescription }
                return Just((genre: "", albums: [])).eraseToAnyPublisher()  // 👈 labels match
            }
            .handleEvents(receiveOutput: { output in
                let genre = output.genre
                let albums = output.albums
                let filteredAlbums = albums.filter { !isAlbumBlacklisted($0) }
                let newSig = sigIDs(filteredAlbums.map(\.id))

                if newSig != self.sigDaily {
                    self.sigDaily = newSig
                    DispatchQueue.main.async {
                        self.dailyGenreName = genre.isEmpty ? nil : genre
                        self.dailyGenreAlbums = filteredAlbums
                    }
                }
            })
            .map { _ in } // Map to Void for MergeMany
            .eraseToAnyPublisher()
    }
    
    // NEW PUBLISHER: loadDailyGenreAlt()
    private func loadDailyGenreAltPublisher() -> AnyPublisher<Void, Never> {
        // Define the explicit output type including labels
        typealias Output = (genre: String, albums: [JellyfinAlbum])

        return feed.fetchDailyGenreAlt(excludingGenre: dailyGenreName, minAlbums: 5, limit: 12)
            // Fix: ensure the catch block returns the exact labeled type
            .catch { err -> AnyPublisher<Output, Never> in
                DispatchQueue.main.async { self.altGenreError = err.localizedDescription }
                return Just((genre: "", albums: [])).eraseToAnyPublisher()  // 👈 labels match
            }
            .handleEvents(receiveOutput: { output in
                let genre = output.genre
                let albums = output.albums
                let filteredAlbums = albums.filter { !isAlbumBlacklisted($0) }
                let newSig = sigIDs(filteredAlbums.map(\.id))

                if newSig != self.sigAlt {
                    self.sigAlt = newSig
                    DispatchQueue.main.async {
                        self.altGenreName = genre.isEmpty ? nil : genre
                        self.altGenreAlbums = filteredAlbums
                    }
                }
            })
            .map { _ in } // Map to Void for MergeMany
            .eraseToAnyPublisher()
    }

    // NEW PUBLISHER: loadMFY()
    private func loadMFYPublisher() -> AnyPublisher<Void, Never> {
        return feed.fetchPlaylistsTaggedMFY(limit: 20)
            .catch { error -> AnyPublisher<[JellyfinAlbum], Never> in
                DispatchQueue.main.async { self.mfyError = error.localizedDescription }
                return Just([]).eraseToAnyPublisher()
            }
            .flatMap { playlists -> AnyPublisher<([JellyfinAlbum], [String: String]), Never> in
                let pubs = playlists.map { p in
                    feed.fetchPlaylistArtistSummary(playlistId: p.id, maxNames: 3)
                        .map { (p.id, $0) }
                        .replaceError(with: (p.id, "Playlist"))
                }
                
                return Publishers.MergeMany(pubs).collect()
                    .map { pairs in
                        let subtitles = Dictionary(uniqueKeysWithValues: pairs)
                        return (playlists, subtitles)
                    }
                    .eraseToAnyPublisher()
            }
            .handleEvents(receiveOutput: { (playlists, subtitles) in
                let newSig = sigIDs(playlists.map(\.id)) // Use sigIDs

                if newSig != self.sigMFY {
                    self.sigMFY = newSig
                    DispatchQueue.main.async {
                        self.mfyPlaylists = playlists
                        self.mfyArtistSubtitles = subtitles
                    }
                }
            })
            .map { _ in } // Map to Void for MergeMany
            .eraseToAnyPublisher()
    }

    // NEW PUBLISHER: loadMood()
    private func loadMoodPublisher() -> AnyPublisher<Void, Never> {
        return feed.fetchPlaylistsTaggedMood(limit: 20)
            .catch { error -> AnyPublisher<[JellyfinAlbum], Never> in
                DispatchQueue.main.async { self.moodError = error.localizedDescription }
                return Just([]).eraseToAnyPublisher()
            }
            .handleEvents(receiveOutput: { playlists in
                let newSig = sigIDs(playlists.map(\.id)) // Use sigIDs

                if newSig != self.sigMood {
                    self.sigMood = newSig
                    DispatchQueue.main.async {
                        self.moodPlaylists = playlists
                    }
                }
            })
            .map { _ in } // Map to Void for MergeMany
            .eraseToAnyPublisher()
    }

    // NEW PUBLISHER: loadNewReleases()
    private func loadNewReleasesPublisher() -> AnyPublisher<Void, Never> {
        return feed.fetchNewestAlbums(limit: 12)
            .catch { error -> AnyPublisher<[JellyfinAlbum], Never> in
                DispatchQueue.main.async { self.newError = error.localizedDescription }
                return Just([]).eraseToAnyPublisher()
            }
            .handleEvents(receiveOutput: { albums in
                let filteredAlbums = albums.filter { !isAlbumBlacklisted($0) }
                let newSig = sigIDs(filteredAlbums.map(\.id)) // Use sigIDs

                if newSig != self.sigNew {
                    self.sigNew = newSig
                    DispatchQueue.main.async {
                        self.newReleases = filteredAlbums
                    }
                }
            })
            .map { _ in } // Map to Void for MergeMany
            .eraseToAnyPublisher()
    }

    // NEW PUBLISHER: loadUpdatedPlaylist()
    private func loadUpdatedPlaylistPublisher() -> AnyPublisher<Void, Never> {
        return feed.fetchMostRecentlyUpdatedPlaylist()
            .catch { error -> AnyPublisher<JellyfinAlbum?, Never> in
                DispatchQueue.main.async { self.updatedError = error.localizedDescription }
                return Just(nil).eraseToAnyPublisher()
            }
            .handleEvents(receiveOutput: { pl in
                let safePl = (pl != nil && !hasTagCI(pl!.tags, "BlacklistHV")) ? pl : nil
                
                // Use sigIDs helper, ensuring array input
                let newSig = sigIDs([safePl?.id].compactMap { $0 })
                
                if newSig != self.sigUpdated {
                    self.sigUpdated = newSig
                    DispatchQueue.main.async {
                        self.updatedPlaylist = safePl
                    }
                }
            })
            .map { _ in } // Map to Void for MergeMany
            .eraseToAnyPublisher()
    }

    // NEW PUBLISHER: loadMoreLike() with retry logic (Failure == Never throughout)
    private func loadMoreLikePublisher(maxTries: Int = 6) -> AnyPublisher<Void, Never> {

        func attempt(_ triesLeft: Int) -> AnyPublisher<(JellyfinAlbum?, [JellyfinAlbum]), Never> {
            // 1) Make the *first* fetch failure-free
            return feed.fetchDailyRandomAlbum()
                .catch { _ in Just<JellyfinAlbum?>(nil).eraseToAnyPublisher() }
                .flatMap { anchorOpt -> AnyPublisher<(JellyfinAlbum?, [JellyfinAlbum]), Never> in
                    guard let anchor = anchorOpt else {
                        return Just((nil, [])).eraseToAnyPublisher()
                    }
                    // 2) Also failure-free
                    return feed.fetchSimilarAlbumsDaily(for: anchor.id, limit: 12)
                        .map { (anchor, $0) }
                        .catch { _ in Just((anchor, [])) }
                        .eraseToAnyPublisher()
                }
                .flatMap { rawAnchor, rawAlbums -> AnyPublisher<(JellyfinAlbum?, [JellyfinAlbum]), Never> in
                    // Filter blacklist
                    let safeAnchor = (rawAnchor != nil && !isAlbumBlacklisted(rawAnchor!)) ? rawAnchor : nil
                    let filteredAlbums = rawAlbums.filter { !isAlbumBlacklisted($0) }

                    if let a = safeAnchor, !filteredAlbums.isEmpty {
                        return Just((a, filteredAlbums)).eraseToAnyPublisher()
                    }
                    // Retry if needed
                    if triesLeft > 1 {
                        return attempt(triesLeft - 1)
                    } else {
                        return Just((nil, [])).eraseToAnyPublisher()
                    }
                }
                .eraseToAnyPublisher()
        }

        return attempt(maxTries)
            .handleEvents(receiveOutput: { anchor, albums in
                let albumIDs = albums.map(\.id)
                let anchorID = anchor?.id ?? ""
                let newSig = sigIDs(albumIDs) + ":ANCHOR:\(anchorID)"

                if newSig != self.sigMoreLike {
                    self.sigMoreLike = newSig
                    DispatchQueue.main.async {
                        self.moreLikeAnchor = anchor
                        self.moreLikeAlbums = albums
                    }
                }
            })
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    // NEW PUBLISHER: loadAMPPublisher()
    private func loadAMPPublisher() -> AnyPublisher<Void, Never> {
        return feed.fetchPlaylistsAlphabetical(tag: "AMP", limit: 200)
            .map { lists in
                lists.filter { hasTagCI($0.tags, "AMP") && !shouldHideInFeatured($0) }
            }
            .catch { error -> AnyPublisher<[JellyfinAlbum], Never> in
                DispatchQueue.main.async { self.ampError = error.localizedDescription }
                return Just([]).eraseToAnyPublisher()
            }
            .handleEvents(receiveOutput: { playlists in
                let newSig = sigIDs(playlists.map(\.id)) // Use sigIDs

                if newSig != self.sigAMP {
                    self.sigAMP = newSig
                    DispatchQueue.main.async {
                        self.ampPlaylists = playlists
                    }
                }
            })
            .map { _ in } // Map to Void for MergeMany
            .eraseToAnyPublisher()
    }
    
    // NEW PUBLISHER: loadReplay()
    private func loadReplayPublisher() -> AnyPublisher<Void, Never> {
        return feed.fetchPlaylists(withTag: "replay", limit: 100)
            .map { lists in
                lists.compactMap { p -> (JellyfinAlbum, Int)? in
                    guard hasTagCI(p.tags, "replay"), let y = replayYear(for: p), y >= 2021 else { return nil }
                    return (p, y)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
            }
            .catch { error -> AnyPublisher<[JellyfinAlbum], Never> in
                DispatchQueue.main.async { self.replayError = error.localizedDescription }
                return Just([]).eraseToAnyPublisher()
            }
            .flatMap { playlists -> AnyPublisher<([JellyfinAlbum], [String: String]), Never> in
                let pubs = playlists.map { p in
                    feed.fetchPlaylistArtistSummary(playlistId: p.id, maxNames: 3)
                        .map { (p.id, $0) }
                        .replaceError(with: (p.id, "Playlist"))
                }
                return Publishers.MergeMany(pubs).collect()
                    .map { pairs in
                        let subtitles = Dictionary(uniqueKeysWithValues: pairs)
                        return (playlists, subtitles)
                    }
                    .eraseToAnyPublisher()
            }
            .handleEvents(receiveOutput: { (playlists, subtitles) in
                let newSig = sigIDs(playlists.map(\.id)) // Use sigIDs

                if newSig != self.sigReplay {
                    self.sigReplay = newSig
                    DispatchQueue.main.async {
                        self.replayPlaylists = playlists
                        self.replayArtistSubtitles = subtitles
                    }
                }
            })
            .map { _ in } // Map to Void for MergeMany
            .eraseToAnyPublisher()
    }
    
    private func replayYear(for p: JellyfinAlbum) -> Int? {
        if let y = p.productionYear { return y }
        let name = p.name.lowercased()
        if let m = name.range(of: #"(20\d{2})"#, options: .regularExpression),
            let y = Int(name[m]) { return y }
        if let t = p.tags {
            for tag in t {
                if let m = tag.range(of: #"(20\d{2})"#, options: .regularExpression),
                    let y = Int(tag[m]) { return y }
            }
        }
        return nil
    }
}

private extension Array where Element == JellyfinTrack {
    // Small array helper to drop a duplicate (by model id) if we’re prepending one
    func dedupByID(excluding id: String) -> [JellyfinTrack] {
        self.filter { $0.id != id }
    }
}


// MARK: - Small Square Card (static)
private struct SmallSquareCard: View {
    let imageURL: URL?
    let title: String
    let subtitle: String?
    let size: CGFloat
    var isExplicit: Bool = false    // NEW

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WebImage(url: imageURL)
                .resizable()
                .indicator(.activity)
                .transition(.fade)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
                .cornerRadius(10)
                .shadow(radius: 4, y: 2)

            // UPDATED: HStack for title + E badge
            HStack(spacing: 3) { // <- TIGHTER SPACING
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .truncationMode(.tail)
                    .alignmentGuide(.lastTextBaseline) { $0[.bottom] } // ALIGN TO BOTTOM FOR VISUAL BASELINE

                if isExplicit { ExplicitBadge() } // NEW
            }
            .frame(width: size, alignment: .leading) // Constrain the HStack to the card width

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: size, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Section header
private struct SectionHeader: View {
    let title: String
    var bottomSpacing: CGFloat
    
    init(_ t: String, bottomSpacing: CGFloat = 0) {
        self.title = t
        self.bottomSpacing = bottomSpacing
    }
    
    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.bottom, bottomSpacing)
    }
}

// 1) Put chevron right next to the "Replay" header - NEW STRUCT
private struct InlineHeaderLink<Destination: View>: View {
    let title: String
    var bottomSpacing: CGFloat = 0
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, bottomSpacing)
    }
}

private struct HeaderLink<Destination: View>: View {
    let title: String
    var bottomSpacing: CGFloat = 0
    let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle()) // whole row tappable
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, bottomSpacing)
    }
}

// MARK: - Poster Card (with optional animated overlay)
struct PosterCard: View {
    let imageURL: URL?
    let animatedURL: URL?
    let title: String
    let artist: String?
    let year: Int?
    let width: CGFloat
    var isExplicit: Bool = false    // NEW
    var forceDarkBanner: Bool = false // <-- 2) Add a flag to PosterCard

    // 👈 ADDED NEW KNOBS (Step 3)
    var showTitle: Bool = true
    var subtitleLineLimit: Int? = 1

    // UPDATED: Start with a default color and force white text
    @State private var bannerColor: Color = Color(.systemGray5)
    @State private var textColor: Color = .white
    
    // FIX 1: Add/adjust state vars
    @State private var videoReady = false
    @State private var player: AVQueuePlayer? = nil // Switched to AVQueuePlayer
    @State private var statusObs: NSKeyValueObservation? = nil // Observer for readiness
    @State private var keepUpObs: NSKeyValueObservation? = nil // FIX 2: Added keepUpObs
    // End Fix 1

    private var height: CGFloat { width * 13.2 / 10 }
    private var bannerHeight: CGFloat { height / 4 }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background fill
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            VStack(spacing: 0) {
                ZStack {
                    // Static cover image (visible first)
                    AsyncCover(url: imageURL) { uiImage in
                        let base = uiImage.averageColor ?? UIColor.systemGray5
                        // 2) Darken harder when that flag is on
                        let target: CGFloat = forceDarkBanner ? 0.06 : 0.12  // darker for Replay
                        let dark = base.darkenedForWhiteText(targetLuminance: target)
                        bannerColor = Color(dark)
                        textColor = .white // 2) set text to white
                    }
                    .frame(width: width, height: width)
                    .clipShape(TopCorners(radius: 14))

                    // FIX 3: Replaced animated overlay block with FadeInPlayerLayer
                    // Animated video overlay (fade ON TOP when really ready)
                    #if canImport(AVKit)
                    if animatedURL != nil, let player {
                        FadeInPlayerLayer(player: player, isVisible: videoReady)
                            .frame(width: width, height: width)
                            .clipShape(TopCorners(radius: 14))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    #else
                    EmptyView()
                    #endif
                }
                Spacer(minLength: 0)
            }

            // 👈 UPDATED BANNER TEXT BLOCK (Step 3)
            VStack(alignment: .center, spacing: 2) {
                Spacer()

                // Title row -> only when enabled
                if showTitle {
                    HStack(spacing: 3) { // <- TIGHTER SPACING
                        Text(title)
                            .font(.system(size: 14))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .alignmentGuide(.lastTextBaseline) { $0[.bottom] } // ALIGN TO BOTTOM

                        if isExplicit { ExplicitBadge() }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                // Subtitle (artist list) -> allow wrapping (no truncation)
                if let artist {
                    Text(artist)
                        .font(.system(size: 12))
                        .opacity(0.85)
                        .lineLimit(subtitleLineLimit)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let year { Text(String(year)).font(.system(size: 12)).opacity(0.85).lineLimit(1) }
                Spacer()
            }
            .foregroundStyle(forceDarkBanner ? .white : textColor)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: bannerHeight)
            .background(
                LinearGradient(colors: [bannerColor.opacity(0.92), bannerColor],
                               startPoint: .top, endPoint: .bottom)
                .clipShape(BottomCorners(radius: 14))
            )
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear(perform: setupPlayer)
        .onDisappear(perform: teardownPlayer)
    }

    // FIX 4: Replaced setupPlayer() to wait for full readiness
    private func setupPlayer() {
        guard player == nil, let url = animatedURL else { return }

        let asset = AVURLAsset(url: url)
        let item  = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2.5
        item.preferredPeakBitRate = 1_500_000
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        let q = AVQueuePlayer(items: [item])
        q.isMuted = true
        q.automaticallyWaitsToMinimizeStalling = true
        q.actionAtItemEnd = .none

        // Loop
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                object: item, queue: .main) { [weak q] _ in
            q?.seek(to: .zero)
            q?.playImmediately(atRate: 1.0)
        }

        // Helper: mark visible & start playback
        let turnOn = { [weak q] in
            guard let q = q else { return }
            // Only set videoReady if player item is actually ready to play AND likely to keep up
            if item.status == .readyToPlay, item.isPlaybackLikelyToKeepUp {
                DispatchQueue.main.async { self.videoReady = true }
                q.playImmediately(atRate: 1.0)
            }
        }

        // Observe readiness + likelyToKeepUp to avoid black
        statusObs = item.observe(\.status, options: [.initial, .new]) { _, _ in
            turnOn()
        }
        // FIX: Add keepUpObs and observe it
        keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { _, _ in
            turnOn()
        }

        // Store player and warm the pipeline without showing it yet
        self.player = q
        q.play()
        q.rate = 0 // warm buffer; playImmediately flips to 1.0 in turnOn()
    }

    // FIX 5: Updated teardownPlayer() to clean up both observers
    private func teardownPlayer() {
        statusObs?.invalidate()
        keepUpObs?.invalidate()
        statusObs = nil
        keepUpObs = nil

        player?.pause()
        player?.removeAllItems()
        player = nil
        videoReady = false
    }
}


// MARK: - Async image with average color callback
private struct AsyncCover: View {
    let url: URL?
    var onImage: (UIImage) -> Void

    @State private var uiImage: UIImage?
    // FIX: Add state for task and lastURL
    @State private var task: URLSessionDataTask?
    @State private var lastURL: URL?

    var body: some View {
        ZStack {
            if let img = uiImage {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(.tertiarySystemFill))
                    .overlay(ProgressView())
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: url) { _ in
            // FIX: reset state and reload when URL changes
            if lastURL != url {
                task?.cancel()
                uiImage = nil
                loadIfNeeded()
            }
        }
    }

    private func loadIfNeeded() {
        guard let url else { return }
        lastURL = url
        // always (re)load for the current URL
        task?.cancel()
        let newTask = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                // Only set if URL hasn't changed mid-flight
                if self.lastURL == url {
                    self.uiImage = img
                    self.onImage(img)
                }
            }
        }
        task = newTask
        newTask.resume()
    }
}

// MARK: - Shapes
private struct TopCorners: Shape {
    var radius: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

private struct BottomCorners: Shape {
    var radius: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.bottomLeft, .bottomRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Average color helpers
private extension UIImage {
    var averageColor: UIColor? {
        guard let inputImage = CIImage(image: self) else { return nil }
        let extentVector = CIVector(x: inputImage.extent.origin.x,
                                    y: inputImage.extent.origin.y,
                                    z: inputImage.extent.size.width,
                                    w: inputImage.extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: inputImage,
                                                 kCIInputExtentKey: extentVector]),
              let outputImage = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull!])
        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)
        return UIColor(red: CGFloat(bitmap[0]) / 255,
                       green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255,
                       alpha: 1.0)
    }
}

private extension UIColor {
    // OLD implementation removed, superseded by new `luminance` property
    var prefersLightText: Bool {
        // Now using the WCAG-ish luminance check
        return self.luminance < 0.25 // A reasonable threshold for black vs white text contrast
    }
}

// MARK: - Album detail loader (no transitionNamespace; URLSession-based)
private struct AlbumDetailLoader: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    let albumId: String

    @State private var album: JellyfinAlbum? = nil
    @State private var error: String? = nil
    @State private var isLoading = false
    @State private var bag = Set<AnyCancellable>()

    var body: some View {
        Group {
            if let album = album {
                AlbumDetailView(album: album).environmentObject(apiService)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                VStack(spacing: 12) {
                    Text("Failed to load album").font(.headline)
                    Text(error).font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear.onAppear(perform: loadAlbum)
            }
        }
        .onAppear(perform: loadAlbum)
    }

    private func loadAlbum() {
        guard !isLoading, album == nil else { return }
        guard !apiService.serverURL.isEmpty,
              !apiService.userId.isEmpty,
              !apiService.authToken.isEmpty else {
            self.error = "Not authenticated with server."
            return
        }

        isLoading = true
        error = nil

        var comps = URLComponents(string: "\(apiService.serverURL)Users/\(apiService.userId)/Items")
        comps?.queryItems = [
            .init(name: "Ids", value: albumId),
            .init(
                name: "Fields",
                value: "Overview,UserData,OfficialRating,CommunityRating,ProductionYear,PremiereDate,DateCreated,AlbumArtist,ArtistItems,Tags,RunTimeTicks,Genres,AlbumId,ParentIndexNumber,ImageTags" // Ensure ImageTags is fetched
            )
        ]

        guard let url = comps?.url else {
            self.isLoading = false
            self.error = "Bad URL."
            return
        }

        var req = URLRequest(url: url)
        req.setValue(apiService.authorizationHeader(withToken: apiService.authToken),
                     forHTTPHeaderField: "X-Emby-Authorization")

        struct ItemsEnvelope<T: Decodable>: Decodable { let Items: [T]? }

        URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, resp -> Data in
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: ItemsEnvelope<JellyfinAlbum>.self, decoder: JSONDecoder())
            .map { $0.Items?.first }
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let err) = completion {
                    self.error = err.localizedDescription
                }
            } receiveValue: { album in
                self.album = album
                if album == nil { self.error = "Album not found." }
            }
            .store(in: &bag)
    }
}

// MARK: - REVISED Tall Poster Card
private struct TallPosterCard: View {
    let imageURL: URL?
    let blurb: String?
    
    var cornerRadius: CGFloat = 24

    var body: some View {
        ZStack(alignment: .bottom) {
            WebImage(url: imageURL)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            
            if let blurb, !blurb.isEmpty {
                Text(blurb)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 6, y: 2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .aspectRatio(3.0/4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
    }
}

// MARK: - Radio Square Card (static)
private struct RadioSquareCard: View {
    let imageName: String   // Asset name == station name
    let title: String
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
                .cornerRadius(10)      // same radius as albums
                .shadow(radius: 4, y: 2)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(width: size, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let jellyfinNowPlayingDidChange = Notification.Name("jellyfinNowPlayingDidChange")
}


// MARK: - New Context Menu Preview Tile
fileprivate struct HomeContextPreviewTile: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Use WebImage for consistency with the rest of HomeView
            WebImage(url: imageURL)
                .resizable()
                .indicator(.activity)
                .transition(.fade)
                .scaledToFill()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
        .frame(width: 280, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(20)
        .clipped()
    }
}
