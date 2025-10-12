import Foundation
import Combine

struct ListenBrainzAPI {
    var username: String

    // MARK: - New album releases (albums only, past N days)

    struct LBAlbumRelease: Identifiable, Hashable {
        let id = UUID().uuidString
        let title: String         // release_name
        let artist: String        // artist_credit_name
        let releaseMBID: String?  // release_mbid
        let releaseGroupMBID: String? // release_group_mbid
        let releaseDate: Date?
    }

    // Optional diagnostics
    struct Diagnostics {
        var source: String = ""     // "fresh-releases" or "recent-listens"
        var url: String = ""
        var statusCode: Int = 0
        var bytes: Int = 0
        var lastError: String?
        var count: Int = 0
    }

    func freshAlbumReleases(days: Int = 120, limit: Int = 20) -> AnyPublisher<([LBAlbumRelease], Diagnostics), Never> {
        // big page so we can dedupe + sort properly, then slice
        let qs = "sort=release_date&past=true&future=false&days=\(days)&count=200&offset=0"
        guard let url = URL(string: "https://api.listenbrainz.org/1/user/\(username)/fresh_releases?\(qs)") else {
            var d = Diagnostics(source: "fresh-releases (JSON)")
            d.url = "(bad URL)"
            d.lastError = "Bad URL"
            return Just(([], d)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("JellyMuse/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        func parseDate(_ s: String?) -> Date? {
            guard let s = s, !s.isEmpty else { return nil }
            for f in ["yyyy-MM-dd","yyyy-MM","yyyy"] {
                let df = DateFormatter()
                df.calendar = Calendar(identifier: .iso8601)
                df.locale = .init(identifier: "en_US_POSIX")
                df.dateFormat = f
                if let d = df.date(from: s) { return d }
            }
            return nil
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast

        return URLSession.shared.dataTaskPublisher(for: req)
            .map { (data, resp) -> ([LBAlbumRelease], Diagnostics) in
                var diag = Diagnostics(source: "fresh-releases (JSON)", url: url.absoluteString)
                if let h = resp as? HTTPURLResponse { diag.statusCode = h.statusCode }
                diag.bytes = data.count

                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    diag.lastError = "HTTP \(diag.statusCode)"
                    return ([], diag)
                }

                // Parse tolerantly
                var rows: [[String: Any]] = []
                if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if let arr = root["releases"] as? [[String: Any]] { rows = arr }
                    else if let payload = root["payload"] as? [String: Any],
                            let arr = payload["releases"] as? [[String: Any]] { rows = arr }
                }

                // Map + filter
                struct Row {
                    let key: String         // group key (RGMBID or RMBID)
                    let date: Date
                    let official: Bool
                    let title: String
                    let artist: String
                    let rel: String?
                    let rgrp: String?
                }

                var mapped: [Row] = rows.compactMap { r in
                    // Only Albums
                    let primaryType = (r["release_group_primary_type"] as? String)?.lowercased()
                    guard primaryType == "album" else { return nil }

                    // Title / artist
                    let title  = ((r["release_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let artist = ((r["artist_credit_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, !artist.isEmpty else { return nil }

                    // Date (required for stable sort)
                    guard let d = parseDate(r["release_date"] as? String), d >= cutoff else { return nil }

                    let rel  = r["release_mbid"] as? String
                    let rgrp = r["release_group_mbid"] as? String
                    // Dedup key: prefer release-group; fallback to release
                    let key = (rgrp ?? rel ?? (artist.lowercased()+"|"+title.lowercased()))

                    // Prefer Official if the field exists
                    let status = (r["release_status"] as? String)?.lowercased()
                    let official = (status == "official") || (status == nil) // treat missing as OK

                    return Row(key: key, date: d, official: official, title: title, artist: artist, rel: rel, rgrp: rgrp)
                }

                // Group by key (release-group) and keep the newest (prefer Official on ties)
                var bestByKey: [String: Row] = [:]
                for r in mapped {
                    if let cur = bestByKey[r.key] {
                        if r.date > cur.date || (r.date == cur.date && r.official && !cur.official) {
                            bestByKey[r.key] = r
                        }
                    } else {
                        bestByKey[r.key] = r
                    }
                }

                // Sort newest first; stable tie-break by title
                let sorted = bestByKey.values.sorted {
                    if $0.date != $1.date { return $0.date > $1.date }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }

                // Slice to limit and map to LBAlbumRelease
                let final = Array(sorted.prefix(limit)).map {
                    LBAlbumRelease(
                        title: $0.title,
                        artist: $0.artist,
                        releaseMBID: $0.rel,
                        releaseGroupMBID: $0.rgrp,
                        releaseDate: $0.date
                    )
                }

                diag.count = final.count
                return (final, diag)
            }
            .replaceError(with: {
                var d = Diagnostics(source: "fresh-releases (JSON)", url: url.absoluteString)
                d.lastError = "Network error"
                return ([], d)
            }())
            .eraseToAnyPublisher()
    }

    // MARK: - Upcoming album releases (albums only, next N days)
    func upcomingAlbumReleases(daysAhead: Int = 180, limit: Int = 10)
    -> AnyPublisher<([LBAlbumRelease], Diagnostics), Never> {

        let qs = "sort=release_date&past=false&future=true&days=\(daysAhead)&count=200&offset=0"
        guard let url = URL(string: "https://api.listenbrainz.org/1/user/\(username)/fresh_releases?\(qs)") else {
            var d = Diagnostics(source: "upcoming-releases (JSON)")
            d.url = "(bad URL)"
            d.lastError = "Bad URL"
            return Just(([], d)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("JellyMuse/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        func parseDate(_ s: String?) -> Date? {
            guard let s = s, !s.isEmpty else { return nil }
            for f in ["yyyy-MM-dd","yyyy-MM","yyyy"] {
                let df = DateFormatter()
                df.calendar = Calendar(identifier: .iso8601)
                df.locale = .init(identifier: "en_US_POSIX")
                df.dateFormat = f
                if let d = df.date(from: s) { return d }
            }
            return nil
        }

        // today at 00:00 so we only keep future (or today) releases
        let todayStart = Calendar.current.startOfDay(for: Date())

        return URLSession.shared.dataTaskPublisher(for: req)
            .map { (data, resp) -> ([LBAlbumRelease], Diagnostics) in
                var diag = Diagnostics(source: "upcoming-releases (JSON)", url: url.absoluteString)
                if let h = resp as? HTTPURLResponse { diag.statusCode = h.statusCode }
                diag.bytes = data.count

                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    diag.lastError = "HTTP \(diag.statusCode)"
                    return ([], diag)
                }

                // tolerant JSON extraction
                var rows: [[String: Any]] = []
                if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if let arr = root["releases"] as? [[String: Any]] { rows = arr }
                    else if let payload = root["payload"] as? [String: Any],
                            let arr = payload["releases"] as? [[String: Any]] { rows = arr }
                }

                struct Row {
                    let key: String
                    let date: Date
                    let official: Bool
                    let title: String
                    let artist: String
                    let rel: String?
                    let rgrp: String?
                }

                // Map + keep only Albums with future dates
                let mapped: [Row] = rows.compactMap { r in
                    let primaryType = (r["release_group_primary_type"] as? String)?.lowercased()
                    guard primaryType == "album" else { return nil }

                    let title  = ((r["release_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let artist = ((r["artist_credit_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, !artist.isEmpty else { return nil }

                    guard let d = parseDate(r["release_date"] as? String), d >= todayStart else { return nil }

                    let rel  = r["release_mbid"] as? String
                    let rgrp = r["release_group_mbid"] as? String
                    let key = (rgrp ?? rel ?? (artist.lowercased() + "|" + title.lowercased()))

                    let status = (r["release_status"] as? String)?.lowercased()
                    let official = (status == "official") || (status == nil)

                    return Row(key: key, date: d, official: official, title: title, artist: artist, rel: rel, rgrp: rgrp)
                }

                // De-dupe by key; prefer newer / official
                var bestByKey: [String: Row] = [:]
                for r in mapped {
                    if let cur = bestByKey[r.key] {
                        if r.date > cur.date || (r.date == cur.date && r.official && !cur.official) {
                            bestByKey[r.key] = r
                        }
                    } else {
                        bestByKey[r.key] = r
                    }
                }

                // Sort soonest first for "upcoming"
                let sorted = bestByKey.values.sorted {
                    if $0.date != $1.date { return $0.date < $1.date }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }

                let final = Array(sorted.prefix(limit)).map {
                    LBAlbumRelease(
                        title: $0.title,
                        artist: $0.artist,
                        releaseMBID: $0.rel,
                        releaseGroupMBID: $0.rgrp,
                        releaseDate: $0.date
                    )
                }

                diag.count = final.count
                return (final, diag)
            }
            .replaceError(with: {
                var d = Diagnostics(source: "upcoming-releases (JSON)", url: url.absoluteString)
                d.lastError = "Network error"
                return ([], d)
            }())
            .eraseToAnyPublisher()
    }


    // MARK: - Fresh Releases (tracks/songs, past N days)
    func freshReleases(days: Int = 120) -> AnyPublisher<([Recommendation], Diagnostics), Never> {
        let qs = "sort=release_date&past=true&future=false&days=\(days)"
        guard let url = URL(string: "https://api.listenbrainz.org/1/user/\(username)/fresh_releases?\(qs)") else {
            var d = Diagnostics(source: "fresh-releases (JSON)"); d.url = "(bad URL)"; d.lastError = "Bad URL"
            return Just(([], d)).eraseToAnyPublisher()
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("JellyMuse/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        func parseDate(_ s: String?) -> Date? {
            guard let s = s, !s.isEmpty else { return nil }
            for f in ["yyyy-MM-dd","yyyy-MM","yyyy"] {
                let df = DateFormatter()
                df.calendar = Calendar(identifier: .iso8601)
                df.locale = .init(identifier: "en_US_POSIX")
                df.dateFormat = f
                if let d = df.date(from: s) { return d }
            }
            return nil
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast

        return URLSession.shared.dataTaskPublisher(for: req)
            .map { (data, resp) -> ([Recommendation], Diagnostics) in
                var diag = Diagnostics(source: "fresh-releases (JSON)", url: url.absoluteString)
                if let h = resp as? HTTPURLResponse { diag.statusCode = h.statusCode }
                diag.bytes = data.count

                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    diag.lastError = "HTTP \(diag.statusCode)"
                    return ([], diag)
                }

                // tolerant JSON extraction
                var rows: [[String: Any]] = []
                if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if let arr = root["releases"] as? [[String: Any]] { rows = arr }
                    else if let payload = root["payload"] as? [String: Any],
                            let arr = payload["releases"] as? [[String: Any]] { rows = arr }
                }

                var seen = Set<String>()
                let recs: [Recommendation] = rows.compactMap { r in
                    let artist = (r["artist_credit_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // prefer recording_name (track), fall back to release_name
                    let title = ((r["recording_name"] as? String) ?? (r["release_name"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !artist.isEmpty, !title.isEmpty else { return nil }

                    let date = parseDate(r["release_date"] as? String)
                    if let d = date, d < cutoff { return nil }

                    let rel  = r["release_mbid"] as? String
                    let rgrp = r["release_group_mbid"] as? String
                    let key = rel ?? rgrp ?? (artist.lowercased()+"|"+title.lowercased())
                    guard seen.insert(key).inserted else { return nil }

                    return Recommendation(artist: artist,
                                          title: title,
                                          releaseMBID: rel,
                                          releaseGroupMBID: rgrp,
                                          releaseDate: date)
                }

                diag.count = recs.count
                return (recs, diag)
            }
            .replaceError(with: {
                var d = Diagnostics(source: "fresh-releases (JSON)", url: url.absoluteString)
                d.lastError = "Network error"
                return ([], d)
            }())
            .eraseToAnyPublisher()
    }


    // MARK: - Recent Listens (JSON fallback)
    // Keep this function as it is in your provided code.
    private struct RecentListensResponse: Decodable {
        struct Payload: Decodable {
            struct Listen: Decodable {
                struct TrackMeta: Decodable {
                    let artist_name: String?
                    let track_name: String?
                }
                let track_metadata: TrackMeta
            }
            let listens: [Listen]
        }
        let payload: Payload
    }

    struct Recommendation: Identifiable, Hashable {
        let id = UUID().uuidString
        let artist: String        // artist_credit_name
        let title: String         // recording_name if present, else release_name
        let releaseMBID: String?  // release_mbid
        let releaseGroupMBID: String? // release_group_mbid
        let releaseDate: Date?    // release_date (parsed)
    }

    func recentListens(count: Int = 50) -> AnyPublisher<([Recommendation], Diagnostics), Never> {
        guard let url = URL(string: "https://api.listenbrainz.org/1/user/\(username)/listens?count=\(max(1, min(count, 100)))") else {
            var d = Diagnostics(source: "recent-listens"); d.url = "(bad URL)"; d.lastError = "Bad URL"
            return Just(([], d)).eraseToAnyPublisher()
        }

        let req = URLRequest(url: url)

        return URLSession.shared.dataTaskPublisher(for: req)
            .map { (data, resp) -> ([Recommendation], Diagnostics) in
                var diag = Diagnostics(source: "recent-listens", url: url.absoluteString)
                if let h = resp as? HTTPURLResponse { diag.statusCode = h.statusCode }
                diag.bytes = data.count

                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    diag.lastError = "HTTP \(diag.statusCode)"
                    return ([], diag)
                }

                do {
                    let obj = try JSONDecoder().decode(RecentListensResponse.self, from: data)
                    var seen = Set<String>()
                    let out = obj.payload.listens.compactMap { l -> Recommendation? in
                        let a = (l.track_metadata.artist_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let t = (l.track_metadata.track_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !a.isEmpty, !t.isEmpty else { return nil }
                        let key = a.lowercased() + "|\(t.lowercased())"
                        guard seen.insert(key).inserted else { return nil }
                        return Recommendation(artist: a, title: t, releaseMBID: nil, releaseGroupMBID: nil, releaseDate: nil)
                    }
                    diag.count = out.count
                    return (Array(out.prefix(32)), diag)
                } catch {
                    diag.lastError = "Decode: \(error.localizedDescription)"
                    return ([], diag)
                }
            }
            .replaceError(with: {
                var d = Diagnostics(source: "recent-listens", url: url.absoluteString)
                d.lastError = "Network error"
                return ([], d)
            }())
            .eraseToAnyPublisher()
    }
}
