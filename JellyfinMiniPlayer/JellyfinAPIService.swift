import Foundation
import Combine
import UIKit
import AVFoundation

// MARK: - PlaybackInfo (minimal)
struct JellyfinPlaybackInfo: Codable {
    let mediaSources: [MediaSource]?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
    }
}

struct MediaSource: Codable {
    let mediaStreams: [MediaStream]?

    enum CodingKeys: String, CodingKey {
        case mediaStreams = "MediaStreams"
    }
}

struct MediaStream: Codable {
    let type: String?
    let codec: String?
    let channels: Int?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case channels = "Channels"
    }
}

public struct PreferredStreamChoice {
    public let url: URL?
    public let channels: Int
    public let codec: String
    public var isMultichannel: Bool { channels > 2 }
}


// MARK: - API SERVICE
final class JellyfinAPIService: ObservableObject {
    static let shared = JellyfinAPIService()
    
    // Session
    @Published var serverURL: String = ""
    @Published var authToken: String = ""
    @Published var userId: String = ""
    @Published var isLoggedIn: Bool = false
    
    // Offline index (trackId -> local file URL)
    @Published var downloadedTrackURLs: [String: URL] = [:]
    
    private let deviceId: String = UIDevice.current.identifierForVendor?.uuidString ?? "some-unique-id"
    var cancellables = Set<AnyCancellable>()
    private init() {}
    
    // MARK: - Auth & Session
    func checkForSavedCredentials() {
        if let savedURL = UserDefaults.standard.string(forKey: "jellyfinServer"),
           let savedToken = UserDefaults.standard.string(forKey: "jellyfinToken"),
           let savedUserId = UserDefaults.standard.string(forKey: "jellyfinUserId"),
           !savedToken.isEmpty {
            self.serverURL = savedURL
            self.authToken = savedToken
            self.userId = savedUserId
            self.isLoggedIn = true
        }
    }
    
    func login(username: String, password: String, serverUrl: String) -> AnyPublisher<JellyfinAuthResult, Error> {
        let cleanedUrl = serverUrl.hasSuffix("/") ? serverUrl : serverUrl + "/"
        let urlString = cleanedUrl + "Users/AuthenticateByName"
        
        guard let url = URL(string: urlString) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(withToken: nil), forHTTPHeaderField: "X-Emby-Authorization")
        
        let body: [String: String] = [ "Username": username, "Pw": password ]
        do { request.httpBody = try JSONEncoder().encode(body) }
        catch { return Fail(error: error).eraseToAnyPublisher() }
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinAuthResult.self, decoder: JSONDecoder())
            .handleEvents(receiveOutput: { [weak self] auth in
                guard let self else { return }
                self.serverURL = cleanedUrl
                self.authToken = auth.accessToken
                self.userId = auth.user.id
                
                UserDefaults.standard.set(cleanedUrl, forKey: "jellyfinServer")
                UserDefaults.standard.set(auth.accessToken, forKey: "jellyfinToken")
                UserDefaults.standard.set(auth.user.id, forKey: "jellyfinUserId")
                
                self.isLoggedIn = true
            })
            .eraseToAnyPublisher()
    }
    
    @MainActor func logout() {
        serverURL = ""
        authToken = ""
        userId = ""
        
        UserDefaults.standard.removeObject(forKey: "jellyfinServer")
        UserDefaults.standard.removeObject(forKey: "jellyfinToken")
        UserDefaults.standard.removeObject(forKey: "jellyfinUserId")
        
        isLoggedIn = false
        stopPlayback()
    }
    
    // MARK: - Library: Albums
    func fetchAlbums() -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        let urlString = "\(serverURL)Users/\(userId)/Items?Recursive=true&IncludeItemTypes=MusicAlbum&Fields=UserData,CommunityRating,OfficialRating,ProductionYear,Tags,Overview,ReleaseDate,PremiereDate,DateCreated,Genres"
        guard let url = URL(string: urlString) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        request.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinAlbumResponse.self, decoder: JSONDecoder())
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }

    func fetchRecentAlbums(limit: Int = 60) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        let urlString = "\(serverURL)Users/\(userId)/Items?Recursive=true&IncludeItemTypes=MusicAlbum&sortBy=DateCreated&sortOrder=Descending&limit=\(limit)&Fields=UserData,CommunityRating,OfficialRating,ProductionYear,Tags,Overview,ReleaseDate,PremiereDate,DateCreated,Genres"
        guard let url = URL(string: urlString) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinAlbumResponse.self, decoder: JSONDecoder())
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // Fetch a single album by id
    func fetchAlbumById(_ id: String) -> AnyPublisher<JellyfinAlbum?, Error> {
        struct ItemsEnvelope<T: Decodable>: Decodable { let Items: [T]? }

        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        comps?.queryItems = [
            .init(name: "Ids", value: id),
            .init(name: "IncludeItemTypes", value: "MusicAlbum"),
            .init(name: "Fields", value: "UserData,CommunityRating,OfficialRating,ProductionYear,Tags,Overview,ReleaseDate,PremiereDate,DateCreated,Genres,AlbumArtist")
        ]

        guard let url = comps?.url else {
            return Just<JellyfinAlbum?>(nil)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.setValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, resp -> Data in
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: ItemsEnvelope<JellyfinAlbum>.self, decoder: JSONDecoder())
            .map { $0.Items?.first }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Library: Playlists
    func fetchPlaylists() -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        comps?.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            URLQueryItem(name: "Fields", value: "UserData,CommunityRating,OfficialRating,ProductionYear,Tags,Overview,ReleaseDate,PremiereDate,DateCreated,Genres, ChildCount")
        ]
        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        request.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinAlbumResponse.self, decoder: JSONDecoder())
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // Fetch a single playlist by id
    func fetchPlaylistById(_ id: String) -> AnyPublisher<JellyfinAlbum?, Error> {
        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        comps?.queryItems = [
            .init(name: "Ids", value: id),
            .init(name: "IncludeItemTypes", value: "Playlist"),
            .init(name: "Fields", value: "UserData,ProductionYear,Tags,DateCreated,AlbumArtist,Genres,Overview")
        ]

        struct ItemsEnvelope<T: Decodable>: Decodable {
            let Items: [T]?
        }

        var req = URLRequest(url: comps!.url!)
        req.setValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, resp -> Data in
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: ItemsEnvelope<JellyfinAlbum>.self, decoder: JSONDecoder())
            .map { $0.Items?.first }
            .eraseToAnyPublisher()
    }
    
    func fetchPlaylistTracks(playlistId: String) -> AnyPublisher<[JellyfinTrack], Error> {
        guard !userId.isEmpty, !authToken.isEmpty, !serverURL.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var components = URLComponents(string: "\(serverURL)Playlists/\(playlistId)/Items")
        components?.queryItems = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Fields", value: "OfficialRating,Tags,RunTimeTicks,AlbumId,ParentIndexNumber")
        ]
        guard let finalURL = components?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: finalURL)
        request.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinTrackResponse.self, decoder: JSONDecoder())
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Tracks (by Album)
    func fetchTracks(for albumId: String) -> AnyPublisher<[JellyfinTrack], Error> {
        guard !userId.isEmpty, !authToken.isEmpty, !serverURL.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        guard let baseURL = URL(string: "\(serverURL)Users/\(userId)/Items") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "parentId", value: albumId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "OfficialRating,Tags,RunTimeTicks,AlbumId,ParentIndexNumber")
        ]

        guard let finalUrl = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var request = URLRequest(url: finalUrl)
        request.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinTrackResponse.self, decoder: JSONDecoder())
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Search (NEW & Unified)

    /// The types of items to include in a search query. Maps to Jellyfin's `IncludeItemTypes` parameter.
    public enum SearchType: String {
        case artist = "MusicArtist"
        case album = "MusicAlbum"
        case song = "Audio"
        case playlist = "Playlist"
    }

    /// A unified, powerful search that uses the `/Search/Hints` endpoint.
    ///
    /// - Note: The `/Search/Hints` endpoint is efficient but may not support all query parameters like `StartIndex`.
    ///   For more advanced, paginated searching, consider switching to the `/Users/{userId}/Items` endpoint
    ///   with a `SearchTerm` parameter.
    ///
    /// - Parameters:
    ///   - query: The string to search for.
    ///   - include: An array of `SearchType` to specify what to search for.
    ///   - limit: The maximum number of results to return.
    ///   - startIndex: The starting offset for pagination.
    /// - Returns: A publisher that emits a `JellyfinSearchResponse` or an error.
    func searchHints(
        query: String,
        include: [SearchType],
        limit: Int = 25,
        startIndex: Int = 0
    ) -> AnyPublisher<JellyfinSearchResponse, Error> {
        guard !query.isEmpty, !userId.isEmpty, !serverURL.isEmpty else {
            let emptyResponse = JellyfinSearchResponse(SearchHints: [])
            return Just(emptyResponse).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
        
        var comps = URLComponents(string: "\(serverURL)Search/Hints")
        let includeTypes = include.map { $0.rawValue }.joined(separator: ",")
        
        comps?.queryItems = [
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "IncludeItemTypes", value: includeTypes),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "UserId", value: userId), // Recommended for user-specific results
            // MODIFIED: Added Fields parameter to get extra data for subtitles
            URLQueryItem(name: "Fields", value: "ProductionYear,Artists")
        ]

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinSearchResponse.self, decoder: JSONDecoder())
            .eraseToAnyPublisher()
    }

    // MARK: - Search Shortcuts

    /// Searches for artists. Returns a publisher with an array of `JellyfinSearchHint`.
    func searchArtists(query: String, limit: Int = 25, startIndex: Int = 0) -> AnyPublisher<[JellyfinSearchHint], Error> {
        searchHints(query: query, include: [.artist], limit: limit, startIndex: startIndex)
            .map { $0.SearchHints ?? [] }
            .eraseToAnyPublisher()
    }

    /// Searches for albums. Returns a publisher with an array of `JellyfinSearchHint`.
    func searchAlbums(query: String, limit: Int = 25, startIndex: Int = 0) -> AnyPublisher<[JellyfinSearchHint], Error> {
        searchHints(query: query, include: [.album], limit: limit, startIndex: startIndex)
            .map { $0.SearchHints ?? [] }
            .eraseToAnyPublisher()
    }

    /// Searches for songs. Returns a publisher with an array of `JellyfinSearchHint`.
    func searchSongs(query: String, limit: Int = 25, startIndex: Int = 0) -> AnyPublisher<[JellyfinSearchHint], Error> {
        searchHints(query: query, include: [.song], limit: limit, startIndex: startIndex)
            .map { $0.SearchHints ?? [] }
            .eraseToAnyPublisher()
    }

    /// Searches for playlists. Returns a publisher with an array of `JellyfinSearchHint`.
    func searchPlaylists(query: String, limit: Int = 25, startIndex: Int = 0) -> AnyPublisher<[JellyfinSearchHint], Error> {
        searchHints(query: query, include: [.playlist], limit: limit, startIndex: startIndex)
            .map { $0.SearchHints ?? [] }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Lyrics (smart, tries multiple endpoints)
    func fetchLyricsSmart(for trackId: String) -> AnyPublisher<String?, Never> {
        // Try several likely endpoints in order
        let candidates: [String] = [
            "\(serverURL)Audio/\(trackId)/Lyrics?format=lrc",
            "\(serverURL)Audio/\(trackId)/Lyrics",
            "\(serverURL)Items/\(trackId)/Lyrics?format=lrc",
            "\(serverURL)Items/\(trackId)/Lyrics"
        ]
        
        func request(_ urlString: String) -> AnyPublisher<String?, Never> {
            guard let url = URL(string: urlString) else {
                return Just(nil).eraseToAnyPublisher()
            }
            var req = URLRequest(url: url)
            req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
            return URLSession.shared.dataTaskPublisher(for: req)
                .map { (data, resp) -> String? in
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    print("LYRICS TRY: \(urlString) -> status=\(status), bytes=\(data.count)")
                    guard (200...299).contains(status), !data.isEmpty else { return nil }
                    
                    if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
                        // If it's JSON with "Lyrics", convert to LRC
                        if raw.first == "{", raw.contains("\"Lyrics\"") {
                            if let lrc = self.jsonLyricsToLRC(raw) {
                                return lrc
                            }
                        }
                        return raw
                    }
                    return nil
                }
                .replaceError(with: nil)
                .eraseToAnyPublisher()
        }
        
        // Chain the candidates: return the first non-nil result
        return Publishers.Sequence(sequence: candidates.map(request))
            .flatMap { $0 }
            .collect()
            .map { results in results.first { ($0?.isEmpty == false) } ?? nil }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Media URLs
    func imageURL(for itemId: String) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        
        var comps = URLComponents(string: "\(serverURL)Items/\(itemId)/Images/Primary")
        comps?.queryItems = [
            URLQueryItem(name: "maxHeight", value: "600"),
            URLQueryItem(name: "quality",   value: "90"),
            URLQueryItem(name: "format",    value: "jpg"),
            URLQueryItem(name: "api_key",   value: authToken)
        ]
        return comps?.url
    }

    // Build an image URL for any item id + type
    // AFTER
    func imageURL(for itemId: String, imageType: String, maxHeight: Int = 600) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        var comps = URLComponents(string: "\(serverURL)Items/\(itemId)/Images/\(imageType)")
        comps?.queryItems = [
            URLQueryItem(name: "maxHeight", value: String(maxHeight)),
            URLQueryItem(name: "quality",   value: "90"),
            URLQueryItem(name: "format",    value: "jpg"),
            URLQueryItem(name: "api_key", value: authToken) // ⬅️ Jellyfin accepts api_key here
        ]
        return comps?.url
    }
    
    /// Alias used by SearchFilter.swift for square covers (Albums/Playlists/Downloaded rows).
    func primaryImageURL(for itemId: String, maxHeight: Int = 600) -> URL? {
        // Either call the specific Primary endpoint…
        return imageURL(for: itemId, imageType: "Primary", maxHeight: maxHeight)
        // …or if you prefer your existing convenience that already builds Primary:
        // return imageURL(for: itemId)
    }

    /// Used by SearchFilter.resolveArtistLogos(). We prefer Menu art (no logos),
    /// then fall back gracefully.
    func bestArtistImageURL(artistId: String, targetHeight: Int = 300) -> URL? {
        // Order intentionally skips "Logo" per your request.
        return imageURL(for: artistId, imageType: "Menu",  maxHeight: targetHeight)
            ?? imageURL(for: artistId, imageType: "Thumb", maxHeight: targetHeight)
            ?? imageURL(for: artistId, imageType: "Primary", maxHeight: targetHeight)
    }

    func artistMenuFirstImageURL(artistId: String, maxHeight: Int = 600) -> URL? {
        return imageURL(for: artistId, imageType: "Menu",  maxHeight: maxHeight)
            ?? imageURL(for: artistId, imageType: "Thumb", maxHeight: maxHeight)
            ?? imageURL(for: artistId) // Primary
    }
    
    func backdropImageURL(for itemId: String, width: Int = 540, height: Int = 264, index: Int = 0) -> URL? {
        guard !serverURL.isEmpty else { return nil }

        // Ensure exactly one trailing slash
        let base = serverURL.hasSuffix("/") ? serverURL : serverURL + "/"
        let path = "Items/\(itemId)/Images/Backdrop/\(index)"

        var comps = URLComponents(string: base + path)
        comps?.queryItems = [
            .init(name: "MaxWidth", value: "\(width)"),
            .init(name: "MaxHeight", value: "\(height)"),
            .init(name: "CropWhitespace", value: "true"),
            .init(name: "Quality", value: "90"),
            .init(name: "Format", value: "jpg"),
            .init(name: "api_key", value: authToken)
        ]
        return comps?.url
    }
    
    // Optional convenience if you pass the whole model:
    func imageURLForArtistMenuFirst(_ artist: JellyfinArtistItem, maxHeight: Int = 600) -> URL? {
        artistMenuFirstImageURL(artistId: artist.id, maxHeight: maxHeight)
    }

    /// Helper to get the correct image URL for a Jellyfin artist.
    func imageURL(for artist: JellyfinArtistItem) -> URL? {
        return imageURL(for: artist.id)
    }

    /// Helper to get the correct image URL for a Jellyfin album or playlist.
    func imageURL(for albumOrPlaylist: JellyfinAlbum) -> URL? {
        return imageURL(for: albumOrPlaylist.id)
    }

    func audioURL(for trackId: String) -> URL? {
        guard !authToken.isEmpty, !serverURL.isEmpty, !userId.isEmpty else { return nil }
        let urlString = "\(serverURL)Audio/\(trackId)/universal"
        var comps = URLComponents(string: urlString)
        comps?.queryItems = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "audioCodec", value: "mp3"),
            URLQueryItem(name: "maxAudioBitrate", value: "128000"),
            URLQueryItem(name: "api_key", value: authToken)
        ]
        return comps?.url
    }
    
    // MARK: - Playback passthrough
    @MainActor
    func playTrack(tracks: [JellyfinTrack], startIndex: Int, albumArtist: String?) {
        AudioPlayer.shared.play(tracks: tracks, startIndex: startIndex, albumArtist: albumArtist)
    }
    
    @MainActor
    func stopPlayback() {
        AudioPlayer.shared.stop()
    }
    
    // MARK: - Jellyfin JSON Lyrics DTOs
    private struct JellyfinLyricsPayload: Decodable {
        let Lyrics: [JellyfinLyricLine]?
    }
    private struct JellyfinLyricLine: Decodable {
        let Text: String
        let Start: Int?  // ticks (100-nanosecond units) or milliseconds depending on server version
    }

    // Convert Jellyfin JSON payload to LRC text
    private func jsonLyricsToLRC(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(JellyfinLyricsPayload.self, from: data),
              let lines = payload.Lyrics, !lines.isEmpty
        else { return nil }

        func ts(from start: Int?) -> String {
            // Many servers deliver "Start" in ticks (1e7 per second). Some deliver ms.
            let s: Double
            if let start {
                // Heuristic: if value looks huge, treat as ticks; else milliseconds
                if start > 1_000_000 { s = Double(start) / 10_000_000.0 } // ticks → seconds
                else { s = Double(start) / 1000.0 }                      // ms → seconds
            } else {
                s = 0
            }
            let m = Int(s) / 60
            let sec = Int(s) % 60
            let cs = Int((s - floor(s)) * 100)  // centiseconds
            return String(format: "[%02d:%02d.%02d]", m, sec, cs)
        }

        // Build LRC lines
        let lrc = lines.map { "\(ts(from: $0.Start)) \($0.Text)" }
                                                                 .joined(separator: "\n")
        return lrc
    }
    
    // MARK: - Helpers
    func authorizationHeader(withToken token: String?) -> String {
        var header = """
        MediaBrowser Client="JellyfinMiniPlayer", \
        Device="iOS", \
        DeviceId="\(deviceId)", \
        Version="1.0"
        """
        if let token = token {
            header += ", Token=\"\(token)\""
        }
        return header
    }

    // MARK: - Streaming helpers
    
}

// MARK: - Playback Info
extension JellyfinAPIService {
    func fetchPlaybackInfo(trackId: String) -> AnyPublisher<JellyfinPlaybackInfo, Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        // GET /Items/{id}/PlaybackInfo?UserId=...
        var comps = URLComponents(string: "\(serverURL)Items/\(trackId)/PlaybackInfo")
        comps?.queryItems = [ URLQueryItem(name: "UserId", value: userId) ]
        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
        
        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, resp -> Data in
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinPlaybackInfo.self, decoder: JSONDecoder())
            .eraseToAnyPublisher()
    }
}

// MARK: - Advanced Playlists (server-side sorting / filtering)
extension JellyfinAPIService {
    enum PlaylistServerSort: String {
        case title = "SortName"
        case dateAdded = "DateCreated"
        case recentlyPlayed = "DatePlayed"
    }

    enum PlaylistServerFilter {
        case all
        case favorites

        var queryItems: [URLQueryItem] {
            switch self {
            case .all:       return []
            case .favorites: return [URLQueryItem(name: "IsFavorite", value: "true")]
            }
        }
    }

    func fetchPlaylistsAdvanced(
        sort: PlaylistServerSort,
        descending: Bool = false,
        filter: PlaylistServerFilter = .all,
        limit: Int? = nil
    ) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            URLQueryItem(name: "Fields", value: "UserData,CommunityRating,OfficialRating,ProductionYear,Tags,Overview,ReleaseDate,PremiereDate,DateCreated,Genres,ChildCount"),
            URLQueryItem(name: "SortBy", value: sort.rawValue),
            URLQueryItem(name: "SortOrder", value: descending ? "Descending" : "Ascending")
        ]
        items.append(contentsOf: filter.queryItems)
        if let limit { items.append(URLQueryItem(name: "Limit", value: String(limit))) }
        comps?.queryItems = items

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.setValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinAlbumResponse.self, decoder: JSONDecoder())
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
}

// MARK: - Instant Mix
extension JellyfinAPIService {
    /// Jellyfin: GET /Items/{id}/InstantMix?UserId=...&Limit=...
    func fetchInstantMix(itemId: String, limit: Int = 100) -> AnyPublisher<[JellyfinTrack], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var comps = URLComponents(string: "\(serverURL)Items/\(itemId)/InstantMix")
        comps?.queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: "OfficialRating,Tags,RunTimeTicks,AlbumId,ParentIndexNumber")
        ]
        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.setValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, resp -> Data in
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinTrackResponse.self, decoder: JSONDecoder())
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
}

// MARK: - Favorite / Unfavorite
extension JellyfinAPIService {
    func markItemFavorite(itemId: String) -> AnyPublisher<Void, Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty,
              let url = URL(string: "\(serverURL)Users/\(userId)/FavoriteItems/\(itemId)") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { _, response in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return ()
            }
            .eraseToAnyPublisher()
    }

    func unmarkItemFavorite(itemId: String) -> AnyPublisher<Void, Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty,
              let url = URL(string: "\(serverURL)Users/\(userId)/FavoriteItems/\(itemId)") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { _, response in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return ()
            }
            .eraseToAnyPublisher()
    }
    
    func fetchItemUserData(itemId: String) -> AnyPublisher<JellyfinUserData, Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        
        let urlString = "\(serverURL)Users/\(userId)/Items/\(itemId)"
        guard let url = URL(string: urlString) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .map(\.data)
            .decode(type: JellyfinAlbum.self, decoder: JSONDecoder()) // Decode as a generic item
            .compactMap { $0.userData }
            .eraseToAnyPublisher()
    }
}

// MARK: - Library: Album Artists
extension JellyfinAPIService {
    private struct ArtistResponseDTO: Codable {
        let Items: [JellyfinArtistItem]?
    }

    // NEW: Fetch artists with thumb images
    func fetchArtistThumbs(limit: Int = 20) -> AnyPublisher<[JellyfinArtistItem], Error> {
        guard !serverURL.isEmpty, !userId.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        comps?.queryItems = [
            .init(name: "IncludeItemTypes", value: "MusicArtist"),
            .init(name: "Recursive", value: "true"),
            .init(name: "ImageTypes", value: "Thumb"), // <--- only fetch thumb images
            .init(name: "Limit", value: "\(limit)"),
            .init(name: "SortBy", value: "SortName"),
            .init(name: "SortOrder", value: "Ascending"),
            .init(name: "Fields", value: "PrimaryImageAspectRatio,UserData,SortName")
        ]

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.setValue(authorizationHeader(withToken: authToken),
                     forHTTPHeaderField: "X-Emby-Authorization")

        struct ArtistResponse: Decodable {
            let Items: [JellyfinArtistItem]
        }

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: ArtistResponse.self, decoder: JSONDecoder())
            .map { $0.Items }
            .eraseToAnyPublisher()
    }
    
    func fetchArtistMenus(limit: Int = 20) -> AnyPublisher<[JellyfinArtistItem], Error> {
        guard !serverURL.isEmpty, !userId.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        comps?.queryItems = [
            .init(name: "IncludeItemTypes", value: "MusicArtist"),
            .init(name: "Recursive", value: "true"),
            .init(name: "ImageTypes", value: "Menu"), // <--- only fetch menu images
            .init(name: "Limit", value: "\(limit)"),
            .init(name: "SortBy", value: "SortName"),
            .init(name: "SortOrder", value: "Ascending"),
            .init(name: "Fields", value: "PrimaryImageAspectRatio,UserData,SortName")
        ]

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.setValue(authorizationHeader(withToken: authToken),
                     forHTTPHeaderField: "X-Emby-Authorization")

        struct ArtistResponse: Decodable {
            let Items: [JellyfinArtistItem]
        }

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: ArtistResponse.self, decoder: JSONDecoder())
            .map { $0.Items }
            .eraseToAnyPublisher()
    }
    
    func fetchAlbumArtists() -> AnyPublisher<[JellyfinArtistItem], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        let urlString = "\(serverURL)Users/\(userId)/Items?Recursive=true&IncludeItemTypes=MusicArtist"
        guard let url = URL(string: urlString) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var request = URLRequest(url: url)
        request.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: ArtistResponseDTO.self, decoder: JSONDecoder())
            .map { $0.Items ?? [] }
            .eraseToAnyPublisher()
    }
    
    func fetchAlbumArtistsAdvanced(favoritesOnly: Bool) -> AnyPublisher<[JellyfinArtistItem], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        var q: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicArtist"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending")
        ]
        if favoritesOnly {
            q.append(URLQueryItem(name: "IsFavorite", value: "true"))
        }
        comps?.queryItems = q

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: ArtistResponseDTO.self, decoder: JSONDecoder())
            .map { $0.Items ?? [] }
            .eraseToAnyPublisher()
    }
}

// MARK: - Songs (server-side sorting + favorites filter)
extension JellyfinAPIService {
    enum SongServerSort {
        case title
        case dateAdded
        case artistAZ

        var sortByParam: String {
            switch self {
            case .title:     return "SortName"
            case .dateAdded: return "DateCreated"
            case .artistAZ:  return "AlbumArtist,SortName"
            }
        }

        var sortOrder: String {
            switch self {
            case .dateAdded: return "Descending"
            default:         return "Ascending"
            }
        }
    }

    func fetchSongsAdvanced(
        sort: SongServerSort,
        favoritesOnly: Bool = false,
        limit: Int? = nil
    ) -> AnyPublisher<[JellyfinTrack], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SortBy", value: sort.sortByParam),
            URLQueryItem(name: "SortOrder", value: sort.sortOrder),
            URLQueryItem(name: "Fields", value: "OfficialRating,Tags,RunTimeTicks,AlbumId,ParentIndexNumber")
        ]
        if favoritesOnly {
            items.append(URLQueryItem(name: "IsFavorite", value: "true"))
        }
        if let limit { items.append(URLQueryItem(name: "Limit", value: String(limit))) }
        comps?.queryItems = items

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinTrackResponse.self, decoder: JSONDecoder())
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
}

// MARK: - Genres
extension JellyfinAPIService {
    private struct GenreResponseDTO: Codable {
        let Items: [JellyfinGenre]?
    }

    /// Music-only genres (Audio, MusicAlbum, MusicArtist)
    func fetchGenres() -> AnyPublisher<[JellyfinGenre], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(serverURL)Genres")
        comps?.queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio,MusicAlbum,MusicArtist"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending")
        ]
        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: GenreResponseDTO.self, decoder: JSONDecoder())
            .map { $0.Items ?? [] }
            .eraseToAnyPublisher()
    }
}

// MARK: - Albums by Genre (music only)
extension JellyfinAPIService {
    /// Fetch MusicAlbum items that belong to a given genre name
    func fetchAlbumsByGenre(_ genreName: String, limit: Int? = nil) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Genres", value: genreName),
            URLQueryItem(name: "Fields", value: "UserData,CommunityRating,OfficialRating,ProductionYear,Tags,Overview,ReleaseDate,PremiereDate,DateCreated,Genres,ChildCount"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending")
        ]
        if let limit { items.append(URLQueryItem(name: "Limit", value: String(limit))) }
        comps?.queryItems = items

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinAlbumResponse.self, decoder: JSONDecoder())
            .map { $0.items ?? [] }
            .eraseToAnyPublisher()
    }
}

// MARK: - Offline downloads
extension JellyfinAPIService {

    private var downloadsIndexKey: String { "jellyfin.downloads.index" }

    private var downloadsFolderURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Offline", isDirectory: true)
    }

    func prepareDownloadsFolderIfNeeded() {
        try? FileManager.default.createDirectory(at: downloadsFolderURL, withIntermediateDirectories: true)
        if let data = UserDefaults.standard.data(forKey: downloadsIndexKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            var tmp: [String: URL] = [:]
            for (trackId, relative) in dict {
                tmp[trackId] = downloadsFolderURL.appendingPathComponent(relative)
            }
            downloadedTrackURLs = tmp
        }
    }

    private func saveDownloadsIndex() {
        var dict: [String: String] = [:]
        for (trackId, url) in downloadedTrackURLs {
            dict[trackId] = url.lastPathComponent
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: downloadsIndexKey)
        }
    }

    func localOrStreamURL(for trackId: String) -> URL? {
        if let local = downloadedTrackURLs[trackId], FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        return audioURL(for: trackId)
    }
    
    func trackIsDownloaded(_ trackId: String) -> Bool {
        if let url = downloadedTrackURLs[trackId] {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return false
    }

    func deleteDownloadedTrack(trackId: String) {
        guard let url = downloadedTrackURLs[trackId] else { return }
        try? FileManager.default.removeItem(at: url)
        downloadedTrackURLs.removeValue(forKey: trackId)
        saveDownloadsIndex()
    }

    func downloadTrack(trackId: String) -> AnyPublisher<URL, Error> {
        Future<URL, Error> { promise in
            guard let remote = self.audioURL(for: trackId) else {
                promise(.failure(URLError(.badURL))); return
            }

            try? FileManager.default.createDirectory(at: self.downloadsFolderURL, withIntermediateDirectories: true)
            let destination = self.downloadsFolderURL.appendingPathComponent("\(trackId).mp3")

            if FileManager.default.fileExists(atPath: destination.path) {
                DispatchQueue.main.async {
                    self.downloadedTrackURLs[trackId] = destination
                    self.saveDownloadsIndex()
                }
                promise(.success(destination))
                return
            }

            let task = URLSession.shared.downloadTask(with: remote) { tempURL, _, error in
                if let error = error { promise(.failure(error)); return }
                guard let tempURL = tempURL else {
                    promise(.failure(URLError(.unknown))); return
                }
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try? FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    DispatchQueue.main.async {
                        self.downloadedTrackURLs[trackId] = destination
                        self.saveDownloadsIndex()
                    }
                    promise(.success(destination))
                } catch {
                    promise(.failure(error))
                }
            }
            task.resume()
        }
        .eraseToAnyPublisher()
    }

    func downloadPlaylist(playlistId: String) -> AnyPublisher<[URL], Error> {
        fetchPlaylistTracks(playlistId: playlistId)
            .map { tracks in tracks.compactMap { $0.serverId ?? $0.id } }
            .flatMap { ids -> AnyPublisher<[URL], Error> in
                Publishers.Sequence(sequence: ids)
                    .flatMap(maxPublishers: .max(1)) { self.downloadTrack(trackId: $0) }
                    .collect()
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    // Download every track of an album to /Documents/Offline and return the saved URLs
    func downloadAlbum(albumId: String) -> AnyPublisher<[URL], Error> {
        fetchTracks(for: albumId)
            .map { tracks in tracks.compactMap { $0.serverId ?? $0.id } }
            .flatMap { ids -> AnyPublisher<[URL], Error> in
                Publishers.Sequence(sequence: ids)
                    .flatMap(maxPublishers: .max(1)) { self.downloadTrack(trackId: $0) }
                    .collect()
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    func downloadedCount(for playlistId: String) -> AnyPublisher<Int, Never> {
        fetchPlaylistTracks(playlistId: playlistId)
            .map { tracks -> Int in
                let ids = tracks.compactMap { $0.serverId ?? $0.id }
                return ids.reduce(0) { $0 + (self.trackIsDownloaded($1) ? 1 : 0) }
            }
            .replaceError(with: 0)
            .eraseToAnyPublisher()
    }

    func hasDownloads(for playlistId: String) -> AnyPublisher<Bool, Never> {
        downloadedCount(for: playlistId)
            .map { $0 > 0 }
            .eraseToAnyPublisher()
    }
}

// ===============================================
// MARK: - Artist detail: Top Songs + Albums
// ===============================================
extension JellyfinAPIService {

    // MARK: - Artist Albums (smart) - NEW
    func fetchArtistAlbumsSmart(artistId: String, artistName: String) -> AnyPublisher<[JellyfinAlbum], Error> {
        func albums(query: [URLQueryItem]) -> AnyPublisher<[JellyfinAlbum], Error> {
            var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
            comps?.queryItems = [
                URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "ProductionYear,SortName"),
                URLQueryItem(name: "SortOrder", value: "Descending"),
                // <<< MODIFIED: Added Genres
                URLQueryItem(name: "Fields", value: "UserData,OfficialRating,CommunityRating,ProductionYear,Tags,Overview,ReleaseDate,PremiereDate,DateCreated,Genres,ChildCount")
            ] + query
            guard let url = comps?.url else {
                return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
            }
            var req = URLRequest(url: url)
            req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
            return URLSession.shared.dataTaskPublisher(for: req)
                .tryMap { data, resp -> Data in
                    guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    return data
                }
                .decode(type: JellyfinAlbumResponse.self, decoder: JSONDecoder())
                .map { $0.items ?? [] }
                .eraseToAnyPublisher()
        }

        let byAlbumArtistId = albums(query: [URLQueryItem(name: "AlbumArtistIds", value: artistId)])
        let byArtistId      = albums(query: [URLQueryItem(name: "ArtistIds", value: artistId)])
        // Fallback: exact name match (server supports filtering by artist name field)
        let byArtistName    = albums(query: [URLQueryItem(name: "Artists", value: artistName)])

        return Publishers.CombineLatest(byAlbumArtistId, byArtistId)
            .map { a, b in
                var seen = Set<String>(); var out: [JellyfinAlbum] = []
                for x in (a + b) where !seen.contains(x.id) { seen.insert(x.id); out.append(x) }
                return out
            }
            .catch { _ in Just<[JellyfinAlbum]>([]) }
            .flatMap { combined -> AnyPublisher<[JellyfinAlbum], Error> in
                if !combined.isEmpty { return Just(combined).setFailureType(to: Error.self).eraseToAnyPublisher() }
                return byArtistName
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Artist Top Songs (smart) - NEW
    func fetchArtistTopSongsSmart(artistId: String, artistName: String, limit: Int = 25) -> AnyPublisher<[JellyfinTrack], Error> {
        func tracks(query: [URLQueryItem]) -> AnyPublisher<[JellyfinTrack], Error> {
            var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
            comps?.queryItems = [
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "PlayCount,CommunityRating"),
                URLQueryItem(name: "SortOrder", value: "Descending"),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: "OfficialRating,AlbumId,RunTimeTicks,Tags,ParentIndexNumber")
            ] + query
            guard let url = comps?.url else {
                return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
            }
            var req = URLRequest(url: url)
            req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
            return URLSession.shared.dataTaskPublisher(for: req)
                .tryMap { data, resp -> Data in
                    guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    return data
                }
                .decode(type: JellyfinTrackResponse.self, decoder: JSONDecoder())
                .map { $0.items ?? [] }
                .eraseToAnyPublisher()
        }

        let byArtistId = tracks(query: [URLQueryItem(name: "ArtistIds", value: artistId)])
        // Fallback: name filter (helps for edge cases)
        let byArtistName = tracks(query: [URLQueryItem(name: "Artists", value: artistName)])

        return byArtistId
            .flatMap { first -> AnyPublisher<[JellyfinTrack], Error> in
                first.isEmpty ? byArtistName : Just(first).setFailureType(to: Error.self).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    func fetchArtistTopSongs(artistId: String, limit: Int = 25) -> AnyPublisher<[JellyfinTrack], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        comps?.queryItems = [
            URLQueryItem(name: "ArtistIds", value: artistId),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "PlayCount,CommunityRating"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: "OfficialRating,AlbumId,RunTimeTicks,Tags,ParentIndexNumber")
        ]

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinTrackResponse.self, decoder: JSONDecoder())
            .map { response in
                let tracks = response.items ?? []
                for track in tracks {
                    print("DEBUG: \(track.name ?? "nil") officialRating = \(track.officialRating ?? "nil")")
                }
                return tracks
            }
            .eraseToAnyPublisher()
    }

    func fetchArtistAlbums(artistId: String) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        comps?.queryItems = [
            URLQueryItem(name: "ArtistIds", value: artistId),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            // <<< MODIFIED: Added Genres
            URLQueryItem(name: "Fields", value: "UserData,OfficialRating,CommunityRating,ProductionYear,Tags,Overview,ReleaseDate,PremiereDate,DateCreated,Genres,ChildCount")
        ]

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: JellyfinAlbumResponse.self, decoder: JSONDecoder())
            .map { response in
                let albums = response.items ?? []
                for album in albums {
                    print("DEBUG: \(album.name) officialRating = \(album.officialRating ?? "nil")")
                }
                return albums
            }
            .eraseToAnyPublisher()
    }
}


// ===============================================
// MARK: - Artist detail: Similar Artists
// ===============================================
extension JellyfinAPIService {
    struct _SimilarArtistsDTO: Codable {
        let Items: [JellyfinArtistItem]?
    }

    /// Jellyfin: /Artists/{id}/Similar?UserId={userId}&Limit={limit}
    func fetchSimilarArtists(artistId: String, limit: Int = 24) -> AnyPublisher<[JellyfinArtistItem], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty,
              let url = URL(string: "\(serverURL)Artists/\(artistId)/Similar?UserId=\(userId)&Limit=\(limit)") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: _SimilarArtistsDTO.self, decoder: JSONDecoder())
            .map { $0.Items ?? [] }
            .eraseToAnyPublisher()
    }
}

// ===============================================
// MARK: - Similar Albums
// ===============================================
extension JellyfinAPIService {
    private struct _SimilarAlbumsDTO: Codable { let Items: [JellyfinAlbum]? }

    /// Jellyfin: /Items/{id}/Similar?UserId=...&Limit=...&IncludeItemTypes=MusicAlbum
    func fetchSimilarAlbums(albumId: String, limit: Int = 24) -> AnyPublisher<[JellyfinAlbum], Error> {
        guard !userId.isEmpty, !serverURL.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var comps = URLComponents(string: "\(serverURL)Items/\(albumId)/Similar")
        comps?.queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            // <<< MODIFIED: Added Genres, Overview, and Dates
            URLQueryItem(name: "Fields", value: "UserData,CommunityRating,OfficialRating,ProductionYear,Tags,Overview,ReleaseDate,PremiereDate,DateCreated,Genres,ChildCount")
        ]

        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, resp -> Data in
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: _SimilarAlbumsDTO.self, decoder: JSONDecoder())
            .map { $0.Items ?? [] }
            .eraseToAnyPublisher()
    }
}


// MARK: - Stream URL builders
extension JellyfinAPIService {
    /// Headers for AVURLAsset so Jellyfin accepts our request
    var embyAuthHeaders: [String: String] {
        ["X-Emby-Authorization": authorizationHeader(withToken: authToken)]
    }

    /// Build HLS stream URL (AAC), with optional 5.1 channels.
    func buildHLSStreamURL(
        trackId: String,
        audioCodec: String = "aac",
        maxAudioChannels: Int = 2,
        audioBitrate: Int = 256_000
    ) -> URL? {
        guard !serverURL.isEmpty, !userId.isEmpty, !authToken.isEmpty else { return nil }
        var comps = URLComponents(string: "\(serverURL)Audio/\(trackId)/universal")
        comps?.queryItems = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "transcodingProtocol", value: "hls"),
            URLQueryItem(name: "container", value: "ts"),
            URLQueryItem(name: "segmentContainer", value: "ts"),
            URLQueryItem(name: "audioCodec", value: audioCodec),
            URLQueryItem(name: "maxAudioChannels", value: String(max(2, maxAudioChannels))),
            URLQueryItem(name: "audioBitrate", value: String(audioBitrate)),
            URLQueryItem(name: "api_key", value: authToken)
        ]
        return comps?.url
    }
    
    /// Decide best stream URL (direct for simple stereo; HLS AAC 5.1 for multichannel/EAC3/etc).
    func preferredStreamURL(for trackId: String) -> AnyPublisher<URL?, Never> {
        fetchPlaybackInfo(trackId: trackId)
            .map { info -> URL? in
                let streams = info.mediaSources?.first?.mediaStreams ?? []
                let audio = streams.first(where: { ($0.type ?? "").lowercased() == "audio" })
                let codec = (audio?.codec ?? "").lowercased()
                let channels = audio?.channels ?? 2

                let multichannel = channels > 2
                let needsTranscodeForiOS =
                    codec == "eac3" || codec == "ac3" || codec == "truehd" || codec == "mlp" || codec == "flac" || codec == "dts" || codec == "opus"

                if multichannel || needsTranscodeForiOS {
                    // HLS AAC 5.1 (fallback to 384 kbps; tweak if needed)
                    return self.buildHLSStreamURL(trackId: trackId,
                                                  audioCodec: "aac",
                                                  maxAudioChannels: multichannel ? 6 : 2,
                                                  audioBitrate: multichannel ? 384_000 : 256_000)
                } else {
                    // direct universal (server decides best; often MP3/AAC)
                    return self.audioURL(for: trackId)
                }
            }
            .replaceError(with: self.audioURL(for: trackId)) // if playbackInfo fails, still try direct
            .eraseToAnyPublisher()
    }

    func preferredStreamChoice(for trackId: String) -> AnyPublisher<PreferredStreamChoice, Never> {
        fetchPlaybackInfo(trackId: trackId)
            .map { info -> PreferredStreamChoice in
                let streams = info.mediaSources?.first?.mediaStreams ?? []
                let audio = streams.first(where: { ($0.type ?? "").lowercased() == "audio" })
                let codec = (audio?.codec ?? "").lowercased()
                let channels = audio?.channels ?? 2

                let multichannel = channels > 2
                let needsTranscode =
                    codec == "eac3" || codec == "ac3" || codec == "truehd" || codec == "mlp" ||
                    codec == "flac" || codec == "dts"  || codec == "opus"

                let url: URL?
                if multichannel || needsTranscode {
                    url = self.buildHLSStreamURL(trackId: trackId,
                                                 audioCodec: "aac",
                                                 maxAudioChannels: multichannel ? 6 : 2,
                                                 audioBitrate: multichannel ? 384_000 : 256_000)
                } else {
                    url = self.audioURL(for: trackId)
                }

                return PreferredStreamChoice(url: url, channels: channels, codec: codec)
            }
            .replaceError(with: PreferredStreamChoice(url: self.audioURL(for: trackId),
                                                       channels: 2,
                                                       codec: "unknown"))
            .eraseToAnyPublisher()
    }
}

// MARK: - Now Playing Reporting
extension JellyfinAPIService {
    // Jellyfin expects "ticks" (100ns units)
    private func ticks(from seconds: TimeInterval) -> Int64 {
        // sanitize
        guard seconds.isFinite, !seconds.isNaN, seconds > 0 else { return 0 }

        // cap to something sane (e.g. 10 hours)
        let capped = min(seconds, 10 * 60 * 60)

        let ticksD = capped * 10_000_000.0
        // guard against overflow (very defensive)
        if ticksD >= Double(Int64.max) { return Int64.max - 1 }
        return Int64(ticksD)
    }

    // Keep track of the current play session id Jellyfin returns
    private struct StartResp: Decodable { let PlaySessionId: String? }
    @MainActor private static var currentPlaySessionId: String?

    @MainActor
    func reportNowPlayingStart(itemId: String) {
        guard !serverURL.isEmpty, !authToken.isEmpty else { return }
        guard let url = URL(string: "\(serverURL)Sessions/Playing") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        // Minimal body works fine
        let body: [String: Any] = [
            "ItemId": itemId,
            "CanSeek": true,
            "IsPaused": false
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let resp = try? JSONDecoder().decode(StartResp.self, from: data) {
                Task { @MainActor in
                    JellyfinAPIService.currentPlaySessionId = resp.PlaySessionId
                }
            }
        }.resume()
    }

    @MainActor
    func reportNowPlayingProgress(itemId: String, position seconds: TimeInterval, isPaused: Bool) {
        guard !serverURL.isEmpty, !authToken.isEmpty else { return }
        guard let url = URL(string: "\(serverURL)Sessions/Playing/Progress") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": ticks(from: seconds),
            "IsPaused": isPaused,
            "PlaySessionId": JellyfinAPIService.currentPlaySessionId as Any
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        URLSession.shared.dataTask(with: req).resume()
    }

    @MainActor func reportNowPlayingStopped(itemId: String, position seconds: TimeInterval) {
        guard !serverURL.isEmpty, !authToken.isEmpty else { return }
        guard let url = URL(string: "\(serverURL)Sessions/Playing/Stopped") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": ticks(from: seconds),
            "PlaySessionId": JellyfinAPIService.currentPlaySessionId as Any
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        URLSession.shared.dataTask(with: req).resume()

        JellyfinAPIService.currentPlaySessionId = nil
    }

    /// Optional: instantly mark an item as played so your carousel updates even before stop.
    func markItemPlayed(_ itemId: String) {
        guard !serverURL.isEmpty, !authToken.isEmpty, !userId.isEmpty else { return }
        guard let url = URL(string: "\(serverURL)Users/\(userId)/PlayedItems/\(itemId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")
        URLSession.shared.dataTask(with: req).resume()
    }
}

// MARK: - Single Item Fetch for Tags (Fix 2)
extension JellyfinAPIService {

    // Decode only what we need
    struct ItemSummary: Decodable {
        let id: String?
        let tags: [String]?
        enum CodingKeys: String, CodingKey {
            case id   = "Id"
            case tags = "Tags"
        }
    }

    /// Fetch a single item (album) and decode Tags.
    /// Endpoint: GET /Items/{id}?Fields=Tags
    func fetchItem(id: String) -> AnyPublisher<ItemSummary, Error> {
        guard !serverURL.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }

        // 1. Build the base URL with the item ID
        guard let baseURL = URL(string: "\(serverURL)Items/\(id)") else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        
        // 2. Add the query parameter: ?Fields=Tags
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "Fields", value: "Tags")]

        // 3. Create the authenticated request
        guard let finalURL = comps.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        
        var req = URLRequest(url: finalURL)
        req.setValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        // 4. Use the URLSession dataTaskPublisher and Combine pipeline
        let decoder = JSONDecoder()
        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: ItemSummary.self, decoder: decoder)
            .eraseToAnyPublisher()
    }
}

// MARK: - New function `fetchSongsByArtist`
extension JellyfinAPIService {
    func fetchSongsByArtist(artistId: String) -> AnyPublisher<[JellyfinTrack], Error> {
        guard !serverURL.isEmpty, !userId.isEmpty, !authToken.isEmpty else {
            return Fail(error: URLError(.userAuthenticationRequired)).eraseToAnyPublisher()
        }
        
        // Build the URL to fetch all songs for this specific artist
        var comps = URLComponents(string: "\(serverURL)Users/\(userId)/Items")
        comps?.queryItems = [
            URLQueryItem(name: "ArtistIds", value: artistId),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Fields", value: "Overview,UserData,RunTimeTicks,Album,AlbumArtist,PrimaryImageAspectRatio")
        ]
        
        // Convert to final URL
        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }
        
        // Create request
        var request = URLRequest(url: url)
        request.addValue(authorizationHeader(withToken: authToken),
                         forHTTPHeaderField: "X-Emby-Authorization")
        
        // Decode JSON with "Items" array
        struct ItemsEnvelope<T: Decodable>: Decodable {
            let Items: [T]?
        }
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: ItemsEnvelope<JellyfinTrack>.self, decoder: JSONDecoder())
            .map { $0.Items ?? [] }
            .eraseToAnyPublisher()
    }
}
import Combine

extension JellyfinAPIService: DownloadsAPI.SessionProvider {}
// MARK: - Genres

struct JellyfinGenreItem: Decodable, Identifiable {
    let id: String
    let name: String
    // You may get image tags, but we’ll just request Primary by id when drawing
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
}

struct JellyfinItemsEnvelope<T: Decodable>: Decodable {
    let items: [T]?
    let totalRecordCount: Int?
    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

extension JellyfinAPIService {
/// Fetch music genres, but only keep those that have at least `minAlbums` music albums.
func fetchMusicGenres(minAlbums: Int = 1) -> AnyPublisher<[JellyfinGenreItem], Error> {
    // 1) get all genres
    var comps = URLComponents(string: "\(serverURL)Genres")
    comps?.queryItems = [
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "SortBy", value: "SortName"),
        URLQueryItem(name: "Fields", value: "ItemCounts") // not always reliable, so we count albums explicitly below
    ]
    guard let url = comps?.url else {
        return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
    }

    var req = URLRequest(url: url)
    req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

    // 2) for each genre, query album count with IncludeItemTypes=MusicAlbum&Limit=0 and read TotalRecordCount
    func albumCountPublisher(for genre: JellyfinGenreItem) -> AnyPublisher<(JellyfinGenreItem, Int), Never> {
        var c = URLComponents(string: "\(serverURL)Items")
        c?.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Genres", value: genre.name),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "0")
        ]
        guard let u = c?.url else {
            return Just((genre, 0)).eraseToAnyPublisher()
        }
        var r = URLRequest(url: u)
        r.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

        return URLSession.shared.dataTaskPublisher(for: r)
            .map { $0.data }
            .decode(type: JellyfinItemsEnvelope<JellyfinAlbum>.self, decoder: JSONDecoder())
            .map { (genre, $0.totalRecordCount ?? 0) }
            .replaceError(with: (genre, 0))
            .eraseToAnyPublisher()
    }

    return URLSession.shared.dataTaskPublisher(for: req)
        .tryMap { data, resp in
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
        .decode(type: JellyfinItemsEnvelope<JellyfinGenreItem>.self, decoder: JSONDecoder())
        .map { $0.items ?? [] }
        .flatMap { genres -> AnyPublisher<[JellyfinGenreItem], Error> in
            let pubs = genres.map { albumCountPublisher(for: $0) } // Failure == Never

            return Publishers.MergeMany(pubs)
                .filter { _, count in count >= minAlbums }
                .map { genre, _ in genre }
                .collect()
                .setFailureType(to: Error.self)   // <- make inner Failure match outer
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
}

/// Fetch *tracks* for a given genre name (we shuffle locally in the UI).
func fetchSongsByGenre(_ genreName: String) -> AnyPublisher<[JellyfinTrack], Error> {
    var comps = URLComponents(string: "\(serverURL)Items")
    comps?.queryItems = [
        URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
        URLQueryItem(name: "Genres", value: genreName),
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "Fields", value: "Album,Artists,Genres,RunTimeTicks"),
        URLQueryItem(name: "Limit", value: "5000") // big cap; adjust as you like
    ]
    guard let url = comps?.url else {
        return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
    }

    var req = URLRequest(url: url)
    req.addValue(authorizationHeader(withToken: authToken), forHTTPHeaderField: "X-Emby-Authorization")

    return URLSession.shared.dataTaskPublisher(for: req)
        .tryMap { data, resp in
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
        .decode(type: JellyfinItemsEnvelope<JellyfinTrack>.self, decoder: JSONDecoder())
        .map { $0.items ?? [] }
        .eraseToAnyPublisher()
}
}
