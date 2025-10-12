//
//  CountryEditorial.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 16.09.2025.
//


// CountryEditorial.swift
import Foundation

enum CountryEditorial {
    /// Editable mapping from ISO country code -> Deezer editorial id.
    /// Source: https://developers.deezer.com/api/editorial
    static var map: [String: Int] = [
        // Common
        "US": 3, "GB": 4, "FR": 2, "DE": 5, "IT": 7, "ES": 6, "NL": 8, "SE": 21, "NO": 23, "DK": 20,
        "PT": 15, "IE": 10, "CA": 16, "AU": 14, "NZ": 22, "JP": 27, "KR": 28, "BR": 75, "MX": 29, "CH": 176,
        // Add more as you need…
    ]

    /// Returns a Deezer editorial id for a given region code, falling back to 0 (Global).
    static func editorialID(for regionCode: String?) -> Int {
        guard let code = regionCode?.uppercased(), let id = map[code] else { return 0 }
        return id
    }
}
