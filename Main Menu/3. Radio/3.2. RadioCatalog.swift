//
//  RadioCatalog.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 11.09.2025.
//


import Foundation

enum RadioCatalog {
    /// Select up to 6 station IDs to pin at the top (3×2 like Apple Music)
    static let pinnedIDs: [String] = [
        "OnlyHits K-Pop",
        "Energy Bern",
        "Radio Argovia",
        "KIIS FM",
        "RadioMonster.FM - 2000's",
        "iHeart Country"
    ]

    // Here are the Radio Stations that also sit as pinned radio stations. Other ones go into the "Radio Stations" section/part
    
    static let stations: [RadioStation] = [
        RadioStation(
            id: "OnlyHits K-Pop",
            name: "OnlyHits K-Pop", // <-- add a square Asset named exactly "K-Pop Radio"
            streamURL: URL(string: "https://ais-sa3.cdnstream1.com/2630_128.mp3")!,
            subtitle: "Live • K-Pop",
            imageName: "OnlyHits K-Pop"
        ),
        
        RadioStation(
            id: "Energy Bern",
            name: "Energy Bern", // <-- add a square Asset named exactly "K-Pop Radio"
            streamURL: URL(string: "https://energybern.ice.infomaniak.ch/energybern-high.mp3")!,
            subtitle: "Live • Pop",
            imageName: "Energy Bern"
        ),
        
        RadioStation(
            id: "Radio Argovia",
            name: "Radio Argovia", // <-- add a square Asset named exactly "K-Pop Radio"
            streamURL: URL(string: "https://stream.streambase.ch/argovia/mp3-192/radiobrowser/")!,
            subtitle: "Live • Pop",
            imageName: "Radio Argovia"
        ),
        
        RadioStation(
            id: "KIIS FM",
            name: "KIIS FM", // <-- add a square Asset named exactly "K-Pop Radio"
            streamURL: URL(string: "https://stream.revma.ihrhls.com/zc185")!,
            subtitle: "Live • Pop",
            imageName: "KIIS FM"
        ),
        
        RadioStation(
            id: "RadioMonster.FM - 2000's",
            name: "RadioMonster.FM - 2000's", // <-- add a square Asset named exactly "K-Pop Radio"
            streamURL: URL(string: "https://ic.radiomonster.fm/2000s.ultra")!,
            subtitle: "Live • 2000s",
            imageName: "RadioMonsterFM2000"
        ),
        
        RadioStation(
            id: "iHeart Country",
            name: "iHeart Country", // <-- add a square Asset named exactly "K-Pop Radio"
            streamURL: URL(string: "https://stream.revma.ihrhls.com/zc4418/hls.m3u8?streamid=4418&zip=60629&clientType=web&host=webapp.US&modTime=1706531123554&profileid=8166296424&terminalid=159&territory=US&us_privacy=1-N-&callLetters=CTYM-FL&devicename=web-desktop&stationid=4418&dist=iheart&subscription_type=free&partnertok=eyJraWQiOiJpaGVhcnQiLCJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZCIsInN1YiI6IjgxNjYyOTY0MjQiLCJjb3BwYSI6MCwicHJvdmlkZXJJZCI6MjUsImlzcyI6ImloZWFydCIsInVzX3ByaXZhY3kiOiIxWU5OIiwiZGlzdCI6ImloZWFydCIsImV4cCI6MTcwNjYxNzUyNiwiaWF0IjoxNzA2NTMxMjYxLCJvbWlkIjowfQ.Cg_65e6-yL4S1-0p2aO52701p_m85oJ1r9n8l-9a-uQ&country=US&locale=en-US&site-url=https%3A%2F%2Fwww.iheart.com%2Flive%2Fiheartcountry-4418%2F")!,
            subtitle: "Live • Country",
            imageName: "iHeart Country"
        ),
    ]

    /// Local Broadcasters carousel
    static let localBroadcasters: [RadioStation] = [
        RadioStation(
            id: "Energy Bern",
            name: "Energy Bern",
            streamURL: URL(string: "https://energybern.ice.infomaniak.ch/energybern-high.mp3")!,
            subtitle: "Local • Pop",
            imageName: "Energy Bern"
        ),
        RadioStation(
            id: "Radio Argovia",
            name: "Radio Argovia",
            streamURL: URL(string: "https://stream.streambase.ch/argovia/mp3-192/radiobrowser/")!,
            subtitle: "Local • Pop",
            imageName: "Radio Argovia"
        ),
        // Add more locals here…
    ]
    
    /// List for "Radio Stations" Carousel (all radio stations)
    static let userStations: [RadioStation] = [
        RadioStation(
            id: "Radio Argovia",
            name: "Radio Argovia",
            streamURL: URL(string: "https://cdn.onlyhitsradio.net/onlyhits")!,
            subtitle: "Local • Pop",
            imageName: "Radio Argovia"
        ),
    ]
}
