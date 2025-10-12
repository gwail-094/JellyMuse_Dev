import Foundation
import Combine

// MARK: - Models

public struct ArtistVideo: Decodable, Identifiable, Hashable {
    public let title: String
    public let youtubeUrl: String
    public let year: Int? // <<< ADDED (Decodes optional "year" field from JSON)

    // Derive ID from YouTube
    public var id: String {
        youtubeId ?? youtubeUrl
    }

    // Compute YouTube ID from any common URL shape
    public var youtubeId: String? {
        Self.extractYouTubeId(from: youtubeUrl)
    }

    // Compute watch + thumbnail URLs on the fly
    public var watchURL: URL? {
        guard let id = youtubeId else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    public var thumbnailURL: URL? {
        // You can also use "sddefault.jpg" or "maxresdefault.jpg"
        guard let id = youtubeId else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")
    }
    
    // Nicely formatted year text for UI <<< ADDED
    public var yearText: String {
        if let y = year { return String(y) }
        
        // Fallback: find a 19xx/20xx year inside the title using regex
        // The #""# literal avoids the need to double-escape backslashes.
        if let r = title.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            return String(title[r])
        }
        return ""
    }

    // Robust extractor for YouTube IDs
    private static func extractYouTubeId(from value: String) -> String? {
        // NOTE: This internal method should delegate to the `YouTube.videoID(from:)` enum helper
        // that exists in your linked file, but the logic is kept here based on your provided context.
        
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 11, trimmed.range(of: #"^[A-Za-z0-9_\-]{11}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
            // fallback: last path segment without params
            return trimmed.components(separatedBy: "/").last?.components(separatedBy: "?").first
        }

        if host.contains("youtu.be") {
            let comp = url.path.split(separator: "/")
            if let first = comp.first {
                return String(first)
            }
        }

        if host.contains("youtube.com") {
            if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               let v = items.first(where: { $0.name == "v" })?.value {
                return v
            }
            // /embed/<id> or /shorts/<id>
            let segs = url.path.split(separator: "/").map(String.init)
            if segs.count >= 2, (segs[0] == "embed" || segs[0] == "shorts") {
                return segs[1]
            }
        }

        // fallback again
        return trimmed.components(separatedBy: "/").last?.components(separatedBy: "?").first
    }
}

public struct ArtistVideosIndexItem: Decodable {
    public let artistId: String
    public let artistName: String
    public let videos: [ArtistVideo]
}

// MARK: - API

public final class MusicVideosAPI: ObservableObject {
    public enum APIError: Error { case badBaseURL, badServerResponse }

    private let baseURL: URL
    private let session: URLSession

    public init(baseURLString: String, session: URLSession = .shared) throws {
        guard let url = URL(string: baseURLString) else { throw APIError.badBaseURL }
        self.baseURL = url
        self.session = session
    }

    /// Fetch from a single index file (e.g. "musicvideos.json") and
    /// return videos for matching artistId, else by artistName (case-insensitive).
    public func fetchFromIndex(indexFile: String = "musicvideos.json",
                               artistId: String,
                               artistName: String) -> AnyPublisher<[ArtistVideo], Never> {
        guard let url = URL(string: indexFile, relativeTo: baseURL) else {
            return Just([]).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData

        return session.dataTaskPublisher(for: req)
            .tryMap { data, response -> Data in
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw APIError.badServerResponse
                }
                return data
            }
            .decode(type: [ArtistVideosIndexItem].self, decoder: JSONDecoder())
            .map { items in
                if let byId = items.first(where: { $0.artistId == artistId }) {
                    return byId.videos
                }
                if let byName = items.first(where: { $0.artistName.compare(artistName, options: .caseInsensitive) == .orderedSame }) {
                    return byName.videos
                }
                return []
            }
            .catch { _ in Just([]) }
            .eraseToAnyPublisher()
    }
}
