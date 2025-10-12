//
//  AnimatedArtworkResolver.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 07.10.2025.
//


import Foundation

struct AnimatedArtworkResolver {
    /// From the same AnimatedArtwork=... tag(s), build .../cover_3x4.mp4
    static func poster3x4URL(from tags: [String]?) -> URL? {
        guard
            let base = (tags ?? [])
                .compactMap({ tag -> URL? in
                    let lower = tag.lowercased()
                    guard lower.hasPrefix("animatedartwork=") else { return nil }
                    let raw = String(tag.split(separator: "=", maxSplits: 1).last ?? "")
                    let enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
                    return URL(string: enc)
                })
                .first
        else { return nil }
        return base.deletingLastPathComponent().appendingPathComponent("cover_3x4.mp4")
    }
}