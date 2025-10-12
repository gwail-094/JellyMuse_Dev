import SwiftUI
import Combine
import AVKit
import AVFoundation
import SDWebImageSwiftUI

struct PlaylistDetailView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @EnvironmentObject var downloads: DownloadsAPI
    @Environment(\.dismiss) private var dismiss

    let playlistId: String

    // Playlist detail loader
    @StateObject private var playlistLoader = PlaylistDetailLoader()

    // Data
    @State private var tracks: [JellyfinTrack] = []
    @State private var visibleTracks: [JellyfinTrack] = []
    @State private var searchText: String = ""

    // UI / state
    @State private var heroPlayer: AVPlayer? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cancellables = Set<AnyCancellable>()

    @State private var showLaunchVeil = true
    @State private var heroReady = false
    @State private var imageReady = false
    @State private var videoReadyPoster = false

    @State private var allowStretch = false

    @State private var navAlbum: JellyfinAlbum?
    
    // Overview State
    @State private var showOverviewSheet = false

    // Download state
    @State private var downloading: Set<String> = []

    // Footer text
    @State private var totalDurationText: String?

    // Layout constants
    private let horizontalPad: CGFloat = 20
    private let coverCorner: CGFloat = 14

    // Computed
    private var playlist: JellyfinAlbum? { playlistLoader.playlist }

    // Normalized overview string
    private var overviewText: String? {
        playlist?.overview?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
    
    // Detect poster.mp4
    private var animatedPosterURL: URL? {
        (playlist?.tags ?? [])
            .compactMap { tag -> URL? in
                let lower = tag.lowercased()
                guard lower.hasPrefix("animatedartwork=") else { return nil }
                let raw = String(tag.split(separator: "=", maxSplits: 1).last ?? "")
                return URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)
            }
            .first { $0.absoluteString.lowercased().contains("poster.mp4") }
    }

    private var hasPosterHero: Bool { animatedPosterURL != nil }

    var body: some View {
        ZStack {
            content
                .allowsHitTesting(!showLaunchVeil)

            // Launch veil
            Color(.systemBackground)
                .ignoresSafeArea()
                .opacity(showLaunchVeil ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: showLaunchVeil)
                .allowsHitTesting(showLaunchVeil)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: handleDownloadAll) {
                    Image(systemName: "arrow.down")
                }
            }
        }
        .tint(.primary)
        .sheet(isPresented: $showOverviewSheet) {
            OverviewSheetView(
                title: playlist?.name ?? "",
                text: overviewText ?? ""
            )
            .presentationDetents([.fraction(0.99)])
            .presentationCornerRadius(30)
            .presentationDragIndicator(.hidden)
        }
        .onAppear {
            showLaunchVeil = true
            allowStretch = false
            videoReadyPoster = false
            heroReady = false
            imageReady = false

            playlistLoader.load(playlistId: playlistId, apiService: apiService)
            loadTracks()
            buildHeroPlayer()

            let safetyDelay: TimeInterval = hasPosterHero ? 1.6 : 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + safetyDelay) {
                if showLaunchVeil {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showLaunchVeil = false
                    }
                    allowStretch = true
                }
            }
        }
        .onDisappear {
            heroPlayer?.pause()
            heroPlayer = nil
            videoReadyPoster = false
            searchText = ""
            visibleTracks = tracks
        }
        .onChange(of: animatedPosterURL) { _ in
            buildHeroPlayer()
        }
        .navigationDestination(item: $navAlbum) { album in
            AlbumDetailView(album: album)
                .environmentObject(apiService)
        }
    }

    // MARK: - Main content
    @ViewBuilder
    private var content: some View {
        if playlistLoader.isLoading || isLoading {
            VStack { Spacer(); ProgressView(); Spacer() }
        } else if let errorMessage = playlistLoader.error ?? errorMessage {
            VStack { Spacer(); Text(errorMessage).foregroundColor(.red); Spacer() }
        } else if playlist == nil {
            VStack { Spacer(); Text("Playlist not found").foregroundColor(.red); Spacer() }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    // 1. Hero section
                    if let posterURL = animatedPosterURL {
                        // Tall hero with video background
                        posterFullBleedHero(posterURL: posterURL)
                    } else {
                        // Square artwork hero with title
                        squareCoverHero

                        // Show Play/Shuffle below title for regular playlists
                        playShuffleButtonsForSquareHero

                        // Overview for square hero
                        if let desc = overviewText {
                            OverviewTeaser(
                                text: desc,
                                isOnDark: false,
                                onMore: { showOverviewSheet = true },
                                font: .callout,
                                weight: .regular,
                                lineSpacing: 1,
                                maxLines: 2
                            )
                            .padding(.horizontal, horizontalPad)
                            .padding(.top, 10)
                        }

                        // Gray divider only for regular playlists
                        Divider()
                            .padding(.leading, 16)
                            .padding(.top, 8)
                    }

                    // 2. Track list
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleTracks, id: \.id) { track in
                            trackRow(track)
                            Divider().padding(.leading, horizontalPad + 48 + 12)
                        }
                    }
                    .padding(.top, 20)

                    // 3. Footer summary
                    if let summary = footerSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, horizontalPad)
                            .padding(.top, 12)
                    }

                    Color.clear.frame(height: 32)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tracks")
            .scrollIndicators(.automatic)
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: searchText) { _ in
                applySearch()
            }
        }
    }

    // MARK: - Poster hero (with clearer buttons)
    private func posterFullBleedHero(posterURL: URL) -> some View {
        let width = UIScreen.main.bounds.width
        let desiredHeroAspect: CGFloat = 1.48
        let heroHeight = width * desiredHeroAspect
        
        return ParallaxHeader(minHeight: heroHeight) {
            GeometryReader { innerGeo in
                let minY = innerGeo.frame(in: .global).minY
                let overscrollAmount = max(0, minY)
                
                ZStack(alignment: .bottom) {
                    // Static fallback
                    WebImage(url: apiService.imageURL(for: playlist?.id ?? "")) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(Color.gray.opacity(0.2)).overlay(ProgressView())
                    }
                    .onSuccess { _, _, _ in
                        DispatchQueue.main.async { imageReady = true }
                    }
                    .frame(width: innerGeo.size.width, height: innerGeo.size.height)
                    .clipped()
                    .opacity(videoReadyPoster ? 0 : 1)

                    // Video
                    VideoPlayerView(
                        player: heroPlayer,
                        onReady: {
                            DispatchQueue.main.async {
                                videoReadyPoster = true
                                heroReady = true
                            }
                        },
                        onFail: {
                            DispatchQueue.main.async { videoReadyPoster = false }
                        }
                    )
                    .opacity(videoReadyPoster ? 1 : 0)
                    .frame(width: innerGeo.size.width, height: innerGeo.size.height)
                    .clipped()
                    .allowsHitTesting(false)

                    // Overlay: Title, artist, buttons, overview
                    VStack(spacing: 8) {
                        Spacer()
                        
                        // Playlist title
                        Text(playlist?.name ?? "")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2)

                        // Artist names
                        if let artists = playlist?.artistItems?.compactMap({ $0.name }), !artists.isEmpty {
                            Text(artists.joined(separator: ", "))
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                        }

                        // Play & Shuffle buttons - more transparent
                        HStack(spacing: 12) {
                            Button {
                                handlePlay(shuffle: false)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(Capsule())
                            }

                            Button {
                                handlePlay(shuffle: true)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }

                        // Overview Teaser
                        if let desc = overviewText {
                            OverviewTeaser(
                                text: desc,
                                isOnDark: true,
                                onMore: { showOverviewSheet = true },
                                font: .callout,
                                weight: .regular,
                                lineSpacing: 1,
                                maxLines: 2
                            )
                            .padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .frame(width: innerGeo.size.width, height: innerGeo.size.height)
                    .offset(y: -overscrollAmount)
                }
                .frame(width: innerGeo.size.width, height: innerGeo.size.height)
            }
        }
    }

    // MARK: - Square fallback hero
    private var squareCoverHero: some View {
        VStack(spacing: 18) {
            if let url = apiService.imageURL(for: playlist?.id ?? "") {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: coverCorner, style: .continuous)
                        .fill(Color.gray.opacity(0.25))
                        .overlay(ProgressView())
                }
                .frame(width: 260, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: coverCorner, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 10)
            }

            Text(playlist?.name ?? "")
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, horizontalPad)
        }
        .padding(.top, 180)
    }

    // MARK: - Play & Shuffle buttons for regular playlists
    private var playShuffleButtonsForSquareHero: some View {
        HStack(spacing: 20) {
            Button(action: { handlePlay(shuffle: false) }) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            Button(action: { handlePlay(shuffle: true) }) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, horizontalPad)
        .padding(.top, 10)
    }

    // MARK: - Track Row
    @ViewBuilder
    private func trackRow(_ track: JellyfinTrack) -> some View {
        let trackId = track.id ?? track.serverId ?? ""
        let isDownloaded = downloads.trackIsDownloaded(trackId)
        let isSpinning = downloading.contains(trackId)

        Button {
            playSingle(track)
        } label: {
            HStack(spacing: 12) {
                RoundedThumb(url: smallCoverURL(for: track), size: 48, corner: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(track.name ?? "Unknown Track")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if track.isExplicit ?? false {
                            Text("🅴")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text((track.artists?.first) ?? "Unknown Artist")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Group {
                    if isSpinning {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(width: 22, height: 22)
                    } else if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .padding(.horizontal, horizontalPad)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                playNext(track)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }

            Button {
                addToQueue(track)
            } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }

            if (track.albumId ?? "").isEmpty == false {
                Button {
                    goToAlbum(from: track)
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
            
            if !trackId.isEmpty, !downloads.trackIsDownloaded(trackId), !downloading.contains(trackId) {
                Button {
                    downloading.insert(trackId)
                    downloads.downloadTrack(trackId: trackId)
                        .receive(on: DispatchQueue.main)
                        .sink(receiveCompletion: { _ in downloading.remove(trackId) },
                              receiveValue: { _ in })
                        .store(in: &cancellables)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            } else if downloads.trackIsDownloaded(trackId) {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - Footer summary
    private var footerSummary: String? {
        let count = visibleTracks.count
        guard count > 0 else { return nil }
        if let duration = totalDurationText, !duration.isEmpty {
            return "\(count) \(count == 1 ? "song" : "songs"), \(duration)"
        } else {
            return "\(count) \(count == 1 ? "song" : "songs")"
        }
    }

    // MARK: - Helpers
    private func playNext(_ track: JellyfinTrack) {
        AudioPlayer.shared.queueNext(track)
    }

    private func addToQueue(_ track: JellyfinTrack) {
        AudioPlayer.shared.queueNext(track)
    }

    private func goToAlbum(from track: JellyfinTrack) {
        guard let albumId = track.albumId, !albumId.isEmpty else { return }
        apiService.fetchAlbumById(albumId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in },
                  receiveValue: { album in
                      self.navAlbum = album
                  })
            .store(in: &cancellables)
    }

    private func buildHeroPlayer() {
        guard let url = animatedPosterURL else {
            heroPlayer?.pause()
            heroPlayer = nil
            return
        }
        
        let item = AVPlayerItem(url: url)
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
        heroPlayer = p
    }
    
    private func seconds(for track: JellyfinTrack) -> Int {
        let ticks = Int64(track.runTimeTicks ?? 0)
        return Int(ticks / 10_000_000)
    }

    private func computeTotalDurationHHMM(from tracks: [JellyfinTrack]) -> String? {
        let totalSeconds = tracks.map { seconds(for: $0) }.reduce(0, +)
        guard totalSeconds > 0 else { return nil }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
    }

    private func smallCoverURL(for track: JellyfinTrack) -> URL? {
        if let id = track.albumId, !id.isEmpty { return apiService.imageURL(for: id) }
        return nil
    }

    // MARK: - Data
    private func loadTracks() {
        isLoading = true
        errorMessage = nil
        apiService.fetchPlaylistTracks(playlistId: playlistId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                isLoading = false
                if case .failure(let err) = completion {
                    errorMessage = "Failed to load playlist: \(err.localizedDescription)"
                }
            }, receiveValue: { t in
                self.tracks = t
                self.applySearch()
                self.totalDurationText = computeTotalDurationHHMM(from: t)
            })
            .store(in: &cancellables)
    }

    private func applySearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            visibleTracks = tracks
            totalDurationText = computeTotalDurationHHMM(from: tracks)
            return
        }
        visibleTracks = tracks.filter {
            ($0.name ?? "").lowercased().contains(q) ||
            (($0.artists?.first ?? "").lowercased().contains(q))
        }
        totalDurationText = computeTotalDurationHHMM(from: visibleTracks)
            ?? computeTotalDurationHHMM(from: tracks)
    }

    // MARK: - Actions
    private func handlePlay(shuffle: Bool) {
        var list = visibleTracks
        if shuffle { list.shuffle() }
        guard !list.isEmpty else { return }
        apiService.playTrack(tracks: list, startIndex: 0, albumArtist: nil)
    }

    private func playSingle(_ track: JellyfinTrack) {
        apiService.playTrack(tracks: [track], startIndex: 0, albumArtist: nil)
    }

    private func handleDownloadAll() {
        let ids: [String] = tracks
            .compactMap { $0.id ?? $0.serverId }
            .filter { !downloads.trackIsDownloaded($0) }
        guard !ids.isEmpty else { return }
        downloading.formUnion(ids)

        Publishers.Sequence(sequence: ids)
            .flatMap(maxPublishers: .max(2)) { id in
                downloads.downloadTrack(trackId: id)
                    .handleEvents(receiveCompletion: { _ in
                        DispatchQueue.main.async {
                            self.downloading.remove(id)
                        }
                    })
            }
            .collect()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let err) = completion {
                        self.errorMessage = "Download failed: \(err.localizedDescription)"
                    }
                },
                receiveValue: { _ in
                    print("✅ Playlist download finished (\(ids.count) tracks)")
                }
            )
            .store(in: &cancellables)
    }
}

// MARK: - Playlist loader
class PlaylistDetailLoader: ObservableObject {
    @Published var playlist: JellyfinAlbum?
    @Published var isLoading = false
    @Published var error: String?

    private var bag = Set<AnyCancellable>()

    func load(playlistId: String, apiService: JellyfinAPIService) {
        guard playlist == nil, !isLoading else { return }
        isLoading = true
        error = nil

        apiService.fetchPlaylistById(playlistId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                self.isLoading = false
                if case .failure(let err) = completion {
                    self.error = err.localizedDescription
                }
            }, receiveValue: { pl in
                self.playlist = pl
                if pl == nil { self.error = "Playlist not found" }
            })
            .store(in: &bag)
    }
}

// MARK: - ParallaxHeader Component
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

// MARK: - RoundedThumb
fileprivate struct RoundedThumb: View {
    let url: URL?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.gray.opacity(0.25))
            if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().scaleEffect(0.8)
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "music.note").foregroundColor(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - OverviewTeaser
private struct OverviewTeaser: View {
    let text: String
    let isOnDark: Bool
    let onMore: () -> Void

    var font: Font = .callout
    var weight: Font.Weight = .regular
    var lineSpacing: CGFloat = 1
    var maxLines: Int = 2

    @State private var fullHeight: CGFloat = .zero
    @State private var limitedHeight: CGFloat = .zero

    private let moreReserve: CGFloat = 44

    var needsMore: Bool { fullHeight > (limitedHeight + 1) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(text)
                .font(font)
                .fontWeight(weight)
                .lineSpacing(lineSpacing)
                .foregroundStyle(isOnDark ? Color.white.opacity(0.82) : Color.secondary)
                .lineLimit(maxLines)
                .multilineTextAlignment(.leading)
                .padding(.trailing, needsMore ? moreReserve : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(TextHeightReader(height: $limitedHeight))
                .mask(
                    Group {
                        if needsMore {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.00),
                                    .init(color: .black, location: 0.78),
                                    .init(color: .black.opacity(0.75), location: 0.88),
                                    .init(color: .clear, location: 1.00)
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        } else {
                            Color.black
                        }
                    }
                )

            if needsMore {
                Button(action: onMore) {
                    Text("MORE")
                        .font(font)
                        .fontWeight(.semibold)
                        .foregroundStyle(isOnDark ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .padding(.bottom, 2)
            }
        }
        .background(
            Text(text)
                .font(font)
                .fontWeight(weight)
                .lineSpacing(lineSpacing)
                .foregroundStyle(.clear)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(TextHeightReader(height: $fullHeight))
                .hidden()
        )
    }
}

// MARK: - TextHeightReader
private struct TextHeightReader: ViewModifier {
    @Binding var height: CGFloat
    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: HeightPreferenceKey.self,
                                    value: proxy.size.height)
                }
            )
            .onPreferenceChange(HeightPreferenceKey.self) { height = $0 }
    }
}

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - OverviewSheetView
private struct OverviewSheetView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                    }
                }
            }
        }
    }
}

// MARK: - String Extension
private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
