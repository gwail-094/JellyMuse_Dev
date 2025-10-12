//
//  RadioAudioPlayer.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 11.09.2025.
//


import SwiftUI
import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import MusicKit   // ← needed to pause Apple Music playback

// MARK: - Artwork Service

final class RadioArtworkService {
    static let shared = RadioArtworkService()

    private let cache = NSCache<NSString, UIImage>()

    func fetchArtwork(artist: String?, title: String?, completion: @escaping (UIImage?) -> Void) {
        // Require at least a title; artist helps a lot
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            completion(nil); return
        }
        let artistQ = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(artistQ.lowercased())|\(title.lowercased())" as NSString

        if let img = cache.object(forKey: key) {
            completion(img); return
        }

        // Build iTunes Search query
        var terms: [String] = []
        if !artistQ.isEmpty { terms.append(artistQ) }
        terms.append(title)
        let query = terms.joined(separator: " ")

        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=music&entity=song&limit=5&term=\(q)") else {
            completion(nil); return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artSmall = first["artworkUrl100"] as? String
            else { DispatchQueue.main.async { completion(nil) }; return }

            // Upsize 100x100 → 1000x1000 (Apple CDNs support this)
            let artLarge = artSmall.replacingOccurrences(of: "100x100bb.jpg", with: "1000x1000bb.jpg")
                                   .replacingOccurrences(of: "100x100bb.png", with: "1000x1000bb.png")

            guard let artURL = URL(string: artLarge) else {
                DispatchQueue.main.async { completion(nil) }; return
            }

            URLSession.shared.dataTask(with: artURL) { data, _, _ in
                guard let data, let img = UIImage(data: data) else {
                    DispatchQueue.main.async { completion(nil) }; return
                }
                self.cache.setObject(img, forKey: key)
                DispatchQueue.main.async { completion(img) }
            }.resume()
        }.resume()
    }
}


// MARK: - Metadata Sanitizer

struct RadioNowPlayingMeta {
    let display: String
    let artist: String?
    let title: String?
}

private func cleanRadioNowPlaying(_ rawIn: String) -> RadioNowPlayingMeta {
    // 0) Normalize wrappers like StreamTitle='...';
    var raw = rawIn.trimmingCharacters(in: .whitespacesAndNewlines)
    if let m = raw.range(of: #"^\s*StreamTitle\s*=\s*['"](.+?)['"]\s*;*$"#,
                          options: .regularExpression) {
        raw = String(raw[m]).replacingOccurrences(of: #"^\s*StreamTitle\s*=\s*['"]|['"]\s*;*$"#,
                                                 with: "", options: .regularExpression)
    } else {
        raw = raw.replacingOccurrences(of: #";+$"#, with: "", options: .regularExpression)
    }

    // 1) Parse key=value pairs if any
    let hasPairs = raw.range(of: #"\b\w+\s*="#, options: .regularExpression) != nil
    var artistFromPairs: String? = nil
    var titleFromPairs:  String? = nil
    var baseNoPairs     = raw

    if hasPairs {
        let pairs = parsePairs(raw)
        artistFromPairs = firstNonEmpty(pairs["artist"], pairs["creator"], pairs["by"], pairs["author"], pairs["albumartist"])
        titleFromPairs  = firstNonEmpty(pairs["title"], pairs["song"], pairs["song_title"], pairs["text"], pairs["track"], pairs["name"])

        // Remove all key=value fragments to inspect any human-readable prefix like "Artist - ..."
        baseNoPairs = raw
            .replacingOccurrences(of: #"(?:^|[\s,\-])\b[\w\-]+\s*=\s*(?:"[^"]*"|'[^']*'|[^,\-]+)"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 2) If we have pairs but *no* artist, try to extract artist from a "Artist - ..." prefix
    if hasPairs, artistFromPairs == nil, baseNoPairs.contains(" - ") {
        let parts = baseNoPairs.components(separatedBy: " - ")
        let artistGuess = parts.first?.trimmingCharacters(in: .whitespaces)
        if let artistGuess, !artistGuess.isEmpty {
            artistFromPairs = artistGuess
        }
    }

    // 3) If we have either (artistFromPairs or titleFromPairs), build display from them
    if hasPairs, (artistFromPairs != nil || titleFromPairs != nil) {
        let a = artistFromPairs?.htmlDecoded().strippedQuotes()
        let t = titleFromPairs?.htmlDecoded().strippedQuotes()

        if let a, let t, !a.isEmpty, !t.isEmpty {
            return .init(display: "\(a) - \(t)", artist: a, title: t)
        } else if let t, !t.isEmpty {
            let dashed = parseDash(baseNoPairs)
            if let a2 = dashed.artist, !a2.isEmpty {
                return .init(display: "\(a2) - \(t)", artist: a2, title: t)
            }
            return .init(display: t, artist: nil, title: t)
        } else if let a, !a.isEmpty {
            return .init(display: a, artist: a, title: nil)
        }
    }

    // 4) Generic dash parsing (covers “Artist - Title”)
    let dashed = parseDash(baseNoPairs)
    if let a = dashed.artist, let t = dashed.title, !a.isEmpty, !t.isEmpty {
        return .init(display: "\(a) - \(t)",
                     artist: a.htmlDecoded().strippedQuotes(),
                     title:  t.htmlDecoded().strippedQuotes())
    }

    // 5) “Title by Artist”
    if let byRange = baseNoPairs.range(of: #" by "#, options: [.regularExpression, .caseInsensitive]) {
        let t = String(baseNoPairs[..<byRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let a = String(baseNoPairs[byRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return .init(display: "\(a) - \(t)",
                     artist: a.htmlDecoded().strippedQuotes(),
                     title:  t.htmlDecoded().strippedQuotes())
    }

    // 6) Fallback: whatever’s left
    let fallback = baseNoPairs.htmlDecoded().strippedQuotes()
    return .init(display: fallback, artist: nil, title: nil)
}

private func parseDash(_ s: String) -> (artist: String?, title: String?) {
    let parts = s.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 2 else { return (nil, nil) }
    let artist = parts[0]
    let title  = parts.dropFirst().joined(separator: " - ")
    return (artist, title)
}

private func parsePairs(_ s: String) -> [String:String] {
    let regex = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^,\s;]+))"#, options: [])
    let ns = s as NSString
    var out: [String:String] = [:]
    for m in regex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
        guard m.numberOfRanges >= 2 else { continue }
        let key = ns.substring(with: m.range(at: 1)).lowercased()
        let val: String = {
            for i in 2..<min(5, m.numberOfRanges) {
                let r = m.range(at: i)
                if r.location != NSNotFound { return ns.substring(with: r) }
            }
            return ""
        }()
        if !val.isEmpty { out[key] = val }
    }
    return out
}

private func firstNonEmpty(_ items: String?...) -> String? {
    for it in items { if let s = it?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s } }
    return nil
}

/// A tiny, self-contained player that handles ONLY live radio streams.
@MainActor
final class RadioAudioPlayer: NSObject, ObservableObject {
    static let shared = RadioAudioPlayer()

    // Public state for UI
    @Published var isPlaying: Bool = false
    @Published var currentStation: RadioStation?
    @Published var liveText: String?
    @Published var currentMeta: RadioNowPlayingMeta?
    @Published var currentArtwork: UIImage?

    // Private
    private var player: AVPlayer?
    private var metadataKVO: NSKeyValueObservation?
    private var endObserver: Any?
    private let commandCenter = MPRemoteCommandCenter.shared()

    private var isRadioSessionActive: Bool {
        player != nil && currentStation != nil
    }

    override init() {
        super.init()
        setupRemoteCommands()
        // Play/Pause commands are kept globally enabled by not setting isEnabled=false here
    }

    // MARK: - Exclusivity

    private func stopOtherPlayers() {
        AudioPlayer.shared.stop()
        Task { try? await ApplicationMusicPlayer.shared.pause() }
    }

    // MARK: - Public API

    func play(_ station: RadioStation) {
        stopOtherPlayers() // only when explicitly starting radio
        stop()

        currentStation = station
        currentArtwork = nil
        currentMeta = nil

        let item = AVPlayerItem(url: station.streamURL)

        metadataKVO = item.observe(\.timedMetadata, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            let raw = item.timedMetadata?.compactMap { $0.value as? String }.first ?? ""
            
            let meta = cleanRadioNowPlaying(raw)
            self.currentMeta = meta
            self.liveText = meta.display

            self.updateNowPlaying(station: station, meta: meta)

            RadioArtworkService.shared.fetchArtwork(artist: meta.artist, title: meta.title) { [weak self] image in
                guard let self, self.currentStation?.id == station.id else { return }
                self.currentArtwork = image
                if image != nil {
                    self.updateNowPlaying(station: station, meta: meta)
                }
            }
        }

        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        self.player = p
        p.play()
        isPlaying = true
        // setRemoteCommandsEnabled(true) removed

        updateNowPlaying(station: station, meta: nil)
    }

    func stop() {
        metadataKVO = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil

        player?.pause()
        player = nil

        isPlaying = false
        currentStation = nil
        liveText = nil
        currentMeta = nil
        currentArtwork = nil

        // setRemoteCommandsEnabled(false) removed
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        // setRemoteCommandsEnabled(true) removed
        updateNowPlayingRate()
    }

    func resume() {
        guard isRadioSessionActive else { return } // only if a station is loaded
        // stopOtherPlayers() removed in previous fix
        player?.play()
        isPlaying = true
        updateNowPlayingRate()
    }

    // MARK: - Remote Commands

    // setRemoteCommandsEnabled(_:) removed entirely

    private func setupRemoteCommands() {
        // We set isEnabled=true on setup once, but don't toggle it per state
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = false // Keep next/prev disabled for radio
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, self.isRadioSessionActive else { return .noActionableNowPlayingItem }
            self.resume()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isRadioSessionActive else { return .noActionableNowPlayingItem }
            self.pause()
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.isRadioSessionActive else { return .noActionableNowPlayingItem }
            self.togglePlayPause()
            return .success
        }
    }

    // MARK: - Now Playing

    private func updateNowPlaying(station: RadioStation, meta: RadioNowPlayingMeta? = nil) {
        var title  = station.name
        var artist: String? = nil

        if let meta {
            // Prefer parsed values; if missing, fall back to display
            title  = meta.title ?? meta.display
            artist = meta.artist
        } else if let sub = station.subtitle {
            artist = sub
        }

        var info: [String: Any] = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        if let artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        } else {
            info[MPMediaItemPropertyArtist] = nil
        }

        // Set artwork: fetched art > station art
        if let artwork = currentArtwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        } else if let name = station.imageName, let img = UIImage(named: name) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }

        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingRate() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

private extension String {
    func strippedQuotes() -> String {
        trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    func htmlDecoded() -> String {
        // lightweight HTML entity decode
        let a = replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return a
    }
}
