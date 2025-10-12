//
//  SectionHeaderLink.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 03.10.2025.
//

import SwiftUI
import Combine
import SDWebImageSwiftUI

// MARK: - Reusable Header with Chevron (Artist Detail style)
struct ArtistSectionHeaderLink<Destination: View>: View {
    let title: String
    @ViewBuilder var destination: Destination
    var leadingPadding: CGFloat = 22   // matches ArtistDetailView.sectionLeading

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - All Top Songs (grid/list, searchable)
struct AllArtistTopSongsView: View {
    let artistName: String
    let tracks: [JellyfinTrack]

    /// Optional: map albumId -> album title (for subtitle + search)
    var albumTitlesById: [String: String] = [:]

    @EnvironmentObject var apiService: JellyfinAPIService

    @State private var searchText = ""
    @State private var filtered: [JellyfinTrack] = []

    @AppStorage("AllArtistTopSongsView.isGridView") private var isGridView: Bool = false

    private let horizontalPad: CGFloat = 20
    private let coverCorner: CGFloat = 8
    private let titleSize: CGFloat = 13
    private let subtitleSize: CGFloat = 11

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer().frame(height: 8)

                if filtered.isEmpty {
                    EmptyState(icon: "music.note", title: "No Songs Found", subtitle: "No results based on your search.")
                        .padding(.horizontal, horizontalPad)
                } else {
                    if isGridView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(filtered, id: \.id) { t in
                                songGridCell(t)
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered, id: \.id) { t in
                                songListRow(t)
                                Divider().padding(.leading, 20 + 44 + 10) // align below artwork
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    }
                }

                Color.clear.frame(height: 120)
            }
            .padding(.top, -20)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Top Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in applyFilter() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { isGridView = true })  { Label("Grid", systemImage: isGridView ? "checkmark" : "") }
                    Button(action: { isGridView = false }) { Label("List", systemImage: !isGridView ? "checkmark" : "") }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .tint(.primary)
        .onAppear {
            filtered = tracks
            applyFilter()
        }
    }

    // MARK: - Helpers

    private func albumTitle(for t: JellyfinTrack) -> String {
        guard let aid = t.albumId, !aid.isEmpty else { return "" }
        return albumTitlesById[aid] ?? ""
    }

    private func isExplicit(_ t: JellyfinTrack) -> Bool {
        if let tags = t.tags,
           tags.contains(where: { $0.caseInsensitiveCompare("Explicit") == .orderedSame }) {
            return true
        }
        return t.isExplicit
    }

    private func smallCoverURL(for track: JellyfinTrack) -> URL? {
        if let aid = track.albumId, !aid.isEmpty { return apiService.imageURL(for: aid) }
        return apiService.imageURL(for: track.id)
    }

    // MARK: - Filter

    private func applyFilter() {
        guard !searchText.isEmpty else { filtered = tracks; return }
        filtered = tracks.filter { t in
            let title = t.name ?? ""
            let album = albumTitle(for: t)
            return title.localizedCaseInsensitiveContains(searchText) ||
                   album.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Cells

    private func songListRow(_ t: JellyfinTrack) -> some View {
        Button {
            apiService.playTrack(tracks: [t], startIndex: 0, albumArtist: artistName)
        } label: {
            HStack(spacing: 10) {
                WebImage(url: smallCoverURL(for: t))
                    .resizable()
                    .indicator(.activity)
                    .transition(.fade)
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: coverCorner, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(t.name ?? "Unknown Track")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if isExplicit(t) {
                            Image(systemName: "e.square.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(albumTitle(for: t).isEmpty ? artistName : albumTitle(for: t))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func songGridCell(_ t: JellyfinTrack) -> some View {
        Button {
            apiService.playTrack(tracks: [t], startIndex: 0, albumArtist: artistName)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                WebImage(url: smallCoverURL(for: t))
                    .resizable()
                    .indicator(.activity)
                    .transition(.fade)
                    .scaledToFill()
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: coverCorner, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                HStack(spacing: 4) {
                    Text(t.name ?? "Unknown Track")
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if isExplicit(t) {
                        Image(systemName: "e.square.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                Text(albumTitle(for: t).isEmpty ? artistName : albumTitle(for: t))
                    .font(.system(size: subtitleSize))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - All Albums (grid/list, searchable)
struct AllArtistAlbumsView: View {
    let artistName: String
    let albums: [JellyfinAlbum]

    @EnvironmentObject var apiService: JellyfinAPIService

    @State private var searchText = ""
    @State private var filtered: [JellyfinAlbum] = []

    @AppStorage("AllArtistAlbumsView.isGridView") private var isGridView: Bool = true

    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 8
    private let titleSize: CGFloat = 12
    private let subtitleSize: CGFloat = 11

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer().frame(height: 8)

                if filtered.isEmpty {
                    EmptyState(icon: "square.stack", title: "No Albums Found", subtitle: "No results based on your search.")
                        .padding(.horizontal, horizontalPad)
                } else {
                    if isGridView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(filtered, id: \.id) { a in
                                albumCell(a)
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(filtered, id: \.id) { a in
                                albumCell(a)
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    }
                }

                Color.clear.frame(height: 120)
            }
            .padding(.top, -20)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in applyFilter() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { isGridView = true })  { Label("Grid", systemImage: isGridView ? "checkmark" : "") }
                    Button(action: { isGridView = false }) { Label("List", systemImage: !isGridView ? "checkmark" : "") }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .tint(.primary)
        .onAppear {
            filtered = albums
            applyFilter()
        }
    }

    private func applyFilter() {
        guard !searchText.isEmpty else { filtered = albums; return }
        filtered = albums.filter { a in
            a.name.localizedCaseInsensitiveContains(searchText) ||
            (a.albumArtists?.first?.name.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    @ViewBuilder
    private func albumCell(_ a: JellyfinAlbum) -> some View {
        NavigationLink {
            AlbumDetailView(album: a)
                .environmentObject(apiService)
        } label: {
            if isGridView {
                VStack(alignment: .leading, spacing: 6) {
                    WebImage(url: apiService.imageURL(for: a.id))
                        .resizable()
                        .indicator(.activity)
                        .transition(.fade)
                        .scaledToFill()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                    HStack(spacing: 4) {
                        Text(a.name)
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if a.isExplicit {
                            Image(systemName: "e.square.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(a.albumArtists?.first?.name ?? artistName)
                        .font(.system(size: subtitleSize))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 12) {
                    WebImage(url: apiService.imageURL(for: a.id))
                        .resizable()
                        .indicator(.activity)
                        .transition(.fade)
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(a.name)
                                .font(.system(size: titleSize, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            if a.isExplicit {
                                Image(systemName: "e.square.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text(a.albumArtists?.first?.name ?? artistName)
                            .font(.system(size: subtitleSize))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - All Music Videos (grid/list, searchable)
struct AllArtistMusicVideosView: View {
    let artistName: String
    let musicVideos: [ArtistVideo]

    @State private var searchText = ""
    @State private var filtered: [ArtistVideo] = []

    @AppStorage("AllArtistMusicVideosView.isGridView") private var isGridView: Bool = true

    private let horizontalPad: CGFloat = 20
    private let thumbCorner: CGFloat = 8
    private let titleSize: CGFloat = 13
    private let subtitleSize: CGFloat = 11

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer().frame(height: 8)

                if filtered.isEmpty {
                    EmptyState(icon: "play.rectangle",
                               title: "No Music Videos Found",
                               subtitle: "No results based on your search.")
                        .padding(.horizontal, horizontalPad)
                } else {
                    if isGridView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(filtered) { v in
                                videoGridCell(v)
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(filtered) { v in
                                videoListRow(v)
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    }
                }

                Color.clear.frame(height: 120)
            }
            .padding(.top, -20)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Music Videos")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in applyFilter() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { isGridView = true })  { Label("Grid", systemImage: isGridView ? "checkmark" : "") }
                    Button(action: { isGridView = false }) { Label("List", systemImage: !isGridView ? "checkmark" : "") }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .tint(.primary)
        .onAppear {
            filtered = musicVideos
            applyFilter()
        }
    }

    private func applyFilter() {
        guard !searchText.isEmpty else { filtered = musicVideos; return }
        filtered = musicVideos.filter { v in
            v.title.localizedCaseInsensitiveContains(searchText) ||
            v.yearText.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func videoListRow(_ v: ArtistVideo) -> some View {
        Button {
            if let url = v.watchURL { UIApplication.shared.open(url) }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: v.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .empty: Color.gray.opacity(0.25).overlay(ProgressView())
                    default: Color.gray.opacity(0.25).overlay(Image(systemName: "play.rectangle").foregroundColor(.secondary))
                    }
                }
                .frame(width: 140, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: thumbCorner, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(v.title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if !v.yearText.isEmpty {
                        Text(v.yearText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "play.fill").foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func videoGridCell(_ v: ArtistVideo) -> some View {
        Button {
            if let url = v.watchURL { UIApplication.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: v.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .empty: Color.gray.opacity(0.25).overlay(ProgressView())
                    default: Color.gray.opacity(0.25).overlay(Image(systemName: "play.rectangle").foregroundColor(.secondary))
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: thumbCorner, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                Text(v.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .frame(height: 34, alignment: .top)

                if !v.yearText.isEmpty {
                    Text(v.yearText)
                        .font(.system(size: subtitleSize))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Small shared empty state
private struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .multilineTextAlignment(.center)
    }
}
