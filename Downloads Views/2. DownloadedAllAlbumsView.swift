import SwiftUI
import Combine

// MARK: - Helpers for Drag Selection (File Scope)

// Collects the on-screen frames of each album tile
private struct ItemRectKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// Creates a CGRect from two points
private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x),
           y: min(a.y, b.y),
           width: abs(a.x - b.x),
           height: abs(a.y - b.y))
}


private struct OfflineAlbum: Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let trackCount: Int
    let newest: Date
}

/// Offline "All Albums" sourced from DownloadsAPI.offlineAlbumsWithMetadata()
struct DownloadedAllAlbumsView: View {
    @EnvironmentObject var downloads: DownloadsAPI
    @EnvironmentObject var apiService: JellyfinAPIService
    @Environment(\.dismiss) private var dismiss
    
    // Raw data
    @State private var albumsRaw: [(
        albumId: String,
        albumName: String?,
        artistName: String?,
        productionYear: Int?,
        trackCount: Int,
        newestFileDate: Date
    )] = []
    @State private var rows: [OfflineAlbum] = []
    
    // UI State
    @State private var searchText = ""
    @State private var isLoading = false
    @AppStorage("DownloadedAllAlbums.isGridView") private var isGridView: Bool = true
    
    // Selection State
    @State private var isSelecting = false
    @State private var selected: Set<String> = []
    private let appleMusicRed = Color(red: 0.95, green: 0.2, blue: 0.3)

    // State for Drag Selection
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var frames: [String: CGRect] = [:]
    @State private var selectionBase: Set<String> = []
    @State private var sweepModeIsSubtracting = false
    
    // Sorting
    private enum SortMode: Int, CaseIterable {
        case title
        case recentlyDownloaded
        case artistAZ
        case year
    }
    @AppStorage("DownloadedAllAlbums.sortMode") private var sortModeRaw: Int = SortMode.recentlyDownloaded.rawValue
    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .recentlyDownloaded }
    
    // Layout constants
    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 8
    private let titleSize: CGFloat = 12
    private let artistSize: CGFloat = 11
    private var bottomInset: CGFloat { 24 }

    // Scroll restoration
    @SceneStorage("DownloadedAllAlbums.restoreID") private var restoreID: String?
    @SceneStorage("DownloadedAllAlbums.needsRestore") private var needsRestore: Bool = false

    var body: some View {
        Group {
            if isLoading {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Spacer().frame(height: 8)
                            searchBar
                            
                            gridOrList()
                                .overlayPreferenceValue(ItemRectKey.self) { anchors in
                                    if isSelecting {
                                        dragSelectionOverlay(anchors: anchors)
                                    }
                                }
                            
                            Color.clear.frame(height: bottomInset)
                        }
                        .padding(.top, 8)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { maybeRestore(proxy) }
                    .onChange(of: rows) { _ in maybeRestore(proxy) }
                }
            }
        }
        .navigationTitle("Downloaded Albums")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .toolbar { downloadedToolbar }
        .onAppear { reloadOfflineAlbums() }
        .tint(appleMusicRed)
    }

    // MARK: - Extracted Views
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search Albums & Artists", text: $searchText)
                .onChange(of: searchText) { _ in applyFiltersAndSort() }
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color(.systemGray5).clipShape(Capsule()))
        .padding(.horizontal, horizontalPad)
    }
    
    @ViewBuilder
    private func dragSelectionOverlay(anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            let resolved: [String: CGRect] = anchors.reduce(into: [:]) { out, pair in
                out[pair.key] = proxy[pair.value]
            }

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(isSelecting)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                guard isSelecting else { return }
                                if dragStart == nil {
                                    dragStart = value.startLocation
                                    selectionBase = selected
                                    frames = resolved
                                    let startPoint = value.startLocation
                                    let hitId = resolved.first { _, rect in rect.contains(startPoint) }?.key
                                    sweepModeIsSubtracting = hitId.map { selectionBase.contains($0) } ?? false
                                }
                                dragCurrent = value.location
                                let box = rect(from: dragStart ?? value.startLocation, to: value.location)
                                let hitIds = resolved.compactMap { id, r in r.intersects(box) ? id : nil }
                                selected = sweepModeIsSubtracting ? selectionBase.subtracting(hitIds)
                                                                   : selectionBase.union(hitIds)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                dragCurrent = nil
                                sweepModeIsSubtracting = false
                            }
                    )

                if let a = dragStart, let b = dragCurrent {
                    let box = rect(from: a, to: b)
                    Rectangle()
                        .path(in: box)
                        .stroke(appleMusicRed, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                        .background(
                            Rectangle()
                                .fill(appleMusicRed.opacity(0.12))
                                .frame(width: box.width, height: box.height)
                                .position(x: box.midX, y: box.midY)
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func gridOrList() -> some View {
        if rows.isEmpty {
            EmptyOfflineAlbumsState()
                .padding(.top, 40)
                .padding(.horizontal, horizontalPad)
        } else if isGridView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(rows) { a in albumCell(a) }
            }
            .padding(.horizontal, horizontalPad)
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { a in albumCell(a) }
            }
            .padding(.horizontal, horizontalPad)
        }
    }
    
    @ToolbarContentBuilder
    private var downloadedToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isSelecting {
                Button(action: toggleSelectAll) {
                    Text(allSelected ? "Deselect All" : "Select All")
                }
            }
            
            if isSelecting && !selected.isEmpty {
                Button(role: .destructive, action: deleteSelectedAlbums) {
                    Image(systemName: "trash")
                }
                .foregroundColor(appleMusicRed)
            }

            Menu {
                Button(action: { setSortMode(.title) }) { Label("Title", systemImage: "textformat.abc") }
                Button(action: { setSortMode(.artistAZ) }) { Label("Artist A–Z", systemImage: "person.text.rectangle") }
                Button(action: { setSortMode(.year) }) { Label("Year", systemImage: "calendar") }
                Button(action: { setSortMode(.recentlyDownloaded) }) { Label("Date Added", systemImage: "clock") }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }

            Menu {
                Button { isGridView = true  } label: { Label("Grid", systemImage: "square.grid.2x2") }
                Button { isGridView = false } label: { Label("List", systemImage: "list.bullet") }
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
            }
        }
    }

    // MARK: - Album Cell
    
    @ViewBuilder
    private func albumCell(_ album: OfflineAlbum) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isSelecting {
                    tileContent(for: album)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleAlbumSelection(album.id) }
                } else {
                    NavigationLink(destination:
                        DownloadedAlbumDetailView(albumId: album.id, fallbackName: album.name)
                            .environmentObject(apiService)
                            .environmentObject(downloads)
                    ) {
                        tileContent(for: album)
                    }
                    .buttonStyle(.plain)
                    .id(album.id)
                    .onTapGesture {
                        restoreID = album.id
                        needsRestore = true
                    }
                }
            }

            if isSelecting {
                Button(action: { toggleAlbumSelection(album.id) }) {
                    Image(systemName: selected.contains(album.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(selected.contains(album.id) ? appleMusicRed : .secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .zIndex(1)
            }
        }
        .anchorPreference(key: ItemRectKey.self, value: .bounds) { anchor in
            [album.id: anchor]
        }
    }

    @ViewBuilder
    private func tileContent(for album: OfflineAlbum) -> some View {
        if isGridView {
            VStack(alignment: .leading, spacing: 6) {
                OfflineCover(albumId: album.id, cornerRadius: coverRadius)
                    .aspectRatio(1, contentMode: .fit)
                Text(album.name)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let artist = album.artist {
                    Text(artist)
                        .font(.system(size: artistSize))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            HStack(spacing: 12) {
                OfflineCover(albumId: album.id, cornerRadius: 8)
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let artist = album.artist {
                        Text(artist)
                            .font(.system(size: artistSize))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: - Data & Logic
    
    private func reloadOfflineAlbums() {
        isLoading = true
        DispatchQueue.main.async {
            self.albumsRaw = downloads.offlineAlbumsWithMetadata()
            self.applyFiltersAndSort()
            self.isLoading = false
        }
    }
    
    private func applyFiltersAndSort() {
        var base = albumsRaw

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchText.lowercased()
            base = albumsRaw.filter {
                ($0.albumName ?? "").lowercased().contains(q) ||
                ($0.artistName ?? "").lowercased().contains(q)
            }
        }

        switch sortMode {
        case .title:
            base.sort { ($0.albumName ?? "").localizedCaseInsensitiveCompare($1.albumName ?? "") == .orderedAscending }
        case .artistAZ:
            base.sort {
                let a0 = $0.artistName ?? ""
                let a1 = $1.artistName ?? ""
                if a0.caseInsensitiveCompare(a1) != .orderedSame {
                    return a0.localizedCaseInsensitiveCompare(a1) == .orderedAscending
                }
                return ($0.albumName ?? "").localizedCaseInsensitiveCompare($1.albumName ?? "") == .orderedAscending
            }
        case .year:
            base.sort {
                let y0 = $0.productionYear ?? Int.max
                let y1 = $1.productionYear ?? Int.max
                if y0 != y1 { return y0 < y1 }
                return ($0.albumName ?? "").localizedCaseInsensitiveCompare($1.albumName ?? "") == .orderedAscending
            }
        case .recentlyDownloaded:
            base.sort { $0.newestFileDate > $1.newestFileDate }
        }

        rows = base.map { OfflineAlbum(id: $0.albumId,
                                        name: $0.albumName ?? "Album",
                                        artist: $0.artistName,
                                        trackCount: $0.trackCount,
                                        newest: $0.newestFileDate) }
    }

    private func setSortMode(_ m: SortMode) {
        sortModeRaw = m.rawValue
        applyFiltersAndSort()
    }
    
    // MARK: - Selection Helpers

    private var allSelected: Bool { !rows.isEmpty && selected.count == rows.count }

    private func toggleSelectAll() {
        if allSelected {
            selected.removeAll()
        } else {
            selected = Set(rows.map { $0.id })
        }
    }

    private func toggleAlbumSelection(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func deleteSelectedAlbums() {
        for id in selected {
            downloads.deleteDownloadedAlbum(albumId: id)
        }
        reloadOfflineAlbums()
        selected.removeAll()
        withAnimation { isSelecting = false }
    }

    // MARK: - Scroll Restore
    private func maybeRestore(_ proxy: ScrollViewProxy) {
        guard needsRestore, let id = restoreID else { return }
        guard rows.contains(where: { $0.id == id }) else {
            needsRestore = false
            return
        }
        DispatchQueue.main.async {
            withAnimation(.none) { proxy.scrollTo(id, anchor: .center) }
            needsRestore = false
        }
    }
}


// MARK: - Helper Views
fileprivate struct OfflineCover: View {
    @EnvironmentObject var downloads: DownloadsAPI
    let albumId: String
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.gray.opacity(0.25))

            if let url = downloads.albumCoverURL(albumId: albumId),
               let ui = UIImage(contentsOfFile: url.path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .foregroundColor(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

fileprivate struct EmptyOfflineAlbumsState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("No Downloaded Albums")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("Albums you download will appear here, even without an internet connection.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .multilineTextAlignment(.center)
    }
}
