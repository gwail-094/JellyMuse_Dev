import Foundation
import Combine

// MARK: - HomeCard DTO (unchanged)
struct HomeCard {
    public enum Kind {
        case album(JellyfinAlbum)
        case playlist(JellyfinAlbum)
        case newest(JellyfinAlbum)
        case artist(JellyfinArtistItem)
    }
    public let kind: Kind
}

// Optional: used if you ever want to return a combined object
struct GenreShelf {
    let genre: String
    let albums: [JellyfinAlbum]
}

final class HomeFeedService {
    private let api: JellyfinAPIService
    private var bag = Set<AnyCancellable>()
    // Cache of "BlacklistHV" album IDs to avoid re-pulling every time
    private var cachedBlacklistAlbumIDs: Set<String>?

    // MARK: - Updated Playlist Fingerprints
    private struct PlaylistFP: Codable {
        let sig: String // fingerprint string
        let lastChange: Date // when we first detected this sig
    }

    private let updatedFPKey = "home.updated.playlist.fp.v1"
    private var updatedFP: [String: PlaylistFP] = [:]

    private static func loadUpdatedFP() -> [String: PlaylistFP] {
        guard let data = UserDefaults.standard.data(forKey: "home.updated.playlist.fp.v1"),
              let dict = try? JSONDecoder().decode([String: PlaylistFP].self, from: data)
        else { return [:] }
        return dict
    }

    private func saveUpdatedFP() {
        if let data = try? JSONEncoder().encode(updatedFP) {
            UserDefaults.standard.set(data, forKey: updatedFPKey)
        }
    }

    /// Optional: expose a dev helper to clear just this cache
    func invalidateUpdatedPlaylistCache() {
        updatedFP.removeAll()
        UserDefaults.standard.removeObject(forKey: updatedFPKey)
    }

    // MARK: - Init
    init(api: JellyfinAPIService = .shared) {
        self.api = api
        self.updatedFP = Self.loadUpdatedFP() // Load the new cache
    }

    /// Fetch all album IDs tagged BlacklistHV
    private func fetchBlacklistedAlbumIDs() -> AnyPublisher<Set<String>, Error> {
        if let cached = cachedBlacklistAlbumIDs {
            return Just(cached).setFailureType(to: Error.self).eraseToAnyPublisher()
        }

        guard ready else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "Tags", value: "BlacklistHV"),
            .init(name: "Fields", value: "Tags"),
            .init(name: "Limit", value: "5000")
        ]

        struct AlbumHead: Decodable { let Id: String }
        struct Envelope: Decodable { let Items: [AlbumHead]? }

        return get(Envelope.self, comps)
            .map { env -> Set<String> in
                let ids = Set((env.Items ?? []).map { $0.Id })
                self.cachedBlacklistAlbumIDs = ids
                return ids
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: Made For You (playlists tagged "MFY")
    func fetchPlaylistsTaggedMFY(limit: Int = 20) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard ready else { return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher() }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Playlist"),
            .init(name: "Tags", value: "MFY"),
            .init(name: "SortBy", value: "DateCreated"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "UserData,ProductionYear,Tags,DateCreated")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            // double-filter just in case (older servers sometimes ignore Tags param)
            .map { ($0.items ?? []).filter { $0.tags?.contains("MFY") ?? false } }
            .eraseToAnyPublisher()
    }
    
    // MARK: Mood playlists
    func fetchPlaylistsTaggedMood(limit: Int = 20) -> AnyPublisher<[JellyfinAlbum], Error> {
        fetchPlaylists(withTag: "Mood", limit: limit)
    }

    // Generic tag-based playlist fetcher (reusable)
    func fetchPlaylists(withTag tag: String, limit: Int = 20) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard ready else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Playlist"),
            .init(name: "Tags", value: tag),
            .init(name: "SortBy", value: "Random"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "UserData,ProductionYear,Tags,DateCreated")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // NEW: Alphabetical playlist fetcher (for stable, sorted lists like Featured Playlists)
    func fetchPlaylistsAlphabetical(tag: String = "AMP", limit: Int = 200)
    -> AnyPublisher<[JellyfinAlbum], Error> {
        fetchPlaylists(withTag: tag, limit: limit)
            .map { lists in
                lists
                    // safety filter: some servers ignore Tags= in query
                    .filter { ($0.tags ?? []).contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
                    // stable, natural A→Z by display name, with id as tiebreaker
                    .sorted {
                        let lhs = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rhs = $1.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cmp = lhs.localizedStandardCompare(rhs)   // natural + case-insensitive
                        return (cmp == .orderedAscending) || (cmp == .orderedSame && $0.id < $1.id)
                    }
            }
            .eraseToAnyPublisher()
    }

    // MARK: Updated Playlists
    func fetchRecentlyUpdatedPlaylists(limit: Int = 10) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard ready else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Playlist"),
            // KEY: prefer last media added, then modified, then created
            .init(name: "SortBy", value: "DateLastMediaAdded,DateModified,DateCreated"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "Limit", value: String(limit)),
            // Ask for the fields we sort on
            .init(name: "Fields", value: "DateLastMediaAdded,DateModified,DateCreated,UserData,Tags")
        ]
        // KEY: Use noCache: true to prevent stale results
        return get(ItemsResponse<JellyfinAlbum>.self, comps, noCache: true)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // Most recently updated playlist (excluding a tag) — robust to schema differences
    // REPLACED WITH NEW LOGIC
    func fetchMostRecentlyUpdatedPlaylist(
        excludingTag skipTag: String = "NotUP",
        lookahead: Int = 40
    ) -> AnyPublisher<JellyfinAlbum?, Error> {
        guard ready else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }

        struct PlaylistHead: Decodable {
            let Id: String
            let Name: String?
            let Tags: [String]?
            let DateLastMediaAdded: String?
            let DateModified: String?
            let DateCreated: String?
            // Optional: if your server returns ChildCount, add:
            // let ChildCount: Int?
        }
        struct Envelope: Decodable { let Items: [PlaylistHead]? }

        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Playlist"),
            .init(name: "SortBy", value: "DateLastMediaAdded,DateModified,DateCreated"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "Limit", value: String(max(20, lookahead))),
            .init(name: "Fields", value: "Tags,DateLastMediaAdded,DateModified,DateCreated")
            // If you have it: add "ChildCount"
        ]

        func ownBestDate(_ h: PlaylistHead) -> Date {
            for ts in [h.DateLastMediaAdded, h.DateModified, h.DateCreated] {
                if let ts, let d = Self.parseDate(ts) { return d }
            }
            return .distantPast
        }

        return get(Envelope.self, comps)
            .map { env in
                (env.Items ?? []).filter {
                    !($0.Tags ?? []).contains { $0.caseInsensitiveCompare(skipTag) == .orderedSame }
                }
            }
            .flatMap { heads -> AnyPublisher<JellyfinAlbum?, Error> in
                let top = Array(heads.prefix(lookahead))

                // For each candidate, compute: (playlistId, computedUpdatedAt)
                let pubs: [AnyPublisher<(String, Date), Error>] = top.map { h in
                    self.playlistFingerprint(for: h.Id)
                        .map { (sig, newestChild, _) -> (String, Date) in
                            let base = max(ownBestDate(h), newestChild ?? .distantPast)

                            // fp cache decision
                            let previous = self.updatedFP[h.Id]
                            let updatedAt: Date
                            if let prev = previous {
                                if prev.sig != sig {
                                    // change detected NOW
                                    updatedAt = Date()
                                    self.updatedFP[h.Id] = PlaylistFP(sig: sig, lastChange: updatedAt)
                                } else {
                                    // unchanged; keep lastChange so "recency" is stable
                                    updatedAt = prev.lastChange
                                }
                            } else {
                                // first sighting: seed with the best known server date
                                updatedAt = base
                                self.updatedFP[h.Id] = PlaylistFP(sig: sig, lastChange: updatedAt)
                            }
                            return (h.Id, updatedAt)
                        }
                        .eraseToAnyPublisher()
                }

                return Publishers.MergeMany(pubs)
                    .collect()
                    .flatMap { pairs -> AnyPublisher<JellyfinAlbum?, Error> in
                        // persist cache once per fetch
                        self.saveUpdatedFP()

                        guard let newest = pairs.max(by: { $0.1 < $1.1 })?.0 else {
                            return Just(nil).setFailureType(to: Error.self).eraseToAnyPublisher()
                        }
                        return self.fetchPlaylistById(newest)
                    }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    // REMOVED: private func latestChildDate(for playlistId: String) -> AnyPublisher<Date?, Error> { ... }

    /// Build a fingerprint from the playlist's children.
    /// Detects adds/removes reliably; reorders may or may not be detected (Jellyfin order is not always exposed).
    private func playlistFingerprint(for playlistId: String, sample: Int = 120)
    -> AnyPublisher<(sig: String, newestChild: Date?, total: Int), Error> {

        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "ParentId", value: playlistId),
            .init(name: "IncludeItemTypes", value: "Audio"),
            // No SortBy on purpose; we'll sort IDs ourselves for a stable set comparison
            .init(name: "Limit", value: String(sample)),
            .init(name: "Fields", value: "DateCreated,DateAdded,DateModified,AlbumId,Id") // for newestChild, and Id for fingerprint
        ]

        struct ChildHead: Decodable {
            let Id: String
            let DateCreated: String?
            let DateAdded: String?
            let DateModified: String?
        }
        struct Env: Decodable {
            let Items: [ChildHead]?
            let TotalRecordCount: Int?
        }

        return get(Env.self, comps)
            .map { env -> (sig: String, newestChild: Date?, total: Int) in
                let items = env.Items ?? []
                let total = env.TotalRecordCount ?? items.count

                // newest child timestamp we see
                let newestChild = items
                    .compactMap { head -> Date? in
                        // prefer Modified > Added > Created
                        if let s = head.DateModified, let d = Self.parseDate(s) { return d }
                        if let s = head.DateAdded,    let d = Self.parseDate(s) { return d }
                        if let s = head.DateCreated,  let d = Self.parseDate(s) { return d }
                        return nil
                    }
                    .max()

                // stable subset of child IDs (sorted so order changes don't create noise)
                let idSubset = items.map(\.Id).sorted().prefix(80)
                let newestEpoch = Int(newestChild?.timeIntervalSince1970 ?? 0)

                // fingerprint ingredients: total count + newest child time + subset of IDs
                let sig = "\(total)#\(newestEpoch)#\(idSubset.joined(separator: ","))"
                return (sig, newestChild, total)
            }
            .eraseToAnyPublisher()
    }


    // Helper: fetch a full playlist item by ID as JellyfinAlbum
    private func fetchPlaylistById(_ id: String) -> AnyPublisher<JellyfinAlbum?, Error> {
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        // STEP 2: Added ImageTags, PrimaryImageTag, DateLastMediaAdded to Fields
        comps?.queryItems = [
            .init(name: "Ids", value: id),
            .init(name: "Fields", value: "Tags,UserData,ProductionYear,DateCreated,DateModified,Overview,ImageTags,PrimaryImageTag,DateLastMediaAdded")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items?.first }
            .eraseToAnyPublisher()
    }
    
    // MARK: New Releases
    func fetchNewestAlbums(limit: Int = 12) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard ready else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "SortBy", value: "PremiereDate,DateCreated"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "ExcludeItemTags", value: "BlacklistHV"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "UserData,ProductionYear,PremiereDate,AlbumArtist,ArtistItems,Genres,Tags,RunTimeTicks,AlbumId,ParentIndexNumber")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }

    // MARK: Top Picks (original random, kept)
    func fetchTopPicks() -> AnyPublisher<[HomeCard], Error> {
        let albumsPub = fetchRandomAlbums(count: 3)
        let playlistsPub = fetchRandomPlaylists(count: 3)
        let newestOnePub = fetchNewestAlbums(limit: 1)
            .map { $0.first }
            .eraseToAnyPublisher()
        let artistPub = fetchRandomArtists(count: 1)
            .map { $0.first }
            .eraseToAnyPublisher()

        return Publishers.Zip4(albumsPub, playlistsPub, newestOnePub, artistPub)
            .map { albums, playlists, newest, artist in
                var cards: [HomeCard] = []
                cards += albums.map { HomeCard(kind: .album($0)) }
                cards += playlists.map { HomeCard(kind: .playlist($0)) }
                if let n = newest { cards.append(HomeCard(kind: .newest(n))) }
                if let a = artist { cards.append(HomeCard(kind: .artist(a))) }
                return cards.shuffled()
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: NEW — Top Picks with daily persistence
    private struct TopPicksState: Codable {
        let day: String
        let albumIds: [String]
        let playlistIds: [String]
        let newestId: String?
        let artistIds: [String]
    }
    private let topPicksKey = "home.top.picks.daily.v1"

    func fetchTopPicksDaily() -> AnyPublisher<[HomeCard], Error> {
        let today = todayString()

        if let saved = loadTopPicksState(), saved.day == today {
            return rebuildTopPicksFromState(saved)
        }

        // Pick new random sets and persist their IDs for today
        return Publishers.Zip4(fetchRandomAlbums(count: 3),
                               fetchRandomPlaylists(count: 3),
                               fetchNewestAlbums(limit: 1).map { $0.first }.eraseToAnyPublisher(),
                               fetchRandomArtists(count: 1).map { $0.first }.eraseToAnyPublisher())
            .map { albums, playlists, newest, artist -> (TopPicksState, [HomeCard]) in
                let state = TopPicksState(
                    day: today,
                    albumIds: albums.map { $0.id },
                    playlistIds: playlists.map { $0.id },
                    newestId: newest?.id,
                    artistIds: artist.map { [$0.id] } ?? []
                )

                var cards: [HomeCard] = []
                cards += albums.map { HomeCard(kind: .album($0)) }
                cards += playlists.map { HomeCard(kind: .playlist($0)) }
                if let n = newest { cards.append(HomeCard(kind: .newest(n))) }
                if let a = artist { cards.append(HomeCard(kind: .artist(a))) }
                cards.shuffle()

                return (state, cards)
            }
            .handleEvents(receiveOutput: { [weak self] state, _ in
                self?.saveTopPicksState(state)
            })
            .map { $0.1 }
            .eraseToAnyPublisher()
    }

    private func rebuildTopPicksFromState(_ s: TopPicksState) -> AnyPublisher<[HomeCard], Error> {
        let albumsPub = fetchAlbumsByIds(s.albumIds)
        let playlistsPub = fetchPlaylistsByIds(s.playlistIds)
        let newestPub: AnyPublisher<JellyfinAlbum?, Error> =
            (s.newestId != nil) ? fetchAlbumsByIds([s.newestId!]).map { $0.first }.eraseToAnyPublisher()
                            : Just(nil).setFailureType(to: Error.self).eraseToAnyPublisher()
        let artistsPub = fetchArtistsByIds(s.artistIds)

        return Publishers.Zip4(albumsPub, playlistsPub, newestPub, artistsPub)
            .map { albums, playlists, newest, artists -> [HomeCard] in
                var cards: [HomeCard] = []
                cards += albums.map { HomeCard(kind: .album($0)) }
                cards += playlists.map { HomeCard(kind: .playlist($0)) }
                if let n = newest { cards.append(HomeCard(kind: .newest(n))) }
                cards += artists.map { HomeCard(kind: .artist($0)) }
                return cards
            }
            .eraseToAnyPublisher()
    }

    private func loadTopPicksState() -> TopPicksState? {
        guard let data = UserDefaults.standard.data(forKey: topPicksKey) else { return nil }
        return try? JSONDecoder().decode(TopPicksState.self, from: data)
    }

    private func saveTopPicksState(_ s: TopPicksState) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: topPicksKey)
        }
    }
    
    // MARK: Randoms / utility
    func fetchRandomAlbums(count: Int = 3) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard ready else { return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher() }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "SortBy", value: "Random"),
            .init(name: "ExcludeItemTags", value: "BlacklistHV"),
            .init(name: "Limit", value: String(max(1, count))),
            .init(name: "Fields", value: "UserData,OfficialRating,CommunityRating,ProductionYear,AlbumArtist,Tags,Genres,RunTimeTicks,AlbumId,ParentIndexNumber")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    func fetchRandomPlaylists(count: Int = 3) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard ready else { return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher() }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Playlist"),
            .init(name: "Tags", value: "MFY"),
            .init(name: "SortBy", value: "Random"),
            .init(name: "Limit", value: String(count)),
            .init(name: "Fields", value: "UserData,ProductionYear,Tags,DateCreated")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { ($0.items ?? []).filter { $0.tags?.contains("MFY") ?? false } } // double filter for good measure
            .eraseToAnyPublisher()
    }
    
    func fetchNewestAlbum() -> AnyPublisher<JellyfinAlbum?, Error> {
        guard ready else { return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher() }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "SortBy", value: "DateCreated"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "ExcludeItemTags", value: "BlacklistHV"),
            .init(name: "Limit", value: "1"),
            .init(name: "Fields", value: "UserData,OfficialRating,CommunityRating,ProductionYear,AlbumArtist,Tags,Genres")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items?.first }
            .eraseToAnyPublisher()
    }
    
    func fetchRandomArtists(count: Int = 2) -> AnyPublisher<[JellyfinArtistItem], Error> {
        guard ready else { return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher() }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicArtist"),
            .init(name: "SortBy", value: "Random"),
            .init(name: "Limit", value: String(max(1, count))),
            .init(name: "Fields", value: "Tags")
        ]
        return get(ItemsResponse<JellyfinArtistItem>.self, comps)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Recently Played MIXED (Albums + Playlists only)
    struct RecentItem: Identifiable, Equatable {     // ← add Equatable
        enum Kind { case album, playlist }
        let id: String
        let name: String
        let subtitle: String?
        let datePlayed: Date
        let kind: Kind
        let tags: [String]? // FIX 2: Added tags property

        static func == (lhs: RecentItem, rhs: RecentItem) -> Bool {
            // Tie equality to identity + recency so SwiftUI sees meaningful changes
            lhs.id == rhs.id && lhs.datePlayed == rhs.datePlayed
        }
    }

    func fetchRecentlyPlayedMixed(limit: Int = 18) -> AnyPublisher<[RecentItem], Error> {
        let pull = max(40, limit * 4)

        let albumsViaAlbum  = _recentAlbums(limit: pull)
        let albumsViaTracks = _recentAlbumsFromTracks(limit: pull)
        let playlists       = _recentPlaylists(limit: pull)

        // 1) Get the set of blacklisted album IDs once
        return fetchBlacklistedAlbumIDs()
            .flatMap { blacklist -> AnyPublisher<[RecentItem], Error> in
                // 2) Pull the three streams and merge as before
                Publishers.Zip3(albumsViaAlbum, albumsViaTracks, playlists)
                    .map { a1, a2, p in
                        // Defensive filter: drop any album tile whose albumId is blacklisted
                        let a1f = a1.filter { !blacklist.contains($0.id) }
                        let a2f = a2.filter { !blacklist.contains($0.id) }
                        // playlists unaffected by album blacklist
                        let pf  = p

                        // --- original de-dupe/merge logic ---
                        var bestAlbumById: [String: RecentItem] = [:]
                        for it in (a1f + a2f) {
                            if let existing = bestAlbumById[it.id] {
                                if it.datePlayed > existing.datePlayed { bestAlbumById[it.id] = it }
                            } else {
                                bestAlbumById[it.id] = it
                            }
                        }
                        let albumsMerged = Array(bestAlbumById.values)

                        var bestById: [String: RecentItem] = [:]
                        for it in (albumsMerged + pf) {
                            if let existing = bestById[it.id] {
                                if it.datePlayed > existing.datePlayed { bestById[it.id] = it }
                            } else {
                                bestById[it.id] = it
                            }
                        }

                        let merged = Array(bestById.values)
                            .sorted(by: { $0.datePlayed > $1.datePlayed })
                        return Array(merged.prefix(limit))
                    }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    // Albums direct (container)
    private func _recentAlbums(limit: Int) -> AnyPublisher<[RecentItem], Error> {
        guard ready else { return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher() }

        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "SortBy", value: "DateLastPlayed,DatePlayed"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "ExcludeItemTags", value: "BlacklistHV"), // ADJUSTED
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "DateLastPlayed,DatePlayed,Artists,UserData,Tags") // FIX 2: Added Tags
        ]

        struct UserDataDTO: Decodable { let LastPlayedDate: String? }
        struct AlbumDTO: Decodable {
            let Id: String
            let Name: String
            let DateLastPlayed: String?
            let DatePlayed: String?
            let Artists: [String]?
            let UserData: UserDataDTO?
            let Tags: [String]? // FIX 2: Added Tags
        }
        struct Envelope: Decodable { let Items: [AlbumDTO]? }

        return get(Envelope.self, comps)
            .map { env in
                (env.Items ?? []).compactMap { it -> RecentItem? in
                    let ts = it.DateLastPlayed ?? it.DatePlayed ?? it.UserData?.LastPlayedDate
                    guard let ts, let when = Self.parseDate(ts) else { return nil }
                    return RecentItem(
                        id: it.Id,
                        name: it.Name,
                        subtitle: it.Artists?.first,
                        datePlayed: when,
                        kind: .album,
                        tags: it.Tags // FIX 2: Plumbed tags
                    )
                }
            }
            .eraseToAnyPublisher()
    }

    // Collapse recent tracks → album tiles
    private func _recentAlbumsFromTracks(limit: Int) -> AnyPublisher<[RecentItem], Error> {
        guard ready else { return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher() }

        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Audio"),
            .init(name: "SortBy", value: "DateLastPlayed,DatePlayed"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "ExcludeItemTags", value: "BlacklistHV"), // ADJUSTED
            .init(name: "Limit", value: String(max(60, limit * 6))),
            .init(name: "Fields", value: "DateLastPlayed,DatePlayed,Album,AlbumId,Artists,UserData,Tags") // FIX 2: Added Tags
        ]

        struct UserDataDTO: Decodable { let LastPlayedDate: String? }
        struct TrackDTO: Decodable {
            let Id: String
            let Name: String
            let DateLastPlayed: String?
            let DatePlayed: String?
            let Album: String?
            let AlbumId: String?
            let Artists: [String]?
            let UserData: UserDataDTO?
            let Tags: [String]? // FIX 2: Added Tags
        }
        struct Envelope: Decodable { let Items: [TrackDTO]? }

        return get(Envelope.self, comps)
            .map { env in
                var newestByAlbum: [String: RecentItem] = [:]
                for it in (env.Items ?? []) {
                    let ts = it.DateLastPlayed ?? it.DatePlayed ?? it.UserData?.LastPlayedDate
                    guard let ts, let when = Self.parseDate(ts) else { continue }
                    guard let albumId = it.AlbumId, !albumId.isEmpty else { continue }

                    let candidate = RecentItem(
                        id: albumId,
                        name: it.Album ?? it.Name,
                        subtitle: it.Artists?.first,
                        datePlayed: when,
                        kind: .album,
                        tags: it.Tags // FIX 2: Plumbed tags
                    )
                    if let existing = newestByAlbum[albumId] {
                        if candidate.datePlayed > existing.datePlayed {
                            newestByAlbum[albumId] = candidate
                        }
                    } else {
                        newestByAlbum[albumId] = candidate
                    }
                }
                return Array(newestByAlbum.values)
            }
            .eraseToAnyPublisher()
    }

    // Playlists
    private func _recentPlaylists(limit: Int) -> AnyPublisher<[RecentItem], Error> {
        guard ready else { return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher() }

        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Playlist"),
            .init(name: "SortBy", value: "DateLastPlayed,DatePlayed"),
            .init(name: "SortOrder", value: "Descending"),
            .init(name: "ExcludeItemTags", value: "BlacklistHV"), // ADJUSTED
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "DateLastPlayed,DatePlayed,UserData,Tags") // FIX 2: Added Tags
        ]

        struct UserDataDTO: Decodable { let LastPlayedDate: String? }
        struct ListDTO: Decodable {
            let Id: String
            let Name: String
            let DateLastPlayed: String?
            let DatePlayed: String?
            let UserData: UserDataDTO?
            let Tags: [String]? // FIX 2: Added Tags
        }
        struct Envelope: Decodable { let Items: [ListDTO]? }

        return get(Envelope.self, comps)
            .map { env in
                (env.Items ?? []).compactMap { it -> RecentItem? in
                    let ts = it.DateLastPlayed ?? it.DatePlayed ?? it.UserData?.LastPlayedDate
                    guard let ts, let when = Self.parseDate(ts) else { return nil }
                    return RecentItem(
                        id: it.Id,
                        name: it.Name,
                        subtitle: "Playlist",
                        datePlayed: when,
                        kind: .playlist,
                        tags: it.Tags // FIX 2: Plumbed tags
                    )
                }
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Daily Genre (persisted per local day)

    private struct DailyState: Codable {
        let day: String      // "yyyy-MM-dd" in .current time zone
        let genre: String
        let albumIds: [String]
    }
    private let dailyStateKey = "daily.genre.state.v1"

    private func todayString() -> String {
        Self._yyyyMMdd(Date())
    }

    private func loadDailyState() -> DailyState? {
        guard let data = UserDefaults.standard.data(forKey: dailyStateKey) else { return nil }
        return try? JSONDecoder().decode(DailyState.self, from: data)
    }

    private func saveDailyState(_ s: DailyState) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: dailyStateKey)
        }
    }

    // Fetch albums by specific IDs (keeps the same set all day)
    private func fetchAlbumsByIds(_ ids: [String]) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !ids.isEmpty else { return Just([]).setFailureType(to: Error.self).eraseToAnyPublisher() }

        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Ids", value: ids.joined(separator: ",")),
            .init(name: "Fields", value: "UserData,ProductionYear,AlbumArtist,Tags,Genres,RunTimeTicks,AlbumId,ParentIndexNumber")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // Ordered by the given ids
    private func fetchAlbumsByIdsOrdered(_ ids: [String]) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !ids.isEmpty else {
            return Just([]).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Ids", value: ids.joined(separator: ",")),
            .init(name: "Fields", value: "UserData,ProductionYear,AlbumArtist,Tags,Genres,RunTimeTicks,AlbumId,ParentIndexNumber")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { resp in
                let dict = Dictionary(uniqueKeysWithValues: (resp.items ?? []).map { ($0.id, $0) })
                // preserve order and drop any missing
                return ids.compactMap { dict[$0] }
            }
            .eraseToAnyPublisher()
    }


    // Public API: returns the genre name + a stable set of albums for *today*.
    func fetchDailyGenre(minAlbums: Int = 5, limit: Int = 12)
    -> AnyPublisher<(genre: String, albums: [JellyfinAlbum]), Error> {
        let today = todayString()

        // 1) If we already have today's pick, return the same albums (by IDs)
        if let state = loadDailyState(), state.day == today {
            return fetchAlbumsByIds(state.albumIds)
                .map { albums in (genre: state.genre, albums: albums) }
                .eraseToAnyPublisher()
        }

        // 2) Pick a new qualified genre name, fetch albums, persist IDs for today
        return _pickQualifiedGenreName(minAlbums: minAlbums)
            .flatMap { genreName -> AnyPublisher<(genre: String, albums: [JellyfinAlbum]), Error> in
                var comps = URLComponents(string: "\(self.api.serverURL)Users/\(self.api.userId)/Items")
                comps?.queryItems = [
                    .init(name: "Recursive", value: "true"),
                    .init(name: "IncludeItemTypes", value: "MusicAlbum"),
                    .init(name: "Genres", value: genreName),
                    .init(name: "SortBy", value: "Random"),
                    .init(name: "ExcludeItemTags", value: "BlacklistHV"),
                    .init(name: "Limit", value: String(limit)),
                    .init(name: "Fields", value: "UserData,ProductionYear,AlbumArtist,Tags,Genres,RunTimeTicks,AlbumId,ParentIndexNumber")
                ]
                return self.get(ItemsResponse<JellyfinAlbum>.self, comps)
                    .map { resp in (genre: genreName, albums: resp.items ?? []) }
                    .eraseToAnyPublisher()
            }
            .handleEvents(receiveOutput: { output in
                let ids = output.albums.map { $0.id }
                self.saveDailyState(.init(day: today, genre: output.genre, albumIds: ids))
            })
            .eraseToAnyPublisher()
    }

    // MARK: - Daily "More Like" anchor
    private struct MoreLikeState: Codable {
        let day: String  // yyyy-MM-dd (local)
        let albumId: String
    }
    private let moreLikeKey = "daily.morelike.album.v1"
    
    // === Add near your other daily state structs ===
    private struct MoreLikeListState: Codable {
        let day: String          // yyyy-MM-dd (local)
        let anchorId: String
        let albumIds: [String] // order matters
    }
    private let moreLikeListKey = "daily.morelike.similar.v1"

    private func loadMoreLikeState() -> MoreLikeState? {
        guard let data = UserDefaults.standard.data(forKey: moreLikeKey) else { return nil }
        return try? JSONDecoder().decode(MoreLikeState.self, from: data)
    }
    private func saveMoreLikeState(_ s: MoreLikeState) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: moreLikeKey)
        }
    }
    
    private func loadMoreLikeListState() -> MoreLikeListState? {
        guard let data = UserDefaults.standard.data(forKey: moreLikeListKey) else { return nil }
        return try? JSONDecoder().decode(MoreLikeListState.self, from: data)
    }
    private func saveMoreLikeListState(_ s: MoreLikeListState) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: moreLikeListKey)
        }
    }

    /// Return one truly random album, but keep it stable for the local day.
    func fetchDailyRandomAlbum() -> AnyPublisher<JellyfinAlbum?, Error> {
        let today = Self._yyyyMMdd(Date())

        // reuse today's pick if we have it
        if let s = loadMoreLikeState(), s.day == today {
            return fetchAlbumsByIds([s.albumId]).map { $0.first }.eraseToAnyPublisher()
        }

        // otherwise pick a new random album from the whole library (server does the random)
        guard ready else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "SortBy", value: "Random"),
            .init(name: "ExcludeItemTags", value: "BlacklistHV"),
            .init(name: "Limit", value: "1"),
            .init(name: "Fields", value: "UserData,ProductionYear,AlbumArtist,Tags,Genres")
        ]

        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items?.first }
            .handleEvents(receiveOutput: { album in
                if let id = album?.id {
                    self.saveMoreLikeState(.init(day: today, albumId: id))
                }
            })
            .eraseToAnyPublisher()
    }

    /// Fetch similar albums for an anchor album. (non-persistent version)
    func fetchSimilarAlbums(to albumId: String, limit: Int = 12) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard ready else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }
        // CORRECT PATH: /Items/{id}/Similar + UserId in query
        var comps = URLComponents(string: "\(api.serverURL)Items/\(albumId)/Similar")
        comps?.queryItems = [
            .init(name: "UserId", value: api.userId),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "ExcludeItemTags", value: "BlacklistHV"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "UserData,ProductionYear,AlbumArtist,ArtistItems,Genres,Tags")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // NEW: Similar albums for an anchor, but keep the order stable for the local day.
    /// 1) If we already saved today's ids for this anchor, return those (ordered).
    /// 2) Else hit /Items/{id}/Similar once, persist ids for today, and return them.
    func fetchSimilarAlbumsDaily(for anchorId: String, limit: Int = 12)
    -> AnyPublisher<[JellyfinAlbum], Error> {
        let today = todayString()

        if let s = loadMoreLikeListState(),
           s.day == today, s.anchorId == anchorId, !s.albumIds.isEmpty {
            return fetchAlbumsByIdsOrdered(Array(s.albumIds.prefix(limit)))
        }

        // Fall through: fetch fresh once, persist ids, then return in that same order
        return fetchSimilarAlbums(to: anchorId, limit: limit)
            .map { $0.map(\.id) } // IDs in the server's order (whatever it gave us first)
            .handleEvents(receiveOutput: { ids in
                // Only save the IDs returned by the server, not the ones that were filtered out
                self.saveMoreLikeListState(.init(day: today, anchorId: anchorId, albumIds: ids))
            })
            .flatMap { ids in
                self.fetchAlbumsByIdsOrdered(ids)
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Daily "Another Genre" (persisted per local day)
    private struct DailyState2: Codable {
        let day: String      // "yyyy-MM-dd" in .current time zone
        let genre: String
        let albumIds: [String]
    }
    private let dailyStateKey2 = "daily.genre.state.v2"

    private func loadDailyState2() -> DailyState2? {
        guard let data = UserDefaults.standard.data(forKey: dailyStateKey2) else { return nil }
        return try? JSONDecoder().decode(DailyState2.self, from: data)
    }

    private func saveDailyState2(_ s: DailyState2) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: dailyStateKey2)
        }
    }

    /// A second daily genre, different from `excludingGenre`, with at least `minAlbums` albums.
    func fetchDailyGenreAlt(
        excludingGenre: String?,
        minAlbums: Int = 5,
        limit: Int = 12
    ) -> AnyPublisher<(genre: String, albums: [JellyfinAlbum]), Error> {
        let today = Self._yyyyMMdd(Date())

        // Reuse today's pick if we have it and it still differs from the excluded one
        if let state = loadDailyState2(), state.day == today, state.genre.caseInsensitiveCompare(excludingGenre ?? "") != .orderedSame {
            return fetchAlbumsByIds(state.albumIds)
                .map { albums in (genre: state.genre, albums: albums) }
                .eraseToAnyPublisher()
        }

        // Otherwise pick a new qualified genre name that's different from excludingGenre
        return _fetchAllGenres()
            .tryMap { names -> [String] in
                let excluded = (excludingGenre ?? "").lowercased()
                let filtered = names.filter { $0.lowercased() != excluded }
                guard !filtered.isEmpty else { throw URLError(.resourceUnavailable) }
                return filtered.shuffled()
            }
            .flatMap { shuffled -> AnyPublisher<String?, Error> in
                let candidates = Array(shuffled.prefix(50)) // probe up to ~50 genres
                let checks = candidates.map { self._albumCount(forGenre: $0) }
                return Publishers.MergeMany(checks)
                    .filter { _, count in count >= minAlbums }
                    .map { name, _ in name }
                    .first()
                    .map(Optional.init)
                    .eraseToAnyPublisher()
            }
            .tryMap { name in
                guard let name else { throw URLError(.dataNotAllowed) }
                return name
            }
            .flatMap { genreName -> AnyPublisher<(genre: String, albums: [JellyfinAlbum]), Error> in
                var comps = URLComponents(string: "\(self.api.serverURL)Users/\(self.api.userId)/Items")
                comps?.queryItems = [
                    .init(name: "Recursive", value: "true"),
                    .init(name: "IncludeItemTypes", value: "MusicAlbum"),
                    .init(name: "Genres", value: genreName),
                    .init(name: "SortBy", value: "Random"),
                    .init(name: "ExcludeItemTags", value: "BlacklistHV"),
                    .init(name: "Limit", value: String(limit)),
                    .init(name: "Fields", value: "UserData,ProductionYear,AlbumArtist,Tags,Genres,RunTimeTicks,AlbumId,ParentIndexNumber")
                ]
                return self.get(ItemsResponse<JellyfinAlbum>.self, comps)
                    .map { resp in (genre: genreName, albums: resp.items ?? []) }
                    .eraseToAnyPublisher()
            }
            .handleEvents(receiveOutput: { output in
                let ids = output.albums.map { $0.id }
                self.saveDailyState2(.init(day: today, genre: output.genre, albumIds: ids))
            })
            .eraseToAnyPublisher()
    }


    // Fetch *names* of all music genres (prefer /Genres; fallback to sampling albums)
    private func _fetchAllGenres() -> AnyPublisher<[String], Error> {
        var comps = URLComponents(string: "\(api.serverURL)Genres")
        comps?.queryItems = [
            .init(name: "UserId", value: api.userId),
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "Limit", value: "2000")
        ]

        struct GenreNameDTO: Decodable { let Name: String }
        struct GenresEnvelope: Decodable { let Items: [GenreNameDTO]? }

        let primary = get(GenresEnvelope.self, comps)
            .map { env in
                let names = (env.Items ?? []).map { $0.Name }.filter { !$0.isEmpty }
                return Array(Set(names)).sorted()
            }

        // Fallback: sample random albums and aggregate their Genres
        let fallback: AnyPublisher<[String], Error> = {
            var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
            comps?.queryItems = [
                .init(name: "Recursive", value: "true"),
                .init(name: "IncludeItemTypes", value: "MusicAlbum"),
                .init(name: "Fields", value: "Genres"),
                .init(name: "SortBy", value: "Random"),
                .init(name: "Limit", value: "400")
            ]

            struct SampleAlbum: Decodable { let Genres: [String]? }
            struct SampleEnvelope: Decodable { let Items: [SampleAlbum]? }

            return get(SampleEnvelope.self, comps)
                .map { env in
                    let flat = (env.Items ?? []).flatMap { $0.Genres ?? [] }.filter { !$0.isEmpty }
                    return Array(Set(flat)).sorted()
                }
                .eraseToAnyPublisher()
        }()

        return primary.catch { _ in fallback }.eraseToAnyPublisher()
    }

    // Cheap count probe: only reads TotalRecordCount
    private func _albumCount(forGenre genre: String) -> AnyPublisher<(String, Int), Error> {
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "Genres", value: genre),
            .init(name: "Limit", value: "0")
        ]

        struct CountEnvelope: Decodable { let TotalRecordCount: Int }
        return get(CountEnvelope.self, comps)
            .map { (genre, $0.TotalRecordCount) }
            .eraseToAnyPublisher()
    }

    // Pick a random genre that has at least `minAlbums` (probes up to ~50 names)
    private func _pickQualifiedGenreName(minAlbums: Int) -> AnyPublisher<String, Error> {
        _fetchAllGenres()
            .tryMap { names -> [String] in
                guard !names.isEmpty else { throw URLError(.resourceUnavailable) }
                return names.shuffled()
            }
            .flatMap { shuffled -> AnyPublisher<String?, Error> in
                let candidates = Array(shuffled.prefix(50))
                let checks = candidates.map { self._albumCount(forGenre: $0) }
                return Publishers.MergeMany(checks)
                    .filter { _, count in count >= minAlbums }
                    .map { name, _ in name }
                    .first()
                    .map(Optional.init)
                    .eraseToAnyPublisher()
            }
            .tryMap { name in
                guard let name else { throw URLError(.dataNotAllowed) }
                return name
            }
            .eraseToAnyPublisher()
    }

    // Helpers: fetch albums for a genre (to show in the shelf)
    private func _fetchAlbums(forGenre genre: String, limit: Int) -> AnyPublisher<[JellyfinAlbum], Error> {
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "Genres", value: genre),
            .init(name: "SortBy", value: "Random"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "UserData,ProductionYear,AlbumArtist,Tags,Genres,RunTimeTicks,AlbumId,ParentIndexNumber")
        ]

        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // Fetch a compact artist headline from a playlist's tracks
    func fetchPlaylistArtistSummary(playlistId: String, maxNames: Int = 4) -> AnyPublisher<String, Error> {
        guard ready else { return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher() }

        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "ParentId", value: playlistId),
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Audio"),
            .init(name: "Fields", value: "Artists"),
            .init(name: "Limit", value: "500")
        ]

        struct TrackDTO: Decodable { let Artists: [String]? }
        struct Envelope: Decodable { let Items: [TrackDTO]? }

        return get(Envelope.self, comps)
            .map { env -> String in
                let all = (env.Items ?? []).flatMap { $0.Artists ?? [] }
                // unique, keep first-seen order (case-insensitive)
                var seen = Set<String>()
                let uniq = all.compactMap { raw -> String? in
                    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return nil }
                    let key = name.lowercased()
                    guard !seen.contains(key) else { return nil }
                    seen.insert(key)
                    return name
                }
                guard !uniq.isEmpty else { return "Playlist" }
                let head = Array(uniq.prefix(maxNames)).joined(separator: ", ")
                return uniq.count > maxNames ? head + ", and more" : head
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - NEW helpers for rebuilding Top Picks
    private func fetchPlaylistsByIds(_ ids: [String]) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !ids.isEmpty else { return Just([]).setFailureType(to: Error.self).eraseToAnyPublisher() }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Ids", value: ids.joined(separator: ",")),
            .init(name: "IncludeItemTypes", value: "Playlist"),
            .init(name: "Fields", value: "UserData,ProductionYear,Tags,DateCreated")
        ]
        return get(ItemsResponse<JellyfinAlbum>.self, comps)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }

    private func fetchArtistsByIds(_ ids: [String]) -> AnyPublisher<[JellyfinArtistItem], Error> {
        guard !ids.isEmpty else { return Just([]).setFailureType(to: Error.self).eraseToAnyPublisher() }
        var comps = URLComponents(string: "\(api.serverURL)Users/\(api.userId)/Items")
        comps?.queryItems = [
            .init(name: "Ids", value: ids.joined(separator: ",")),
            .init(name: "IncludeItemTypes", value: "MusicArtist"),
            .init(name: "Fields", value: "Tags")
        ]
        return get(ItemsResponse<JellyfinArtistItem>.self, comps)
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Shared plumbing
    private var ready: Bool { !api.serverURL.isEmpty && !api.userId.isEmpty && !api.authToken.isEmpty }

    private func get<T: Decodable>(_ type: T.Type, _ comps: URLComponents?, noCache: Bool = false)
    -> AnyPublisher<T, Error> {
        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.setValue(api.authorizationHeader(withToken: api.authToken), forHTTPHeaderField: "X-Emby-Authorization")
        
        // KEY: Apply cache-busting headers if requested
        if noCache {
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        
        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, resp -> Data in
                guard let http = resp as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200...299).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? "No body"
                    print("API Request Failed with status code \(http.statusCode):\n\(body)")
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: T.self, decoder: JSONDecoder())
            .eraseToAnyPublisher()
    }

    private struct ItemsResponse<Item: Decodable>: Decodable {
        let items: [Item]?
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }
    
    // Robust parser: supports fractional seconds & plain Z/UTC
    private static func parseDate(_ ts: String) -> Date? {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: ts) { return d }

        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: ts) { return d }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        if let d = df.date(from: ts) { return d }

        let df2 = DateFormatter()
        df2.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        df2.timeZone = TimeZone(secondsFromGMT: 0)
        return df2.date(from: ts)
    }
    
    // Date helper
    private static func _yyyyMMdd(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
