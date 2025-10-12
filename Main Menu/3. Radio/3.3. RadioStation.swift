//RadioStation.swift

//Created by Ardit Sejdiu

//11.09.2025



import Foundation

public struct RadioStation: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let streamURL: URL
    public let subtitle: String?
    public let imageName: String?   // <-- add this

    public init(
        id: String,
        name: String,
        streamURL: URL,
        subtitle: String? = nil,
        imageName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.subtitle = subtitle
        self.imageName = imageName
    }
}
