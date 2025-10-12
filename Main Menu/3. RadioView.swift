//
// RadioView.swift
// JellyMuse
//
// Created by Ardit Sejdiu on 15.09.2025.
//

import SwiftUI
import Combine

// MARK: - Reusable Modifiers

private struct StandardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
    }
}

private extension View {
    func standardShadow() -> some View {
        modifier(StandardShadow())
    }
}

// MARK: - External Genre Art (Nginx)

/// Base URL for your Nginx-served genre images (e.g. http://192.168.1.169/genres/pop.png)
private let genreImageBaseURL = URL(string: "http://192.168.1.169/genres/")!

/// Turn a Jellyfin genre name into a predictable filename slug (lowercase, hyphens)
private func genreSlug(_ name: String) -> String {
    let lower = name.lowercased()
    let swapped = lower.replacingOccurrences(of: "&", with: "and")
    let dashed = swapped.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    let trimmed = dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
}

private func genreImageURL(_ name: String) -> URL {
    genreImageBaseURL.appendingPathComponent("\(genreSlug(name)).png")
}

// MARK: - Reusable Header with Chevron

private struct SectionHeaderLink<Destination: View>: View {
    let title: String
    @ViewBuilder var destination: Destination
    
    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.title3).bold()
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - All Radio Stations Detail View

struct AllRadioStationsDetailView: View {
    let stations: [RadioStation]
    let title: String
    
    @ObservedObject private var radio = RadioAudioPlayer.shared
    @State private var searchText = ""
    @State private var filteredStations: [RadioStation] = []
    
    // Persisted UI prefs
    @AppStorage("RadioStationsDetailView.isGridView") private var isGridView: Bool = true
    
    // UI Constants to match GenreDetailView
    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 8
    private let titleSize: CGFloat = 12
    private let subtitleSize: CGFloat = 11
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Small spacer for breathing room under the large title
                Spacer().frame(height: 8)
                
                // Play All / Shuffle pills (if needed for radio stations)
                // Removed Play/Shuffle buttons as requested
                
                // Grid/List content
                if filteredStations.isEmpty {
                    EmptyStationsState()
                        .padding(.top, 40)
                        .padding(.horizontal, horizontalPad)
                } else {
                    if isGridView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(filteredStations, id: \.id) { station in
                                stationCell(station)
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(filteredStations, id: \.id) { station in
                                stationCell(station)
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search stations"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in
            applyFilter()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // VIEW MODE
                Menu {
                    Button(action: { isGridView = true }) {
                        Label("Grid", systemImage: isGridView ? "checkmark" : "")
                    }
                    Button(action: { isGridView = false }) {
                        Label("List", systemImage: !isGridView ? "checkmark" : "")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .tint(.primary)
        .onAppear {
            filteredStations = stations
            applyFilter()
        }
    }
    
    // MARK: - Station Cell
    @ViewBuilder
    private func stationCell(_ station: RadioStation) -> some View {
        Button {
            if radio.currentStation?.id == station.id {
                radio.togglePlayPause()
            } else {
                radio.play(station)
            }
        } label: {
            if isGridView {
                VStack(alignment: .leading, spacing: 6) {
                    StationCover(station: station, cornerRadius: coverRadius)
                        .aspectRatio(1, contentMode: .fit)
                    
                    HStack(spacing: 6) {
                        Text(station.name)
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        if radio.currentStation?.id == station.id && radio.isPlaying {
                            LiveDot(active: true)
                        }
                    }
                    
                    if let subtitle = station.subtitle {
                        Text(subtitle)
                            .font(.system(size: subtitleSize))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 12) {
                    StationCover(station: station, cornerRadius: 8)
                        .frame(width: 60, height: 60)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(station.name)
                                .font(.system(size: titleSize, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            if radio.currentStation?.id == station.id && radio.isPlaying {
                                LiveDot(active: true)
                            }
                        }
                        
                        if let subtitle = station.subtitle {
                            Text(subtitle)
                                .font(.system(size: subtitleSize))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            stationContextMenu(station)
        } preview: {
            StationContextPreviewTile(
                station: station,
                corner: 14
            )
            .frame(width: 280)
        }
    }
    
    // MARK: - Data Filtering
    private func applyFilter() {
        if searchText.isEmpty {
            filteredStations = stations
        } else {
            filteredStations = stations.filter { station in
                station.name.localizedCaseInsensitiveContains(searchText) ||
                (station.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
    }
    
    // MARK: - Context Menu
    @ViewBuilder
    private func stationContextMenu(_ station: RadioStation) -> some View {
        if radio.currentStation?.id == station.id {
            Button(radio.isPlaying ? "Pause" : "Play") {
                radio.togglePlayPause()
            }
        } else {
            Button("Play") {
                radio.play(station)
            }
        }
        
        Button("Stop Radio") {
            radio.stop()
        }
    }
}

// MARK: - Helper Views

private struct StationCover: View {
    let station: RadioStation
    let cornerRadius: CGFloat
    
    var body: some View {
        ZStack {
            if let imageName = station.imageName, let img = UIImage(named: imageName) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.gray.opacity(0.25))
                    .overlay(
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct EmptyStationsState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("No Stations Found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("No results based on your search.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .multilineTextAlignment(.center)
    }
}

private struct StationContextPreviewTile: View {
    let station: RadioStation
    let corner: CGFloat
    private let previewWidth: CGFloat = 280
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StationCover(station: station, cornerRadius: corner)
                .aspectRatio(1, contentMode: .fit)
            
            Text(station.name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            
            if let subtitle = station.subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: previewWidth, alignment: .leading)
    }
}

private struct PillButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    // Apple-Music-ish red
    private let accent = Color(red: 0.95, green: 0.20, blue: 0.30)
    
    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(accent)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity) // stretch so both pills match width
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct LiveDot: View {
    let active: Bool
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? .red : .gray)
                .frame(width: 7, height: 7)
            Text("LIVE")
                .font(.caption2).bold()
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Convenience Views for Different Station Types

struct AllLocalBroadcastersDetailView: View {
    var body: some View {
        AllRadioStationsDetailView(
            stations: RadioCatalog.localBroadcasters,
            title: "Local Broadcasters"
        )
    }
}

struct AllRadioStationsFullView: View {
    private var localIds: Set<String> {
        Set(RadioCatalog.localBroadcasters.map { $0.id })
    }
    
    private var radioCarouselStations: [RadioStation] {
        var seen = Set<String>()
        let preferred = RadioCatalog.userStations
        let rest = RadioCatalog.stations.filter {
            !RadioCatalog.pinnedIDs.contains($0.id) && !localIds.contains($0.id)
        }
        return (preferred + rest).filter { station in
            let inserted = seen.insert(station.id).inserted
            return inserted
        }
    }
    
    var body: some View {
        AllRadioStationsDetailView(
            stations: radioCarouselStations,
            title: "Radio Stations"
        )
    }
}

// MARK: - Artist Stations Detail View

struct AllArtistStationsDetailView: View {
    let artistStations: [JellyfinArtistItem]
    let apiService: JellyfinAPIService
    let audioPlayer: AudioPlayer
    
    @State private var searchText = ""
    @State private var filteredArtists: [JellyfinArtistItem] = []
    
    // Persisted UI prefs
    @AppStorage("ArtistStationsDetailView.isGridView") private var isGridView: Bool = true
    
    // UI Constants to match GenreDetailView
    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 8
    private let titleSize: CGFloat = 12
    private let subtitleSize: CGFloat = 11
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Small spacer for breathing room under the large title
                Spacer().frame(height: 8)
                
                // Removed Play/Shuffle buttons as requested
                
                // Grid/List content
                if filteredArtists.isEmpty {
                    EmptyArtistsState()
                        .padding(.top, 40)
                        .padding(.horizontal, horizontalPad)
                } else {
                    if isGridView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(filteredArtists, id: \.id) { artist in
                                artistCell(artist)
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(filteredArtists, id: \.id) { artist in
                                artistCell(artist)
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
        .navigationTitle("Artist Stations")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search artists"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in
            applyFilter()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // VIEW MODE
                Menu {
                    Button(action: { isGridView = true }) {
                        Label("Grid", systemImage: isGridView ? "checkmark" : "")
                    }
                    Button(action: { isGridView = false }) {
                        Label("List", systemImage: !isGridView ? "checkmark" : "")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .tint(.primary)
        .onAppear {
            filteredArtists = artistStations
            applyFilter()
        }
    }
    
    // MARK: - Artist Cell
    @ViewBuilder
    private func artistCell(_ artist: JellyfinArtistItem) -> some View {
        Button {
            playArtistStation(artist)
        } label: {
            if isGridView {
                VStack(alignment: .leading, spacing: 6) {
                    ArtistCover(artist: artist, apiService: apiService, cornerRadius: coverRadius)
                        .aspectRatio(1, contentMode: .fit)
                    
                    Text(artist.name)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Text("Apple Music")
                        .font(.system(size: subtitleSize))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 12) {
                    ArtistCover(artist: artist, apiService: apiService, cornerRadius: 8)
                        .frame(width: 60, height: 60)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name)
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        Text("Apple Music")
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
        .contextMenu {
            artistContextMenu(artist)
        } preview: {
            ArtistContextPreviewTile(
                artist: artist,
                apiService: apiService,
                corner: 14
            )
            .frame(width: 280)
        }
    }
    
    // MARK: - Data Filtering
    private func applyFilter() {
        if searchText.isEmpty {
            filteredArtists = artistStations
        } else {
            filteredArtists = artistStations.filter { artist in
                artist.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    // MARK: - Artist Actions
    private func playArtistStation(_ artist: JellyfinArtistItem) {
        apiService.fetchSongsByArtist(artistId: artist.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                let shuffledTracks = tracks.shuffled()
                audioPlayer.play(tracks: shuffledTracks, startIndex: 0, albumArtist: artist.name)
            }
            .store(in: &apiService.cancellables)
    }
    
    // MARK: - Context Menu
    @ViewBuilder
    private func artistContextMenu(_ artist: JellyfinArtistItem) -> some View {
        Button("Shuffle \(artist.name)") {
            playArtistStation(artist)
        }
    }
}

// MARK: - Stations by Genre Detail View

struct AllStationsByGenreDetailView: View {
    let genres: [JellyfinGenreItem]
    let apiService: JellyfinAPIService
    let audioPlayer: AudioPlayer
    
    @State private var searchText = ""
    @State private var filteredGenres: [JellyfinGenreItem] = []
    
    // Persisted UI prefs
    @AppStorage("GenreStationsDetailView.isGridView") private var isGridView: Bool = true
    
    // UI Constants to match GenreDetailView
    private let horizontalPad: CGFloat = 20
    private let coverRadius: CGFloat = 8
    private let titleSize: CGFloat = 12
    private let subtitleSize: CGFloat = 11
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Small spacer for breathing room under the large title
                Spacer().frame(height: 8)
                
                // Removed Play/Shuffle buttons as requested
                
                // Grid/List content
                if filteredGenres.isEmpty {
                    EmptyGenresState()
                        .padding(.top, 40)
                        .padding(.horizontal, horizontalPad)
                } else {
                    if isGridView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(filteredGenres) { genre in
                                genreCell(genre)
                            }
                        }
                        .padding(.horizontal, horizontalPad)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(filteredGenres) { genre in
                                genreCell(genre)
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
        .navigationTitle("Stations by Genre")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search genres"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in
            applyFilter()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // VIEW MODE
                Menu {
                    Button(action: { isGridView = true }) {
                        Label("Grid", systemImage: isGridView ? "checkmark" : "")
                    }
                    Button(action: { isGridView = false }) {
                        Label("List", systemImage: !isGridView ? "checkmark" : "")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .tint(.primary)
        .onAppear {
            filteredGenres = genres
            applyFilter()
        }
    }
    
    // MARK: - Genre Cell
    @ViewBuilder
    private func genreCell(_ genre: JellyfinGenreItem) -> some View {
        Button {
            playGenre(genre)
        } label: {
            if isGridView {
                VStack(alignment: .leading, spacing: 6) {
                    GenreCover(genre: genre, cornerRadius: coverRadius)
                        .aspectRatio(1, contentMode: .fit)
                    
                    Text(genre.name)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Text("Apple Music \(genre.name)")
                        .font(.system(size: subtitleSize))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 12) {
                    GenreCover(genre: genre, cornerRadius: 8)
                        .frame(width: 60, height: 60)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(genre.name)
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        Text("Apple Music \(genre.name)")
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
        .contextMenu {
            genreContextMenu(genre)
        } preview: {
            GenreContextPreviewTile(
                genre: genre,
                corner: 14
            )
            .frame(width: 280)
        }
    }
    
    // MARK: - Data Filtering
    private func applyFilter() {
        if searchText.isEmpty {
            filteredGenres = genres
        } else {
            filteredGenres = genres.filter { genre in
                genre.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    // MARK: - Genre Actions
    private func playGenre(_ genre: JellyfinGenreItem) {
        RadioAudioPlayer.shared.stop()
        apiService.fetchSongsByGenre(genre.name)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                let shuffled = tracks.shuffled()
                audioPlayer.play(tracks: shuffled, startIndex: 0, albumArtist: genre.name)
            }
            .store(in: &apiService.cancellables)
    }
    
    // MARK: - Context Menu
    @ViewBuilder
    private func genreContextMenu(_ genre: JellyfinGenreItem) -> some View {
        Button("Shuffle \(genre.name)") {
            playGenre(genre)
        }
    }
}

// MARK: - Additional Helper Views

private struct ArtistCover: View {
    let artist: JellyfinArtistItem
    let apiService: JellyfinAPIService
    let cornerRadius: CGFloat
    
    private func artistThumbURL(_ id: String) -> URL? {
        guard !apiService.serverURL.isEmpty, !apiService.authToken.isEmpty else { return nil }
        var comps = URLComponents(string: "\(apiService.serverURL)Items/\(id)/Images/Thumb")
        comps?.queryItems = [ URLQueryItem(name: "X-Emby-Token", value: apiService.authToken) ]
        return comps?.url
    }
    
    var body: some View {
        ZStack {
            AsyncImage(url: artistThumbURL(artist.id)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    Color.gray.opacity(0.25).overlay(ProgressView())
                case .failure:
                    Color.gray.opacity(0.25)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(.secondary)
                        )
                @unknown default:
                    Color.gray.opacity(0.25)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct GenreCover: View {
    let genre: JellyfinGenreItem
    let cornerRadius: CGFloat
    
    /// Turn a Jellyfin genre name into a predictable filename slug (lowercase, hyphens)
    private func genreSlug(_ name: String) -> String {
        let lower = name.lowercased()
        let swapped = lower.replacingOccurrences(of: "&", with: "and")
        let dashed = swapped.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
    }
    
    private func genreImageURL(_ name: String) -> URL {
        let genreImageBaseURL = URL(string: "http://192.168.1.169/genres/")!
        return genreImageBaseURL.appendingPathComponent("\(genreSlug(name)).png")
    }
    
    var body: some View {
        ZStack {
            AsyncImage(url: genreImageURL(genre.name)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    Color.gray.opacity(0.25).overlay(ProgressView())
                case .failure:
                    Color.gray.opacity(0.25)
                        .overlay(
                            Image(systemName: "music.note.list")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(.secondary)
                        )
                @unknown default:
                    Color.gray.opacity(0.25)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct EmptyArtistsState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("No Artists Found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("No results based on your search.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .multilineTextAlignment(.center)
    }
}

private struct EmptyGenresState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(.secondary)
            Text("No Genres Found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("No results based on your search.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .multilineTextAlignment(.center)
    }
}

private struct ArtistContextPreviewTile: View {
    let artist: JellyfinArtistItem
    let apiService: JellyfinAPIService
    let corner: CGFloat
    private let previewWidth: CGFloat = 280
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtistCover(artist: artist, apiService: apiService, cornerRadius: corner)
                .aspectRatio(1, contentMode: .fit)
            
            Text(artist.name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            
            Text("Apple Music")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: previewWidth, alignment: .leading)
    }
}

private struct GenreContextPreviewTile: View {
    let genre: JellyfinGenreItem
    let corner: CGFloat
    private let previewWidth: CGFloat = 280
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GenreCover(genre: genre, cornerRadius: corner)
                .aspectRatio(1, contentMode: .fit)
            
            Text(genre.name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            
            Text("Apple Music \(genre.name)")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: previewWidth, alignment: .leading)
    }
}

// MARK: - Main View

struct RadioView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @EnvironmentObject var audioPlayer: AudioPlayer

    @ObservedObject private var radio = RadioAudioPlayer.shared

    @State private var showNowPlaying = false
    
    @State private var artistStations: [JellyfinArtistItem] = []
    @State private var isLoadingArtistStations = false
    @State private var artistStationsError: String?

    @State private var genres: [JellyfinGenreItem] = []
    @State private var isLoadingGenres = false
    @State private var genreError: String?
    
    // Layout / sizing to match HomeView
    private let tileSide: CGFloat = 150
    private let tileCorner: CGFloat = 10
    private let pinnedTileCorner: CGFloat = 20  // Adjust this for pinned tiles corner radius
    
    // Layouts
    private let pinnedCols = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    private var pinnedStations: [RadioStation] {
        // Keep RadioCatalog.pinnedIDs order
        let map = Dictionary(uniqueKeysWithValues: RadioCatalog.stations.map { ($0.id, $0) })
        return RadioCatalog.pinnedIDs.compactMap { map[$0] }
    }
    
    // IDs of Local Broadcasters for quick exclusion
    private var localIds: Set<String> {
        Set(RadioCatalog.localBroadcasters.map { $0.id })
    }

    // Combine userStations + the rest (exclude pinned + local), de-duped by id
    private var radioCarouselStations: [RadioStation] {
        var seen = Set<String>()
        let preferred = RadioCatalog.userStations
        let rest = RadioCatalog.stations.filter {
            !RadioCatalog.pinnedIDs.contains($0.id) && !localIds.contains($0.id)
        }
        return (preferred + rest).filter { station in
            let inserted = seen.insert(station.id).inserted
            return inserted
        }
    }
    
    // Helper to build artist thumb URL
    private func artistThumbURL(_ id: String) -> URL? {
        guard !apiService.serverURL.isEmpty, !apiService.authToken.isEmpty else { return nil }
        var comps = URLComponents(string: "\(apiService.serverURL)Items/\(id)/Images/Thumb")
        comps?.queryItems = [ URLQueryItem(name: "X-Emby-Token", value: apiService.authToken) ]
        return comps?.url
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    // --- Featured (Pinned) grid — Apple Music style (no header) ---
                    if !pinnedStations.isEmpty {
                        LazyVGrid(columns: pinnedCols, spacing: 12) {
                            ForEach(pinnedStations, id: \.id) { station in
                                let isActive = (radio.currentStation?.id == station.id)
                                let isPlaying = radio.isPlaying && isActive

                                StationPinTile(
                                    station: station,
                                    corner: pinnedTileCorner,
                                    isPlaying: isPlaying
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .padding(4)          // tiny gutter so shadows don't clip
                                .zIndex(isActive ? 1 : 0)  // active one on top
                                .onTapGesture {
                                    if isActive { radio.togglePlayPause() }
                                    else { radio.play(station) }
                                }
                                .contextMenu {
                                    if isActive {
                                        Button(radio.isPlaying ? "Pause" : "Play") { radio.togglePlayPause() }
                                    } else {
                                        Button("Play") { radio.play(station) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                    }

                    // --- Local Broadcasters (horizontal carousel) ---
                    if !RadioCatalog.localBroadcasters.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeaderLink(title: "Local Broadcasters") {
                                AllLocalBroadcastersDetailView() // New detail view
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(RadioCatalog.localBroadcasters, id: \.id) { station in
                                        StationPosterTile(
                                            station: station,
                                            side: tileSide,
                                            corner: tileCorner
                                        )
                                        .onTapGesture {
                                            if radio.currentStation?.id == station.id {
                                                radio.togglePlayPause()
                                            } else {
                                                radio.play(station)
                                            }
                                        }
                                        .contextMenu {
                                            if radio.currentStation?.id == station.id {
                                                Button(radio.isPlaying ? "Pause" : "Play") { radio.togglePlayPause() }
                                            } else {
                                                Button("Play") { radio.play(station) }
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                        }
                        .padding(.top, 8)
                    }
                    
                    // --- Radio Stations (horizontal carousel) ---
                    if !radioCarouselStations.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeaderLink(title: "Radio Stations") {
                                AllRadioStationsFullView() // New detail view
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(radioCarouselStations, id: \.id) { station in
                                        StationPosterTile(
                                            station: station,
                                            side: tileSide,
                                            corner: tileCorner
                                        )
                                        .onTapGesture {
                                            if radio.currentStation?.id == station.id {
                                                radio.togglePlayPause()
                                            } else {
                                                radio.play(station)
                                            }
                                        }
                                        .contextMenu {
                                            if radio.currentStation?.id == station.id {
                                                Button(radio.isPlaying ? "Pause" : "Play") { radio.togglePlayPause() }
                                            } else {
                                                Button("Play") { radio.play(station) }
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                        }
                        .padding(.top, 8)
                    }
                    
                    // --- Artist Stations (horizontal carousel) ---
                    if isLoadingArtistStations {
                        ProgressView("Loading artists…")
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if let error = artistStationsError {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if !artistStations.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeaderLink(title: "Artist Stations") {
                                AllArtistStationsDetailView( // New detail view
                                    artistStations: artistStations,
                                    apiService: apiService,
                                    audioPlayer: audioPlayer
                                )
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(artistStations, id: \.id) { artist in
                                        ArtistCarouselTile(
                                            name: artist.name,
                                            imageURL: artistThumbURL(artist.id),
                                            side: tileSide,
                                            corner: tileCorner
                                        )
                                        .onTapGesture { playArtistStation(artist) }
                                        .contextMenu {
                                            Button("Shuffle \(artist.name)") { playArtistStation(artist) }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                        }
                        .padding(.top, 8)
                    }

                    // --- Stations by Genre (horizontal carousel) ---
                    if isLoadingGenres {
                        ProgressView("Loading genres…")
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if let error = genreError {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                    } else if !genres.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeaderLink(title: "Stations by Genre") {
                                AllStationsByGenreDetailView( // New detail view
                                    genres: genres,
                                    apiService: apiService,
                                    audioPlayer: audioPlayer
                                )
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(genres) { g in
                                        GenreTile(
                                            name: g.name,
                                            side: tileSide,
                                            corner: tileCorner
                                        )
                                        .environmentObject(apiService) // GenreTile needs this
                                        .onTapGesture { playGenre(g) }
                                        .contextMenu {
                                            Button("Shuffle \(g.name)") { playGenre(g) }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.top, 12)
            }
            .navigationTitle("Radio")
            .onAppear {
                loadArtistStations()
                loadGenres()
            }
        }
    }
    
    private func loadArtistStations() {
        isLoadingArtistStations = true
        artistStationsError = nil
        
        apiService.fetchArtistThumbs(limit: 15)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                self.isLoadingArtistStations = false
                if case .failure(let error) = completion {
                    self.artistStationsError = error.localizedDescription
                }
            }, receiveValue: { artists in
                self.artistStations = artists
            })
            .store(in: &apiService.cancellables)
    }

    private func loadGenres() {
        isLoadingGenres = true
        genreError = nil

        apiService.fetchMusicGenres(minAlbums: 4)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                self.isLoadingGenres = false
                if case .failure(let err) = completion {
                    self.genreError = err.localizedDescription
                }
            }, receiveValue: { gens in
                self.genres = gens
            })
            .store(in: &apiService.cancellables)
    }

    private func playArtistStation(_ artist: JellyfinArtistItem) {
        apiService.fetchSongsByArtist(artistId: artist.id)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                let shuffledTracks = tracks.shuffled()
                audioPlayer.play(tracks: shuffledTracks, startIndex: 0, albumArtist: artist.name)
            }
            .store(in: &apiService.cancellables)
    }

    private func playGenre(_ genre: JellyfinGenreItem) {
        RadioAudioPlayer.shared.stop()
        apiService.fetchSongsByGenre(genre.name)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                guard !tracks.isEmpty else { return }
                let shuffled = tracks.shuffled()
                audioPlayer.play(tracks: shuffled, startIndex: 0, albumArtist: genre.name)
            }
            .store(in: &apiService.cancellables)
    }
}

// MARK: - All Grid Views (OLD VERSIONS REMOVED)
// The old AllLocalBroadcastersView and AllRadioStationsView were fully replaced.
// The old AllArtistStationsView and AllStationsByGenreView are replaced by their *DetailView counterparts in the navigation links.

// MARK: - Tile

private struct StationTile: View {
    let station: RadioStation
    let isCurrent: Bool
    let isPlaying: Bool
    
    private let corner: CGFloat = 12
    private let artRatio: CGFloat = 1
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let name = station.imageName, let img = UIImage(named: name) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(artRatio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.gray.opacity(0.20))
                        .aspectRatio(artRatio, contentMode: .fit)
                        .overlay(
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(.secondary)
                        )
                }
                
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: isCurrent ? (isPlaying ? "pause.fill" : "play.fill") : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                    )
                    .shadow(radius: 8, y: 4)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(station.name)
                        .font(.headline)
                        .lineLimit(1)
                    if isCurrent {
                        LiveDot(active: isPlaying)
                    }
                }
                Text(station.subtitle ?? "Live")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct StationPinTile: View {
    let station: RadioStation
    let corner: CGFloat
    let isPlaying: Bool

    var body: some View {
        let rounded = RoundedRectangle(cornerRadius: corner, style: .continuous)

        // When playing: smaller scale + tighter shadow
        let scale: CGFloat = isPlaying ? 0.93 : 1.0

        // Shadow changes smoothly
        let shadowRadius: CGFloat = isPlaying ? 4 : 12    // smaller when playing
        let shadowY: CGFloat      = isPlaying ? 2 : 6     // closer when playing
        let shadowOpacity: Double = isPlaying ? 0.10 : 0.18 // softer when playing

        ZStack {
            if let name = station.imageName, let img = UIImage(named: name) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.20)
                    .overlay(
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(rounded)
        .compositingGroup() // prevents clipping issues with shadows
        .scaleEffect(scale)
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isPlaying)
        .contentShape(rounded)
        .accessibilityLabel(Text(station.name))
        .accessibilityHint(Text(station.subtitle ?? "Live"))
    }
}

private struct StationPosterTile: View {
    let station: RadioStation
    let side: CGFloat
    let corner: CGFloat

    var body: some View {
        let rounded = RoundedRectangle(cornerRadius: corner, style: .continuous)

        ZStack {
            if let name = station.imageName, let img = UIImage(named: name) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.2)
                    .overlay(
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: side * 0.22, weight: .semibold))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .frame(width: side, height: side)
        .clipShape(rounded)
        .compositingGroup()
        .standardShadow()
        .contentShape(rounded)
        .accessibilityLabel(Text(station.name))
        .accessibilityHint(Text(station.subtitle ?? "Live"))
    }
}

private struct ArtistCarouselTile: View {
    let name: String
    let imageURL: URL?
    let side: CGFloat
    let corner: CGFloat

    var body: some View {
        let rounded = RoundedRectangle(cornerRadius: corner, style: .continuous)

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let url = imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        case .empty: Color.gray.opacity(0.2).overlay(ProgressView())
                        case .failure:
                            Color.gray.opacity(0.2)
                                .overlay(Image(systemName: "person.fill")
                                    .font(.system(size: side * 0.28))
                                    .foregroundColor(.secondary))
                        @unknown default: Color.gray.opacity(0.2)
                        }
                    }
                } else {
                    Color.gray.opacity(0.2)
                        .overlay(Image(systemName: "person.fill")
                            .font(.system(size: side * 0.28))
                            .foregroundColor(.secondary))
                }
            }
            .frame(width: side, height: side)
            .clipShape(rounded)
            .compositingGroup()
            .standardShadow()

            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(width: side, alignment: .leading)

            Text("Apple Music")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: side, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

private struct GenreTile: View {
    let name: String
    let side: CGFloat
    let corner: CGFloat

    @EnvironmentObject var apiService: JellyfinAPIService

    // Fallback: Jellyfin (may not exist for genres)
    private func jellyfinImageURL(for name: String) -> URL? {
        if let u = apiService.imageURL(for: name, imageType: "Thumb") { return u }
        return apiService.imageURL(for: name, imageType: "Primary")
    }

    var body: some View {
        // Primary: your Nginx-served PNG, e.g. http://192.168.1.169/genres/pop.png
        let imgURL = genreImageURL(name)
        
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                AsyncImage(url: imgURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        Color.gray.opacity(0.2).overlay(ProgressView())
                    case .failure:
                        Color.gray.opacity(0.2).overlay(
                            Image(systemName: "music.note.list")
                                .font(.system(size: side * 0.28))
                                .foregroundColor(.secondary)
                        )
                    @unknown default:
                        Color.gray.opacity(0.2)
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .standardShadow()

            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(width: side, alignment: .leading)

            Text("Apple Music \(name)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: side, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Mini Bar (kept as-is in your file; not shown in this view)

private struct RadioMiniBar: View {
    let station: RadioStation
    let liveText: String?
    let isPlaying: Bool
    let onTap: () -> Void
    let onPlayPause: () -> Void
    let onStop: () -> Void
    
    private let barHeight: CGFloat = 64
    private let artSize: CGFloat = 44
    private let corner: CGFloat = 10
    
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                // Artwork
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.gray.opacity(0.2))
                    if let name = station.imageName, let img = UIImage(named: name) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: artSize, height: artSize)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                
                // Texts
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    Text((liveText ?? station.subtitle) ?? "Live")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Controls
                HStack(spacing: 16) {
                    Button(action: onPlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: barHeight)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 0.5)
                    .offset(y: -barHeight/2),
                alignment: .top
            )
            .padding(.horizontal, 12)
            .padding(.bottom, safeBottomInset())
            .onTapGesture { onTap() }
        }
        .ignoresSafeArea(edges: .bottom)
    }
    
    private func safeBottomInset() -> CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.bottom ?? 12
    }
}

// MARK: - Tiny helpers

// Note: LiveDot is defined in the patch, so the old definition is removed if present,
// but since the patch's LiveDot is identical to the one you had, no net change here.
