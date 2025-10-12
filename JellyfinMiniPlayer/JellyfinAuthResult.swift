import Foundation
import SwiftUI
import Combine

// MARK: - API Response Models

struct JellyfinAuthResult: Codable {
    let accessToken: String
    let user: JellyfinUser
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

struct JellyfinUser: Codable {
    let id: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct JellyfinAlbumResponse: Codable {
    let items: [JellyfinAlbum]?
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

struct JellyfinUserData: Codable, Equatable {
    let isFavorite: Bool?
    enum CodingKeys: String, CodingKey { case isFavorite = "IsFavorite" }
}

struct JellyfinAlbum: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
    let artistItems: [JellyfinArtistItem]?
    let productionYear: Int?
    let genres: [String]?
    let genreItems: [JellyfinGenre]?
    let albumArtists: [JellyfinArtistItem]?
    var userData: JellyfinUserData?

    let overview: String?
    let communityRating: Double?
    let officialRating: String?
    let tags: [String]?

    let releaseDate: String?
    let premiereDate: String?
    let dateCreated: String?

    // NEW (optional):
    let primaryImageTag: String?
    let imageTags: [String: String]?
    let dateLastMediaAdded: String?
    let dateModified: String?
    
    let childCount: Int? // <-- ADDED

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case artistItems = "ArtistItems"
        case productionYear = "ProductionYear"
        case genres = "Genres"
        case genreItems = "GenreItems"
        case albumArtists = "AlbumArtists"
        case userData = "UserData"
        case communityRating = "CommunityRating"
        case officialRating = "OfficialRating"
        case tags = "Tags"
        case overview = "Overview"
        case releaseDate = "ReleaseDate"
        case premiereDate = "PremiereDate"
        case dateCreated = "DateCreated"
        
        // NEW MAPPINGS:
        case primaryImageTag    = "PrimaryImageTag"
        case imageTags          = "ImageTags"
        case dateLastMediaAdded = "DateLastMediaAdded"
        case dateModified       = "DateModified"
        
        case childCount = "ChildCount" // <-- ADDED
    }
    
    /// Prefer string Genres, fall back to GenreItems name.
    var primaryGenre: String? {
        if let g = genres?.first, !g.isEmpty { return g }
        if let g = genreItems?.first?.name, !g.isEmpty { return g }
        return nil
    }

    // Helper: explicit via tag OR rating
    var isExplicitByTag: Bool { (tags ?? []).contains { $0.lowercased() == "explicit" } }
    var isExplicitByRating: Bool {
        (officialRating?.trimmingCharacters(in: .whitespacesAndNewlines) == "10")
        || (officialRating?.localizedCaseInsensitiveContains("explicit") == true)
    }
    var isExplicit: Bool { isExplicitByTag || isExplicitByRating }

    static func == (lhs: JellyfinAlbum, rhs: JellyfinAlbum) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct JellyfinArtistItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    
    // NEW (optional):
    let primaryImageTag: String?
    let imageTags: [String: String]?
    let dateLastMediaAdded: String? = nil
    let dateModified: String? = nil
    
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        
        // NEW MAPPINGS:
        case primaryImageTag = "PrimaryImageTag"
        case imageTags       = "ImageTags"
    }
}

struct JellyfinTrackResponse: Codable {
    let items: [JellyfinTrack]?
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

struct JellyfinTrack: Codable, Equatable, Identifiable, Hashable {
    let serverId: String?
    let name: String?
    let artists: [String]?
    let albumId: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?  // Disc number (Jellyfin uses ParentIndexNumber)
    let officialRating: String?
    let runTimeTicks: Int?
    let tags: [String]?

    // NEW (optional):
    let primaryImageTag: String?
    let imageTags: [String: String]?
    let dateLastMediaAdded: String? = nil
    let dateModified: String? = nil

    enum CodingKeys: String, CodingKey {
        case serverId = "Id"
        case name = "Name"
        case artists = "Artists"
        case albumId = "AlbumId"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case officialRating = "OfficialRating"
        case runTimeTicks = "RunTimeTicks"
        case tags = "Tags"
        
        // NEW MAPPINGS:
        case primaryImageTag = "PrimaryImageTag"
        case imageTags       = "ImageTags"
    }

    // Helper: explicit via tag OR rating
    var isExplicitByTag: Bool { (tags ?? []).contains { $0.lowercased() == "explicit" } }
    var isExplicitByRating: Bool {
        (officialRating?.trimmingCharacters(in: .whitespacesAndNewlines) == "10")
        || (officialRating?.localizedCaseInsensitiveContains("explicit") == true)
    }
    var isExplicit: Bool { isExplicitByTag || isExplicitByRating }

    public var id: String {
        if let serverId = self.serverId, !serverId.isEmpty { return serverId }
        let title = (name ?? "")
        let artist = (artists?.first ?? "")
        let idx = indexNumber ?? 0
        return "\(title)|\(artist)|\(idx)"
    }

    static func == (lhs: JellyfinTrack, rhs: JellyfinTrack) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Search Models

struct JellyfinSearchResponse: Codable {
    let SearchHints: [JellyfinSearchHint]?
}

struct JellyfinSearchHint: Codable, Identifiable, Hashable {
    // Matches Jellyfin JSON: Id / Name / Type / AlbumId / PrimaryImageItemId / Artists
    let idRaw: String?
    let name: String?
    let type: String?
    let album: String?
    let artists: [String]?
    let albumId: String?
    let primaryImageItemId: String?
    let productionYear: Int?

    // NEW (optional):
    let primaryImageTag: String?
    let imageTags: [String: String]?
    let dateLastMediaAdded: String? = nil
    let dateModified: String? = nil

    // Identifiable
    var id: String {
        idRaw ?? primaryImageItemId ?? albumId ?? UUID().uuidString
    }

    var imageID: String {
        primaryImageItemId ?? albumId ?? idRaw ?? ""
    }

    var artistName: String {
        artists?.first ?? "Unknown Artist"
    }

    enum CodingKeys: String, CodingKey {
        case idRaw               = "Id"
        case name                = "Name"
        case type                = "Type"
        case album               = "Album"
        case artists             = "Artists"
        case albumId             = "AlbumId"
        case primaryImageItemId  = "PrimaryImageItemId"
        case productionYear      = "ProductionYear"
        
        // NEW MAPPINGS:
        case primaryImageTag     = "PrimaryImageTag"
        case imageTags           = "ImageTags"
    }
}

// MARK: - Genres
public struct JellyfinGenre: Codable, Equatable, Identifiable, Hashable {
    public let rawId: String?
    public let name: String

    public var id: String { rawId ?? name }

    enum CodingKeys: String, CodingKey {
        case rawId = "Id"
        case name  = "Name"
    }
}

// MARK: - Small helpers

extension Int64 {
    func formattedDuration() -> String {
        let seconds = self / 10_000_000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

// MARK: - Backward Compatibility Initializers

extension JellyfinAlbum {
    // Old initializer (before ratings/tags)
    init(
        id: String,
        name: String,
        artistItems: [JellyfinArtistItem]?,
        productionYear: Int?,
        genres: [String]?,
        albumArtists: [JellyfinArtistItem]?,
        userData: JellyfinUserData?
    ) {
        self.init(
            id: id,
            name: name,
            artistItems: artistItems,
            productionYear: productionYear,
            genres: genres,
            genreItems: nil,
            albumArtists: albumArtists,
            userData: userData,
            overview: nil,
            communityRating: nil,
            officialRating: nil,
            tags: nil,
            releaseDate: nil,
            premiereDate: nil,
            dateCreated: nil,
            primaryImageTag: nil,
            imageTags: nil,
            dateLastMediaAdded: nil,
            dateModified: nil,
            childCount: nil // <-- ADDED
        )
    }
}

extension JellyfinTrack {
    // Old initializer (before officialRating/tags existed)
    init(
        serverId: String?,
        name: String?,
        artists: [String]?,
        albumId: String?,
        indexNumber: Int?,
        runTimeTicks: Int?,
        parentIndexNumber: Int? = nil
    ) {
        // FIX: Provide nil for the fields that exist in the memberwise init,
        // and DO NOT pass dateLastMediaAdded/dateModified (they aren’t params).
        self.init(
            serverId: serverId,
            name: name,
            artists: artists,
            albumId: albumId,
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            officialRating: nil,
            runTimeTicks: runTimeTicks,
            tags: nil,
            primaryImageTag: nil,
            imageTags: nil
        )
    }
}
