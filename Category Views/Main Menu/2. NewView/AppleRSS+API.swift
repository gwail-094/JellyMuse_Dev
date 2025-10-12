// AppleRSS+API.swift
import Foundation
import Combine

/// Tiny wrapper over Apple’s public RSS JSON feeds.
/// Docs: https://rss.marketingtools.apple.com/
enum AppleRSSAPI {

    // Use higher-res Apple Music artwork instead of the default 100x100
    static func hiResArtworkURL(from s: String, size: Int = 600) -> URL? {
        var u = s
        // Handles both the fixed "100x100" URLs and the "{w}x{h}" template URLs
        u = u.replacingOccurrences(of: "{w}x{h}", with: "\(size)x\(size)")
        u = u.replacingOccurrences(of: "100x100", with: "\(size)x\(size)")
        return URL(string: u)
    }

    // MARK: - Models (Songs)
    struct AppleSong: Identifiable, Hashable, Decodable {
        let id: String
        let title: String
        let artistName: String
        let artworkURL: URL?
        let releaseDate: Date?

        private enum Keys: String, CodingKey {
            case id, name, artistName, artworkUrl100, releaseDate
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            self.id         = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
            self.title      = (try? c.decode(String.self, forKey: .name)) ?? "Unknown"
            self.artistName = (try? c.decode(String.self, forKey: .artistName)) ?? "Unknown"

            if let s = try? c.decode(String.self, forKey: .artworkUrl100) {
                self.artworkURL = AppleRSSAPI.hiResArtworkURL(from: s, size: 600)
            } else {
                self.artworkURL = nil
            }

            if let s = try? c.decode(String.self, forKey: .releaseDate) {
                let df = DateFormatter()
                df.calendar = .init(identifier: .iso8601)
                df.locale = .init(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy-MM-dd"
                self.releaseDate = df.date(from: s)
            } else {
                self.releaseDate = nil
            }
        }
    }

    // MARK: - Models (Albums)
    struct AppleAlbum: Identifiable, Hashable, Decodable {
        let id: String
        let title: String
        let artistName: String
        let artworkURL: URL?
        let releaseDate: Date?

        private enum Keys: String, CodingKey {
            case id, name, artistName, artworkUrl100, releaseDate
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            self.id         = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
            self.title      = (try? c.decode(String.self, forKey: .name)) ?? "Unknown"
            self.artistName = (try? c.decode(String.self, forKey: .artistName)) ?? "Unknown"

            if let s = try? c.decode(String.self, forKey: .artworkUrl100) {
                self.artworkURL = AppleRSSAPI.hiResArtworkURL(from: s, size: 600)
            } else {
                self.artworkURL = nil
            }

            if let s = try? c.decode(String.self, forKey: .releaseDate) {
                let df = DateFormatter()
                df.calendar = .init(identifier: .iso8601)
                df.locale = .init(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy-MM-dd"
                self.releaseDate = df.date(from: s)
            } else {
                self.releaseDate = nil
            }
        }
    }

    // MARK: - Helpers
    private static func region(_ fallback: String = "us") -> String {
        (Locale.current.regionCode ?? fallback).lowercased()
    }

    // MARK: - Local Top Albums (single region)
    static func topAlbums(region: String = AppleRSSAPI.region(), limit: Int = 20)
    -> AnyPublisher<[AppleRSSAPI.AppleAlbum], Never> {
        let lim = max(1, min(limit, 100))
        guard let url = URL(string:
            "https://rss.marketingtools.apple.com/api/v2/\(region)/music/most-played/\(lim)/albums.json"
        ) else {
            return Just([]).eraseToAnyPublisher()
        }

        struct FeedWrap: Decodable {
            let feed: Feed
            struct Feed: Decodable { let results: [AppleRSSAPI.AppleAlbum] }
        }

        return URLSession.shared.dataTaskPublisher(for: url)
            .map(\.data)
            .decode(type: FeedWrap.self, decoder: JSONDecoder())
            .map { $0.feed.results }
            .catch { _ in Just([]) }
            .eraseToAnyPublisher()
    }

    // MARK: - Global / Multi-region Top Songs
    static func globalTopSongs(finalLimit: Int = 24)
    -> AnyPublisher<[AppleRSSAPI.AppleSong], Never> {

        let regions = ["us","gb","de","fr","jp","br","au"]

        func fetch(region: String, limit: Int)
        -> AnyPublisher<[AppleRSSAPI.AppleSong], Never> {
            let url = URL(string:
                "https://rss.marketingtools.apple.com/api/v2/\(region)/music/most-played/50/songs.json"
            )!

            struct FeedWrap: Decodable {
                let feed: Feed
                struct Feed: Decodable { let results: [AppleRSSAPI.AppleSong] }
            }

            return URLSession.shared.dataTaskPublisher(for: url)
                .map(\.data)
                .decode(type: FeedWrap.self, decoder: JSONDecoder())
                .map { Array($0.feed.results.prefix(limit)) }
                .catch { _ in Just([]) }
                .eraseToAnyPublisher()
        }

        let publishers = regions.map { fetch(region: $0, limit: finalLimit) }
        return Publishers.MergeMany(publishers)
            .collect()
            .map { arrays -> [AppleRSSAPI.AppleSong] in
                var seen = Set<String>()
                var out: [AppleRSSAPI.AppleSong] = []
                for list in arrays {
                    for s in list {
                        let key = "\(s.title.lowercased())|\(s.artistName.lowercased())"
                        if seen.insert(key).inserted {
                            out.append(s)
                            if out.count >= finalLimit { return out }
                        }
                    }
                }
                return out
            }
            .catch { _ in Just([]) }
            .eraseToAnyPublisher()
    }
}

// MARK: - Global / Multi-region Top Albums
extension AppleRSSAPI {
    static func globalTopAlbums(finalLimit: Int = 24)
    -> AnyPublisher<[AppleRSSAPI.AppleAlbum], Never> {

        let regions = ["us","gb","de","fr","jp","br","au"]

        func fetch(region: String, limit: Int)
        -> AnyPublisher<[AppleRSSAPI.AppleAlbum], Never> {
            let url = URL(string:
                "https://rss.marketingtools.apple.com/api/v2/\(region)/music/most-played/50/albums.json"
            )!

            struct FeedWrap: Decodable {
                let feed: Feed
                struct Feed: Decodable { let results: [AppleRSSAPI.AppleAlbum] }
            }

            return URLSession.shared.dataTaskPublisher(for: url)
                .map(\.data)
                .decode(type: FeedWrap.self, decoder: JSONDecoder())
                .map { Array($0.feed.results.prefix(limit)) }
                .catch { _ in Just([]) }
                .eraseToAnyPublisher()
        }

        let pubs = regions.map { fetch(region: $0, limit: finalLimit) }
        return Publishers.MergeMany(pubs)
            .collect()
            .map { arrays -> [AppleRSSAPI.AppleAlbum] in
                var seen = Set<String>() // title|artist (lowercased)
                var out: [AppleRSSAPI.AppleAlbum] = []
                for list in arrays {
                    for a in list {
                        let key = "\(a.title.lowercased())|\(a.artistName.lowercased())"
                        if seen.insert(key).inserted {
                            out.append(a)
                            if out.count >= finalLimit { return out }
                        }
                    }
                }
                return out
            }
            .eraseToAnyPublisher()
    }
}
