//
//  DownloadedPlaylistsView.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 02.09.2025.
//


import SwiftUI
import Combine

struct DownloadedPlaylistsView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @EnvironmentObject var downloads: DownloadsAPI

    @State private var searchText = ""
    @State private var isGridView = true

    // MARK: - Selection State & Helpers
    @State private var isSelecting = false
    @State private var selected = Set<String>()

    private var visiblePlaylists: [DownloadedPlaylistMeta] { playlists }
    private var allSelected: Bool { !visiblePlaylists.isEmpty && selected.count == visiblePlaylists.count }

    // MARK: - Sort Mode
    private enum SortMode: Int, CaseIterable { case title, dateAdded, recentlyPlayed }
    @AppStorage("DownloadedPlaylists.sortMode") private var sortModeRaw: Int = SortMode.dateAdded.rawValue
    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .dateAdded }
    private func setSortMode(_ m: SortMode) { sortModeRaw = m.rawValue }

    private func toggleSelectAll() {
        if allSelected {
            selected.removeAll()
        } else {
            selected = Set(visiblePlaylists.map { $0.id })
        }
    }

    private func togglePlaylistSelection(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func deleteSelectedPlaylists() {
        for id in selected { downloads.deleteDownloadedPlaylist(playlistId: id) }
        selected.removeAll()
        withAnimation { isSelecting = false }
    }
    
    // UI constants
    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 12
    private let titleSize: CGFloat = 12
    private let grid = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    // Derived (sorted + filtered)
    private var playlists: [DownloadedPlaylistMeta] {
        let all = Array(downloads.downloadedPlaylists.values)
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        var filtered = term.isEmpty ? all
                                    : all.filter { $0.name.localizedCaseInsensitiveContains(term) }

        switch sortMode {
        case .title:
            filtered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .dateAdded:
            // Newest file date desc
            filtered.sort { ($0.newestFileDate ?? .distantPast) > ($1.newestFileDate ?? .distantPast) }
        case .recentlyPlayed:
            // Offline placeholder: falls back to newestFileDate
            filtered.sort { ($0.newestFileDate ?? .distantPast) > ($1.newestFileDate ?? .distantPast) }
        }

        return filtered
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                Spacer().frame(height: 8)

                // Offline search
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .disableAutocorrection(true)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color(.systemGray5).clipShape(Capsule()))
                .padding(.horizontal, horizontalPad)

                if isGridView {
                    LazyVGrid(columns: grid, spacing: 20) {
                        ForEach(visiblePlaylists, id: \.id) { p in
                            playlistGridCell(p)
                        }
                    }
                    .padding(.horizontal, horizontalPad)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visiblePlaylists, id: \.id) { p in
                            playlistListCell(p)
                        }
                    }
                    .padding(.horizontal, horizontalPad)
                }

                Color.clear.frame(height: 24)
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Downloaded Playlists")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    Button(action: toggleSelectAll) {
                        Text(allSelected ? "Deselect All" : "Select All")
                    }
                    .tint(Color(.black))
                }
                
                if isSelecting && !selected.isEmpty {
                    Button(role: .destructive, action: deleteSelectedPlaylists) {
                        Image(systemName: "trash")
                    }
                    .foregroundColor(Color(red: 0.95, green: 0.2, blue: 0.3))
                }

                // FILTER menu (sorting)
                Menu {
                    Button(action: { setSortMode(.title) })       { Label("Title",           systemImage: "textformat.abc") }
                    Button(action: { setSortMode(.dateAdded) })   { Label("Date Added",      systemImage: "clock") }
                    Button(action: { setSortMode(.recentlyPlayed) }) { Label("Recently Played", systemImage: "clock.arrow.2.circlepath") }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundColor(.black)
                }

                // THREE DOTS: view mode (grid/list) + Select/Cancel
                Menu {
                    Button(action: { isGridView = true  }) { Label("Grid", systemImage: "square.grid.2x2") }
                    Button(action: { isGridView = false }) { Label("List", systemImage: "list.bullet") }
                    Divider()
                    Button {
                        withAnimation {
                            isSelecting.toggle()
                            selected.removeAll()
                        }
                    } label: {
                        Label(isSelecting ? "Cancel" : "Select", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.black)
                }
            }
        }
    }
    
    // MARK: - Cell Views

    @ViewBuilder
    private func playlistGridCell(_ p: DownloadedPlaylistMeta) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isSelecting {
                    OfflinePlaylistTile(
                        playlistId: p.id,
                        title: p.name,
                        coverRadius: coverRadius,
                        titleSize: titleSize
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlaylistSelection(p.id) }
                } else {
                    NavigationLink {
                        DownloadedPlaylistDetailView(playlistId: p.id)
                            .environmentObject(apiService)
                            .environmentObject(downloads)
                    } label: {
                        OfflinePlaylistTile(
                            playlistId: p.id,
                            title: p.name,
                            coverRadius: coverRadius,
                            titleSize: titleSize
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { playlistContextMenu(meta: p) }
                }
            }

            if isSelecting {
                Button(action: { togglePlaylistSelection(p.id) }) {
                    Image(systemName: selected.contains(p.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(selected.contains(p.id)
                                         ? Color(red: 0.95, green: 0.2, blue: 0.3)
                                         : .secondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    @ViewBuilder
    private func playlistListCell(_ p: DownloadedPlaylistMeta) -> some View {
        ZStack(alignment: .trailing) {
            Group {
                if isSelecting {
                    listCellContent(p)
                        .contentShape(Rectangle())
                        .onTapGesture { togglePlaylistSelection(p.id) }
                } else {
                    NavigationLink {
                        DownloadedPlaylistDetailView(playlistId: p.id)
                            .environmentObject(apiService)
                            .environmentObject(downloads)
                    } label: {
                        listCellContent(p)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { playlistContextMenu(meta: p) }
                }
            }

            if isSelecting {
                Button(action: { togglePlaylistSelection(p.id) }) {
                    Image(systemName: selected.contains(p.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(selected.contains(p.id)
                                         ? Color(red: 0.95, green: 0.2, blue: 0.3)
                                         : .secondary)
                        .padding(.trailing, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    @ViewBuilder
    private func listCellContent(_ p: DownloadedPlaylistMeta) -> some View {
        HStack(spacing: 12) {
            Group {
                if let url = downloads.playlistCoverURL(playlistId: p.id),
                   let ui = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    OfflineRoundedCover(cornerRadius: 10)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(p.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    // MARK: - Context menu
    @ViewBuilder
    private func playlistContextMenu(meta: DownloadedPlaylistMeta) -> some View {
        Button {
            let tracks = downloads.offlineTracks(forTrackIds: meta.trackIds)
            guard !tracks.isEmpty else { return }
            apiService.playTrack(tracks: tracks, startIndex: 0, albumArtist: nil)
        } label: {
            Label("Play", systemImage: "play")
        }

        Button {
            var tracks = downloads.offlineTracks(forTrackIds: meta.trackIds)
            tracks.shuffle()
            guard !tracks.isEmpty else { return }
            apiService.playTrack(tracks: tracks, startIndex: 0, albumArtist: nil)
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button(role: .destructive) {
            downloads.deleteDownloadedPlaylist(playlistId: meta.id)
        } label: {
            Label("Remove from Downloads", systemImage: "trash")
        }
    }
}

// MARK: - Helper Views
fileprivate struct OfflinePlaylistTile: View {
    @EnvironmentObject var downloads: DownloadsAPI
    let playlistId: String
    let title: String
    let coverRadius: CGFloat
    let titleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let url = downloads.playlistCoverURL(playlistId: playlistId),
                   let ui = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                } else {
                    OfflineRoundedCover(cornerRadius: coverRadius)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))

            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

fileprivate struct OfflineRoundedCover: View {
    let cornerRadius: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.systemGray5))
            Image(systemName: "music.note.list")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
