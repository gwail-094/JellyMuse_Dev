//
//  AppleArtworkService.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 18.09.2025.
//


import Foundation
import Combine

final class AppleArtworkService {
    static let shared = AppleArtworkService()

    private var cache = NSCache<NSString, NSURL>()
    private let decoder = JSONDecoder()

    // Upsize Apple art to a square size (e.g. 600)
    private func hiRes(_ s: String, size: Int = 600) -> URL? {
        let r1 = s.replacingOccurrences(of: "{w}x{h}", with: "\(size)x\(size)")
        let r2 = r1.replacingOccurrences(of: "100x100", with: "\(size)x\(size)")
        return URL(string: r2)
    }

    /// Best-effort Apple album art for (artist, album). Never fails — returns nil on miss.
    func albumArtwork(artist: String, album: String, country: String? = nil, size: Int = 600)
    -> AnyPublisher<URL?, Never> {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum  = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty, !trimmedAlbum.isEmpty else {
            return Just(nil).eraseToAnyPublisher()
        }

        let cacheKey = "\(trimmedArtist.lowercased())|\(trimmedAlbum.lowercased())" as NSString
        if let u = cache.object(forKey: cacheKey) { return Just(u as URL).eraseToAnyPublisher() }

        // iTunes Search (album-level)
        // https://itunes.apple.com/search?term=<artist> <album>&entity=album&limit=5
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        let term = "\(trimmedArtist) \(trimmedAlbum)"
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "5")
        ]
        if let cc = (country ?? Locale.current.region?.identifier)?.lowercased() {
            comps.queryItems?.append(.init(name: "country", value: cc))
        }

        struct SearchResponse: Decodable {
            struct Item: Decodable {
                let collectionName: String?
                let artistName: String?
                let artworkUrl100: String?
            }
            let results: [Item]
        }

        let url = comps.url!

        return URLSession.shared.dataTaskPublisher(for: url)
            .map(\.data)
            .decode(type: SearchResponse.self, decoder: decoder)
            .map { resp -> URL? in
                // naive ranking: prefer items that match both artist and album substrings
                let lowerArtist = trimmedArtist.lowercased()
                let lowerAlbum  = trimmedAlbum.lowercased()

                let best = resp.results.max { a, b in
                    // score a candidate
                    func score(_ x: SearchResponse.Item) -> Int {
                        var s = 0
                        if let an = x.artistName?.lowercased(), an.contains(lowerArtist) { s += 2 }
                        if let cn = x.collectionName?.lowercased(), cn.contains(lowerAlbum) { s += 2 }
                        return s
                    }
                    return score(a) < score(b)
                }

                guard let art = best?.artworkUrl100, let hi = self.hiRes(art, size: size) else { return nil }
                return hi
            }
            .catch { _ in Just(nil) }
            .handleEvents(receiveOutput: { url in
                if let u = url { self.cache.setObject(u as NSURL, forKey: cacheKey) }
            })
            .eraseToAnyPublisher()
    }
}
