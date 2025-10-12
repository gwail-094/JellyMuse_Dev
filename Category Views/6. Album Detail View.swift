import SwiftUI
import Combine
import SDWebImageSwiftUI
import AVKit
import AVFoundation
import CoreImage // Needed for CIImage and CIFilter

// MARK: - Deterministic shuffle
private struct LCRandom {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 0x9E3779B97F4A7C15 }
    
    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1
        return state
    }
    
    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

private extension Array {
    func shuffled(seed: UInt64) -> [Element] {
        var out = self
        var rng = LCRandom(seed: seed)
        var i = out.count - 1
        while i > 0 {
            let r = Int(rng.nextDouble() * Double(i + 1))
            out.swapAt(i, r)
            i -= 1
        }
        return out
    }
}

private enum RecOrderCache {
    static var similarAlbumsByAlbum: [String: [JellyfinAlbum]] = [:] // Cache the actual albums
    
    static func getCached(for albumId: String) -> [JellyfinAlbum]? {
        return similarAlbumsByAlbum[albumId]
    }
    
    static func cache(_ albums: [JellyfinAlbum], for albumId: String) {
        similarAlbumsByAlbum[albumId] = albums
    }
}

// ✅ 2A) Add shared playback state model
final class PlaybackState: ObservableObject {
    static let shared = PlaybackState()
    @Published var currentTrackId: String = ""   // set this from your player
    @Published var isPlaying: Bool = false       // set this from your player
}

struct AlbumDetailView: View {
    // MARK: - Properties
    let album: JellyfinAlbum

    // ★ NEW: namespace + flag to slightly change entry behavior if needed
    let zoomNamespace: Namespace.ID?
    let isZoomDestination: Bool

    init(album: JellyfinAlbum,
         zoomNamespace: Namespace.ID? = nil,
         isZoomDestination: Bool = false) {
        self.album = album
        self.zoomNamespace = zoomNamespace
        self.isZoomDestination = isZoomDestination
    }
    
    // MARK: - State & Environment
    @StateObject private var playback = PlaybackState.shared // ✅ 2B) Use playback state
    
    // ★ NEW: Separate namespace for carousel transitions
    @Namespace private var carouselZoomNS
    
    @State private var heroPlayer: AVPlayer? = nil
    @State private var squarePlayer: AVPlayer? = nil
    @State private var overlayColorDecided = false
    @State private var desiredHeroAspect: CGFloat = 1.48 // tweak 1.20–1.33 for "a bit taller"
    
    @State private var tracks: [JellyfinTrack] = []
    @State private var cancellables = Set<AnyCancellable>()
    @State private var isFavoriteAlbum: Bool = false
    @State private var navArtist: JellyfinArtistItem?
    @State private var moreByArtist: [JellyfinAlbum] = []
    @State private var similarAlbums: [JellyfinAlbum] = []
    @State private var videoReadySquare = false
    @State private var videoReadyPoster = false

    // Dynamic overlay styling (poster hero)
    @State private var overlayWantsDarkText = false   // true => use black/"dark" text

    // Launch Veil State
    @State private var showLaunchVeil = true
    @State private var tracksReady = false
    @State private var heroReady = false   // poster OR square video ready
    @State private var imageReady = false  // fallback if no video

    // Stretch Animation State
    @State private var allowStretch = false   // only allow stretch after veil is gone
    @State private var isDragging = false     // only stretch while user drags
    
    // 1) State for the sheet
    @State private var showOverviewSheet = false

    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase

    @EnvironmentObject var apiService: JellyfinAPIService
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Layout Constants
    @ScaledMetric(relativeTo: .caption) private var badgeHeight: CGFloat = 28
    
    // Badge tuning (light)
    private let dolbyBadgeScale: CGFloat     = 0.95
    private let dolbyBadgeYOffset: CGFloat   = 1.5
    
    private let hiresBadgeScale: CGFloat     = 0.55
    private let hiresBadgeYOffset: CGFloat   = 0.0
    
    private let losslessBadgeScale: CGFloat  = 0.55
    private let losslessBadgeYOffset: CGFloat = 0.0
    
    // Badge tuning (black variants) — tweak these as you like
    private let dolbyBadgeScaleBlack: CGFloat      = 0.60
    private let dolbyBadgeYOffsetBlack: CGFloat    = 1.5
    
    private let hiresBadgeScaleBlack: CGFloat      = 0.55
    private let hiresBadgeYOffsetBlack: CGFloat    = 0.0
    
    private let losslessBadgeScaleBlack: CGFloat   = 0.55
    private let losslessBadgeYOffsetBlack: CGFloat = 0.0

    private let horizontalPad: CGFloat = 20
    private let primaryButtonHeight: CGFloat = 46
    private let primaryButtonsHPad: CGFloat = 8
    
    private let showPosterLegibilityGradient = false

    // Recs strip tuning
    private let recsTopOffset: CGFloat = 30
    private let recsItemSpacing: CGFloat = 14
    
    private let posterSpacingTitleToArtist: CGFloat = 2
    private let posterSpacingArtistToMeta: CGFloat = 2
    private let posterSpacingMetaToButtons: CGFloat = 2 // was 6
    private let posterOverlayBottomPadding: CGFloat = 10   // distance from buttons to hero bottom
    private let posterSpacingButtonsToOverview: CGFloat = 10

    // MARK: - Computed Properties
    private var sortedTracks: [JellyfinTrack] {
        tracks.sorted {
            let d0 = $0.parentIndexNumber ?? 1
            let d1 = $1.parentIndexNumber ?? 1
            if d0 != d1 { return d0 < d1 }
            let t0 = $0.indexNumber ?? Int.max
            let t1 = $1.indexNumber ?? Int.max
            return t0 < t1
        }
    }
    
    private var studioTags: [String] {
        (album.tags ?? [])
            .compactMap { tag -> String? in
                let lower = tag.lowercased()
                guard lower.hasPrefix("studio:") else { return nil }
                let parts = tag.split(separator: ":", maxSplits: 1)
                return parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            }
    }
    
    private var overviewText: String? {
        album.overview?
            .replacingOccurrences(of: "\r\n", with: "\n")   // normalize
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private var artistFirst: JellyfinArtistItem? { album.albumArtists?.first }
    private var artistName: String { album.albumArtists?.map { $0.name }.joined(separator: ", ") ?? "" }
    private var badge: (name: String, kind: BadgeKind)? { badgeFor(album) }
    private var discs: [Int: [JellyfinTrack]] { Dictionary(grouping: sortedTracks, by: { $0.parentIndexNumber ?? 1 }) }
    private var discKeys: [Int] { discs.keys.sorted() }

    private var isDigitalMaster: Bool {
        let lowercasedTags = album.tags?.map { $0.lowercased() } ?? []
        return lowercasedTags.contains("digital master")
    }

    /// Finds animated artwork tags and separates them into poster vs square
    private var animatedSquareURL: URL? {
        animatedArtworkURLs.first { $0.absoluteString.lowercased().contains("animated.mp4") }
    }

    private var animatedPosterURL: URL? {
        animatedArtworkURLs.first { $0.absoluteString.lowercased().contains("poster.mp4") }
    }

    private var hasPosterHero: Bool { animatedPosterURL != nil }

    /// Returns all URLs for AnimatedArtwork= tags
    private var animatedArtworkURLs: [URL] {
        (album.tags ?? []).compactMap { tag -> URL? in
            let lower = tag.lowercased()
            guard lower.hasPrefix("animatedartwork=") else { return nil }
            let raw = String(tag.split(separator: "=", maxSplits: 1).last ?? "")
            let enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
            return URL(string: enc)
        }
    }
    
    private var contentReady: Bool {
        let heroOk: Bool = {
            if hasPosterHero { return heroReady }       // poster: wait for video first frame
            else if animatedSquareURL != nil { return heroReady }
            else { return imageReady }
        }()
        return tracksReady && heroOk
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            // your existing content
            contentView
                .allowsHitTesting(!showLaunchVeil)

            Color(.systemBackground)
                .ignoresSafeArea()
                .opacity((showLaunchVeil && !isZoomDestination) ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: showLaunchVeil && !isZoomDestination)
                .allowsHitTesting(showLaunchVeil && !isZoomDestination)
        }
        .sheet(isPresented: $showOverviewSheet) {
            OverviewSheetView(
                title: album.name,
                text: overviewText ?? ""
            )
            .presentationDetents([.fraction(0.99)])
            .presentationCornerRadius(30)
            .presentationDragIndicator(.hidden)
        }
    }
    
    private var contentView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // HERO (poster takes priority)
                if let posterURL = animatedPosterURL {
                    posterHero(posterURL: posterURL)
                } else {
                    albumCoverSection
                    albumInfoSection
                    Divider()
                        .padding(.leading, 16)
                        .padding(.top, 20)
                }
                trackListSection
            }
        }
        .coordinateSpace(name: "albumScroll")
        .scrollIndicators(.hidden)
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: { downloadAlbum(album) }) {
                    Image(systemName: "arrow.down")
                }
                
                Menu {
                    Button(action: { playNextAlbum(album) }) {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    Button(action: { toggleFavoriteAlbum(album) }) {
                        Label(isFavoriteAlbum ? "Undo Favorite" : "Favorite",
                              systemImage: isFavoriteAlbum ? "star.fill" : "star")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .tint(.primary)
        .onAppear {
            isVisible = true
            
            if isZoomDestination { showLaunchVeil = false }
            
            allowStretch = false
            showLaunchVeil = true
            tracksReady = false
            heroReady = false
            imageReady = false
            
            videoReadySquare = false
            videoReadyPoster = false
            isFavoriteAlbum = album.userData?.isFavorite ?? false
            loadTracks()
            loadMoreAndSimilar()
            
            if let remotePoster = animatedPosterURL {
                ensurePosterCached(remoteURL: remotePoster, albumId: album.id) { localURL in
                    guard let localURL else { return }
                    let asset = makeCellularOKAsset(url: localURL)

                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.appliesPreferredTrackTransform = true
                    let t = CMTime(seconds: 0.12, preferredTimescale: 600)
                    if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                        let ui = UIImage(cgImage: cg)
                        if let avg = ui.averageColor {
                            DispatchQueue.main.async {
                                if avg.prefersDarkText { overlayWantsDarkText = true }
                                overlayColorDecided = true
                            }
                        }
                    }

                    let item = AVPlayerItem(asset: asset)
                    item.preferredForwardBufferDuration = 0.5

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
                    self.heroPlayer = p
                }
            }
            
            if let squareURL = animatedSquareURL {
                let asset = makeCellularOKAsset(url: squareURL)
                let item = AVPlayerItem(asset: asset)
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
                self.squarePlayer = p
            } else {
                self.squarePlayer = nil
            }

            let safetyDelay: TimeInterval = hasPosterHero ? 1.6 : 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + safetyDelay) {
                if showLaunchVeil {
                    showLaunchVeil = false
                    allowStretch = true
                }
            }
        }
        .onChange(of: contentReady) { ready in
            guard ready else { return }
            let extra: TimeInterval = hasPosterHero ? 0.25 : 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + extra) {
                showLaunchVeil = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    allowStretch = true
                }
            }
        }
        .onDisappear {
            isVisible = false
            
            heroPlayer?.pause()
            heroPlayer = nil

            squarePlayer?.pause()
            squarePlayer = nil

            videoReadySquare = false
            videoReadyPoster = false
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if isVisible {
                    heroPlayer?.play()
                    squarePlayer?.play()
                }
                PlaybackState.shared.isPlaying = true // Player resumes
            case .inactive, .background:
                heroPlayer?.pause()
                squarePlayer?.pause()
                PlaybackState.shared.isPlaying = false
            @unknown default:
                break
            }
        }
        .navigationDestination(item: $navArtist) { artist in
            ArtistDetailView(artist: artist).environmentObject(apiService)
        }
    }
    
    // MARK: - Subviews
    
    private func posterHero(posterURL: URL) -> some View {
        let minH = UIScreen.main.bounds.width * desiredHeroAspect
        return ParallaxHeader(minHeight: minH) {
            GeometryReader { innerGeo in
                let width = innerGeo.size.width
                let height = innerGeo.size.height

                ZStack(alignment: .bottom) {
                    WebImage(url: apiService.imageURL(for: album.id)) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(Color.gray.opacity(0.2)).overlay(ProgressView())
                    }
                    .onSuccess { image, _, _ in
                        DispatchQueue.main.async {
                            imageReady = true
                            if !overlayColorDecided, let avg = image.averageColor {
                                overlayWantsDarkText = avg.prefersDarkText
                                overlayColorDecided = true
                            }
                        }
                    }
                    .frame(width: width, height: height)
                    .clipped()
                    .opacity(heroPlayer == nil ? 1 : 0)

                    VideoPlayerView(
                        player: heroPlayer,
                        onReady: { videoReadyPoster = true; heroReady = true },
                        onFail:  { videoReadyPoster = false }
                    )
                    .frame(width: width, height: height)
                    .allowsHitTesting(false)
                    .opacity(videoReadyPoster ? 1 : 0)

                    overlayContent
                        .padding(.bottom, posterOverlayBottomPadding)
                }
                .frame(width: width, height: height)
                .background(Color.black)
                .clipped()
                .ifLet(zoomNamespace) { view, ns in
                    view.navigationTransition(.zoom(sourceID: album.id, in: ns))
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
    
    @ViewBuilder
    private var overlayContent: some View {
        let titleColor: Color  = overlayWantsDarkText ? .black : .white
        let artistColor: Color = overlayWantsDarkText ? .black : .white
        let metaColor: Color   = overlayWantsDarkText ? .black : Color(.systemGray)
        let buttonTextColor: Color = overlayWantsDarkText ? .black : .white
    
        VStack(spacing: 0) {
            Text(album.name)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
                .shadow(radius: overlayWantsDarkText ? 0 : 4)
                .padding(.bottom, posterSpacingTitleToArtist)

            if let firstArtist = artistFirst {
                Button { self.navArtist = firstArtist } label: {
                    Text(artistName)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(artistColor)
                        .multilineTextAlignment(.center)
                        .shadow(radius: overlayWantsDarkText ? 0 : 3)
                }
                .buttonStyle(.plain)
                .padding(.bottom, posterSpacingArtistToMeta)
            }

            HStack(spacing: 6) {
                if let genre = album.genres?.first, !genre.isEmpty {
                    Text(genre).font(.caption).fontWeight(.semibold)
                }
                if let genre = album.genres?.first, !genre.isEmpty, album.productionYear != nil {
                    Text("·").font(.caption)
                }
                if let year = album.productionYear {
                    Text(String(year)).font(.caption).fontWeight(.semibold)
                }
                if let b = badge {
                    Text("·").font(.caption)
                    Image(badgeImageName(for: b.kind, wantsBlack: overlayWantsDarkText))
                        .resizable()
                        .renderingMode(.original)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: badgeHeight * badgeScale(for: b.kind, wantsBlack: overlayWantsDarkText))
                        .offset(y: badgeYOffset(for: b.kind, wantsBlack: overlayWantsDarkText))
                }
            }
            .foregroundStyle(metaColor)
            .shadow(radius: overlayWantsDarkText ? 0 : 1)
            .padding(.bottom, posterSpacingMetaToButtons)

            HStack(spacing: 12) {
                Button {
                    apiService.playTrack(tracks: sortedTracks, startIndex: 0, albumArtist: artistName)
                    setNowPlaying(trackId: sortedTracks.first?.id, playing: true)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(buttonTextColor)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

                Button {
                    let list = tracks.shuffled()
                    apiService.playTrack(tracks: list, startIndex: 0, albumArtist: artistName)
                    setNowPlaying(trackId: list.first?.id, playing: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.headline)
                        .foregroundStyle(buttonTextColor)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }

            if let desc = overviewText {
                OverviewTeaser(
                    text: desc,
                    isOnDark: !overlayWantsDarkText,
                    onMore: { showOverviewSheet = true },
                    font: .callout,
                    weight: .regular,
                    lineSpacing: 1,
                    maxLines: 2
                )
                .padding(.top, hasPosterHero ? posterSpacingButtonsToOverview : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, posterOverlayBottomPadding)
        .frame(maxWidth: .infinity, alignment: .center)
    }
    
    private var albumCoverSection: some View {
        let animatedTagURL = animatedSquareURL

        return ZStack {
            let artCorner: CGFloat = 8

            WebImage(url: apiService.imageURL(for: album.id)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(ProgressView())
            }
            .onSuccess { _, _, _ in
                DispatchQueue.main.async { imageReady = true }
            }
            .frame(width: 260, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: artCorner, style: .continuous))
            .ifLet(zoomNamespace) { view, ns in
                view.navigationTransition(.zoom(sourceID: "album-art-\(album.id)", in: ns))
            }

            if animatedTagURL != nil {
                VideoPlayerView(
                    player: squarePlayer,
                    onReady: {
                        DispatchQueue.main.async {
                            videoReadySquare = true
                            heroReady = true
                        }
                    },
                    onFail:  {
                        DispatchQueue.main.async { videoReadySquare = false }
                    }
                )
                .frame(width: 260, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: artCorner, style: .continuous))
                .opacity(videoReadySquare ? 1 : 0)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 8)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 130)
    }

    private var albumInfoSection: some View {
        VStack(alignment: .center, spacing: 3) {
            Text(album.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .frame(maxWidth: UIScreen.main.bounds.width * 0.75)

            if let firstArtist = artistFirst {
                Button {
                    self.navArtist = firstArtist
                } label: {
                    Text(artistName)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                if let genre = album.genres?.first, !genre.isEmpty {
                    Text(genre)
                        .font(.caption)
                        .fontWeight(.semibold)
                }

                if let genre = album.genres?.first, !genre.isEmpty,
                   album.productionYear != nil {
                    Text("·").font(.caption).foregroundColor(.secondary)
                }

                if let year = album.productionYear {
                    Text(String(year))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }

                if let badge = badge {
                    if album.genres?.first != nil || album.productionYear != nil {
                        Text("·").font(.caption).foregroundColor(.secondary)
                    }
                    Image(badge.name)
                        .resizable()
                        .renderingMode(.original)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: badgeHeight * badgeScale(for: badge.kind, wantsBlack: false))
                        .offset(y: badgeYOffset(for: badge.kind, wantsBlack: false))
                }
            }
            .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button {
                    apiService.playTrack(tracks: sortedTracks, startIndex: 0, albumArtist: artistName)
                    setNowPlaying(trackId: sortedTracks.first?.id, playing: true)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, minHeight: primaryButtonHeight)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }

                Button {
                    let list = tracks.shuffled()
                    apiService.playTrack(tracks: list, startIndex: 0, albumArtist: artistName)
                    setNowPlaying(trackId: list.first?.id, playing: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.headline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, minHeight: primaryButtonHeight)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 4)

            if let desc = overviewText {
                OverviewTeaser(text: desc, isOnDark: false) {
                    showOverviewSheet = true
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, horizontalPad)
        .padding(.top, 16)
    }
    
    private var trackListSection: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(discKeys, id: \.self) { disc in
                discSection(disc: disc)
            }
            bottomSummarySection
            if !moreByArtist.isEmpty || !similarAlbums.isEmpty {
                recommendationsSection
            }
        }
    }
    
    private func discSection(disc: Int) -> some View {
        Group {
            if discKeys.count > 1 {
                Text("Disc \(disc)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .padding(.horizontal, horizontalPad)
                    .padding(.top, 12)
                    .padding(.vertical, 14)
            }

            let tracksInDisc = (discs[disc] ?? []).sorted {
                ($0.indexNumber ?? Int.max) < ($1.indexNumber ?? Int.max)
            }

            ForEach(tracksInDisc, id: \.id) { track in
                let tid = idFor(track)
                TrackRow(
                    track: track,
                    albumArtistName: artistName,
                    isDownloaded: apiService.trackIsDownloaded(track.id),
                    onTapPlay: {
                        if let idx = sortedTracks.firstIndex(where: { $0.id == track.id }) {
                            apiService.playTrack(tracks: sortedTracks, startIndex: idx, albumArtist: artistName)
                            setNowPlaying(trackId: track.id, playing: true)
                        }
                    },
                    onMenuPlayNext: { AudioPlayer.shared.queueNext(track) },
                    onMenuCreateStation: { createStation(for: track.id) },
                    onMenuFavorite: { toggleFavorite(track) },
                    onMenuDownload: { download(track) },
                    isNowPlaying: tid == currentTrackId,
                    isPlaying: isPlaybackActive
                )
                .contextMenu(menuItems: {
                    Button(action: { AudioPlayer.shared.queueNext(track) }) {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    Button(action: { createStation(for: track.id) }) {
                        Label("Create Station", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button(action: { download(track) }) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    Button(action: { toggleFavorite(track) }) {
                        Label("Favorite", systemImage: "star")
                    }
                }, preview: {
                    TrackContextPreviewTile(
                        track: track,
                        album: album,
                        imageURL: apiService.imageURL(for: album.id)
                    )
                })
                .tint(.primary)
            }
        }
    }
    
    private var bottomSummarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isDigitalMaster {
                HStack(spacing: 6) {
                    Image("badge_digital_master")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(height: 12)
                    Text("Apple Digital Master")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 10)
            }
            
            if let dateString = formattedAlbumDate(album) {
                Text(dateString).font(.footnote).foregroundColor(.secondary)
            }
            
            let totalTracks = sortedTracks.count
            if let durationString = formattedAlbumDuration(sortedTracks) {
                Text("\(totalTracks) song\(totalTracks == 1 ? "" : "s"), \(durationString)")
                    .font(.footnote).foregroundColor(.secondary)
            }

            if !studioTags.isEmpty {
                ForEach(studioTags, id: \.self) { t in
                    Text(t)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, horizontalPad)
        .padding(.top, 20)
    }
    
    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let headerName = album.albumArtists?.first?.name, !moreByArtist.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("More by \(headerName)")
                        .font(.title2.bold())
                        .padding(.leading, horizontalPad)
                    albumHorizontalScrollView(albums: moreByArtist, subtitleMode: .releaseYear)
                }
            }
            if !similarAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("You Might Also Like")
                        .font(.title2.bold())
                        .padding(.leading, horizontalPad)
                    albumHorizontalScrollView(albums: similarAlbums, subtitleMode: .artistName)
                }
            }
        }
        .padding(.top, recsTopOffset)
        .padding(.bottom, 40)
    }

    private func albumHorizontalScrollView(albums: [JellyfinAlbum], subtitleMode: AlbumMiniCard.SubtitleMode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: recsItemSpacing) {
                ForEach(albums) { a in
                    NavigationLink {
                        // ★ DESTINATION: Pass carousel namespace and mark as zoom destination
                        AlbumDetailView(
                            album: a,
                            zoomNamespace: carouselZoomNS,
                            isZoomDestination: true
                        )
                        .environmentObject(apiService)
                        .navigationTransition(.zoom(sourceID: a.id, in: carouselZoomNS))
                    } label: {
                        // ★ SOURCE: Mark carousel item as transition source
                        AlbumMiniCard(
                            album: a,
                            imageURL: apiService.imageURL(for: a.id),
                            subtitleMode: subtitleMode
                        )
                        .matchedTransitionSource(id: a.id, in: carouselZoomNS)
                    }
                    .buttonStyle(.plain)
                    .contextMenu(menuItems: {
                        Button(action: { playAlbum(a) }) { Label("Play", systemImage: "play.fill") }
                        Button(action: { shuffleAlbum(a) }) { Label("Shuffle", systemImage: "shuffle") }
                        Button(action: { playNextAlbum(a) }) { Label("Play Next", systemImage: "text.insert") }
                        Button(action: { toggleFavoriteAlbum(a) }) { Label("Favorite", systemImage: "star") }
                        Button(action: { downloadAlbum(a) }) { Label("Download", systemImage: "arrow.down.circle") }
                    }, preview: {
                        AlbumContextPreviewTile(
                            title: a.name,
                            subtitle: (a.albumArtists?.first?.name) ?? "",
                            imageURL: apiService.imageURL(for: a.id),
                            corner: 20
                        )
                        .frame(width: 280)
                    })
                    .tint(.primary)
                }
            }
            .padding(.horizontal, horizontalPad)
        }
        .scrollClipDisabled(true)
    }
    
    // --- Badge helpers ---
    private func badgeScale(for kind: BadgeKind, wantsBlack: Bool) -> CGFloat {
        switch (kind, wantsBlack) {
        case (.dolby, false):    return dolbyBadgeScale
        case (.dolby, true):     return dolbyBadgeScaleBlack
        case (.hires, false):    return hiresBadgeScale
        case (.hires, true):     return hiresBadgeScaleBlack
        case (.lossless, false): return losslessBadgeScale
        case (.lossless, true):  return losslessBadgeScaleBlack
        }
    }

    private func badgeYOffset(for kind: BadgeKind, wantsBlack: Bool) -> CGFloat {
        switch (kind, wantsBlack) {
        case (.dolby, false):    return dolbyBadgeYOffset
        case (.dolby, true):     return dolbyBadgeYOffsetBlack
        case (.hires, false):    return hiresBadgeYOffset
        case (.hires, true):     return hiresBadgeYOffsetBlack
        case (.lossless, false): return losslessBadgeYOffset
        case (.lossless, true):  return losslessBadgeYOffsetBlack
        }
    }

    private func badgeImageName(for kind: BadgeKind, wantsBlack: Bool) -> String {
        switch kind {
        case .dolby:     return wantsBlack ? "badge_dolby_black"    : "badge_dolby"
        case .hires:     return wantsBlack ? "badge_hires_black"    : "badge_hires"
        case .lossless:  return wantsBlack ? "badge_lossless_black" : "badge_lossless"
        }
    }
}

// Average color + luminance helper (fast 1×1 downsample)
private extension UIImage {
    var averageColor: UIColor? {
        guard let input = CIImage(image: self) else { return nil }
        let extent = input.extent
        let params: [String: Any] = [kCIInputImageKey: input,
                                     kCIInputExtentKey: CIVector(cgRect: extent)]
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: params),
              let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: kCFNull!])
        ctx.render(output,
                   toBitmap: &bitmap,
                   rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8,
                   colorSpace: nil)
        return UIColor(red: CGFloat(bitmap[0])/255,
                       green: CGFloat(bitmap[1])/255,
                       blue: CGFloat(bitmap[2])/255,
                       alpha: 1)
    }
}

private extension UIColor {
    var prefersDarkText: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let L = 0.2126*r + 0.7152*g + 0.0722*b
        return L > 0.72
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let v = value { transform(self, v) } else { self }
    }
}


// MARK: - Helper Functions & Actions
private extension AlbumDetailView {
    private func isBlacklisted(_ a: JellyfinAlbum) -> Bool {
        let tags = (a.tags ?? []).map { $0.lowercased() }
        return tags.contains("blacklist") || tags.contains("blacklisthv")
    }

    private func makeCellularOKAsset(url: URL) -> AVURLAsset {
        let opts: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true
        ]
        return AVURLAsset(url: url, options: opts)
    }
    
    func isSameArtist(_ candidate: JellyfinAlbum, as reference: JellyfinAlbum) -> Bool {
        let refIDs   = Set(reference.albumArtists?.compactMap { $0.id }.filter { !$0.isEmpty } ?? [])
        let refNames = Set(reference.albumArtists?.compactMap { $0.name.lowercased() }.filter { !$0.isEmpty } ?? [])

        let candIDs   = Set(candidate.albumArtists?.compactMap { $0.id }.filter { !$0.isEmpty } ?? [])
        let candNames = Set(candidate.albumArtists?.compactMap { $0.name.lowercased() }.filter { !$0.isEmpty } ?? [])

        if !refIDs.isEmpty && !candIDs.isEmpty { return !refIDs.isDisjoint(with: candIDs) }
        if !refNames.isEmpty && !candNames.isEmpty { return !refNames.isDisjoint(with: candNames) }
        return false
    }

    func ensurePosterCached(remoteURL: URL, albumId: String, completion: @escaping (URL?) -> Void) {
        completion(remoteURL)
    }

    func loadTracks() {
        apiService.fetchTracks(for: album.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { value in
                self.tracks = value
                self.tracksReady = true
            })
            .store(in: &cancellables)
    }

    func loadMoreAndSimilar() {
        if let first = album.albumArtists?.first {
            apiService.fetchArtistAlbumsSmart(artistId: first.id, artistName: first.name)
                .map { albums in
                    albums
                        .filter { $0.id != album.id }
                        .filter { !isBlacklisted($0) }
                }
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { self.moreByArtist = $0 })
                .store(in: &cancellables)
        }
        
        // Check cache first
        if let cached = RecOrderCache.getCached(for: album.id) {
            let cleaned = cached.filter { !isBlacklisted($0) }
            self.similarAlbums = cleaned
            if cleaned.count != cached.count { RecOrderCache.cache(cleaned, for: album.id) }
            return
        }
        
        // If not cached, fetch and cache
        apiService.fetchSimilarAlbums(albumId: album.id, limit: 24)
            .map { incoming in
                incoming
                    .filter { !isSameArtist($0, as: album) }
                    .filter { !isBlacklisted($0) }
            }
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { items in
                let seed = UInt64(abs(album.id.hashValue))
                let ordered = items.shuffled(seed: seed)
                RecOrderCache.cache(ordered, for: album.id)
                self.similarAlbums = ordered
            })
            .store(in: &cancellables)
    }
    
    // MARK: - Now Playing Helpers
    
    private func setNowPlaying(trackId: String?, playing: Bool) {
        guard let id = trackId, !id.isEmpty else { return }
        PlaybackState.shared.currentTrackId = id
        PlaybackState.shared.isPlaying      = playing
    }
    
    private func idFor(_ t: JellyfinTrack) -> String {
        (t.id ?? t.serverId) ?? ""
    }
    
    // ✅ 2B) Use playback state model
    private var currentTrackId: String { playback.currentTrackId }
    private var isPlaybackActive: Bool { playback.isPlaying }
    
    // MARK: - Other Actions
    
    func createStation(for itemId: String) {
        apiService.fetchInstantMix(itemId: itemId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { tracks in
                guard !tracks.isEmpty else { return }
                apiService.playTrack(tracks: tracks, startIndex: 0, albumArtist: nil)
                setNowPlaying(trackId: tracks.first?.id, playing: true)
            })
            .store(in: &cancellables)
    }

    func playAlbum(_ a: JellyfinAlbum) {
        apiService.fetchTracks(for: a.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                let artistName = a.albumArtists?.map { $0.name }.joined(separator: ", ")
                apiService.playTrack(tracks: tracks, startIndex: 0, albumArtist: artistName)
                setNowPlaying(trackId: tracks.first?.id, playing: true)
            }
            .store(in: &cancellables)
    }

    func shuffleAlbum(_ a: JellyfinAlbum) {
        apiService.fetchTracks(for: a.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                let artistName = a.albumArtists?.map { $0.name }.joined(separator: ", ")
                let shuffled = tracks.shuffled()
                apiService.playTrack(tracks: shuffled, startIndex: 0, albumArtist: artistName)
                setNowPlaying(trackId: shuffled.first?.id, playing: true)
            }
            .store(in: &cancellables)
    }

    func playNextAlbum(_ a: JellyfinAlbum? = nil) {
        let target = a ?? album
        apiService.fetchTracks(for: target.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                for t in tracks.reversed() { AudioPlayer.shared.queueNext(t) }
            }
            .store(in: &cancellables)
    }

    func toggleFavoriteAlbum(_ a: JellyfinAlbum) {
        if a.id == self.album.id {
            isFavoriteAlbum.toggle()
        }
    
        let call: AnyPublisher<Void, Error> = (a.userData?.isFavorite ?? false)
            ? apiService.unmarkItemFavorite(itemId: a.id)
            : apiService.markItemFavorite(itemId: a.id)

        call.receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &cancellables)
    }

    func downloadAlbum(_ a: JellyfinAlbum) {
        apiService.downloadAlbum(albumId: a.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &cancellables)
    }
    
    func toggleFavorite(_ track: JellyfinTrack) {
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

    func download(_ track: JellyfinTrack) {
        apiService.downloadTrack(trackId: track.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &cancellables)
    }
    
    func isTrackDownloaded(_ track: JellyfinTrack) -> Bool {
        return apiService.trackIsDownloaded(track.id)
    }
    
    private func formattedAlbumDuration(_ tracks: [JellyfinTrack]) -> String? {
        let totalTicks = tracks.compactMap { $0.runTimeTicks }.reduce(0, +)
        let totalSeconds = Double(totalTicks) / 10_000_000.0
        let totalMinutes = Int(round(totalSeconds / 60.0))

        guard totalMinutes > 0 else { return nil }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        var parts: [String] = []

        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }

        return parts.joined(separator: " ")
    }

    func formattedAlbumDate(_ album: JellyfinAlbum) -> String? {
        guard let dateString = album.releaseDate ?? album.premiereDate ?? album.dateCreated, !dateString.isEmpty else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        let ymdFormatter = DateFormatter()
        ymdFormatter.dateFormat = "yyyy-MM-dd"

        let date = isoFormatter.date(from: dateString) ?? ymdFormatter.date(from: String(dateString.prefix(10)))
        guard let validDate = date else {
            print("⚠️ Could not parse date string: \(dateString)")
            return nil
        }

        let displayFormatter = DateFormatter()
        displayFormatter.locale = .current
        displayFormatter.dateFormat = "d MMMM yyyy"
        return displayFormatter.string(from: validDate)
    }
}

private struct OverviewTeaser: View {
    let text: String
    let isOnDark: Bool
    let onMore: () -> Void
    var font: Font = .footnote
    var weight: Font.Weight = .regular
    var lineSpacing: CGFloat = 0
    var maxLines: Int = 2

    @State private var limitedH: CGFloat = .zero
    @State private var fullH: CGFloat = .zero
    private let moreReserve: CGFloat = 44

    var body: some View {
        let truncated = fullH > (limitedH + 1)

        ZStack(alignment: .bottomTrailing) {
            Text(text)
                .font(font)
                .fontWeight(weight)
                .lineSpacing(lineSpacing)
                .foregroundStyle(isOnDark ? Color.white.opacity(0.82) : Color.secondary)
                .lineLimit(truncated ? maxLines : nil)
                .multilineTextAlignment(.leading)
                .padding(.trailing, truncated ? moreReserve : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(truncated ? AnyView(
                    LinearGradient(
                        stops: [
                            .init(color: .black,                location: 0.00),
                            .init(color: .black,                location: 0.78),
                            .init(color: .black.opacity(0.75), location: 0.88),
                            .init(color: .clear,                location: 1.00)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                ) : AnyView(Color.black))
                .readSize { limitedH = $0.height }

            if truncated {
                Button(action: onMore) {
                    Text("MORE")
                        .font(font).fontWeight(.semibold)
                        .foregroundStyle(isOnDark ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .padding(.bottom, 2)
            }
        }
        .overlay(
            Text(text)
                .font(font)
                .fontWeight(weight)
                .lineSpacing(lineSpacing)
                .foregroundStyle(.clear)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, moreReserve)
                .readSize { fullH = $0.height }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(0)
        )
    }
}

private struct OverviewSheetView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
            
                ScrollView {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}


// MARK: - TrackRow View
struct TrackRow: View {
    let track: JellyfinTrack
    let albumArtistName: String?
    let isDownloaded: Bool
    let onTapPlay: () -> Void
    let onMenuPlayNext: () -> Void
    let onMenuCreateStation: () -> Void
    let onMenuFavorite: () -> Void
    let onMenuDownload: () -> Void
    
    let isNowPlaying: Bool
    let isPlaying: Bool
    let nowPlayingColor: Color = .red

    private func norm(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    if isNowPlaying {
                        CenteredPlayingGlyph(isPlaying: isPlaying, color: .red)
                            .frame(width: 20, height: 18)
                            .padding(.leading, 4)
                    } else {
                        Text("\(track.indexNumber ?? 0)")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 30, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name ?? "Unknown Track")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.primary)
                    +
                    Text(track.isExplicit ? " 🅴" : "")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        
                    if let artists = track.artists, !artists.isEmpty {
                        let trackArtistsJoined = artists.joined(separator: ", ")
                        if norm(trackArtistsJoined) != norm(albumArtistName) {
                            Text(trackArtistsJoined).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer()
    
                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }
    
                Menu {
                    Button(action: onMenuPlayNext) { Label("Play Next", systemImage: "text.insert") }
                    Button(action: onMenuCreateStation) { Label("Create Station", systemImage: "dot.radiowaves.left.and.right") }
                    Button(action: onMenuDownload) { Label("Download", systemImage: "arrow.down.circle") }
                    Button(action: onMenuFavorite) { Label("Favorite", systemImage: "star") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()
                .padding(.leading, 58)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapPlay)
    }
}


// MARK: - Global Helpers & Other Views

/// An equalizer-style glyph with a more dynamic, music-like simulation.
struct CenteredPlayingGlyph: View {
    var isPlaying: Bool
    var color: Color = .red

    // --- Configuration for 6 bars ---
    private let barCount = 6
    private let idleScale: CGFloat = 0.08 // How small the bars are when paused ("dots")

    // --- Animation Tuning ---
    // We use two different sine waves to create more complex motion
    private let speed1: Double = 1.8
    private let speed2: Double = 2.4
    
    // Per-bar values adjusted for 6 bars
    private let minScale: [CGFloat] = [0.2, 0.35, 0.5, 0.5, 0.35, 0.2]
    private let phases1: [Double]   = [0.0, 0.5, 1.0, 0.2, 0.7, 1.2]
    private let phases2: [Double]   = [0.8, 0.3, 1.1, 0.6, 0.1, 0.9]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            // Adjust spacing for 6 bars
            let barW = W / (CGFloat(barCount) * 2.0)
            let gap = barW

            TimelineView(.animation(minimumInterval: 0.04)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate

                HStack(alignment: .center, spacing: gap) {
                    ForEach(0..<barCount, id: \.self) { i in
                        // Combine two sine waves for more variation
                        let osc1 = 0.5 * (1 + sin((t * speed1) + phases1[i]))
                        let osc2 = 0.5 * (1 + sin((t * speed2) + phases2[i]))
                        let combinedOsc = (osc1 + osc2) / 2.0

                        // Determine the final scale
                        let targetScale = max(minScale[i], combinedOsc)
                        let scale = (isPlaying && !reduceMotion) ? targetScale : idleScale

                        Capsule()
                            .fill(color)
                            .frame(width: barW, height: H)
                            .scaleEffect(y: scale, anchor: .center)
                            // Add a subtle animation to smooth the scale changes
                            .animation(.easeOut(duration: 0.1), value: scale)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

private enum BadgeKind { case dolby, hires, lossless }

private func badgeFor(_ album: JellyfinAlbum) -> (name: String, kind: BadgeKind)? {
    let tags = (album.tags ?? []).map { $0.lowercased() }
    if tags.contains(where: { $0.contains("dolby") || $0.contains("atmos") }) { return ("badge_dolby", .dolby) }
    if tags.contains(where: { $0.contains("hi-res") || $0.contains("hires") || $0.contains("hi res") }) { return ("badge_hires", .hires) }
    if tags.contains(where: { $0.contains("lossless") }) { return ("badge_lossless", .lossless) }
    return nil
}

private func albumIsExplicit(_ a: JellyfinAlbum) -> Bool {
    let tags = (a.tags ?? []).map { $0.lowercased() }
    return tags.contains(where: { $0 == "explicit" || $0.contains("explicit") })
}

private struct AlbumMiniCard: View {
    enum SubtitleMode {
        case artistName
        case releaseYear
    }

    let album: JellyfinAlbum
    let imageURL: URL?
    let subtitleMode: SubtitleMode

    private let width: CGFloat = 140
    private let radius: CGFloat = 8
    private let titleSize: CGFloat = 12
    private let artistSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WebImage(url: imageURL)
                .resizable().indicator(.activity).transition(.fade)
                .scaledToFill()
                .frame(width: width, height: width)
                .clipped().cornerRadius(radius)
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(album.name)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1).truncationMode(.tail)
                if albumIsExplicit(album) {
                    Text("🅴").font(.caption).foregroundColor(.secondary)
                }
            }
            
            switch subtitleMode {
            case .artistName:
                if let artist = (album.albumArtists?.first?.name ?? album.artistItems?.first?.name) {
                    Text(artist)
                        .font(.system(size: artistSize))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            case .releaseYear:
                if let year = album.productionYear {
                    Text(String(year))
                        .font(.system(size: artistSize))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Context Menu Previews

fileprivate struct AlbumContextPreviewTile: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let corner: CGFloat
    private let previewWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WebImage(url: imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack { Color.gray.opacity(0.2); ProgressView() }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            VStack(alignment: .leading) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(width: previewWidth)
        .background(Color(.systemBackground))
        .cornerRadius(corner + 4)
    }
}

fileprivate struct TrackContextPreviewTile: View {
    let track: JellyfinTrack
    let album: JellyfinAlbum
    let imageURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            WebImage(url: imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.gray.opacity(0.2)
                    ProgressView()
                }
            }
            .frame(width: 100, height: 100)
            .cornerRadius(18)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.name ?? "Unknown Track")
                    .font(.headline)
                    .lineLimit(1)

                if let artists = track.artists, !artists.isEmpty {
                    Text(artists.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let year = album.productionYear {
                    Text("\(album.name) · \(String(year))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(album.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
        .padding(14)
        .frame(minWidth: 280, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
}

fileprivate struct ParallaxHeader<Content: View>: View {
    let minHeight: CGFloat
    let content: () -> Content
    init(minHeight: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.minHeight = minHeight; self.content = content
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

fileprivate struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
fileprivate extension View {
    func readSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(GeometryReader { Color.clear
            .preference(key: SizeKey.self, value: $0.size)
        })
        .onPreferenceChange(SizeKey.self, perform: onChange)
    }
}
