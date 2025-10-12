//
//  to.swift
//  JellyfinMiniPlayer
//
//  Created by Ardit Sejdiu on 15.08.2025.
//


import Foundation

// A Codable struct to represent the data for a single album.
// The `Codable` protocol allows us to easily decode JSON from the Jellyfin API.
struct Album: Codable, Identifiable {
    // The `id` property is essential for SwiftUI's `List` to uniquely
    // identify each album. The Jellyfin API returns an "Id" field,
    // so we map it to our `id` property.
    var id: String { Id }
    
    // The actual ID from the Jellyfin API.
    let Id: String
    
    // The title of the album.
    let Name: String
    
    // A computed property to make the title more accessible in the view.
    var title: String { Name }
    
    // A placeholder to match the expected API response. You can
    // add more properties here as needed, such as artist, year, etc.
    // The API might also provide an `AlbumArtist` or `Artists` field.
    let AlbumArtist: String?
    
    // Coding keys allow us to map the API's camelCase fields to
    // Swift's more idiomatic PascalCase. This is not strictly necessary
    // here, but it's good practice for more complex API responses.
    private enum CodingKeys: String, CodingKey {
        case Id
        case Name
        case AlbumArtist
    }
}
