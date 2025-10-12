//
//  ExternalArt.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 14.09.2025.
//


// ExternalArt.swift
import Foundation

enum ExternalArt {
    /// Set this ONCE to your nginx URL that serves /Apple Music/Genres/
    static var baseURL = URL(string: "http://192.168.1.168/genres")!

    /// Turn "R&B" -> "r-b", "Hip Hop" -> "hip-hop", "Pop" -> "pop"
    static func slug(for name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: " & ", with: " and ")
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "+", with: "plus")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
    }

    /// https://media.yourdomain.com/genres/<slug>.png
    static func genreImageURL(for name: String, ext: String = "png") -> URL {
        baseURL
            .appendingPathComponent(slug(for: name))
            .appendingPathExtension(ext)
    }
}
