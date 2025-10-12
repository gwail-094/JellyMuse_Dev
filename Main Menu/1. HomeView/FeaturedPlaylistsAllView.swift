//
//  FeaturedPlaylistsAllView.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 27.09.2025.
//


import SwiftUI
import SDWebImageSwiftUI

struct FeaturedPlaylistsAllView: View {
    let playlists: [JellyfinAlbum]
    @EnvironmentObject var apiService: JellyfinAPIService

    @State private var searchText = ""
    @State private var filtered: [JellyfinAlbum] = []

    @AppStorage("FeaturedPlaylistsAllView.isGridView") private var isGridView: Bool = true

    // Match Radio detail “All …” views
    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 8
    private let titleSize: CGFloat = 12
    private let subtitleSize: CGFloat = 11

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer().frame(height: 8)

                if filtered.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundColor(.secondary)
                        Text("No Playlists Found")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("No results based on your search.")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPad)
                } else {
                    if isGridView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(filtered, id: \.id) { p in
                                playlistCell(p)
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(filtered, id: \.id) { p in
                                playlistCell(p)
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
        .navigationTitle("Featured Playlists")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search playlists"
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
            filtered = playlists
            applyFilter()
        }
    }

    // MARK: Filter
    private func applyFilter() {
        guard !searchText.isEmpty else { filtered = playlists; return }
        filtered = playlists.filter { p in
            p.name.localizedCaseInsensitiveContains(searchText)
            || (p.artistItems?.first?.name.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    // MARK: Cell
    @ViewBuilder
    private func playlistCell(_ p: JellyfinAlbum) -> some View {
        NavigationLink {
            PlaylistDetailView(playlistId: p.id)
                .environmentObject(apiService)
        } label: {
            if isGridView {
                VStack(alignment: .leading, spacing: 6) {
                    WebImage(url: apiService.imageURL(for: p.id))
                        .resizable()
                        .indicator(.activity)
                        .transition(.fade)
                        .scaledToFill()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                    Text(p.name)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(p.artistItems?.first?.name ?? "Playlist")
                        .font(.system(size: subtitleSize))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 12) {
                    WebImage(url: apiService.imageURL(for: p.id))
                        .resizable()
                        .indicator(.activity)
                        .transition(.fade)
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(p.artistItems?.first?.name ?? "Playlist")
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
        // (Optional) context menu goes here if you want it
    }
}