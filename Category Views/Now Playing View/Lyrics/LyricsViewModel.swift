//
//  LyricsViewModel.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 22.08.2025.
//


import Foundation
import Combine

class LyricsViewModel: ObservableObject {
    @Published var lyrics: [TimeInterval: String] = [:]
    @Published var lyricsKeys: [TimeInterval] = []
    @Published var activeLineIndex: Int = 0
    @Published var lyricsLoaded = false
    @Published var lyricsFetchFailed = false
    
    private var cancellables = Set<AnyCancellable>()
    
    func loadLyrics(for trackId: String) {
        JellyfinAPIService.shared.fetchLyricsSmart(for: trackId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure = completion {
                    self.lyricsFetchFailed = true
                    self.lyricsLoaded = false
                }
            }, receiveValue: { text in
                guard let text else {
                    self.lyricsFetchFailed = true
                    return
                }
                let parsed = parseLRC(lyrics: text)
                self.lyrics = Dictionary(uniqueKeysWithValues: parsed.map { ($0.time, $0.text) })
                self.lyricsKeys = parsed.map { $0.time }
                self.lyricsLoaded = true
            })
            .store(in: &cancellables)
    }
    
    func updateActiveLine(currentTime: TimeInterval) {
        if let idx = lyricsKeys.lastIndex(where: { $0 <= currentTime }) {
            activeLineIndex = idx
        }
    }
}
