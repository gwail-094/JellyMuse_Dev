import Foundation
import Combine
import UIKit

// MARK: - Local Metadata Structs

/// Metadata for a single downloaded song, stored locally for offline use.
struct DownloadedSongMeta: Codable, Identifiable {
    let id: String
    let name: String
    let albumId: String
    let albumName: String?
    let artists: [String]?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let runTimeTicks: Int64?
}

/// Aggregated metadata for a downloaded album, built from its songs.
struct DownloadedAlbumMeta: Codable, Identifiable {
    let id: String
    let name: String
    let artist: String?
    let productionYear: Int? // Note: This data is not currently cached.
    let coverFilename: String?
    let newestFileDate: Date
    let trackCount: Int
}

/// Metadata for a downloaded playlist.
struct DownloadedPlaylistMeta: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var trackIds: [String]
    var newestFileDate: Date?
    var coverFilename: String?
}

/// A bundle containing top results from a local search.
struct DownloadedSearchBundle {
    let albums: [DownloadedAlbumMeta]
    let songs: [DownloadedSongMeta]
    let playlists: [DownloadedPlaylistMeta]
}


// MARK: - DownloadsAPI SessionProvider Protocol
extension DownloadsAPI {
    protocol SessionProvider: AnyObject {
        var serverURL: String { get }
        var authToken: String { get }
        var userId: String { get }
        func authorizationHeader(withToken token: String?) -> String
        func imageURL(for itemId: String) -> URL? // Added for fetching covers

        func fetchPlaylistTracks(playlistId: String) -> AnyPublisher<[JellyfinTrack], Error>
        func fetchTracks(for albumId: String) -> AnyPublisher<[JellyfinTrack], Error>
    }
}


// MARK: - DownloadsAPI
/// A focused, self-contained service that handles:
/// - Downloading tracks/albums/playlists to disk
/// - Maintaining the local downloads index
/// - Building offline models for UI (albums/tracks/playlists)
///
/// It needs the server session (URL/token/userId) only to *perform* downloads or fetch per-track meta.
/// Provide that via a lightweight `SessionProvider`.
@MainActor
final class DownloadsAPI: ObservableObject {
    static let shared = DownloadsAPI()

    // You must set this from your app (usually to JellyfinAPIService.shared)
    weak var session: SessionProvider?

    // MARK: - Published state (for UI)
    @Published private(set) var downloadedTrackURLs: [String: URL] = [:]  // trackId -> file URL
    @Published private(set) var downloadedMeta:      [String: DownloadedSongMeta] = [:] // trackId -> meta
    @Published private(set) var downloadedPlaylists: [String: DownloadedPlaylistMeta] = [:] // playlistId -> meta

    // NEW: In-memory indexes for fast searching and UI filtering
    @Published private(set) var downloadedAlbumsIndex: [DownloadedAlbumMeta] = []
    @Published private(set) var downloadedSongsIndex: [DownloadedSongMeta] = []
    @Published private(set) var downloadedPlaylistsIndex: [DownloadedPlaylistMeta] = []

    // MARK: - Files/paths
    private var downloadsFolderURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Offline", isDirectory: true)
    }
    
    private var coversFolderURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Offline/Covers", isDirectory: true)
    }
    
    private var downloadsIndexKey: String { "jellyfin.downloads.index" }

    private var downloadedMetaFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("downloaded_meta_v1.json")
    }
    private var downloadedPlaylistsFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("downloaded_playlists_v1.json")
    }

    private let deviceId: String = UIDevice.current.identifierForVendor?.uuidString ?? "device-id"
    private var cancellables = Set<AnyCancellable>()
    private var isRecordingPlaylist = false // Re-entrancy fuse
    private var inflightCoverFetches = Set<String>() // Prevent duplicate cover fetches

    private init() {}

    // MARK: - One-time boot
    func prepareDownloadsFolderIfNeeded() {
        try? FileManager.default.createDirectory(at: downloadsFolderURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coversFolderURL, withIntermediateDirectories: true)
        // Restore URL index
        if let data = UserDefaults.standard.data(forKey: downloadsIndexKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            var tmp: [String: URL] = [:]
            for (trackId, relative) in dict {
                tmp[trackId] = downloadsFolderURL.appendingPathComponent(relative)
            }
            downloadedTrackURLs = tmp
        }
        // Restore meta
        loadDownloadedMetaFromDisk()
        // Restore downloaded playlists
        loadDownloadedPlaylistsFromDisk()
        // Build fast in-memory search indexes
        rebuildIndexes()
    }

    // MARK: - Persistence
    private func saveDownloadsIndex() {
        var dict: [String: String] = [:]
        for (trackId, url) in downloadedTrackURLs {
            dict[trackId] = url.lastPathComponent
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: downloadsIndexKey)
        }
    }

    private func loadDownloadedMetaFromDisk() {
        if let data = try? Data(contentsOf: downloadedMetaFileURL),
           let dict = try? JSONDecoder().decode([String: DownloadedSongMeta].self, from: data) {
            downloadedMeta = dict
        }
    }
    private func saveDownloadedMetaToDisk() {
        if let data = try? JSONEncoder().encode(downloadedMeta) {
            try? data.write(to: downloadedMetaFileURL, options: [.atomic])
        }
    }

    func loadDownloadedPlaylistsFromDisk() {
        if let data = try? Data(contentsOf: downloadedPlaylistsFileURL),
           let dict = try? JSONDecoder().decode([String: DownloadedPlaylistMeta].self, from: data) {
            downloadedPlaylists = dict
        }
    }
    private func saveDownloadedPlaylistsToDisk() {
        if let data = try? JSONEncoder().encode(downloadedPlaylists) {
            try? data.write(to: downloadedPlaylistsFileURL, options: [.atomic])
        }
    }

    // MARK: - Quick queries
    func trackIsDownloaded(_ trackId: String) -> Bool {
        if let url = downloadedTrackURLs[trackId] {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return false
    }

    func localURL(for trackId: String) -> URL? {
        guard let url = downloadedTrackURLs[trackId],
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    
    func albumCoverURL(albumId: String) -> URL? {
        let jpgURL = coversFolderURL.appendingPathComponent("\(albumId).jpg")
        if FileManager.default.fileExists(atPath: jpgURL.path) {
            return jpgURL
        }
        
        let pngURL = coversFolderURL.appendingPathComponent("\(albumId).png")
        if FileManager.default.fileExists(atPath: pngURL.path) {
            return pngURL
        }
        
        return nil
    }
    
    func playlistCoverURL(playlistId: String) -> URL? {
        guard let meta = downloadedPlaylists[playlistId],
              let name = meta.coverFilename else { return nil }
        let url = coversFolderURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Delete
    func deleteDownloadedTrack(trackId: String, rebuild: Bool = true) {
        if let url = downloadedTrackURLs[trackId] {
            try? FileManager.default.removeItem(at: url)
        }
        downloadedTrackURLs.removeValue(forKey: trackId)
        saveDownloadsIndex()

        downloadedMeta.removeValue(forKey: trackId)
        saveDownloadedMetaToDisk()

        for key in downloadedPlaylists.keys {
            downloadedPlaylists[key]?.trackIds.removeAll(where: { $0 == trackId })
        }
        saveDownloadedPlaylistsToDisk()

        if rebuild {
            rebuildIndexes()
        }
    }

    func deleteDownloadedAlbum(albumId: String) {
        let ids = downloadedMeta.values.filter { $0.albumId == albumId }.map { $0.id }
        ids.forEach { deleteDownloadedTrack(trackId: $0, rebuild: false) } // Pass false to avoid N rebuilds
        
        if let coverURL = albumCoverURL(albumId: albumId) {
            try? FileManager.default.removeItem(at: coverURL)
        }
        
        rebuildIndexes() // Rebuild once after all deletions are done
    }

    func deleteDownloadedPlaylist(playlistId: String) {
        downloadedPlaylists.removeValue(forKey: playlistId)
        saveDownloadedPlaylistsToDisk()
        rebuildIndexes()
    }

    // MARK: - Build offline models for UI
    
    /// Provides album metadata in a tuple format for UI compatibility.
    /// This is now a lightweight wrapper around the `downloadedAlbumsIndex`.
    func offlineAlbumsWithMetadata() -> [
        (albumId: String,
         albumName: String?,
         artistName: String?,
         productionYear: Int?,
         trackCount: Int,
         newestFileDate: Date)
    ] {
        return downloadedAlbumsIndex.map { meta in
            (albumId: meta.id,
             albumName: meta.name,
             artistName: meta.artist,
             productionYear: meta.productionYear,
             trackCount: meta.trackCount,
             newestFileDate: meta.newestFileDate)
        }
        .sorted { $0.newestFileDate > $1.newestFileDate } // Maintain original sort order
    }

    func offlineTracks(forAlbumId albumId: String) -> [JellyfinTrack] {
        let metas = self.downloadedMeta.values.filter { $0.albumId == albumId }
        let sorted = metas.sorted {
            let d0 = $0.parentIndexNumber ?? 1, d1 = $1.parentIndexNumber ?? 1
            if d0 != d1 { return d0 < d1 }
            let t0 = $0.indexNumber ?? Int.max, t1 = $1.indexNumber ?? Int.max
            return t0 < t1
        }
        return sorted.compactMap { makeLocalJellyfinTrack(from: $0) }
    }

    func offlineTracks(forTrackIds ids: [String]) -> [JellyfinTrack] {
        ids.compactMap { downloadedMeta[$0] }.compactMap { makeLocalJellyfinTrack(from: $0) }
    }

    // MARK: - Local Search

    func searchDownloadedAlbums(query: String) -> [DownloadedAlbumMeta] {
        if query.isEmpty { return downloadedAlbumsIndex }
        let q = query.lowercased()
        return downloadedAlbumsIndex.filter {
            $0.name.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) ?? false)
        }
    }

    func searchDownloadedSongs(query: String) -> [DownloadedSongMeta] {
        if query.isEmpty { return downloadedSongsIndex }
        let q = query.lowercased()
        return downloadedSongsIndex.filter {
            $0.name.lowercased().contains(q) ||
            ($0.albumName?.lowercased().contains(q) ?? false) ||
            ($0.artists?.contains(where: { $0.lowercased().contains(q) }) ?? false)
        }
    }

    func searchDownloadedPlaylists(query: String) -> [DownloadedPlaylistMeta] {
        if query.isEmpty { return downloadedPlaylistsIndex }
        let q = query.lowercased()
        return downloadedPlaylistsIndex.filter {
            $0.name.lowercased().contains(q)
        }
    }

    func searchDownloadedTop(query: String) -> DownloadedSearchBundle {
        let albums = searchDownloadedAlbums(query: query)
        let songs = searchDownloadedSongs(query: query)
        let playlists = searchDownloadedPlaylists(query: query)
        
        return DownloadedSearchBundle(
            albums: Array(albums.prefix(5)),
            songs: Array(songs.prefix(10)),
            playlists: Array(playlists.prefix(5))
        )
    }


    // MARK: - Downloading

    /// Fetches and caches a single album cover if it doesn't exist locally.
    func ensureAlbumCover(albumId: String) -> AnyPublisher<URL?, Never> {
        if let existingURL = albumCoverURL(albumId: albumId) {
            return Just(existingURL).eraseToAnyPublisher()
        }

        guard !inflightCoverFetches.contains(albumId),
              let session = self.session,
              let remoteURL = session.imageURL(for: albumId) else {
            return Just(nil).eraseToAnyPublisher()
        }

        inflightCoverFetches.insert(albumId)

        return URLSession.shared.dataTaskPublisher(for: remoteURL)
            .map(\.data)
            .map { data -> URL? in
                guard let image = UIImage(data: data),
                      let thumbnail = image.preparingThumbnail(of: CGSize(width: 300, height: 300)),
                      let jpegData = thumbnail.jpegData(compressionQuality: 0.8) else {
                    return nil
                }
                
                let fileURL = self.coversFolderURL.appendingPathComponent("\(albumId).jpg")
                try? jpegData.write(to: fileURL)
                return fileURL
            }
            .replaceError(with: nil)
            .handleEvents(receiveCompletion: { _ in
                DispatchQueue.main.async {
                    self.inflightCoverFetches.remove(albumId)
                }
            })
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Download a single track to disk, saving URL + meta.
    func downloadTrack(trackId: String) -> AnyPublisher<URL, Error> {
        guard let session else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }
        return Future<URL, Error> { promise in
            Task {
                if self.downloadedMeta[trackId] == nil {
                    if let meta = await self.fetchTrackMetaForCache(trackId: trackId, session: session) {
                        self.downloadedMeta[trackId] = meta
                        self.saveDownloadedMetaToDisk()
                        
                        // Automatically fetch cover art after saving track metadata
                        self.ensureAlbumCover(albumId: meta.albumId)
                            .sink(receiveValue: { _ in })
                            .store(in: &self.cancellables)
                    }
                }

                guard let remote = self.buildDownloadURL(for: trackId, session: session) else {
                    promise(.failure(URLError(.badURL))); return
                }

                try? FileManager.default.createDirectory(at: self.downloadsFolderURL, withIntermediateDirectories: true)
                var destination = self.downloadsFolderURL.appendingPathComponent("\(trackId).m4a")

                let task = URLSession.shared.downloadTask(with: remote) { tempURL, response, error in
                    if let error = error { promise(.failure(error)); return }
                    guard let tempURL else { promise(.failure(URLError(.unknown))); return }

                    if let http = response as? HTTPURLResponse {
                        if let dispo = http.value(forHTTPHeaderField: "Content-Disposition"),
                           let suggested = dispo.split(separator: ";").first(where: { $0.contains("filename=") })?.split(separator: "=").last {
                            let clean = suggested.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                            if !clean.isEmpty {
                                destination = self.downloadsFolderURL.appendingPathComponent(clean)
                            }
                        } else if let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
                            let ext = mime.contains("mp4") || mime.contains("m4a") ? "m4a" : "mp3"
                            destination = self.downloadsFolderURL.appendingPathComponent("\(trackId).\(ext)")
                        }
                    }

                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try? FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        Task { @MainActor in
                            self.downloadedTrackURLs[trackId] = destination
                            self.saveDownloadsIndex()
                            self.rebuildIndexes() // Update search indexes
                        }
                        promise(.success(destination))
                    } catch {
                        promise(.failure(error))
                    }
                }
                task.resume()
            }
        }
        .eraseToAnyPublisher()
    }

    /// Download all tracks from an album.
    func downloadAlbum(albumId: String) -> AnyPublisher<[URL], Error> {
        guard let session else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }
        return session.fetchTracks(for: albumId)
            .map { $0.compactMap { $0.serverId ?? $0.id } }
            .flatMap { ids -> AnyPublisher<[URL], Error> in
                Publishers.Sequence(sequence: ids)
                    .flatMap(maxPublishers: .max(1)) { self.downloadTrack(trackId: $0) }
                    .collect()
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    /// Download all tracks from a playlist and record a local index entry.
    func downloadPlaylist(playlistId: String) -> AnyPublisher<[URL], Error> {
        guard let session else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }

        let namePub: AnyPublisher<String, Never> = (session as? JellyfinAPIService)?
            .fetchPlaylistById(playlistId)
            .map { $0?.name ?? "Playlist" }
            .replaceError(with: "Playlist")
            .eraseToAnyPublisher() ?? Just("Playlist").eraseToAnyPublisher()

        let idsPub: AnyPublisher<[String], Never> = session.fetchPlaylistTracks(playlistId: playlistId)
            .map { $0.compactMap { $0.serverId ?? $0.id } }
            .replaceError(with: [])
            .eraseToAnyPublisher()

        return Publishers.Zip(idsPub, namePub)
            .flatMap { ids, plistName -> AnyPublisher<[URL], Error> in
                Publishers.Sequence(sequence: ids)
                    .flatMap(maxPublishers: .max(1)) { self.downloadTrack(trackId: $0) }
                    .collect()
                    .receive(on: DispatchQueue.main)
                    .handleEvents(receiveOutput: { _ in
                        self.recordPlaylistDownload(playlistId: playlistId, playlistName: plistName, trackIds: ids)
                        Task { await self.fetchAndCachePlaylistCover(playlistId: playlistId) }
                    })
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Downloaded playlists index ops
    func recordPlaylistDownload(playlistId: String, playlistName: String?, trackIds: [String]) {
        guard !isRecordingPlaylist else { return }
        let name = (playlistName?.isEmpty == false) ? playlistName! : "Playlist"
        if let existing = downloadedPlaylists[playlistId], existing.name == name, existing.trackIds == trackIds { return }

        isRecordingPlaylist = true
        defer { isRecordingPlaylist = false }
        
        var newest: Date? = nil
        for tid in trackIds {
            if let url = downloadedTrackURLs[tid], let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let m = attrs[.modificationDate] as? Date {
                if newest == nil || m > newest! { newest = m }
            }
        }
        
        var newMeta = DownloadedPlaylistMeta(id: playlistId, name: name, trackIds: trackIds, newestFileDate: newest)
        if let existingCover = downloadedPlaylists[playlistId]?.coverFilename {
            newMeta.coverFilename = existingCover
        }
        downloadedPlaylists[playlistId] = newMeta
        saveDownloadedPlaylistsToDisk()
        rebuildIndexes()
    }

    // MARK: - Internals

    private func rebuildIndexes() {
        // 1. Rebuild Songs Index
        self.downloadedSongsIndex = downloadedMeta.values.sorted { $0.name.lowercased() < $1.name.lowercased() }

        // 2. Rebuild Playlists Index
        self.downloadedPlaylistsIndex = downloadedPlaylists.values.sorted { $0.name.lowercased() < $1.name.lowercased() }

        // 3. Rebuild Albums Index
        let songsByAlbum = Dictionary(grouping: downloadedMeta.values, by: { $0.albumId })

        var albums: [DownloadedAlbumMeta] = []
        for (albumId, songs) in songsByAlbum {
            guard let firstSong = songs.first, let albumName = firstSong.albumName else { continue }

            let artist = songs.flatMap { $0.artists ?? [] }
                .reduce(into: [:]) { counts, artist in counts[artist, default: 0] += 1 }
                .max(by: { $0.value < $1.value })?
                .key

            let newestDate = songs.reduce(Date.distantPast) { latest, song in
                guard let url = downloadedTrackURLs[song.id],
                      let modDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                    return latest
                }
                return modDate > latest ? modDate : latest
            }

            let jpgFilename = "\(albumId).jpg"
            let pngFilename = "\(albumId).png"
            var coverFilename: String? = nil
            if FileManager.default.fileExists(atPath: coversFolderURL.appendingPathComponent(jpgFilename).path) {
                coverFilename = jpgFilename
            } else if FileManager.default.fileExists(atPath: coversFolderURL.appendingPathComponent(pngFilename).path) {
                coverFilename = pngFilename
            }

            let albumMeta = DownloadedAlbumMeta(
                id: albumId,
                name: albumName,
                artist: artist,
                productionYear: nil,
                coverFilename: coverFilename,
                newestFileDate: newestDate,
                trackCount: songs.count
            )
            albums.append(albumMeta)
        }
        self.downloadedAlbumsIndex = albums.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }


    private func buildDownloadURL(for trackId: String, session: SessionProvider) -> URL? {
        guard !session.authToken.isEmpty, !session.serverURL.isEmpty, !session.userId.isEmpty else { return nil }
        var comps = URLComponents(string: "\(session.serverURL)Audio/\(trackId)/universal")
        comps?.queryItems = [
            URLQueryItem(name: "userId", value: session.userId),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "container", value: "m4a"),
            URLQueryItem(name: "maxAudioBitrate", value: "256000"),
            URLQueryItem(name: "api_key", value: session.authToken)
        ]
        return comps?.url
    }

    private func fetchTrackMetaForCache(trackId: String, session: SessionProvider) async -> DownloadedSongMeta? {
        guard !session.serverURL.isEmpty, !session.authToken.isEmpty,
              let url = URL(string: "\(session.serverURL)Items/\(trackId)?Fields=AlbumId,Album,IndexNumber,ParentIndexNumber,Artists,RunTimeTicks,Name")
        else { return nil }

        var req = URLRequest(url: url)
        req.setValue(session.authorizationHeader(withToken: session.authToken), forHTTPHeaderField: "X-Emby-Authorization")

        struct ItemDTO: Decodable {
            let Id: String?, Name: String?, AlbumId: String?, Album: String?, IndexNumber: Int?, ParentIndexNumber: Int?, Artists: [String]?, RunTimeTicks: Int64?
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let dto = try JSONDecoder().decode(ItemDTO.self, from: data)
            guard let id = dto.Id, let albumId = dto.AlbumId else { return nil }
            return DownloadedSongMeta(id: id, name: dto.Name ?? "Track", albumId: albumId, albumName: dto.Album, artists: dto.Artists, indexNumber: dto.IndexNumber, parentIndexNumber: dto.ParentIndexNumber, runTimeTicks: dto.RunTimeTicks)
        } catch {
            return nil
        }
    }

    private struct _LocalTrackDTO: Codable {
        let Id: String, Name: String, AlbumId: String, Album: String?, Artists: [String]?, IndexNumber: Int?, ParentIndexNumber: Int?, RunTimeTicks: Int?
    }
    private func makeLocalJellyfinTrack(from m: DownloadedSongMeta) -> JellyfinTrack? {
        let dto = _LocalTrackDTO(Id: m.id, Name: m.name, AlbumId: m.albumId, Album: m.albumName, Artists: m.artists, IndexNumber: m.indexNumber, ParentIndexNumber: m.parentIndexNumber, RunTimeTicks: m.runTimeTicks.flatMap { Int(exactly: $0) ?? Int($0) })
        do {
            let data = try JSONEncoder().encode(dto)
            return try JSONDecoder().decode(JellyfinTrack.self, from: data)
        } catch {
            print("offline decode JellyfinTrack failed for \(m.id): \(error)")
            return nil
        }
    }
}

extension DownloadsAPI {
    func refreshDownloadedPlaylist(playlistId: String) async throws {
        guard let session else { throw URLError(.userAuthenticationRequired) }
        guard let existing = downloadedPlaylists[playlistId] else { return }
        let idsToRefresh = existing.trackIds

        var refreshedName: String? = nil
        if let api = session as? JellyfinAPIService {
            do {
                refreshedName = try await withCheckedThrowingContinuation { cont in
                    api.fetchPlaylistById(playlistId)
                        .sink(receiveCompletion: { completion in
                            if case .failure(let err) = completion { cont.resume(throwing: err) }
                        }, receiveValue: { p in
                            cont.resume(returning: p?.name ?? existing.name)
                        })
                        .store(in: &self.cancellables)
                }
            } catch {
                refreshedName = existing.name
            }
        } else {
            refreshedName = existing.name
        }

        let metas: [(id: String, meta: DownloadedSongMeta?)] = try await withTaskGroup(of: (String, DownloadedSongMeta?).self) { group in
            for tid in idsToRefresh {
                group.addTask { await (tid, self.fetchTrackMetaForCache(trackId: tid, session: session)) }
            }
            var collected: [(String, DownloadedSongMeta?)] = []
            for await pair in group { collected.append(pair) }
            return collected
        }

        await MainActor.run {
            for (tid, meta) in metas {
                if let meta { self.downloadedMeta[tid] = meta }
            }
            if var pl = self.downloadedPlaylists[playlistId] {
                pl.name = refreshedName ?? pl.name
                self.downloadedPlaylists[playlistId] = pl
            }
            self.saveDownloadedMetaToDisk()
            self.saveDownloadedPlaylistsToDisk()
            self.rebuildIndexes()
        }
        
        Task { await self.fetchAndCachePlaylistCover(playlistId: playlistId) }
    }
}

extension DownloadsAPI {
    func fetchAndCachePlaylistCover(playlistId: String) async {
        guard let session else { return }
        var comps = URLComponents(string: "\(session.serverURL)Items/\(playlistId)/Images/Primary")
        comps?.queryItems = [.init(name: "maxHeight", value: "600"), .init(name: "quality", value: "90"), .init(name: "format", value: "jpg"), .init(name: "api_key", value: session.authToken)]
        guard let remote = comps?.url else { return }

        do {
            let (data, resp) = try await URLSession.shared.data(from: remote)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else { return }

            let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let ext = mime.contains("png") ? "png" : "jpg"
            let filename = "\(playlistId).\(ext)"
            let fileURL = coversFolderURL.appendingPathComponent(filename)

            try? FileManager.default.createDirectory(at: coversFolderURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])

            await MainActor.run {
                if var meta = self.downloadedPlaylists[playlistId] {
                    meta.coverFilename = filename
                    self.downloadedPlaylists[playlistId] = meta
                    self.saveDownloadedPlaylistsToDisk()
                    self.rebuildIndexes()
                }
            }
        } catch {}
    }
}
