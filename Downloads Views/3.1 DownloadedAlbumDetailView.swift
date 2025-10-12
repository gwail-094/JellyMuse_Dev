import SwiftUI
import Combine
import SDWebImageSwiftUI
import AVKit
import AVFoundation

// MARK: - Downloaded Album Detail (no recommendations & no animated artwork)
struct DownloadedAlbumDetailView: View {
    // MARK: - Inputs
    let albumId: String
    let fallbackName: String?

    // MARK: - State & Environment
    @EnvironmentObject var apiService: JellyfinAPIService
    @EnvironmentObject var downloads: DownloadsAPI
    @Environment(\.dismiss) private var dismiss
    
    @State private var album: JellyfinAlbum?
    @State private var tracks: [JellyfinTrack] = []
    @State private var cancellables = Set<AnyCancellable>()
    @State private var showDeleteAlbumAlert = false

    // Layout constants
    @ScaledMetric(relativeTo: .caption) private var badgeHeight: CGFloat = 28
    private let dolbyBadgeScale: CGFloat   = 0.95
    private let dolbyBadgeYOffset: CGFloat = 1.5
    private let hiresBadgeScale: CGFloat   = 0.95
    private let hiresBadgeYOffset: CGFloat = 0.0
    private let losslessBadgeScale: CGFloat   = 0.95
    private let losslessBadgeYOffset: CGFloat = 0.0

    private let horizontalPad: CGFloat = 20
    private let primaryButtonHeight: CGFloat = 46

    // MARK: - Derived
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
    private var discs: [Int: [JellyfinTrack]] { Dictionary(grouping: sortedTracks, by: { $0.parentIndexNumber ?? 1 }) }
    private var discKeys: [Int] { discs.keys.sorted() }
    private var artistName: String {
        if let names = album?.albumArtists?.map({ $0.name }), !names.isEmpty {
            return names.joined(separator: ", ")
        }
        return tracks.first?.artists?.joined(separator: ", ") ?? ""
    }
    private var isDigitalMaster: Bool {
        let lower = album?.tags?.map { $0.lowercased() } ?? []
        return lower.contains("digital master")
    }
    private var badge: (name: String, kind: BadgeKind)? {
        guard let a = album else { return nil }
        return badgeFor(a)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let album {
                    albumCoverSection(album)
                    albumInfoSection(album)
                    trackListSection(album)
                } else {
                    skeletonHeader
                }
            }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let album {
                    Menu {
                        Button {
                            playNextAlbum(album)
                        } label: {
                            Label("Play Next", systemImage: "text.insert")
                        }

                        Button {
                            refreshAlbumAssets()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive) {
                            showDeleteAlbumAlert = true
                        } label: {
                            Label("Remove Download", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .alert("Remove downloaded album?",
               isPresented: $showDeleteAlbumAlert) {
            Button("Delete", role: .destructive) {
                downloads.deleteDownloadedAlbum(albumId: albumId)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes all downloaded tracks for this album from your device.")
        }
        .onAppear(perform: loadOfflineData)
    }

    // MARK: - Sections

    private func albumCoverSection(_ album: JellyfinAlbum) -> some View {
        let localCoverURL = downloads.albumCoverURL(albumId: albumId)

        return ZStack {
            if let url = localCoverURL, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                // Placeholder while offline / until a cover exists locally
                Rectangle().fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.system(size: 80, weight: .light))
                            .foregroundColor(.secondary.opacity(0.5))
                    )
                    .onAppear {
                        // Kick off a best-effort cover fetch if user is online.
                        downloads.ensureAlbumCover(albumId: albumId)
                            .receive(on: DispatchQueue.main)
                            .sink { _ in
                                // Nudge the state to force a redraw and pick up the new file
                                self.album = self.album
                            }
                            .store(in: &cancellables)
                    }
            }
        }
        .frame(width: 260, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 8)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 130)
    }

    private func albumInfoSection(_ album: JellyfinAlbum) -> some View {
        VStack(alignment: .center, spacing: 3) {
            Text(album.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .frame(maxWidth: UIScreen.main.bounds.width * 0.75)

            if !artistName.isEmpty {
                Text(artistName)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 4) {
                if let genre = album.genres?.first, !genre.isEmpty {
                    Text(genre).font(.caption).fontWeight(.semibold)
                }
                if let genre = album.genres?.first, !genre.isEmpty, album.productionYear != nil {
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
                        .frame(height: badgeHeight * badgeScale(for: badge.kind))
                        .offset(y: badgeYOffset(for: badge.kind))
                }
            }
            .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button {
                    AudioPlayer.shared.play(tracks: sortedTracks, startIndex: 0, albumArtist: artistName)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, minHeight: primaryButtonHeight)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }

                Button {
                    AudioPlayer.shared.play(tracks: tracks.shuffled(), startIndex: 0, albumArtist: artistName)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.headline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, minHeight: primaryButtonHeight)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, horizontalPad)
    }

    private func trackListSection(_ album: JellyfinAlbum) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.leading, 16)
                .padding(.top, 8)

            ForEach(discKeys, id: \.self) { disc in
                discSection(disc: disc, album: album)
            }

            bottomSummarySection(album)
                .padding(.bottom, 30)
        }
        .padding(.top, 8)
    }

    private func discSection(disc: Int, album: JellyfinAlbum) -> some View {
        let tracksInDisc = (discs[disc] ?? []).sorted { ($0.indexNumber ?? Int.max) < ($1.indexNumber ?? Int.max) }

        return VStack(alignment: .leading, spacing: 0) {
            if discKeys.count > 1 {
                Text("Disc \(disc)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, horizontalPad)
                    .padding(.top, 12)
                    .padding(.vertical, 14)
            }

            ForEach(tracksInDisc, id: \.id) { track in
                DownloadTrackRow(
                    track: track,
                    albumArtistName: artistName,
                    isDownloaded: downloads.trackIsDownloaded(track.id),
                    onTapPlay: {
                        if let idx = sortedTracks.firstIndex(where: { $0.id == track.id }) {
                            AudioPlayer.shared.play(tracks: sortedTracks, startIndex: idx, albumArtist: artistName)
                        }
                    },
                    onMenuPlayNext: { AudioPlayer.shared.queueNext(track) },
                    onMenuRemoveDownload: {
                        downloads.deleteDownloadedTrack(trackId: track.id)
                        self.tracks = downloads.offlineTracks(forAlbumId: albumId)
                    }
                )
            }
        }
    }

    private func bottomSummarySection(_ album: JellyfinAlbum) -> some View {
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

            if let overview = album.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
               !overview.isEmpty {
                Text(overview).font(.footnote).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
        }
        .padding(.horizontal, horizontalPad)
        .padding(.top, 10)
    }

    // MARK: - Data loading

    private func loadOfflineData() {
        self.tracks = downloads.offlineTracks(forAlbumId: albumId)

        if let first = tracks.first {
            let localName = downloads.downloadedMeta[first.id]?.albumName
            self.album = JellyfinAlbum(
                id: albumId,
                name: localName ?? fallbackName ?? "Album",
                artistItems: nil,           // keep nil offline
                productionYear: nil,
                genres: nil,
                albumArtists: nil,          // or synthesize if you have a model for it
                userData: nil
            )
        } else {
            self.album = JellyfinAlbum(
                id: albumId,
                name: fallbackName ?? "Album",
                artistItems: nil,
                productionYear: nil,
                genres: nil,
                albumArtists: nil,
                userData: nil
            )
        }
    }

    // MARK: - Actions & helpers
    
    /// Re-scan local files and refresh the cover from the server (if connected).
    private func refreshAlbumAssets() {
        // Ensure (re)download of the cover; when done, nudge the UI so the new file is read.
        downloads.ensureAlbumCover(albumId: albumId)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                // A minimal nudge to trigger a redraw of the cover section
                self.album = self.album
            }
            .store(in: &cancellables)

        // Rebuild track list from disk
        self.tracks = downloads.offlineTracks(forAlbumId: albumId)
    }

    private func playNextAlbum(_ a: JellyfinAlbum) {
        let localTracks = downloads.offlineTracks(forAlbumId: a.id)
        guard !localTracks.isEmpty else { return }
        for t in localTracks.reversed() { AudioPlayer.shared.queueNext(t) }
    }
    
    // NOTE: This function isn't called from the UI anymore, but updating it for consistency.
    private func downloadAlbum(_ a: JellyfinAlbum) {
        downloads.downloadAlbum(albumId: a.id)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &cancellables)
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

    private func formattedAlbumDate(_ album: JellyfinAlbum) -> String? {
        guard let ds = album.releaseDate ?? album.premiereDate ?? album.dateCreated, !ds.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        let ymd = DateFormatter(); ymd.dateFormat = "yyyy-MM-dd"
        let date = iso.date(from: ds) ?? ymd.date(from: String(ds.prefix(10)))
        guard let d = date else { return nil }
        let out = DateFormatter()
        out.locale = .current
        out.dateFormat = "d MMMM yyyy"
        return out.string(from: d)
    }

    // Badges
    private func badgeScale(for kind: BadgeKind) -> CGFloat {
        switch kind {
        case .dolby: return dolbyBadgeScale
        case .hires: return hiresBadgeScale
        case .lossless: return losslessBadgeScale
        }
    }
    private func badgeYOffset(for kind: BadgeKind) -> CGFloat {
        switch kind {
        case .dolby: return dolbyBadgeYOffset
        case .hires: return hiresBadgeYOffset
        case .lossless: return losslessBadgeYOffset
        }
    }

    // Skeleton while loading album meta
    private var skeletonHeader: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2))
                .frame(width: 260, height: 260).overlay(ProgressView())
                .padding(.top, 130)
            Text(fallbackName ?? "Album")
                .font(.system(size: 20, weight: .bold))
                .redacted(reason: .placeholder)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

// MARK: - Reused helpers

private enum BadgeKind { case dolby, hires, lossless }

private func badgeFor(_ album: JellyfinAlbum) -> (name: String, kind: BadgeKind)? {
    let tags = (album.tags ?? []).map { $0.lowercased() }
    if tags.contains(where: { $0.contains("dolby") || $0.contains("atmos") }) { return ("badge_dolby", .dolby) }
    if tags.contains(where: { $0.contains("hi-res") || $0.contains("hires") || $0.contains("hi res") }) { return ("badge_hires", .hires) }
    if tags.contains(where: { $0.contains("lossless") }) { return ("badge_lossless", .lossless) }
    return nil
}

// MARK: - DownloadTrackRow (downloads-only)
private struct DownloadTrackRow: View {
    let track: JellyfinTrack
    let albumArtistName: String?
    let isDownloaded: Bool

    // Actions we actually need in downloads
    let onTapPlay: () -> Void
    let onMenuPlayNext: () -> Void
    let onMenuRemoveDownload: () -> Void

    private func norm(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(track.indexNumber ?? 0)")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.secondary)
                    .frame(width: 30, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name ?? "Unknown Track")
                        .font(.system(size: 15, weight: .regular))
                    +
                    Text((track.isExplicit ?? false) ? " 🅴" : "")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)

                    if let artists = track.artists, !artists.isEmpty {
                        let joined = artists.joined(separator: ", ")
                        if norm(joined) != norm(albumArtistName) {
                            Text(joined)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
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

                // Three-dots menu (only Play Next + Remove Download)
                Menu {
                    Button(action: onMenuPlayNext) {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    Button(role: .destructive, action: onMenuRemoveDownload) {
                        Label("Remove Download", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider().padding(.leading, 58)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapPlay)
    }
}
