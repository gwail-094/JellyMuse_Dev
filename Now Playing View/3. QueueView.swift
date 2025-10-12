//
//  NowPlayingQueueView.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 04.09.2025.
//

import SwiftUI

struct NowPlayingQueueView: View {
    @ObservedObject var player: AudioPlayer
    let artworkURL: URL?

    var history: [JellyfinTrack]
    var upNext: [JellyfinTrack]

    var onJumpToIndex: (Int) -> Void
    var onMove: ((IndexSet, Int) -> Void)?
    var onDelete: ((IndexSet) -> Void)?

    @State private var tab: QueueTab = .queue

    // Density controls
    private let COMPACT_ART_SIZE: CGFloat = 36
    private let ROW_VERTICAL_INSET: CGFloat = 1

    enum QueueTab: String, CaseIterable, Identifiable {
        case history = "History"
        case queue   = "Up Next"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            // Tabs
            Picker("", selection: $tab) {
                ForEach(QueueTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            // Lists
            Group {
                if tab == .history {
                    QueueSectionList(
                        title: "History",
                        tracks: history,
                        canEdit: false,
                        onMove: nil,
                        onDelete: nil,
                        rowContent: row(draggable: false),
                        onTap: { index in onJumpToIndex(index) },
                        rowVerticalInset: ROW_VERTICAL_INSET,
                        listRowSpacing: 0
                    )
                } else {
                    QueueSectionList(
                        title: "Up Next",
                        tracks: upNext,
                        canEdit: true,
                        onMove: onMove,
                        onDelete: onDelete,
                        rowContent: row(draggable: true),
                        onTap: { index in onJumpToIndex(index) },
                        rowVerticalInset: ROW_VERTICAL_INSET,
                        listRowSpacing: 0
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .presentationDetents([.large, .fraction(0.66)])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .interactiveDismissDisabled(false)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let url = artworkURL {
                    ItemImage(url: url, cornerRadius: 10)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.25))
                }
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentTrack?.name ?? "—")
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                Text(player.currentAlbumArtist ?? (player.currentTrack?.artists?.joined(separator: ", ") ?? ""))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 10) {
                Button(action: {
                    // Implement favorite toggle here
                }) {
                    Image(systemName: "star")
                }
                Button(action: {
                    // Implement menu presentation here
                }) {
                    Image(systemName: "ellipsis")
                }
            }
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
        }
    }

    // MARK: - Row builder

    private func row(draggable: Bool) -> (_ track: JellyfinTrack) -> QueueRow {
        { track in
            QueueRow(
                track: track,
                artURL: JellyfinAPIService.shared.imageURL(for: track.albumId ?? track.id),
                draggable: draggable,
                artSize: COMPACT_ART_SIZE
            )
        }
    }
}

// MARK: - Reusable list wrapper

private struct QueueSectionList<RowView: View>: View {
    let title: String
    let tracks: [JellyfinTrack]
    let canEdit: Bool
    let onMove: ((IndexSet, Int) -> Void)?
    let onDelete: ((IndexSet) -> Void)?
    let rowContent: (_ track: JellyfinTrack) -> RowView
    let onTap: (_ index: Int) -> Void

    // Compactness controls passed in
    let rowVerticalInset: CGFloat
    let listRowSpacing: CGFloat

    var body: some View {
        // Provide non-optional handlers so modifiers compile cleanly
        let moveHandler: (IndexSet, Int) -> Void = onMove ?? { _, _ in }
        let deleteHandler: (IndexSet) -> Void = onDelete ?? { _ in }

        List {
            if tracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Nothing here yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } else {
                // Use stable identity if available on JellyfinTrack: .id(\.id)
                ForEach(tracks.indices, id: \.self) { idx in
                    rowContent(tracks[idx])
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(idx) }
                        .listRowInsets(EdgeInsets(top: rowVerticalInset, leading: 16, bottom: rowVerticalInset, trailing: 16))
                }
                .onMove(perform: moveHandler)
                .onDelete(perform: deleteHandler)
                .moveDisabled(!canEdit)
            }
        }
        .listStyle(.plain)
        .listRowSpacing(listRowSpacing) // <-- removes the default inter-row gap
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .contentMargins(.vertical, 0)
        .listSectionSpacing(.custom(0))
    }
}

// MARK: - Queue Row

private struct QueueRow: View {
    let track: JellyfinTrack
    let artURL: URL?
    let draggable: Bool
    let artSize: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            // Art (reduced size to allow tighter rows)
            ItemImage(url: artURL, cornerRadius: 8)
                .frame(width: artSize, height: artSize)

            // Title/artist
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name ?? "—")
                    .font(.body)
                    .lineLimit(1)
                if let a = track.artists?.joined(separator: ", "), !a.isEmpty {
                    Text(a)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if draggable {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Reorder")
            }
        }
    }
}
