import Foundation
import Combine

struct DeezerAPI {
    // MARK: - Public “section-level” fetchers

    static func topTracks(regionCode: String? = Locale.current.regionCode,
                          limit: Int = 20) -> AnyPublisher<[DeezerTrack], Never> {
        let id = CountryEditorial.editorialID(for: regionCode)
        return charts(editorialID: id)
            .map { Array($0.tracks.prefix(limit)) }
            .catch { _ in charts(editorialID: 0).map { Array($0.tracks.prefix(limit)) } }
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    static func topAlbums(regionCode: String? = Locale.current.regionCode,
                          limit: Int = 20) -> AnyPublisher<[DeezerAlbum], Never> {
        let id = CountryEditorial.editorialID(for: regionCode)
        return charts(editorialID: id)
            .map { Array($0.albums.prefix(limit)) }
            .catch { _ in charts(editorialID: 0).map { Array($0.albums.prefix(limit)) } }
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    static func editorialPlaylists(regionCode: String? = Locale.current.regionCode,
                                   limit: Int = 20) -> AnyPublisher<[DeezerPlaylist], Never> {
        let id = CountryEditorial.editorialID(for: regionCode)
        return charts(editorialID: id)
            .map { Array($0.playlists.prefix(limit)) }
        .catch { _ in charts(editorialID: 0).map { Array($0.playlists.prefix(limit)) } }
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    // MARK: - Low-level charts fetch

    struct DeezerCharts: Decodable {
        let tracks: [DeezerTrack]
        let albums: [DeezerAlbum]
        let playlists: [DeezerPlaylist]

        private enum CodingKeys: String, CodingKey { case tracks, albums, playlists }
        private struct Wrap<T: Decodable>: Decodable { let data: [T] } // Deezer wraps arrays as { data: [...] }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.tracks    = (try? c.decode(Wrap<DeezerTrack>.self, forKey: .tracks).data) ?? []
            self.albums    = (try? c.decode(Wrap<DeezerAlbum>.self, forKey: .albums).data) ?? []
            self.playlists = (try? c.decode(Wrap<DeezerPlaylist>.self, forKey: .playlists).data) ?? []
        }
    }

    static func charts(editorialID: Int) -> AnyPublisher<DeezerCharts, Error> {
        let url = URL(string: "https://api.deezer.com/editorial/\(editorialID)/charts")!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("JellyMuse/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        return URLSession.shared.dataTaskPublisher(for: req)
            .tryMap { (data, resp) -> Data in
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            .decode(type: DeezerCharts.self, decoder: JSONDecoder())
            .eraseToAnyPublisher()
    }
}

// MARK: - Models

struct DeezerTrack: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let artist: Artist
    let album: Album

    struct Artist: Decodable, Hashable { let name: String }
    struct Album: Decodable, Hashable {
        let title: String
        let cover: String?
        let cover_small: String?
        let cover_medium: String?
        let cover_big: String?
        let cover_xl: String?
        let release_date: String? // yyyy-MM-dd (sometimes)
    }

    /// Best artwork URL as URL?
    var artworkURL: URL? {
        DeezerArtwork.bestURL(
            album.cover_xl,
            album.cover_big,
            album.cover_medium,
            album.cover_small,
            album.cover
        )
    }

    /// Parsed Date if present
    var releaseDate: Date? { DeezerArtwork.parse(dateString: album.release_date) }
}

struct DeezerAlbum: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let artist: Artist
    let cover: String?
    let cover_small: String?
    let cover_medium: String?
    let cover_big: String?
    let cover_xl: String?
    let release_date: String?

    struct Artist: Decodable, Hashable { let name: String }

    var artworkURL: URL? {
        DeezerArtwork.bestURL(
            cover_xl,
            cover_big,
            cover_medium,
            cover_small,
            cover
        )
    }
    var releaseDate: Date? { DeezerArtwork.parse(dateString: release_date) }
}

struct DeezerPlaylist: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let picture: String?
    let picture_small: String?
    let picture_medium: String?
    let picture_big: String?
    let picture_xl: String?

    var artworkURL: URL? {
        DeezerArtwork.bestURL(
            picture_xl,
            picture_big,
            picture_medium,
            picture_small,
            picture
        )
    }
}

// MARK: - Artwork/Date helpers

enum DeezerArtwork {
    static func bestURL(_ candidates: String?...) -> URL? {
        for s in candidates {
            if let s, let u = URL(string: s) { return u }
        }
        return nil
    }

    static func parse(dateString: String?) -> Date? {
        guard let s = dateString, !s.isEmpty else { return nil }
        for fmt in ["yyyy-MM-dd", "yyyy-MM", "yyyy"] {
            let df = DateFormatter()
            df.calendar = Calendar(identifier: .iso8601)
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}
