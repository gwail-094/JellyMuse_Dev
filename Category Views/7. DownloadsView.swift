import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @EnvironmentObject var downloads: DownloadsAPI

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    private let accent  = Color(red: 0.95, green: 0.2, blue: 0.3)

    @State private var albums: [(albumId: String, albumName: String?, trackCount: Int, newestFileDate: Date)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: Categories
                let titleStart = CategoryRow.hPad + CategoryRow.iconBoxWidth + CategoryRow.gapIconTitle
                VStack(spacing: 0) {
                    NavigationLink {
                        DownloadedPlaylistsView()
                            .environmentObject(apiService)
                            .environmentObject(downloads)
                    } label: {
                        CategoryRow(title: "Playlists", systemImage: "tray.and.arrow.down.fill", accent: accent)
                    }
                    .buttonStyle(.plain)
                    InsetDivider(leading: titleStart)

                    NavigationLink {
                        DownloadedAllAlbumsView()
                            .environmentObject(apiService)
                            .environmentObject(downloads)
                    } label: {
                        CategoryRow(title: "Albums", systemImage: "square.stack.3d.up", accent: accent)
                    }
                    .buttonStyle(.plain)
                    InsetDivider(leading: titleStart)

                    NavigationLink {
                        DownloadedAllSongsView()
                            .environmentObject(apiService)
                            .environmentObject(downloads)
                    } label: {
                        CategoryRow(title: "Songs", systemImage: "music.note", accent: accent)
                    }.buttonStyle(.plain)
                }
                .background(Color(.systemBackground))
                .overlay(InsetDivider(leading: titleStart), alignment: .bottom)

                // MARK: Recently Downloaded
                Text("Recently Downloaded")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 15)

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums, id: \.albumId) { a in
                        NavigationLink {
                            DownloadedAlbumDetailView(albumId: a.albumId, fallbackName: a.albumName ?? "Album")
                                .environmentObject(apiService)
                                .environmentObject(downloads)
                        } label: {
                            DownloadAlbumGridItem(
                                albumName: a.albumName ?? "Album",
                                imageURL: apiService.imageURL(for: a.albumId)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .navigationTitle("Downloads")
        .onAppear(perform: loadOfflineAlbums)
    }

    private func loadOfflineAlbums() {
        downloads.prepareDownloadsFolderIfNeeded()
        let rich = downloads.offlineAlbumsWithMetadata() // <- Use the new function
        self.albums = rich.map { (albumId: $0.albumId,
                                  albumName: $0.albumName,
                                  trackCount: $0.trackCount,
                                  newestFileDate: $0.newestFileDate) }
    }
}

private struct DownloadedSongsListView: View {
    @EnvironmentObject var downloads: DownloadsAPI
    @EnvironmentObject var apiService: JellyfinAPIService
    @State private var trackIds: [String] = []

    var body: some View {
        List(trackIds, id: \.self) { tid in
            Text(downloads.downloadedMeta[tid]?.name ?? tid)
        }
        .onAppear {
            trackIds = Array(downloads.downloadedTrackURLs.keys).sorted()
        }
        .navigationTitle("Downloaded Songs")
    }
}

private struct DownloadedAlbumsListView: View {
    @EnvironmentObject var downloads: DownloadsAPI
    @EnvironmentObject var apiService: JellyfinAPIService
    let albums: [(albumId: String, albumName: String?, trackCount: Int, newestFileDate: Date)]

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums, id: \.albumId) { a in
                    NavigationLink {
                        DownloadedAlbumDetailView(albumId: a.albumId, fallbackName: a.albumName ?? "Album")
                            .environmentObject(apiService)
                            .environmentObject(downloads)
                    } label: {
                        DownloadAlbumGridItem(
                            albumName: a.albumName ?? "Album",
                            imageURL: apiService.imageURL(for: a.albumId)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
        .navigationTitle("Downloaded Albums")
    }
}

// Reuse visual pieces (kept local-friendly)
private struct DownloadAlbumGridItem: View {
    let albumName: String
    let imageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.25))
                .overlay {
                    if let imageURL {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .empty: ProgressView()
                            case .success(let img): img.resizable().scaledToFill()
                            case .failure: Image(systemName: "photo").foregroundColor(.secondary)
                            @unknown default: EmptyView()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .aspectRatio(1, contentMode: .fit)

            Text(albumName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    static let hPad: CGFloat       = 20
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
