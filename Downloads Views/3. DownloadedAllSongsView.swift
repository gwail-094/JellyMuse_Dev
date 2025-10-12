//
//  DownloadedAllSongsView.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 03.09.2025.
//


import SwiftUI
import Combine
import UIKit

// Offline "All Songs" sourced from DownloadsAPI.downloadedTrackURLs + offlineTracks(forTrackIds:)
struct DownloadedAllSongsView: View {
    @EnvironmentObject var downloads: DownloadsAPI
    @EnvironmentObject var apiService: JellyfinAPIService
    @Environment(\.dismiss) private var dismiss

    // Data
    @State private var tracks: [JellyfinTrack] = []
    @State private var filtered: [JellyfinTrack] = []
    @State private var sections: [(key: String, items: [JellyfinTrack])] = []
    @State private var searchText: String = ""
    @State private var isLoading = false

    // Selection
    @State private var isSelecting = false
    @State private var selected: Set<String> = []

    // UI
    private let horizontalPad: CGFloat = 20
    private let coverSize: CGFloat = 48
    private let coverCorner: CGFloat = 8
    private let sectionScrollTopOffset: CGFloat = 80
    private let appleMusicRed = Color(red: 0.95, green: 0.2, blue: 0.3)

    // Persisted prefs (sorting)
    private enum SortMode: Int, CaseIterable { case title, dateAdded, artist }
    @AppStorage("DownloadedAllSongs.sortMode") private var sortModeRaw: Int = SortMode.title.rawValue
    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .title }
    private func setSortMode(_ mode: SortMode) { sortModeRaw = mode.rawValue; applySearchAndSort() }

    // A-Z index helpers
    private let indexLetters: [String] = (65...90).compactMap { UnicodeScalar($0).map { String($0) } } + ["#"]
    private func firstIndexLetter(for name: String) -> String {
        guard let ch = name.unicodeScalars.first else { return "#" }
        let s = String(ch).uppercased()
        return (s.range(of: "^[A-Z]$", options: .regularExpression) != nil) ? s : "#"
    }
    private func makeSections(from list: [JellyfinTrack]) -> [(key: String, items: [JellyfinTrack])] {
        let groups = Dictionary(grouping: list) { firstIndexLetter(for: $0.name ?? "") }
        let keys = indexLetters.filter { groups[$0] != nil }
        return keys.map { key in
            (key, (groups[key] ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") })
        }
    }

    var body: some View {
        Group {
            if isLoading {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else {
                ScrollViewReader { proxy in
                    ZStack(alignment: .topTrailing) {
                        // LIST
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Spacer().frame(height: 8)

                                // Search
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                                    TextField("Search", text: $searchText)
                                        .onChange(of: searchText) { _ in applySearchAndSort() }
                                        .textFieldStyle(.plain)
                                        .disableAutocorrection(true)
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 14)
                                .background(Color(.systemGray5).clipShape(Capsule()))
                                .padding(.horizontal, horizontalPad)

                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(sections, id: \.key) { section in
                                        // invisible anchor for fast index
                                        Color.clear
                                            .frame(height: 1)
                                            .offset(y: -sectionScrollTopOffset)
                                            .id("anchor-\(section.key)")

                                        Text(section.key)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .padding(.horizontal, horizontalPad)
                                            .padding(.vertical, 6)

                                        ForEach(section.items, id: \.id) { track in
                                            offlineSongRow(track)
                                                .id(track.id)
                                            Divider()
                                                .padding(.leading, horizontalPad + coverSize + 12)
                                        }
                                    }
                                }
                                Color.clear.frame(height: 120)
                            }
                            .padding(.top, 8)
                        }
                        .scrollIndicators(.hidden)

                        // Fast A–Z index
                        FastIndexBar(
                            letters: indexLetters,
                            topInset: 120,
                            bottomInset: 28,
                            onTapLetter: { letter in
                                if sections.contains(where: { $0.key == letter }) {
                                    var tx = Transaction(); tx.disablesAnimations = true
                                    withTransaction(tx) { proxy.scrollTo("anchor-\(letter)", anchor: .top) }
                                }
                            }
                        )
                        .zIndex(1)
                    }
                }
            }
        }
        .navigationTitle("Downloaded Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .toolbar { toolbarContent }
        .onAppear { reloadOfflineSongs() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func offlineSongRow(_ track: JellyfinTrack) -> some View {
        let isChecked = selected.contains(track.id)

        HStack(spacing: 12) {
            OfflineAlbumCover(albumId: track.albumId, size: coverSize, corner: coverCorner)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(track.name ?? "Unknown Track")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if (track.isExplicit) {
                        Image(systemName: "e.square.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                Text((track.artists?.first) ?? "Unknown Artist")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelecting {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(isChecked ? appleMusicRed : .secondary)
                    .padding(.trailing, 4)
            } else {
                Menu {
                    Button { AudioPlayer.shared.queueNext(track) }  label: { Label("Play Next", systemImage: "text.insert") }
                    Button(role: .destructive) {
                        downloads.deleteDownloadedTrack(trackId: track.id)
                        reloadOfflineSongs()
                    } label: { Label("Remove Download", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .padding(.trailing, 10)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, horizontalPad)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                toggleSelection(track.id)
            } else {
                playTrackFromFiltered(track)
            }
        }
        .contextMenu {
            if !isSelecting {
                Button { AudioPlayer.shared.queueNext(track) }  label: { Label("Play Next", systemImage: "text.insert") }
                Button(role: .destructive) {
                    downloads.deleteDownloadedTrack(trackId: track.id)
                    reloadOfflineSongs()
                } label: { Label("Remove Download", systemImage: "trash") }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isSelecting {
                Button {
                    if selected.count == filtered.count {
                        selected.removeAll()
                    } else {
                        selected = Set(filtered.map { $0.id })
                    }
                } label: {
                    Text(selected.count == filtered.count && !filtered.isEmpty ? "Deselect All" : "Select All")
                }
                .tint(.primary)
            }

            if isSelecting && !selected.isEmpty {
                Button(role: .destructive, action: deleteSelected) {
                    Image(systemName: "trash")
                }
                .foregroundColor(appleMusicRed)
            }

            Menu {
                Button { setSortMode(.title) }     label: { Label("Title",      systemImage: "textformat.abc") }
                Button { setSortMode(.dateAdded) } label: { Label("Date Added", systemImage: "calendar.badge.clock") }
                Button { setSortMode(.artist) }    label: { Label("Artist A–Z", systemImage: "person.text.rectangle") }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundColor(.primary)
            }

            Menu {
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
                    .foregroundColor(.primary)
            }
        }
    }

    // MARK: - Data & Logic

    private func reloadOfflineSongs() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ids = Array(downloads.downloadedTrackURLs.keys)
            let list = downloads.offlineTracks(forTrackIds: ids)
            DispatchQueue.main.async {
                self.tracks = list
                self.applySearchAndSort()
                self.isLoading = false
            }
        }
    }

    private func applySearchAndSort() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [JellyfinTrack] = q.isEmpty
        ? tracks
        : tracks.filter {
            ($0.name ?? "").lowercased().contains(q) ||
            (($0.artists?.first ?? "").lowercased().contains(q))
        }

        var sorted = base
        switch sortMode {
        case .title:
            sorted.sort { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
        case .artist:
            sorted.sort {
                let a0 = ($0.artists?.first ?? "")
                let a1 = ($1.artists?.first ?? "")
                if a0.caseInsensitiveCompare(a1) != .orderedSame {
                    return a0.localizedCaseInsensitiveCompare(a1) == .orderedAscending
                }
                return ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
            }
        case .dateAdded:
            sorted.sort {
                addedDate(for: $0.id) > addedDate(for: $1.id)
            }
        }

        filtered = sorted
        sections = makeSections(from: filtered)

        if isSelecting {
            selected = selected.intersection(filtered.map { $0.id })
        }
    }

    private func addedDate(for trackId: String) -> Date {
        if let url = downloads.downloadedTrackURLs[trackId] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if let c = attrs[.creationDate] as? Date { return c }
                if let m = attrs[.modificationDate] as? Date { return m }
            }
        }
        return .distantPast
    }

    private func toggleSelection(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func deleteSelected() {
        for id in selected { downloads.deleteDownloadedTrack(trackId: id) }
        selected.removeAll()
        reloadOfflineSongs()
        withAnimation { isSelecting = false }
    }

    private func playTrackFromFiltered(_ tapped: JellyfinTrack) {
        guard let start = filtered.firstIndex(where: { $0.id == tapped.id }) else {
            AudioPlayer.shared.play(tracks: [tapped], startIndex: 0, albumArtist: tapped.artists?.first)
            return
        }
        AudioPlayer.shared.play(tracks: filtered, startIndex: start, albumArtist: tapped.artists?.first)
    }
}

// MARK: - Helper Views

fileprivate struct OfflineAlbumCover: View {
    @EnvironmentObject var downloads: DownloadsAPI
    @State private var cancellables = Set<AnyCancellable>()
    
    let albumId: String?
    let size: CGFloat
    let corner: CGFloat
    
    var body: some View {
        Group {
            if let id = albumId,
               let url = downloads.albumCoverURL(albumId: id),
               let ui = UIImage(contentsOfFile: url.path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.gray.opacity(0.25))
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onAppear {
            if let id = albumId, downloads.albumCoverURL(albumId: id) == nil {
                downloads.ensureAlbumCover(albumId: id)
                    .sink(receiveValue: { _ in })
                    .store(in: &cancellables)
            }
        }
    }
}

fileprivate struct FastIndexBar: View {
    let letters: [String]
    let topInset: CGFloat
    let bottomInset: CGFloat
    var visualWidth: CGFloat = 18
    var touchWidth: CGFloat  = 36
    var fontSize: CGFloat    = 9
    var minRowHeight: CGFloat = 9
    var rightPadding: CGFloat = 6

    @State private var dragIndex: Int?
    private let selectionGen = UISelectionFeedbackGenerator()
    private let impactGen = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            let totalHeight = max(geo.size.height - topInset - bottomInset, 0)
            let rowHeight   = max(totalHeight / CGFloat(max(letters.count, 1)), minRowHeight)

            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    Spacer().frame(height: topInset)
                    VStack(spacing: 0) {
                        ForEach(letters, id: \.self) { letter in
                            Text(letter)
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundColor(Color(red: 0.95, green: 0.2, blue: 0.3))
                                .frame(width: visualWidth, height: rowHeight)
                        }
                    }
                    Spacer().frame(height: bottomInset)
                }
                .frame(width: visualWidth, height: geo.size.height, alignment: .top)

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: touchWidth, height: geo.size.height)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let y = value.location.y - topInset
                                guard y >= 0, y <= totalHeight else { return }
                                let i = min(max(Int(y / rowHeight), 0), letters.count - 1)
                                if dragIndex != i {
                                    dragIndex = i
                                    selectionGen.selectionChanged()
                                    selectionGen.prepare()
                                    onTapLetter(letters[i])
                                }
                            }
                            .onEnded { _ in
                                dragIndex = nil
                                impactGen.impactOccurred(intensity: 0.6)
                                impactGen.prepare()
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(.trailing, rightPadding)
        .ignoresSafeArea(.keyboard)
        .onAppear {
            selectionGen.prepare()
            impactGen.prepare()
        }
    }

    let onTapLetter: (String) -> Void
}
