//
//  ReplayView.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 20.09.2025.
//

import SwiftUI
import Combine
import SDWebImageSwiftUI
import AVKit
import UIKit // for foreground notifications

// MARK: - JSON Decoders (match your file)
private struct MilestonesJSON: Decodable {
    struct Year: Decodable {
        let year: Int
        let milestones: [Entry]
    }
    struct Entry: Decodable {
        let kind: String  // "songs" | "artists" | "minutes"
        let threshold: Int
        let achievedOn: String  // "YYYY-MM-DD"
    }
    let years: [Year]
}

// Alternate shape support (your current file):
private struct MilestonesJSONAlt: Decodable {
    struct SimpleEntry: Decodable {
        let threshold: Int
        let achievedAt: String
    }
    struct Year: Decodable {
        let year: Int
        let songs: [SimpleEntry]?
        let artists: [SimpleEntry]?
        let minutes: [SimpleEntry]?
    }
    let years: [Year]
}

struct ReplayView: View {
    @EnvironmentObject var api: JellyfinAPIService
    @StateObject private var vm = ReplayViewModel()

    // State for the pill button's position.
    @State private var pillVerticalOffset: CGFloat = -120
    
    // State to control sheets
    @State private var showMilestones = false
    @State private var showReel = false
    @State private var reelYear: Int = Calendar.current.component(.year, from: Date())
    
    // MARK: - App change (cache-busting + bypass query cache)
    @State private var artBust: Int = Int(Date().timeIntervalSince1970)

    private func bust(_ url: URL?) -> URL? {
        guard let url else { return nil }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = c?.queryItems ?? []
        items.removeAll { $0.name == "v" }
        items.append(.init(name: "v", value: "\(artBust)"))
        c?.queryItems = items
        return c?.url
    }

    // MARK: - Hero Image Configuration
    private let replayImageBaseURL = URL(string: "http://192.168.1.169/replay")!

    private func replayImageURL(for year: Int) -> URL {
        replayImageBaseURL.appendingPathComponent("\(year).png")
    }
              
    private var heroURLProvider: ((Int?) -> URL?) {
        { year in
            guard let year = year else { return nil }
            return self.replayImageURL(for: year)
        }
    }

    var body: some View {
        ScrollView {
            content
        }
        .navigationTitle("") // Hide the default title to use our custom one.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMilestones = true
                } label: {
                    Image(systemName: "trophy")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.black)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Milestones")
            }
        }
        .fullScreenCover(isPresented: $showMilestones) {
            MilestonesSheet(
                year: Optional(vm.heroYear),
                unlocked: vm.unlockedMilestones(for: Optional(vm.heroYear)),
                onClose: { showMilestones = false }
            )
        }
        .fullScreenCover(isPresented: $showReel) {
            ReelPlayerView(
                year: reelYear,
                baseURL: URL(string: "http://192.168.1.169/replay/reels")!
            )
        }
        .task {
            await vm.load(api: api)
            await vm.loadMilestonesJSON()
            vm.updateHero(using: heroURLProvider)
            artBust = Int(Date().timeIntervalSince1970)   // <- bust on first load
        }
        .onChange(of: vm.heroYear) { _ in
            vm.updateHero(using: heroURLProvider)
            artBust = Int(Date().timeIntervalSince1970)   // <- bust when year changes
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification
        )) { _ in
            artBust = Int(Date().timeIntervalSince1970)   // <- bust on app foreground
        }
    }

    // MARK: - Extracted Content View
    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            // --- New Header Section ---
            HStack(alignment: .center) {
                Text("Replay")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            
                Spacer()
            
                Menu {
                    Picker("Year", selection: $vm.heroYear) {
                        ForEach(vm.yearsForPicker, id: \.self) { y in
                            Text(String(y)).tag(y)
                        }
                    }
                    .onChange(of: vm.heroYear) { newValue in
                        // Update reelYear instantly when user picks a new year
                        reelYear = newValue
                        vm.updateHero(using: heroURLProvider)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(vm.heroYearLabel).fontWeight(.semibold)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.1), in: Capsule())
                }
            }
            .padding(.horizontal)

            let heroSize = UIScreen.main.bounds.width - 32

            // Big artwork (hero)
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color(.systemGray5))
                WebImage(
                    url: bust(vm.heroURL),
                    options: [.retryFailed, .highPriority, .fromLoaderOnly] // <- no context; force network
                )
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .id("hero-\(artBust)") // force rebuild when bust changes
                

                // --- Overlay pill button ---
                let locked = vm.isReelLocked

                VStack {
                    Spacer()
                    Button {
                        guard !vm.isReelLocked else { return }
                        showReel = true // reelYear is already synced now
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: locked ? "lock.fill" : "play.fill")
                                .font(.callout.weight(.semibold))
                                .foregroundColor(.white)
                            Text(locked ? "Highlight Reel (available December 1st)" : "Highlight Reel")
                                .font(.callout.weight(.semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(Color.black.opacity(locked ? 0.08 : 0.15))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                    .accessibilityLabel(locked ? "Highlight Reel locked until year ends" : "Play highlight reel")
                    Spacer().frame(height: 0)
                }
                .offset(y: pillVerticalOffset)
            }
            .frame(width: heroSize, height: heroSize)
            .padding(.horizontal)
            .padding(.top, 4)

            // --- Replay Playlists Header ---
            Text("Replay Playlists")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            // Grid of Replay playlists
            if vm.isLoading {
                ProgressView("Loading Replay playlists...")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if vm.filteredPlaylists.isEmpty {
                Text("No Replay playlists found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                     GridItem(.flexible(), spacing: 12)],
                                     spacing: 12) {
                    ForEach(vm.filteredPlaylists, id: \.id) { pl in
                        let id = pl.id // <-- non-optional String

                        NavigationLink {
                            PlaylistDetailView(playlistId: id)
                                .environmentObject(api)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray5))
                                    WebImage(
                                        url: vm.imageURL(for: id, api: api, maxWidth: 600),
                                        options: [.retryFailed, .refreshCached, .highPriority]
                                    )
                                    .resizable()
                                    .indicator(.activity)
                                    .transition(.fade)
                                    .scaledToFill()
                                    .allowsHitTesting(false)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(height: 160)

                                Text(pl.name)
                                    .font(.subheadline.weight(.regular))
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                    .padding(.top, 6)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - ViewModel

final class ReplayViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var allReplayPlaylists: [JellyfinAlbum] = []
    @Published var filteredPlaylists: [JellyfinAlbum] = []
    @Published var availableYears: [Int] = []
    @Published var heroURL: URL? = nil
    
    private let currentYear = Calendar.current.component(.year, from: Date())
    @Published var heroYear: Int = Calendar.current.component(.year, from: Date())

    var yearsForPicker: [Int] {
        Array(Set(availableYears + [currentYear])).sorted(by: >)
    }
    
    var heroYearLabel: String { String(heroYear) }
    
    private func releaseDate(for year: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = 12
        comps.day = 1
        return Calendar.current.date(from: comps) ?? Date.distantFuture
    }

    var isReelLocked: Bool {
        Date() < releaseDate(for: heroYear)
    }
    
    private var milestonesByYear: [Int: [MilestoneKind: [Int: Date]]] = [:]

    private lazy var ymdParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var bag = Set<AnyCancellable>()

    var achievementDateProvider: (_ kind: MilestoneKind, _ threshold: Int, _ year: Int?) -> Date? = { _,_,_ in nil }

    func unlockedMilestones(for year: Int?) -> [Milestone] {
        let make: (MilestoneKind, [Int]) -> [Milestone] = { kind, thresholds in
            thresholds.compactMap { t in
                if let when = self.achievementDateProvider(kind, t, year) {
                    return Milestone(kind: kind, threshold: t, achievedOn: when)
                } else {
                    return nil
                }
            }
        }
        return
            make(.songs, SONG_THRESHOLDS) +
            make(.artists, ARTIST_THRESHOLDS) +
            make(.minutes, MINUTE_THRESHOLDS)
    }

    func load(api: JellyfinAPIService) async {
        guard !isLoading else { return }
        await MainActor.run { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }

        do {
            let pub = api.fetchPlaylistsAdvanced(sort: .dateAdded, descending: true, filter: .all, limit: 300)
            let playlists = try await pub.values.first(where: { _ in true }) ?? []

            await MainActor.run {
                self.allReplayPlaylists = playlists.filter { pl in
                    let tags = Set((pl.tags ?? []).map { $0.lowercased() })
                    return tags.contains("replay")
                }
                self.filteredPlaylists = self.allReplayPlaylists
                self.availableYears = self.extractYears(from: self.allReplayPlaylists)
                self.heroYear = self.yearsForPicker.first ?? self.currentYear
            }
        } catch {
            await MainActor.run {
                self.allReplayPlaylists = []
                self.availableYears = []
                self.heroYear = self.currentYear
                self.filteredPlaylists = []
            }
        }
    }
    
    func loadMilestonesJSON() async {
        guard let url = URL(string: "http://192.168.1.169/replay/milestones.json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let byYear: [Int: [MilestoneKind: [Int: Date]]]

            // Try primary schema first
            if let decoded = try? JSONDecoder().decode(MilestonesJSON.self, from: data) {
                var tmp: [Int: [MilestoneKind: [Int: Date]]] = [:]
                for y in decoded.years {
                    var map: [MilestoneKind: [Int: Date]] = [:]
                    for e in y.milestones {
                        guard let d = ymdParser.date(from: e.achievedOn) else { continue }
                        let kind: MilestoneKind?
                        switch e.kind.lowercased() {
                        case "songs":   kind = .songs
                        case "artists": kind = .artists
                        case "minutes": kind = .minutes
                        default:        kind = nil
                        }
                        if let k = kind {
                            var inner = map[k] ?? [:]
                            inner[e.threshold] = d
                            map[k] = inner
                        }
                    }
                    tmp[y.year] = map
                }
                byYear = tmp
            } else {
                // Fallback: your alt schema
                let alt = try JSONDecoder().decode(MilestonesJSONAlt.self, from: data)
                var tmp: [Int: [MilestoneKind: [Int: Date]]] = [:]
                for y in alt.years {
                    var map: [MilestoneKind: [Int: Date]] = [:]
                    func ingest(kind: MilestoneKind, entries: [MilestonesJSONAlt.SimpleEntry]?) {
                        guard let entries else { return }
                        var inner = map[kind] ?? [:]
                        for e in entries {
                            if let d = ymdParser.date(from: e.achievedAt) {
                                inner[e.threshold] = d
                            }
                        }
                        map[kind] = inner
                    }
                    ingest(kind: .songs,   entries: y.songs)
                    ingest(kind: .artists, entries: y.artists)
                    ingest(kind: .minutes, entries: y.minutes)
                    tmp[y.year] = map
                }
                byYear = tmp
            }

            await MainActor.run {
                self.milestonesByYear = byYear
                self.achievementDateProvider = { [weak self] kind, threshold, year in
                    guard let self, let year = year else { return nil }
                    return self.milestonesByYear[year]?[kind]?[threshold]
                }
            }
        } catch {
            #if DEBUG
            print("❌ Milestones load failed:", error)
            if let s = String(data: (try? Data(contentsOf: URL(string: "http://192.168.1.169/replay/milestones.json")!)) ?? Data(),
                                      encoding: .utf8) {
                print("Milestones payload preview:\n", s.prefix(400))
            }
            #endif
        }
    }

    func updateHero(using provider: (Int?) -> URL?) {
        heroURL = provider(heroYear)
    }

    func onTapMilestones() {}
    
    func onTapHighlightReel(heroYear: Int) {}

    func openPlaylist(_ pl: JellyfinAlbum, api: JellyfinAPIService) {}

    func imageURL(for itemId: String, api: JellyfinAPIService, maxWidth: Int = 600) -> URL? {
        guard !api.serverURL.isEmpty else { return nil }
        var c = URLComponents(string: "\(api.serverURL)Items/\(itemId)/Images/Primary")
        c?.queryItems = [
            .init(name: "maxWidth", value: "\(maxWidth)"),
            .init(name: "quality", value: "85"),
            .init(name: "format", value: "jpg"),
            .init(name: "enableImageEnhancers", value: "false"),
            .init(name: "api_key", value: api.authToken)
        ]
        return c?.url
    }

    private func extractYears(from items: [JellyfinAlbum]) -> [Int] {
        let years = items.compactMap { parseYear(from: $0) }
        return Array(Set(years)).sorted(by: >)
    }

    private func parseYear(from pl: JellyfinAlbum) -> Int? {
        if let y = pl.productionYear { return y }
        let iso = ISO8601DateFormatter()
        for s in [pl.premiereDate, pl.releaseDate, pl.dateCreated].compactMap({ $0 }) {
            if let d = iso.date(from: s) { return Calendar.current.component(.year, from: d) }
        }
        let name = pl.name
        if let match = name.range(of: #"(?<!\d)(19|20)\d{2}(?!\d)"#, options: .regularExpression) { // <-- Corrected
            return Int(name[match])
        }
        return nil
    }
}


// MARK: - Milestones

enum MilestoneKind: String, CaseIterable {
    case songs = "Songs"
    case artists = "Artists"
    case minutes = "Minutes"
}

struct Milestone: Identifiable, Hashable {
    let id = UUID()
    let kind: MilestoneKind
    let threshold: Int
    let achievedOn: Date?
    
    var assetName: String {
        switch kind {
        case .songs:   return "songs_\(threshold)"
        case .artists: return "artists_\(threshold)"
        case .minutes: return "minutes_\(threshold)"
        }
    }
    
    var displayName: String { kind.rawValue }
}

private let SONG_THRESHOLDS      = [100, 250, 500, 1_000, 2_500, 5_000, 7_500, 100_000]
private let ARTIST_THRESHOLDS    = [10, 50, 100, 250, 1_000]
private let MINUTE_THRESHOLDS    = [1_000, 5_000, 7_500, 10_000, 25_000, 100_000, 200_000]


// MARK: - Milestones Sheet

struct MilestonesSheet: View {
    let year: Int?
    let unlocked: [Milestone]
    let onClose: () -> Void
    
    private let cols = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    private var titleText: String {
        if let y = year { return "Milestones for \(y)" }
        return "Milestones"
    }
    
    private let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d") // “Apr 3”
        return f
    }()
    
    var body: some View {
        NavigationView {
            ScrollView {
                if unlocked.isEmpty {
                    Text("No milestones unlocked yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .padding()
                } else {
                    LazyVGrid(columns: cols, spacing: 18) {
                        ForEach(unlocked) { badge in
                            VStack(spacing: 8) {
                                Image(badge.assetName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 90, maxHeight: 90)
                                
                                if let when = badge.achievedOn {
                                    Text(monthDayFormatter.string(from: when))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Text(badge.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }
                        .font(.headline)
                }
            }
        }
    }
}

// MARK: - Reel Player
struct ReelPlayerView: View {
    let year: Int
    let baseURL: URL   // e.g. http://192.168.1.169/replay/reels

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 1
    @State private var player = AVPlayer()
    @State private var isAtEnd = false

    // MARK: - Build video URL
    private func clipURL(year: Int, index: Int) -> URL {
        baseURL.appendingPathComponent("\(year)/\(index).mp4")
    }

    // MARK: - Load specific index
    private func load(index newIndex: Int) {
        isAtEnd = false
        let url = clipURL(year: year, index: newIndex)

        // HEAD request to check if video exists
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                if ok {
                    self.index = newIndex
                    self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
                    self.player.play()
                } else {
                    self.isAtEnd = true
                }
            }
        }.resume()
    }

    private func advance(_ delta: Int) {
        let target = max(1, index + delta)
        load(index: target)
    }

    var body: some View {
        ZStack {
            // Video background
            VideoPlayer(player: player)
                .ignoresSafeArea()

            // Tap zones for previous / next video
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { advance(-1) }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { advance(+1) }
            }
            .allowsHitTesting(true)

            // Top-right close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        player.pause()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.8), in: Circle())
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
        .onAppear {
            // Start on first video
            load(index: 1)

            // Auto-advance when a clip finishes
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { _ in
                advance(+1)
            }
        }
        .onDisappear {
            player.pause()
        }
    }
}
