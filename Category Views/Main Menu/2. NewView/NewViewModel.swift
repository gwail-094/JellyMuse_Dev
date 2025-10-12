//
//  NewViewModel.swift
//  JellyMuse
//

import Foundation
import SwiftUI
import Combine
import SDWebImage // Added for prefetching

// Ask Apple artwork endpoints for a specific square size (e.g. 120, 300)
@inline(__always)
private func appleArtwork(_ url: URL?, square: Int) -> URL? {
    guard var s = url?.absoluteString else { return url }
    // Covers common "/{w}x{h}" pattern in Apple RSS
    s = s.replacingOccurrences(of: "/{w}x{h}", with: "/\(square)x\(square)")
    return URL(string: s)
}

final class NewViewModel: ObservableObject {
    // Data
    @Published var feed: [NewFeedItem] = []
    @Published var freshCards: [SongCard] = []
    @Published var newAlbums: [AlbumCard] = []
    @Published var updatedPlaylists: [AlbumCard] = []
    @Published var editorialAlbums: [AlbumCard] = []
    @Published var everybodySongCards: [SongCard] = []
    @Published var globalSongCards: [SongCard] = []
    @Published var upcomingAlbums: [AlbumCard] = []

    // Loading / state
    @Published var isLoaded: Bool = false
    @Published var screenIsLoading: Bool = false
    @Published var hasLoadedOnce: Bool = false
    @Published var lastError: String?

    // Services
    let api: JellyfinAPIService
    private let artworkService = AppleArtworkService.shared
    let lbUsername: String

    // Internals
    private var cancellables = Set<AnyCancellable>()
    private var bag = Set<AnyCancellable>() // for feed zip

    // Tunables
    private let heroLimit = 12
    private let playlistLimit = 6
    private let blacklistedAlbumTags: Set<String> = ["blacklist", "blacklisthv"]
    private let blacklistedPlaylistTags: Set<String> = ["replay", "mfy"]

    init(api: JellyfinAPIService, lbUsername: String) {
        self.api = api
        self.lbUsername = lbUsername
    }

    // MARK: - Public orchestrator

    @MainActor
    func loadAllOnce() async {
        guard !hasLoadedOnce else { return } // no reloading on navigating back
        screenIsLoading = true

        let group = DispatchGroup()

        group.enter(); loadFeed { group.leave() }
        group.enter(); loadFreshReleases { group.leave() }
        group.enter(); loadNewAlbums(days: 120, limit: 20) { group.leave() }
        group.enter(); loadUpdatedPlaylists(limit: 20) { group.leave() }
        group.enter(); loadEditorialTopAlbums(limit: 19) { group.leave() }
        group.enter(); loadGlobalSongs(limit: 24) { group.leave() }
        group.enter(); loadEverybodySongs(limit: 16) { group.leave() }
        group.enter(); loadUpcomingAlbums(limit: 10) { group.leave() }

        group.notify(queue: .main) {
            // Prefetch images for the first screen
            let firstScreenURLs: [URL] = (
                // banners
                self.feed.compactMap { $0.imageURL } +
                // first 8 small song arts (120x)
                self.freshCards.prefix(8).compactMap { appleArtwork($0.artworkURL, square: 120) ?? $0.artworkURL } +
                // first 6 album tiles (300x)
                self.newAlbums.prefix(6).compactMap { $0.artworkURL } +
                // first 6 playlist tiles
                self.updatedPlaylists.prefix(6).compactMap { $0.artworkURL }
            )
            self.prefetch(firstScreenURLs)
            
            self.screenIsLoading = false
            self.isLoaded = true
            self.hasLoadedOnce = true
        }
    }

    // MARK: - Loaders (Combine)

    private func loadFeed(onDone: (() -> Void)? = nil) {
        let albumsPublisher = api.fetchAlbums()
            .map { (albums: [JellyfinAlbum]) -> [JellyfinAlbum] in
                let sorted = albums.sorted { a, b in self.parseJellyfinDate(from: a) > self.parseJellyfinDate(from: b) }
                return Array(sorted.prefix(self.heroLimit))
            }
            .eraseToAnyPublisher()

        let playlistsPublisher = api.fetchPlaylistsAdvanced(
            sort: .dateAdded, descending: true, filter: .all, limit: playlistLimit
        )

        Publishers.Zip(albumsPublisher, playlistsPublisher)
            .map { (albums: [JellyfinAlbum], playlists: [JellyfinAlbum]) -> [NewFeedItem] in
                let albumItems = self.mapAlbumsToFeedItems(albums)
                let playlistItems = self.mapPlaylistsToFeedItems(playlists)
                let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
                let merged = (day % 2 == 0) ? (albumItems + playlistItems) : (playlistItems + albumItems)
                return merged.sorted { $0.date > $1.date }
            }
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion { self.lastError = err.localizedDescription }
                onDone?()
            }, receiveValue: { items in
                self.feed = items
            })
            .store(in: &bag)
    }

    private func loadFreshReleases(onDone: (() -> Void)? = nil) {
        ListenBrainzAPI(username: lbUsername)
            .freshReleases()
            .receive(on: DispatchQueue.main)
            .sink { recs, _ in
                let cards = recs.map {
                    SongCard(
                        artist: $0.artist,
                        title: $0.title,
                        artworkURL: self.coverArtURL(releaseMBID: $0.releaseMBID, releaseGroupMBID: $0.releaseGroupMBID),
                        date: $0.releaseDate
                    )
                }
                self.freshCards = cards
                if cards.isEmpty {
                    self.lastError = "No fresh releases found in the last 4 months for \(self.lbUsername)."
                }
                onDone?()
            }
            .store(in: &cancellables)
    }

    private func loadNewAlbums(days: Int, limit: Int, onDone: (() -> Void)? = nil) {
        ListenBrainzAPI(username: lbUsername)
            .freshAlbumReleases(days: days, limit: limit)
            .receive(on: DispatchQueue.main)
            .sink { releases, _ in
                var cards = releases.map { r in
                    AlbumCard(title: r.title, artist: r.artist, artworkURL: nil, date: r.releaseDate)
                }
                self.newAlbums = cards
                if cards.isEmpty {
                    self.lastError = "No new album releases in the last \(days/30) months."
                    onDone?(); return
                }
                // Fetch artwork (non-blocking)
                for idx in cards.indices {
                    let artist = cards[idx].artist
                    let title  = cards[idx].title
                    self.artworkService.albumArtwork(artist: artist, album: title)
                        .receive(on: DispatchQueue.main)
                        .sink { url in
                            guard let url = url else { return }
                            if idx < self.newAlbums.count,
                               self.newAlbums[idx].title == title,
                               self.newAlbums[idx].artist == artist {
                                let sized = appleArtwork(url, square: 300) ?? url
                                self.newAlbums[idx] = AlbumCard(title: title, artist: artist, artworkURL: sized, date: self.newAlbums[idx].date)
                            }
                        }
                        .store(in: &self.cancellables)
                }
                onDone?()
            }
            .store(in: &cancellables)
    }

    private func loadUpdatedPlaylists(limit: Int, onDone: (() -> Void)? = nil) {
        api.fetchPlaylistsAdvanced(sort: .dateAdded, descending: true, filter: .all, limit: 100)
            .map { (playlists: [JellyfinAlbum]) -> [AlbumCard] in
                let filtered = playlists.filter { pl in
                    let tagSet = Set((pl.tags ?? []).map { $0.lowercased() })
                    return !tagSet.contains("replay") && tagSet.isDisjoint(with: self.blacklistedPlaylistTags)
                }
                let cards: [AlbumCard] = filtered.map { pl in
                    AlbumCard(
                        title: pl.name,
                        artist: "Playlist",
                        artworkURL: self.imageURL(for: pl.id, type: "Primary", maxWidth: 300, aspectRatio: nil, quality: 75),
                        date: self.parseJellyfinDate(from: pl)
                    )
                }
                return Array(cards.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
            }
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let err) = completion { self.lastError = err.localizedDescription }
                onDone?()
            }, receiveValue: { cards in
                self.updatedPlaylists = cards
                if cards.isEmpty {
                    self.lastError = "No recently updated playlists."
                }
            })
            .store(in: &cancellables)
    }

    private func loadEditorialTopAlbums(limit: Int, onDone: (() -> Void)? = nil) {
        AppleRSSAPI.topAlbums(limit: limit)
            .receive(on: DispatchQueue.main)
            .sink { albums in
                if albums.isEmpty {
                    self.editorialAlbums = []
                    self.lastError = "No local editorial picks available for your region."
                } else {
                    self.editorialAlbums = albums.map {
                        AlbumCard(title: $0.title, artist: $0.artistName, artworkURL: $0.artworkURL, date: $0.releaseDate)
                    }
                }
                onDone?()
            }
            .store(in: &cancellables)
    }

    private func loadGlobalSongs(limit: Int, onDone: (() -> Void)? = nil) {
        AppleRSSAPI.globalTopSongs(finalLimit: limit)
            .receive(on: DispatchQueue.main)
            .sink { songs in
                self.globalSongCards = songs.map {
                    SongCard(artist: $0.artistName, title: $0.title, artworkURL: $0.artworkURL, date: $0.releaseDate)
                }
                if songs.isEmpty { self.lastError = "No global trending songs right now." }
                onDone?()
            }
            .store(in: &cancellables)
    }

    private func loadEverybodySongs(limit: Int, onDone: (() -> Void)? = nil) {
        AppleRSSAPI.globalTopSongs(finalLimit: limit)
            .receive(on: DispatchQueue.main)
            .sink { songs in
                self.everybodySongCards = songs.map {
                    SongCard(artist: $0.artistName, title: $0.title, artworkURL: $0.artworkURL, date: $0.releaseDate)
                }
                if songs.isEmpty { self.lastError = "No global listening data right now." }
                onDone?()
            }
            .store(in: &cancellables)
    }

    private func loadUpcomingAlbums(limit: Int, onDone: (() -> Void)? = nil) {
        ListenBrainzAPI(username: lbUsername)
            .upcomingAlbumReleases(limit: limit)
            .receive(on: DispatchQueue.main)
            .sink { releases, _ in
                var cards = releases.map { r in
                    AlbumCard(title: r.title, artist: r.artist, artworkURL: nil, date: r.releaseDate)
                }
                self.upcomingAlbums = cards
                if cards.isEmpty {
                    self.lastError = "No upcoming albums curated for \(self.lbUsername)."
                    onDone?(); return
                }
                for idx in cards.indices {
                    let artist = cards[idx].artist
                    let title  = cards[idx].title
                    self.artworkService.albumArtwork(artist: artist, album: title)
                        .receive(on: DispatchQueue.main)
                        .sink { url in
                            guard let url = url else { return }
                            if idx < self.upcomingAlbums.count,
                               self.upcomingAlbums[idx].title == title,
                               self.upcomingAlbums[idx].artist == artist {
                                let sized = appleArtwork(url, square: 300) ?? url
                                self.upcomingAlbums[idx] = AlbumCard(title: title, artist: artist, artworkURL: sized, date: self.upcomingAlbums[idx].date)
                            }
                        }
                        .store(in: &self.cancellables)
                }
                onDone?()
            }
            .store(in: &cancellables)
    }

    // MARK: - Helpers (local to the VM file)

    private func prefetch(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        SDWebImagePrefetcher.shared.prefetchURLs(urls)
    }

    private func coverArtURL(releaseMBID: String?, releaseGroupMBID: String?) -> URL? {
        if let id = releaseMBID { return URL(string: "https://coverartarchive.org/release/\(id)/front?size=250") }
        if let id = releaseGroupMBID { return URL(string: "https://coverartarchive.org/release-group/\(id)/front?size=250") }
        return nil
    }
    
    @inline(__always)
    func imageURL(for itemId: String,
                  type: String = "Primary",
                  maxWidth: Int = 600,
                  aspectRatio: String? = nil,
                  quality: Int = 90) -> URL? {
        guard !api.serverURL.isEmpty else { return nil }
        var c = URLComponents(string: "\(api.serverURL)Items/\(itemId)/Images/\(type)")
        var items: [URLQueryItem] = [
            .init(name: "maxWidth", value: "\(maxWidth)"),
            .init(name: "quality", value: "\(quality)"),
            .init(name: "format", value: "jpg"),
            .init(name: "enableImageEnhancers", value: "false"),
            .init(name: "api_key", value: api.authToken)
        ]
        if let ar = aspectRatio { items.append(.init(name: "aspectRatio", value: ar)) }
        c?.queryItems = items
        return c?.url
    }

    private func parseJellyfinDate(from item: JellyfinAlbum) -> Date {
        let iso = ISO8601DateFormatter()
        for opts in [
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
            ISO8601DateFormatter.Options([.withFullDate])
        ] {
            iso.formatOptions = opts
            for s in [item.premiereDate, item.releaseDate, item.dateCreated].compactMap({ $0 }) {
                if let d = iso.date(from: s) { return d }
            }
        }
        if let year = item.productionYear,
           let d = Calendar.current.date(from: DateComponents(year: year)) { return d }
        return .distantPast
    }

    private func mapAlbumsToFeedItems(_ albums: [JellyfinAlbum]) -> [NewFeedItem] {
        albums.compactMap { album in
            let tagSet = Set((album.tags ?? []).map { $0.lowercased() })
            guard tagSet.isDisjoint(with: self.blacklistedAlbumTags) else { return nil }
            let releaseDate = self.parseJellyfinDate(from: album)

            let badge: String = {
                if let days = Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day, days > 14 { return "ALBUM" }
                return "NEW ALBUM"
            }()

            let subtitle: String = {
                if let names = album.artistItems?.compactMap({ $0.name }), !names.isEmpty { return names.joined(separator: ", ") }
                if let names = album.albumArtists?.compactMap({ $0.name }), !names.isEmpty { return names.joined(separator: ", ") }
                return "Unknown Artist"
            }()

            return NewFeedItem(
                id: album.id,
                kind: .album,
                title: album.name,
                subtitle: subtitle,
                badge: badge,
                date: releaseDate,
                imageURL: self.imageURL(for: album.id, type: "Banner", maxWidth: 1500, aspectRatio: "3:2", quality: 85)
            )
        }
    }

    private func mapPlaylistsToFeedItems(_ playlists: [JellyfinAlbum]) -> [NewFeedItem] {
        playlists.compactMap { pl in
            let tagSet = Set((pl.tags ?? []).map { $0.lowercased() })
            guard tagSet.isDisjoint(with: self.blacklistedPlaylistTags) else { return nil }

            return NewFeedItem(
                id: pl.id,
                kind: .playlist,
                title: pl.name,
                subtitle: "Playlist",
                badge: "UPDATED PLAYLIST",
                date: self.parseJellyfinDate(from: pl),
                imageURL: self.imageURL(for: pl.id, type: "Menu", maxWidth: 1500, aspectRatio: "3:2")
            )
        }
    }
}
