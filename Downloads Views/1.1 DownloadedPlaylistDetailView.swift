//
//  DownloadedPlaylistDetailView.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 03.09.2025.
//


import SwiftUI
import Combine

/// Offline detail screen for a *downloaded* playlist
struct DownloadedPlaylistDetailView: View {
    let playlistId: String

    @EnvironmentObject var apiService: JellyfinAPIService
    @EnvironmentObject var downloads: DownloadsAPI

    @State private var title: String = "Playlist"
    @State private var tracks: [JellyfinTrack] = []
    @State private var showDeleteAlert = false
    @State private var isRefreshing = false
    @State private var refreshError: String?

    private let horizontalPad: CGFloat = 20
    private let primaryButtonHeight: CGFloat = 46

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Header (simple offline cover + title)
                VStack(spacing: 12) {
                    Group {
                        if let url = downloads.playlistCoverURL(playlistId: playlistId),
                           let ui = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFill()
                        } else {
                            // final placeholder
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(.systemGray5))
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 36, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)

                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)

                    if !tracks.isEmpty {
                        Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    // Play / Shuffle
                    HStack(spacing: 12) {
                        Button {
                            guard !tracks.isEmpty else { return }
                            AudioPlayer.shared.play(tracks: tracks, startIndex: 0, albumArtist: nil)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, minHeight: primaryButtonHeight)
                                .background(Color(.systemGray5))
                                .clipShape(Capsule())
                        }

                        Button {
                            guard !tracks.isEmpty else { return }
                            var shuffled = tracks
                            shuffled.shuffle()
                            AudioPlayer.shared.play(tracks: shuffled, startIndex: 0, albumArtist: nil)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.headline)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, minHeight: primaryButtonHeight)
                                .background(Color(.systemGray5))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, horizontalPad)

                // Track list
                LazyVStack(alignment: .leading, spacing: 0) {
                    Divider().padding(.leading, 16).padding(.top, 8)

                    ForEach(Array(tracks.enumerated()), id: \.element.id) { (idx, t) in
                        TrackRowOffline(
                            index: idx + 1,
                            track: t,
                            isDownloaded: downloads.trackIsDownloaded(t.id),
                            onTapPlay: {
                                // --- START: Temporary debug log ---
                                let trackId = t.id
                                print("--- 🎧 Tapped Track ---")
                                print("Track ID: \(trackId)")
                                if let url = downloads.localURL(for: trackId) {
                                    print("Local URL: \(url.path)")
                                    let exists = FileManager.default.fileExists(atPath: url.path)
                                    print("File Exists: \(exists)")
                                    if exists, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                                        print("File Size: \(attrs[.size] ?? "N/A") bytes")
                                    }
                                } else {
                                    print("Local URL: nil")
                                }
                                print("--------------------")
                                // --- END: Temporary debug log ---

                                AudioPlayer.shared.play(tracks: tracks, startIndex: idx, albumArtist: nil)
                            },
                            onMenuPlayNext: { AudioPlayer.shared.queueNext(t) },
                            onMenuRemoveDownload: {
                                // remove this file and update local UI
                                downloads.deleteDownloadedTrack(trackId: t.id)
                                reloadFromStore()
                            }
                        )
                    }
                }
                .padding(.top, 8)

                Color.clear.frame(height: 24)
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: doRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Label("Remove Playlist Downloads", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .alert("Remove downloaded playlist?",
               isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                downloads.deleteDownloadedPlaylist(playlistId: playlistId)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local index entry for this playlist and stops showing it here (song files remain unless removed individually).")
        }
        .onAppear(perform: reloadFromStore)
        .onReceive(downloads.$downloadedPlaylists) { _ in reloadFromStore() }
        .onReceive(downloads.$downloadedTrackURLs) { _ in reloadFromStore() }
        .onReceive(downloads.$downloadedMeta) { _ in reloadFromStore() }
    }

    private func doRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshError = nil
        Task {
            do {
                try await downloads.refreshDownloadedPlaylist(playlistId: playlistId)
            } catch {
                await MainActor.run { self.refreshError = error.localizedDescription }
            }
            await MainActor.run { self.isRefreshing = false }
        }
    }

    private func reloadFromStore() {
        if let meta = downloads.downloadedPlaylists[playlistId] {
            title = meta.name
            // Preserve the saved order of trackIds
            tracks = downloads.offlineTracks(forTrackIds: meta.trackIds)
        } else {
            title = "Playlist"
            tracks = []
        }
    }
}

// MARK: - Simple offline row (no server lookups, minimal UI)
private struct TrackRowOffline: View {
    let index: Int
    let track: JellyfinTrack
    let isDownloaded: Bool

    let onTapPlay: () -> Void
    let onMenuPlayNext: () -> Void
    let onMenuRemoveDownload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(index)")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.secondary)
                    .frame(width: 30, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(track.name ?? "Unknown Track")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if track.isExplicit {
                            Text("🅴")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    if let artists = track.artists, !artists.isEmpty {
                        Text(artists.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
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
