//
// NowPlayingView.swift
// JellyMuse
//
// Created by Ardit Sejdiu on 22.08.2025.
//

import SwiftUI
import MediaPlayer
import AVKit
import UIImageColors
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import MobileCoreServices
import UniformTypeIdentifiers
import AVFoundation // Added for AVPlayer

private struct VerticalAlbumGradient: View {
    let top: Color
    let bottom: Color
    let midBias: CGFloat   // 0...1; 0.5 is even

    var body: some View {
        // Implement mid-bias by using three stops (top, midpoint color mix, bottom)
        let midColor = top.gradient(to: bottom, fraction: midBias)

        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: top,      location: 0.0),
                .init(color: midColor, location: midBias),
                .init(color: bottom,   location: 1.0),
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// Little helper to mix two SwiftUI Colors in sRGB
private extension Color {
    func components() -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r,g,b,a)
        #else
        return (0,0,0,1)
        #endif
    }
    func gradient(to other: Color, fraction t: CGFloat) -> Color {
        let a = self.components(), b = other.components()
        let lerp = { (x: CGFloat, y: CGFloat) in x + (y - x) * t }
        return Color(.sRGB,
                     red:   Double(lerp(a.r, b.r)),
                     green: Double(lerp(a.g, b.g)),
                     blue:  Double(lerp(a.b, b.b)),
                     opacity: Double(lerp(a.a, b.a)))
    }
}

// Placeholder: Looping Player Helper (assuming it is defined globally or in a utility file)
func makeLoopingMutedPlayer(assetURL: URL) -> AVPlayer {
    let asset = AVURLAsset(url: assetURL, options: [
        AVURLAssetPreferPreciseDurationAndTimingKey: true,
        AVURLAssetAllowsCellularAccessKey: true,
        AVURLAssetAllowsExpensiveNetworkAccessKey: true,
        AVURLAssetAllowsConstrainedNetworkAccessKey: true
    ])
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 0.5
    let p = AVPlayer(playerItem: item)
    p.isMuted = true
    p.actionAtItemEnd = .none
    p.automaticallyWaitsToMinimizeStalling = false
    NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
    ) { _ in
        p.seek(to: .zero)
        p.play()
    }
    return p
}

// MARK: - Explicit Badge Helpers
@inline(__always)
private func trackIsExplicit(_ tags: [String]?) -> Bool {
    guard let tags else { return false }
    return tags.contains { $0.caseInsensitiveCompare("Explicit") == .orderedSame }
}

private struct InlineExplicitBadge: View {
    var body: some View {
        Text("🅴")
            .font(.system(size: 17.5).bold())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Explicit")
    }
}

// MARK: - Hero Animation AnchorKey
private struct AnchorKey: PreferenceKey {
    typealias Value = [String: Anchor<CGRect>]
    static var defaultValue: Value = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

// NEW: Hero Animation Direction
private enum HeroDirection { case toHeader, toCenter }


// MARK: - Helpers
extension UIColor {
    var hsv: (h: CGFloat, s: CGFloat, v: CGFloat, a: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return (h, s, v, a)
    }
    func with(h: CGFloat? = nil, s: CGFloat? = nil, v: CGFloat? = nil) -> UIColor {
        let p = hsv
        return UIColor(hue: h ?? p.h, saturation: s ?? p.s, brightness: v ?? p.v, alpha: p.a)
    }
    
    // Helper function used in the palette generation logic
    func adjusted(saturation s: CGFloat? = nil, brightness v: CGFloat? = nil) -> UIColor {
        let p = hsv
        return UIColor(hue: p.h, saturation: s ?? p.s, brightness: v ?? p.v, alpha: p.a)
    }
}

private extension UIImage {
    var averageColor: UIColor? {
        guard let inputImage = CIImage(image: self) else { return nil }
        let extentVector = CIVector(x: inputImage.extent.origin.x, y: inputImage.extent.origin.y, z: inputImage.extent.size.width, w: inputImage.extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]),
              let outputImage = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull!])
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return UIColor(red: CGFloat(bitmap[0]) / 255, green: CGFloat(bitmap[1]) / 255, blue: CGFloat(bitmap[2]) / 255, alpha: 1.0)
    }
}

class ColorCache {
    static let shared = ColorCache()
    private let cache = NSCache<NSString, NSArray>()
    func get(forKey key: String) -> [UIColor]? { cache.object(forKey: key as NSString) as? [UIColor] }
    func set(_ colors: [UIColor], forKey key: String) { cache.setObject(colors as NSArray, forKey: key as NSString) }
}

// MARK: - Reusable Artwork View
private struct ArtworkView: View {
    let url: URL?
    var body: some View {
        Group {
            if let url {
                ItemImage(url: url, cornerRadius: 0)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
        }
    }
}

private extension Array where Element == Color {
    func padTo4(with filler: Color) -> [Color] {
        var c = self
        while c.count < 4 { c.append(filler) }
        return Array(c.prefix(4))
    }
}

// MARK: - Unified Now Playing Header
struct UnifiedNowPlayingHeader: View {
    @ObservedObject var player: AudioPlayer
    var artworkURL: URL?
    var showHeroArtwork: Bool
    var anchorID: String
    var animationProgress: CGFloat
    
    @EnvironmentObject var contextActions: NowPlayingContextActions
    
    @State private var localFaves = Set<String>()

    private var currentID: String? { player.currentTrack?.id }
    private var isFaved: Bool { currentID.map { localFaves.contains($0) } ?? false }

    private func onFavoriteTap() {
        guard let id = currentID else { return }
        if localFaves.contains(id) { localFaves.remove(id) } else { localFaves.insert(id) }
    }
    private func createStation()  { /* TODO: hook up */ }
    private func goToAlbum()      { /* TODO: navigate */ }
    private func goToArtist()     { /* TODO: navigate */ }
    private func download()       { /* TODO: download */ }

    private var title: String { player.currentTrack?.name ?? "—" }
    private var artist: String {
        player.currentAlbumArtist ?? (player.currentTrack?.artists?.joined(separator: ", ") ?? "")
    }

    private var textAndControlsOpacity: Double {
        max(0, (animationProgress - 0.5) * 2)
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: artworkURL)
                .frame(width: 72, height: 72)
                .cornerRadius(10)
                .opacity(showHeroArtwork ? 0 : 1)
                .anchorPreference(key: AnchorKey.self, value: .bounds) { anchor in [self.anchorID: anchor] }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    if trackIsExplicit(player.currentTrack?.tags) { InlineExplicitBadge() }
                }
                
                ZStack {
                    Menu {
                        if let albumId = player.currentTrack?.albumId, !albumId.isEmpty {
                            Button("Go to Album", systemImage: "square.stack") {
                                contextActions.goToAlbum(albumId: albumId)
                            }
                        }
                        if !artist.isEmpty, let artistName = player.currentTrack?.artists?.first {
                            Button("Go to Artist", systemImage: "music.microphone") {
                                contextActions.goToArtist(artistName: artistName, artistId: nil)
                            }
                        }
                    } label: {
                        Text(artist)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .swipeToChangeTrack()
            .opacity(textAndControlsOpacity)
            
            Spacer(minLength: 12)
            
            HStack(spacing: 12) {
                Button(action: onFavoriteTap) {
                    Image(systemName: isFaved ? "star.fill" : "star")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(CircularButtonStyle(size: 28))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: isFaved) // FIX: Used 'isFaved' instead of missing 'favoriteAnimationTrigger'
                .accessibilityLabel(isFaved ? "Unfavorite" : "Favorite")
                
                ZStack {
                    Menu {
                        if let track = player.currentTrack {
                            TrackContextMenuBuilder(track: track, actions: contextActions)
                                .build()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .opacity(textAndControlsOpacity)
        }
        .padding(.horizontal, 28)
    }
}

// MARK: - Unified Controls Component
enum ControlsViewMode { case main, lyrics, queue }

private struct BottomSlab: Shape {
    var height: CGFloat
    func path(in rect: CGRect) -> Path {
        let h = min(height, rect.height)
        let r = CGRect(x: 0, y: rect.maxY - h, width: rect.width, height: h)
        return Path(r)
    }
}

struct UnifiedControlsView: View {
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject var contextActions: NowPlayingContextActions
    
    let mode: ControlsViewMode
    let visible: Bool
    let showingLyrics: Bool
    let showingQueue: Bool
    let artworkURL: URL?
    let controlsVisible: Bool
    @Binding var volume: Float
    let progressBinding: Binding<Double>
    let volumeBinding: Binding<Double>
    let onLyricsToggle: () -> Void
    let onQueueToggle: () -> Void
    let onRevealAndReschedule: () -> Void
    let hasLyricsAvailable: Bool
    let routeSymbolName: String
    let titleReveal: CGFloat
    let isFaved: Bool
    let onFavoriteTap: () -> Void
    let createStation: () -> Void
    let goToAlbum: () -> Void
    let goToArtist: () -> Void
    let download: () -> Void
    
    private let reservedTitleRowHeight: CGFloat = 56
    var badgeHeight: CGFloat = 17

    private var qualityBadgeAsset: (name: String, label: String)? {
        let tags = (player.currentTrack?.tags ?? []).map { $0.lowercased() }
        if tags.contains(where: { $0.contains("dolby") }) { return ("badge_dolby_NPV", "Dolby Atmos") }
        if tags.contains(where: { $0.contains("hires") || $0.contains("hi-res") || $0.contains("hi res") }) { return ("badge_hires_NPV", "Hi-Res Lossless") }
        if tags.contains(where: { $0.contains("lossless") }) { return ("badge_lossless_NPV", "Lossless") }
        return nil
    }

    private let panelHeight: CGFloat = 320
    private let panelSafeBottom: CGFloat = 34
    private let controlsLift: CGFloat = 60
    private var artistLabelText: String {
        player.currentAlbumArtist ?? (player.currentTrack?.artists?.joined(separator: ", ") ?? "")
    }
    
    private var contentYOffset: CGFloat { controlsLift }

    var body: some View {
        let panelAreaHeight = panelHeight + panelSafeBottom
        ZStack {
            VStack(spacing: 20) {
                ZStack {
                    Color.clear.frame(height: reservedTitleRowHeight)
                    titleAndButtonsContent
                        .opacity(titleReveal)
                        .offset(y: (1 - titleReveal) * -18)
                        .offset(y: controlsVisible ? 0 : 20)  // Faster slide
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: controlsVisible)  // Faster
                        .animation(.snappy(duration: 0.28, extraBounce: 0), value: titleReveal)
                }
                
                lowerControls
                    .offset(y: controlsVisible ? 0 : 40)  // Slower slide (more offset = slower visual speed)
                    .animation(.spring(response: 0.50, dampingFraction: 0.85), value: controlsVisible)  // Slower
            }
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 40 + panelSafeBottom)
            .frame(height: panelHeight, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: -contentYOffset)
        }
        .contentShape(BottomSlab(height: panelAreaHeight))
    }

    private var titleAndButtonsContent: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "—")
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    if trackIsExplicit(player.currentTrack?.tags) { InlineExplicitBadge() }
                }
                
                ZStack {
                    Menu {
                        if let albumId = player.currentTrack?.albumId, !albumId.isEmpty {
                            Button("Go to Album", systemImage: "square.stack") {
                                contextActions.goToAlbum(albumId: albumId)
                            }
                        }
                        if !artistLabelText.isEmpty, let artistName = player.currentTrack?.artists?.first {
                            Button("Go to Artist", systemImage: "music.microphone") {
                                contextActions.goToArtist(artistName: artistName, artistId: nil)
                            }
                        }
                    } label: {
                        Text(artistLabelText)
                            .font(.system(size: 19))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SwipeToChangeTrackModifier())
            
            Spacer(minLength: 12)
            
            HStack(spacing: 15) {
                Button(action: onFavoriteTap) {
                    Image(systemName: isFaved ? "star.fill" : "star")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(CircularButtonStyle(size: 28))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: isFaved) // FIX: Used 'isFaved' instead of missing 'favoriteAnimationTrigger'
                .accessibilityLabel(isFaved ? "Unfavorite" : "Favorite")
                
                ZStack {
                    Menu {
                        if let track = player.currentTrack {
                            TrackContextMenuBuilder(track: track, actions: contextActions)
                                .build()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
            }
            .font(.callout.weight(.semibold))
        }
        .frame(height: reservedTitleRowHeight, alignment: .center)
        .padding(.horizontal, 16)
    }

    private var lowerControls: some View {
        VStack(spacing: 20) {
            // MARK: 1. Progress Slider
            VStack(spacing: 0) {
                ElasticSlider(
                    value: progressBinding,
                    in: 0...(player.duration.isFinite && player.duration > 0 ? player.duration : 1),
                    leadingLabel: { Text(timeString(player.currentTime)).font(.caption.monospacedDigit()).padding(.top, 11) },
                    trailingLabel: { Text("-\(timeString(max(0, player.duration - player.currentTime)))").font(.caption.monospacedDigit()).padding(.top, 11) }
                )
                .sliderStyle(.playbackProgress).frame(height: 56).padding(.horizontal, 16)
                .overlay(alignment: .bottom) {
                    Group {
                        if let badge = qualityBadgeAsset {
                            Image(badge.name).resizable().scaledToFit().frame(height: badgeHeight).accessibilityLabel(Text(badge.label)).transition(.opacity)
                        }
                    }
                    .offset(y: -8)
                }
            }
            .offset(y: controlsVisible ? 0 : 30)
            .animation(
                controlsVisible
                    ? .spring(response: 0.35, dampingFraction: 0.85).delay(0.06) // MODIFIED: Tighter delay
                    : .spring(response: 0.35, dampingFraction: 0.90),      // MODIFIED: Closer duration
                value: controlsVisible
            )
            
            // MARK: 2. Transport buttons
            HStack(spacing: 48) {
                PlayerButton(label: { Image(systemName: "backward.fill").font(.system(size: 24, weight: .semibold)) }, onPressed: { onRevealAndReschedule(); AudioPlayer.shared.previousTrack() })
                PlayerButton(label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 38, weight: .regular)).contentTransition(.symbolEffect(.replace)) }, onPressed: { onRevealAndReschedule(); AudioPlayer.shared.togglePlayPause() })
                PlayerButton(label: { Image(systemName: "forward.fill").font(.system(size: 24, weight: .semibold)) }, onPressed: { onRevealAndReschedule(); AudioPlayer.shared.nextTrack() })
            }
            .playerButtonStyle(.transport).foregroundStyle(.white)
            .offset(y: controlsVisible ? 0 : 45)
            .animation(
                controlsVisible
                    ? .spring(response: 0.35, dampingFraction: 0.85).delay(0.03) // MODIFIED: Tighter delay
                    : .spring(response: 0.40, dampingFraction: 0.90),      // (This is the middle value, unchanged)
                value: controlsVisible
            )
            
            // MARK: 3. Volume slider and bottom buttons group
            VStack(spacing: 20) {
                ElasticSlider(
                    value: volumeBinding, in: 0...1,
                    leadingLabel: { Image(systemName: "speaker.fill").padding(.trailing, 10) },
                    trailingLabel: { Image(systemName: "speaker.wave.3.fill").padding(.leading, 10) }
                )
                .sliderStyle(.volume).frame(height: 50).padding(.horizontal, 16)
                
                bottomActionButtons
            }
            .padding(.top, 10)
            .offset(y: controlsVisible ? 0 : 60)
            .animation(
                controlsVisible
                    ? .spring(response: 0.35, dampingFraction: 0.85)             // (Starts first, no delay needed)
                    : .spring(response: 0.45, dampingFraction: 0.90),      // MODIFIED: Closer duration
                value: controlsVisible
            )
        }
    }
    
        // --- MINOR CHANGES HERE ---
        private var bottomActionButtons: some View {
            HStack {
                Spacer()
                Button(action: onLyricsToggle) {
                    Image(systemName: "quote.bubble")
                        .font(.title3)
                        .foregroundStyle(showingLyrics ? .black : Color.white.opacity(0.6))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(showingLyrics ? Color.white : Color.clear))
                }
                .buttonStyle(.plain)
                .disabled(!hasLyricsAvailable)
                // Removed individual .offset and .animation modifiers
                
                Spacer()
                CustomAirPlayButton(symbolName: routeSymbolName)
                    .padding(.horizontal, CGFloat(4))
                // Removed individual .offset and .animation modifiers
                
                Spacer()
                Button(action: onQueueToggle) {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(showingQueue ? .black : Color.white.opacity(0.6))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(showingQueue ? Color.white : Color.clear))
                }
                .buttonStyle(.plain)
                // Removed individual .offset and .animation modifiers
                
                Spacer()
            }.foregroundStyle(.white)
        }

        private func timeString(_ t: TimeInterval) -> String {
            guard t.isFinite && !t.isNaN && t >= 0 else { return "0:00" }
            let seconds = Int(t.rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }

// MARK: - CHANGE 1: New View for the Controls Background "Slab"
private struct ControlsSlabView: View {
    let controlsTint: Color
    let controlsSolidOpacity: Double
    let controlsQuickFadeHeight: CGFloat
    let controlsQuickFadeTopOpacity: Double
    let controlsSolidHeight: CGFloat
    let controlsChromeTransparent: Bool

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    controlsTint.opacity(controlsSolidOpacity),
                    controlsTint.opacity(controlsQuickFadeTopOpacity)
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: controlsQuickFadeHeight)

            Rectangle()
                .fill(controlsTint.opacity(controlsSolidOpacity))
                .frame(height: controlsSolidHeight)
                .ignoresSafeArea(edges: .bottom)
        }
        .frame(height: controlsQuickFadeHeight + controlsSolidHeight)
        .frame(maxHeight: .infinity, alignment: .bottom) // Stick to the bottom
        .allowsHitTesting(false)
        .opacity(controlsChromeTransparent ? 0 : 1)
    }
}


// MARK: - Main View
struct NowPlayingView: View {
    let onDismiss: () -> Void
    
    @ObservedObject private var player = AudioPlayer.shared
    @State private var volume: Float = AVAudioSession.sharedInstance().outputVolume
    
    @StateObject private var contextActions = NowPlayingContextActions()
    @EnvironmentObject var apiService: JellyfinAPIService
    
    @Environment(\.scenePhase) var scenePhase: ScenePhase
    
    @State private var localFaves = Set<String>()
    
    // MARK: - Chrome Tweaks
    private let lyricsHeaderTopInset: CGFloat = 17.5
    private let lyricsHeaderHeight: CGFloat = 170
    private let lyricsHeaderYOffset: CGFloat = -15
    private let lyricsHeaderBGHeight: CGFloat = 220
    private let lyricsHeaderBGTopOpacity: Double = 0.0
    private let lyricsHeaderBGFadeStop: CGFloat = 0.40

    private let queueHeaderTopInset: CGFloat = 2
    private let queueHeaderHeight: CGFloat = 170
    private let queueHeaderYOffset: CGFloat = -15
    private let queueHeaderBGHeight: CGFloat = 170
    private let queueHeaderBGTopOpacity: Double = 0.0
    private let queueHeaderBGFadeStop: CGFloat = 0.40

    private let controlsSolidOpacity: Double = 1.0
    private let controlsQuickFadeHeight: CGFloat = 140
    private let controlsQuickFadeTopOpacity: Double = 0.0
    private let controlsSolidHeight: CGFloat = 260
    
    private var currentID: String? { player.currentTrack?.id }
    private var isFaved: Bool { currentID.map { localFaves.contains($0) } ?? false }
    
    private func onFavoriteTap() {
        guard let id = currentID else { return }
        if localFaves.contains(id) { localFaves.remove(id) } else { localFaves.insert(id) }
    }
    private func createStation()  { /* TODO: hook up */ }
    private func goToAlbum()      { /* TODO: navigate */ }
    private func goToArtist()     { /* TODO: navigate */ }
    private func download()       { /* TODO: download */ }

    @State private var heroPosterPlayer: AVPlayer? = nil
    @State private var posterReady = false
    @State private var posterVisible = false
    private let posterFadeDuration: Double = 0.35

    @State private var albumTags: [String]? = nil
    @State private var albumPosterURL: URL? = nil
    
    @State private var viewWidth: CGFloat = 0

    @State private var showingLyrics: Bool = false
    @State private var showingQueue: Bool = false
    @State private var showingHistory: Bool = false

    @State private var controlsVisible: Bool = true
    @State private var autoHideTask: DispatchWorkItem?

    @State private var lyricsText: String? = nil
    @State private var cancellables = Set<AnyCancellable>()
    @State private var hasLyricsAvailable: Bool = false

    @State private var isLoadingAutoplay: Bool = false
    @State private var autoplayTopGap: CGFloat = -125

    @State private var isReorderingQueue: Bool = false
    @State private var queueScrollView: UIScrollView? = nil
    
    @State private var showAutoplaySection: Bool = false
    
    @State private var dismissDragOffset: CGFloat = 0
    @State private var isDismissingInteractively = false
    
    @State private var routeSymbolName: String = "airplayaudio"
    private let routeDidChange = NotificationCenter.default.publisher(
        for: AVAudioSession.routeChangeNotification
    )
    
    @State private var artworkScale: CGFloat = 1.0
    @State private var artworkShadowRadius: CGFloat = 24
    @State private var artworkShadowOpacity: CGFloat = 0.35
    @State private var artworkShadowY: CGFloat = 14
                    
    @State private var heroDirection: HeroDirection = .toHeader
    
    @State private var gradTop: Color = .black
    @State private var gradBottom: Color = .black
    @State private var baseTop: UIColor = .black
    @State private var baseBottom: UIColor = .black

    @State private var gradMidBias: CGFloat = 0.50
    
    private let pausedScale: CGFloat = 0.75
    private let playOvershootScale: CGFloat = 1.10
    
    private let heroAnimation: Animation = .interactiveSpring(response: 0.40, dampingFraction: 0.92, blendDuration: 0.12)
    
    @State private var artworkFrames: [String: Anchor<CGRect>] = [:]
    @State private var animationProgress: CGFloat = 0
    @State private var showHeroArtwork: Bool = false

    private let headerHeight: CGFloat = 280
    private let lyricsTopFadeHeight: CGFloat = 100
    private let panelHeight: CGFloat = 320
    private let panelSafeBottom: CGFloat = 34
    private let controlsLift: CGFloat = 40

    private var isEmptyState: Bool {
        player.currentTrack == nil && !player.isPlaying
    }
    
    private var hasCoverNPTag: Bool {
        guard let tags = albumTags, !tags.isEmpty else { return false }
        return tags.contains { $0.compare("covernp", options: .caseInsensitive) == .orderedSame }
    }
    
    private var hasHeroPoster: Bool { albumPosterURL != nil }
    private var isMainMode: Bool { !showingLyrics && !showingQueue }
    private var heroNearCenter: Bool { hasHeroPoster && (animationProgress < 0.08) }

    private let posterMoveY: CGFloat = -72
    private let posterScaleDrop: CGFloat = 0.05
    private var posterParallaxScale: CGFloat { 1 - posterScaleDrop * animationProgress }
    private var posterParallaxOffset: CGSize { .init(width: 0, height: posterMoveY * animationProgress) }

    // MARK: - Shared Animation Properties
    private var controlsAndSlabOpacity: Double {
        if (showingLyrics || showingQueue) && !controlsVisible {
            return 0.0
        }
        return 1.0
    }

    private var controlsAndSlabYOffset: CGFloat {
        if (showingLyrics || showingQueue) && !controlsVisible {
            return panelHeight + 100
        }
        return 0
    }
    
    private var cascadingOffset: CGFloat {
        if (showingLyrics || showingQueue) && !controlsVisible {
            return panelHeight + 100
        }
        return 0
    }

    private var artworkURL: URL? {
        if let track = player.currentTrack {
            return JellyfinAPIService.shared.imageURL(for: track.albumId ?? track.id)
        }
        return nil
    }

    private let volumeDidChange = NotificationCenter.default.publisher(for: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"))
    
    private func posterURLFrom(tags: [String]?) -> URL? {
        guard let tags, !tags.isEmpty else { return nil }
        return tags
            .compactMap { tag -> URL? in
                let s = tag.lowercased()
                guard s.hasPrefix("animatedartwork=") else { return nil }
                let raw = String(tag.split(separator: "=", maxSplits: 1).last ?? "")
                let enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
                return URL(string: enc)
            }
            .first(where: { $0.lastPathComponent.lowercased().contains("covernp.mp4") })
    }

    private func nowPlayingPosterURL() -> URL? { albumPosterURL }

    private func makeCellularOKAsset(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true
        ])
    }

    private func loadAlbumTagsIfNeeded() {
        albumTags = nil
        albumPosterURL = nil

        guard let albumId = player.currentTrack?.albumId else { return }

        JellyfinAPIService.shared.fetchItem(id: albumId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }) { item in
                self.albumTags = item.tags
                self.albumPosterURL = posterURLFrom(tags: item.tags)
                if self.albumPosterURL != nil { self.loadNowPlayingPoster() }
            }
            .store(in: &cancellables)
    }

    private func loadNowPlayingPoster() {
        posterReady = false
        posterVisible = false
        heroPosterPlayer?.pause()
        heroPosterPlayer = nil

        guard let url = nowPlayingPosterURL() else { return }

        let asset = makeCellularOKAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0.3

        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .none
        p.automaticallyWaitsToMinimizeStalling = false

        item.publisher(for: \.status).sink { status in
            if status == .readyToPlay {
                p.play()
                posterReady = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeInOut(duration: posterFadeDuration)) {
                        posterVisible = true
                    }
                }
            } else if status == .failed {
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        posterVisible = false
                    }
                }
            }
        }.store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            p.seek(to: .zero)
            p.play()
        }

        heroPosterPlayer = p
    }

    private func crossfadePoster(to visible: Bool, duration: Double? = nil) {
        withAnimation(.easeInOut(duration: duration ?? posterFadeDuration)) {
            posterVisible = visible
        }
    }
    
    private func shift(_ ui: UIColor, hue: CGFloat, sat k: CGFloat, val add: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let hh = (h + hue).truncatingRemainder(dividingBy: 1.0)
        let ss = max(0, min(1, s * k))
        let vv = max(0, min(1, v + add))
        return UIColor(hue: hh < 0 ? hh + 1 : hh, saturation: ss, brightness: vv, alpha: a)
    }

    private func colorFromHex(_ raw: String) -> Color? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }

        let chars = Array(hex.uppercased())
        let to255: (Int) -> Double = { Double($0) / 255.0 }

        func hexVal(_ c: Character) -> Int? {
            switch c {
            case "0"..."9": return Int(String(c))
            case "A"..."F": return 10 + Int(c.asciiValue! - Character("A").asciiValue!)
            default: return nil
            }
        }

        func read2(_ i: Int) -> Int? {
            guard i + 1 < chars.count, let a = hexVal(chars[i]), let b = hexVal(chars[i+1]) else { return nil }
            return a * 16 + b
        }

        switch chars.count {
        case 3:
            guard let r = hexVal(chars[0]), let g = hexVal(chars[1]), let b = hexVal(chars[2]) else { return nil }
            let rr = r * 17, gg = g * 17, bb = b * 17
            return Color(.sRGB, red: to255(rr), green: to255(gg), blue: to255(bb), opacity: 1)
        case 6:
            guard let r = read2(0), let g = read2(2), let b = read2(4) else { return nil }
            return Color(.sRGB, red: to255(r), green: to255(g), blue: to255(b), opacity: 1)
        case 8:
            guard let r = read2(0), let g = read2(2), let b = read2(4), let a = read2(6) else { return nil }
            return Color(.sRGB, red: to255(r), green: to255(g), blue: to255(b), opacity: to255(a))
        default:
            return nil
        }
    }

    private func parseGradientOverride(from tags: [String]?) -> (Color, Color)? {
        guard let tags, !tags.isEmpty else { return nil }

        let regex = try! NSRegularExpression(
            pattern: #"(?i)\bC:\s*#?([0-9a-f]{3,8})\s*&\s*#?([0-9a-f]{3,8})\b"#
        )

        for tag in tags {
            let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            if let m = regex.firstMatch(in: tag, options: [], range: range),
               let r1 = Range(m.range(at: 1), in: tag),
               let r2 = Range(m.range(at: 2), in: tag)
            {
                let h1 = String(tag[r1])
                let h2 = String(tag[r2])
                if let top = colorFromHex(h1), let bottom = colorFromHex(h2) {
                    return (top, bottom)
                }
            }
        }
        return nil
    }
    
    private func pickGradientPair(from c: UIImageColors) -> (UIColor, UIColor) {
        let primary = c.primary ?? .darkGray
        let companion = (c.background?.hsv.v ?? 0) < 0.35 ? (c.background ?? primary)
                                  : (c.detail?.hsv.v ?? 1) < 0.35 ? (c.detail ?? primary)
                                  : (c.secondary ?? primary)
        return (primary, companion)
    }

    private func updateGradient(from url: URL?) {
        if let (top, bottom) = parseGradientOverride(from: player.currentTrack?.tags) {
            gradTop = top
            gradBottom = bottom
            return
        }

        guard let url else {
            gradTop = .black
            gradBottom = .black
            return
        }
        Task.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            image.getColors(quality: .high) { colors in
                guard let colors else { return }
                let (a, b) = pickGradientPair(from: colors)
                Task { @MainActor in
                    baseTop = a
                    baseBottom = b
                    applyGradientBase(top: baseTop, bottom: baseBottom)
                }
            }
        }
    }

    @MainActor
    private func applyGradientBase(top: UIColor, bottom: UIColor) {
        gradTop = Color(top)
        gradBottom = Color(bottom)
    }
    
    private func canBeginDismiss(from value: DragGesture.Value) -> Bool {
        guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) else { return false }
        if isReorderingQueue { return false }
        if showingQueue { return isQueueAtTop() }
        return true
    }

    private func isQueueAtTop() -> Bool {
        guard let sv = queueScrollView else { return true }
        let topInset = sv.adjustedContentInset.top
        return sv.contentOffset.y <= -topInset + 0.5
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if !isDismissingInteractively {
                    if canBeginDismiss(from: value) {
                        isDismissingInteractively = true
                    } else { return }
                }
                let y = max(0, value.translation.height)
                dismissDragOffset = y * 0.95
            }
            .onEnded { value in
                guard isDismissingInteractively else { return }
                let current = dismissDragOffset
                let predicted = value.predictedEndTranslation.height
                let shouldDismiss = (current > 160) || (predicted > 240)
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    if shouldDismiss { onDismiss() }
                    dismissDragOffset = 0
                    isDismissingInteractively = false
                }
            }
    }
    
    private var mainArtworkView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            mainArtworkPlaceholder
            Spacer().frame(height: 400)
        }
        .opacity(1 - animationProgress)
        .allowsHitTesting(!(showingLyrics || showingQueue))
        .contentShape(Rectangle())
        .gesture(dismissDragGesture)
    }
    
    private var mainArtworkPlaceholder: some View {
        let side = (viewWidth > 0 ? viewWidth : UIScreen.main.bounds.width) - 52

        let squareOpacity: Double = {
            if !hasHeroPoster { return 1.0 }
            if isMainMode { return posterVisible ? 0 : 1 }
            return 1.0
        }()
        let heroOccludesSquare = showHeroArtwork || heroNearCenter

        return ArtworkView(url: artworkURL)
            .frame(width: side, height: side)
            .cornerRadius(12)
            .opacity(squareOpacity * (heroOccludesSquare ? 0 : 1))
            .allowsHitTesting(squareOpacity > 0.001 && !heroOccludesSquare)
            .scaleEffect(artworkScale)
            .shadow(color: Color.black.opacity(artworkShadowOpacity),
                    radius: artworkShadowRadius,
                    y: artworkShadowY)
            .animation(.snappy(duration: 0.28, extraBounce: 0), value: artworkScale)
            .animation(.easeInOut(duration: posterFadeDuration), value: posterVisible)
            .animation(.easeInOut(duration: 0.3), value: isMainMode)
            .zIndex(hasHeroPoster ? -1 : 0)
            .anchorPreference(key: AnchorKey.self, value: .bounds) { ["SOURCE": $0] }
    }
    
    var body: some View {
        ZStack {
            // MARK: - Layer 1: Gradient
            VerticalAlbumGradient(top: gradTop, bottom: gradBottom, midBias: 0.5)
                .opacity(hasHeroPoster && posterVisible && isMainMode ? 0 : 1)
                .animation(.easeInOut(duration: 0.3), value: isMainMode)
                .animation(.easeInOut(duration: posterFadeDuration), value: posterVisible)

            // MARK: - Layer 2: Controls Slab
            if !isEmptyState && (showingLyrics || showingQueue) {
                ControlsSlabView(
                    controlsTint: gradBottom,
                    controlsSolidOpacity: controlsSolidOpacity,
                    controlsQuickFadeHeight: controlsQuickFadeHeight,
                    controlsQuickFadeTopOpacity: controlsQuickFadeTopOpacity,
                    controlsSolidHeight: controlsSolidHeight,
                    controlsChromeTransparent: false
                )
                .ignoresSafeArea(edges: .bottom)
                .opacity(1.0) // Always fully opaque when visible in lyrics/queue mode
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: controlsVisible)
            }
            
            // MARK: - Layer 2: Poster Video
            if hasHeroPoster, let player = heroPosterPlayer {
                VideoPlayerView(
                    player: player,
                    gravity: .resizeAspectFill,
                    onReady: { Task { @MainActor in posterReady = true } },
                    onFail: { Task { @MainActor in
                        posterReady = false
                        withAnimation(.easeInOut(duration: 0.2)) { posterVisible = false }
                    }}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .scaleEffect(posterParallaxScale)
                .offset(posterParallaxOffset)
                .opacity(posterVisible && isMainMode ? 1 : 0)
                .animation(.easeInOut(duration: posterFadeDuration), value: posterVisible)
                .animation(.easeInOut(duration: 0.3), value: isMainMode)
                .animation(.easeInOut(duration: 0.35), value: animationProgress)
                .overlay(
                    Rectangle().fill(Color.black.opacity(0.18))
                        .ignoresSafeArea()
                        .opacity((posterVisible && isMainMode && !hasCoverNPTag) ? 1 : 0)
                )
            }

            // MARK: - Foreground Content & Sizing
            GeometryReader { geometry in Color.clear.onAppear { self.viewWidth = geometry.size.width } }
            VolumeControlView(volume: $volume).frame(width: 0, height: 0).hidden()
            contentBody

            // MARK: - Layer 3: Controls UI + Slab Background
            if !isEmptyState {
                ZStack(alignment: .bottom) {
                    // Slab background (renders first, behind controls)
                    if showingLyrics || showingQueue {
                        ControlsSlabView(
                            controlsTint: gradBottom,
                            controlsSolidOpacity: controlsSolidOpacity,
                            controlsQuickFadeHeight: controlsQuickFadeHeight,
                            controlsQuickFadeTopOpacity: controlsQuickFadeTopOpacity,
                            controlsSolidHeight: controlsSolidHeight,
                            controlsChromeTransparent: false
                        )
                        .opacity(1.0)
                    }
                    
                    // Controls UI (renders on top)
                    UnifiedControlsView(
                        player: player,
                        mode: showingLyrics ? .lyrics : (showingQueue ? .queue : .main),
                        visible: controlsVisible && !isReorderingQueue,
                        showingLyrics: showingLyrics,
                        showingQueue: showingQueue,
                        artworkURL: artworkURL,
                        controlsVisible: controlsVisible,
                        volume: $volume,
                        progressBinding: progressSecondsBinding,
                        volumeBinding: volumeBinding,
                        onLyricsToggle: { toggleLyrics() },
                        onQueueToggle: { toggleQueue() },
                        onRevealAndReschedule: revealControlsAndReschedule,
                        hasLyricsAvailable: hasLyricsAvailable,
                        routeSymbolName: routeSymbolName,
                        titleReveal: 1 - animationProgress,
                        isFaved: isFaved,
                        onFavoriteTap: onFavoriteTap,
                        createStation: createStation,
                        goToAlbum: goToAlbum,
                        goToArtist: goToArtist,
                        download: download
                    )
                    .offset(y: controlsAndSlabYOffset)
                    .opacity(controlsAndSlabOpacity)
                    .animation(.spring(response: 0.40, dampingFraction: 0.85), value: controlsVisible)
                    .animation(.easeInOut(duration: 0.3), value: showingLyrics)
                    .animation(.easeInOut(duration: 0.3), value: showingQueue)
                    .animation(.easeInOut(duration: 0.3), value: animationProgress)
                }
                .offset(y: controlsAndSlabYOffset)
                .animation(.spring(response: 0.40, dampingFraction: 0.85), value: controlsVisible)
            }

            // MARK: - Top Overlays
            if showingLyrics && !controlsVisible {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(height: 240)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .onTapGesture { revealControlsAndReschedule() }
                    .zIndex(60)
            }
        }
        .environmentObject(contextActions)
        .offset(y: dismissDragOffset)
        .preferredColorScheme(.dark)
        .overlayPreferenceValue(AnchorKey.self) { anchors in
            heroAnimationLayer(anchors: anchors)
                .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .onChange(of: player.currentTrack) { _, track in
            if track == nil {
                showingLyrics = false
                showingQueue  = false
                animationProgress = 0
                showHeroArtwork = false
                controlsVisible = true
                if player.upNext.isEmpty { onDismiss() }
            }
        }
        .onChange(of: player.currentTrack?.id) { _, _ in
            updateGradient(from: artworkURL)
            checkLyricsAvailability()
            if showingLyrics { loadLyrics() }
            loadAlbumTagsIfNeeded()
        }
        .onChange(of: showingLyrics) { _, isShowing in
            handleModeChange(isShowingLyrics: isShowing)
            if isShowing { heroPosterPlayer?.pause(); crossfadePoster(to: false, duration: 0.16) }
            else { heroPosterPlayer?.play(); crossfadePoster(to: true) }
        }
        .onChange(of: showingQueue) { _, isShowing in
            if !isShowing { showingHistory = false; isReorderingQueue = false; controlsVisible = true }
            if isShowing { heroPosterPlayer?.pause(); crossfadePoster(to: false, duration: 0.16) }
            else { heroPosterPlayer?.play(); crossfadePoster(to: true) }
        }
        .onChange(of: hasLyricsAvailable) { _, available in
            if showingLyrics && !available { toggleLyrics() }
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying {
                withAnimation(.easeInOut(duration: 1.0)) {
                    artworkScale = playOvershootScale
                    artworkShadowRadius = 24
                    artworkShadowOpacity = 0.35
                    artworkShadowY = 14
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeInOut(duration: 0.4)) { artworkScale = 1.0 }
                }
            } else {
                withAnimation(.easeInOut(duration: 100)) {
                    artworkScale = pausedScale
                    artworkShadowRadius = 1.0
                    artworkShadowOpacity = 0.05
                    artworkShadowY = 0.5
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: heroPosterPlayer?.play()
            case .inactive, .background: heroPosterPlayer?.pause()
            @unknown default: break
            }
        }
        .onAppear {
            volume = getSystemVolume()
            updateGradient(from: artworkURL)
            checkLyricsAvailability()
            refreshRouteSymbol()
            contextActions.onDismiss = onDismiss
            if player.isPlaying {
                artworkScale = 1.0
                artworkShadowRadius = 24
                artworkShadowOpacity = 0.35
                artworkShadowY = 14
            } else {
                artworkScale = pausedScale
                artworkShadowRadius = 1.0
                artworkShadowOpacity = 0.05
                artworkShadowY = 0.5
            }
            loadAlbumTagsIfNeeded()
        }
        .onDisappear {
            heroPosterPlayer?.pause()
            heroPosterPlayer = nil
        }
        .onReceive(volumeDidChange) { notification in
            if let newVolume = notification.userInfo?["AVSystemController_AudioVolumeNotificationParameter"] as? Float {
                self.volume = newVolume
            }
        }
        .onReceive(routeDidChange) { _ in
            refreshRouteSymbol()
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        ZStack(alignment: .top) {
            if isEmptyState {
                VStack(spacing: 12) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 56, weight: .light))
                        .opacity(0.8)
                    Text("Nothing Playing").font(.headline)
                    Text("Start a song to see it here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Close") { onDismiss() }
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                        .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .multilineTextAlignment(.center)
            } else {
                mainArtworkView
                lyricsFullScreen
                    .opacity(showingLyrics ? 1 : 0)
                    .allowsHitTesting(showingLyrics)
                queueFullScreen
                    .opacity(showingQueue ? 1 : 0)
                    .allowsHitTesting(showingQueue)
                topGrabber
            }
        }
        .frame(maxWidth: 430)
    }

    private var topGrabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.6))
            .frame(width: 60, height: 5)
            .padding(.top, 18)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
    }
    
    private var lyricsFullScreen: some View {
        let contentOpacity = max(0, (animationProgress - 0.5) * 2)

        return ZStack(alignment: .top) {
            if let lyrics = lyricsText {
                LyricsView(lyrics: lyrics, currentTime: player.currentTime, activeTopOffset: 220)
                    .safeAreaPadding(.top, 170)
                    .safeAreaPadding(.bottom, controlsVisible ? (panelHeight + panelSafeBottom + controlsLift) : 0)
                    .compositingGroup().mask(lyricsMaskView).zIndex(0)
                    .opacity(contentOpacity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(lyricsHeaderBGTopOpacity), location: 0.0),
                            .init(color: Color.black.opacity(0.0), location: max(0, min(1, lyricsHeaderBGFadeStop)))
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: lyricsHeaderBGHeight)
                    .ignoresSafeArea(edges: .top)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Color.clear.frame(height: lyricsHeaderTopInset)
                    UnifiedNowPlayingHeader(
                        player: player,
                        artworkURL: artworkURL,
                        showHeroArtwork: showHeroArtwork,
                        anchorID: "DESTINATION_LYRICS",
                        animationProgress: animationProgress
                    )
                    .frame(height: lyricsHeaderHeight)
                    .offset(y: lyricsHeaderYOffset)
                }
            }
            .frame(height: lyricsHeaderTopInset + lyricsHeaderHeight)
            .contentShape(Rectangle())
            .gesture(dismissDragGesture)
        }
    }
    
    private var queueFullScreen: some View {
        // These match your current layout
        let topInset: CGFloat = 10
        let headerHeight: CGFloat = 20
        let pillsHeight: CGFloat = 145
        let spacingBelowHeader: CGFloat = 65
        let pillsOffsetY: CGFloat = -100  // your pills row offset in FixedQueueTopChrome

        // Where header background should end (bottom of pills block after its offset)
        let cutoff = max(0, topInset + headerHeight + (pillsHeight + pillsOffsetY))

        // KNOB 1: Move the occlusion earlier (positive pushes it lower on screen)
        let cutoffNudge: CGFloat = 110   // try 16–32

        // KNOB 2: Quick fade band thickness at the bottom of the header background
        let headerQuickFadeHeight: CGFloat = 20  // try 80–140

        let chromeHeight = topInset + headerHeight + pillsHeight + spacingBelowHeader
        let contentOpacity = max(0, (animationProgress - 0.5) * 2)

        return ZStack(alignment: .top) {
            NowPlayingQueueContent(
                player: player,
                isReorderingQueue: $isReorderingQueue,
                queueScrollView: $queueScrollView,
                isLoadingAutoplay: $isLoadingAutoplay,
                showingHistory: $showingHistory,
                animationProgress: animationProgress,
                chromeHeight: chromeHeight,
                panelHeight: panelHeight,
                panelSafeBottom: panelSafeBottom,
                controlsLift: controlsLift,
                autoplayTopGap: autoplayTopGap,
                showAutoplaySection: showAutoplaySection,
                toggleAutoPlay: toggleAutoPlay
            )
            .compositingGroup()
            .mask(queueMaskView(cutoff: cutoff + cutoffNudge, fadeHeight: headerQuickFadeHeight))
            .opacity(contentOpacity)

            FixedQueueTopChrome(
                player: player,
                artworkURL: artworkURL,
                showingHistory: $showingHistory,
                showHeroArtwork: showHeroArtwork,
                animationProgress: animationProgress,
                onHistoryToggle: { withAnimation { showingHistory.toggle() } },
                autoplayOn: Binding(get: { player.autoplayEnabled }, set: { _ in }),
                onAutoplayToggle: toggleAutoPlay,
                queueHeaderTopInset: queueHeaderTopInset,
                queueHeaderHeight: queueHeaderHeight,
                queueHeaderYOffset: queueHeaderYOffset,
                queueHeaderBGHeight: cutoff + cutoffNudge,            // total header background height
                queueHeaderQuickFadeHeight: headerQuickFadeHeight,    // length of quick fade band
                queueHeaderBGTopOpacity: queueHeaderBGTopOpacity,     // opacity of the solid part
                queueHeaderBGFadeStop: queueHeaderBGFadeStop          // unused now; kept for compat
            )
            .zIndex(1)
            .gesture(dismissDragGesture)
        }
    }

    private func queueMaskView(cutoff: CGFloat, fadeHeight: CGFloat) -> some View {
        let topHiddenHeight = max(0, cutoff - fadeHeight)
        return VStack(spacing: 0) {
            // Fully hidden region (rows completely under the header)
            Color.clear.frame(height: topHiddenHeight)

            // Quick fade-out band at the bottom of the header
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fadeHeight)

            // Fully visible list below
            Rectangle().fill(Color.black)

            if !controlsVisible {
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
            }
        }
    }
    
    @ViewBuilder
    private func heroAnimationLayer(anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            let sourceAnchor = anchors["SOURCE"]
            let destAnchor = showingLyrics ? anchors["DESTINATION_LYRICS"] : anchors["DESTINATION_QUEUE"]

            if let sourceAnchor, let destAnchor {
                let sourceRect = geometry[sourceAnchor]
                let destRect = geometry[destAnchor]
                
                let scaleStart = artworkScale
                let scaledW = sourceRect.width * scaleStart
                let scaledH = sourceRect.height * scaleStart
                let dx = (scaledW - sourceRect.width) / 2
                let dy = (scaledH - sourceRect.height) / 2
                let scaledSource = CGRect(x: sourceRect.minX - dx, y: sourceRect.minY - dy, width: scaledW, height: scaledH)

                let diffSize = CGSize(width: destRect.width - scaledSource.width, height: destRect.height - scaledSource.height)
                let diffOrigin = CGPoint(x: destRect.minX - scaledSource.minX, y: destRect.minY - scaledSource.minY)
                
                let srcCorner: CGFloat = 12
                let destCorner: CGFloat = 8
                let cornerRadius = srcCorner + (destCorner - srcCorner) * animationProgress
                
                let liveCenterShadow: (opacity: CGFloat, radius: CGFloat, y: CGFloat) = (opacity: artworkShadowOpacity, radius: artworkShadowRadius, y: artworkShadowY)
                let zeroShadow: (opacity: CGFloat, radius: CGFloat, y: CGFloat) = (0, 0, 0)
                let startShadow = (heroDirection == .toHeader) ? liveCenterShadow : zeroShadow
                let endShadow = (heroDirection == .toHeader) ? zeroShadow : liveCenterShadow
                let t = animationProgress
                let sOpacity: CGFloat = max(0, lerp(startShadow.opacity, endShadow.opacity, t))
                let sRadius: CGFloat = max(0, lerp(startShadow.radius, endShadow.radius, t))
                let sY: CGFloat = lerp(startShadow.y, endShadow.y, t)
                let heroOpacity: Double = showHeroArtwork ? 1.0 : 0.0
                
                ArtworkView(url: artworkURL)
                    .frame(width: scaledSource.width + diffSize.width * animationProgress, height: scaledSource.height + diffSize.height * animationProgress)
                    .cornerRadius(cornerRadius)
                    .shadow(color: Color.black.opacity(Double(sOpacity)), radius: sRadius, y: sY)
                    .offset(x: scaledSource.minX + diffOrigin.x * animationProgress, y: scaledSource.minY + diffOrigin.y * animationProgress)
                    .opacity(heroOpacity)
                    .allowsHitTesting(false)
            }
        }
    }
    
    // MARK: - Helper Functions
    private func toggleLyrics() {
        if showingLyrics {
            heroDirection = .toCenter
            showHeroArtwork = true
            withAnimation(heroAnimation) { animationProgress = 0 }
            Task { try? await Task.sleep(for: .seconds(0.40)); showingLyrics = false; showHeroArtwork = false }
        } else {
            if showingQueue { showingQueue = false }
            heroDirection = .toHeader
            showingLyrics = true
            showHeroArtwork = true
            withAnimation(heroAnimation) { animationProgress = 1 }
            Task { try? await Task.sleep(for: .seconds(0.40)); showHeroArtwork = false }
        }
    }

    private func toggleQueue() {
        if showingQueue {
            heroDirection = .toCenter
            showHeroArtwork = true
            withAnimation(heroAnimation) { animationProgress = 0 }
            Task { try? await Task.sleep(for: .seconds(0.40)); showingQueue = false; showHeroArtwork = false }
        } else {
            if showingLyrics { showingLyrics = false }
            heroDirection = .toHeader
            showingQueue = true
            showHeroArtwork = true
            withAnimation(heroAnimation) { animationProgress = 1 }
            Task { try? await Task.sleep(for: .seconds(0.40)); showHeroArtwork = false }
        }
    }
    
    private var lyricsMaskView: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: lyricsTopFadeHeight).padding(.top, headerHeight * 0.4)
            Rectangle().fill(Color.black)
            if !controlsVisible {
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 110)
            }
        }
    }

    private func handleModeChange(isShowingLyrics: Bool) {
        if isShowingLyrics {
            isReorderingQueue = false; loadLyrics(); controlsVisible = true; scheduleAutoHide()
        } else { autoHideTask?.cancel(); controlsVisible = true }
    }
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        let task = DispatchWorkItem { controlsVisible = false }
        autoHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: task)
    }
    private func revealControlsAndReschedule() {
        if !controlsVisible { controlsVisible = true }
        if showingLyrics { scheduleAutoHide() }
    }
    
    private func refreshRouteSymbol() {
        let session = AVAudioSession.sharedInstance()
        guard let output = session.currentRoute.outputs.first else {
            routeSymbolName = "airplayaudio"; return
        }
        let name = output.portName.lowercased()
        if name.contains("airpods max") { routeSymbolName = "airpods.max"; return }
        if name.contains("airpods pro") { routeSymbolName = "airpods.pro"; return }
        if name.contains("airpods gen") { routeSymbolName = "airpods"; return }
        if name.contains("airpods") { routeSymbolName = "airpods"; return }
        if name.contains("beats") { routeSymbolName = "beats.headphones"; return }
        if name.contains("homepod") { routeSymbolName = "homepod"; return }
        if name.contains("headphone") { routeSymbolName = "headphones"; return }
        switch output.portType {
        case .airPlay: routeSymbolName = "airplayaudio"
        case .bluetoothA2DP, .bluetoothLE: routeSymbolName = "headphones"
        case .builtInSpeaker: routeSymbolName = "speaker.wave.2.fill"
        default: routeSymbolName = "airplayaudio"
        }
    }

    private func checkLyricsAvailability() {
        guard let trackId = player.currentTrack?.id else { hasLyricsAvailable = false; return }
        JellyfinAPIService.shared.fetchLyricsSmart(for: trackId)
            .map { text in guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }; return true }
            .replaceError(with: false)
            .receive(on: DispatchQueue.main)
            .sink { available in self.hasLyricsAvailable = available }
            .store(in: &cancellables)
    }

    private func loadLyrics() {
        guard let trackId = player.currentTrack?.id else { self.lyricsText = "Could not find track ID."; return }
        self.lyricsText = nil
        JellyfinAPIService.shared.fetchLyricsSmart(for: trackId)
            .receive(on: DispatchQueue.main)
            .sink { fetched in
                guard var text = fetched?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { self.lyricsText = "No lyrics available for this track."; return }
                if !(text.contains("[") && text.contains("]")) { text = "[00:00.00] \(text)" }
                self.lyricsText = text
            }.store(in: &cancellables)
    }
    private func toggleAutoPlay() {
        if player.autoplayEnabled {
            // Turning OFF: fade out first, then disable
            withAnimation(.easeOut(duration: 0.1)) {
                showAutoplaySection = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                AudioPlayer.shared.setAutoplay(enabled: false, items: [])
            }
        } else {
            // Turning ON: enable, load, then fade in
            AudioPlayer.shared.setAutoplay(enabled: true, items: [])
            loadAutoplay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.1)) {
                    showAutoplaySection = true
                }
            }
        }
    }
    
    // Add this function in NowPlayingView, after toggleAutoPlay()
    private func loadAutoplay() {
        guard let track = player.currentTrack else { return }
        isLoadingAutoplay = true
        
        func mix(for seed: String, limit: Int = 50) -> AnyPublisher<[JellyfinTrack], Never> {
            JellyfinAPIService.shared.fetchInstantMix(itemId: seed, limit: limit)
                .map { tracks in return tracks }
                .replaceError(with: [])
                .eraseToAnyPublisher()
        }
        
        let first = mix(for: track.id, limit: 60)
        let publisher: AnyPublisher<[JellyfinTrack], Never>
        
        if let albumId = track.albumId {
            publisher = first.flatMap { $0.isEmpty ? mix(for: albumId, limit: 60) : Just($0).eraseToAnyPublisher() }
                .eraseToAnyPublisher()
        } else {
            publisher = first
        }
        
        publisher
            .receive(on: DispatchQueue.main)
            .sink { tracks in
                self.isLoadingAutoplay = false
                AudioPlayer.shared.setAutoplay(enabled: AudioPlayer.shared.autoplayEnabled, items: tracks)
            }
            .store(in: &cancellables)
    }
    
    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    
    private var progressSecondsBinding: Binding<Double> {
        Binding<Double>(get: { player.currentTime }, set: { newSec in revealControlsAndReschedule(); AudioPlayer.shared.seek(to: newSec) })
    }
    private var volumeBinding: Binding<Double> {
        Binding<Double>(get: { Double(self.volume) }, set: { revealControlsAndReschedule(); self.volume = Float($0) })
    }
    private func getSystemVolume() -> Float { AVAudioSession.sharedInstance().outputVolume }
}

// MARK: - UIKit Bridges
struct VolumeControlView: UIViewRepresentable {
    @Binding var volume: Float
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero); volumeView.showsRouteButton = false; return volumeView
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if let slider = uiView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            if abs(slider.value - volume) > 0.01 { slider.setValue(volume, animated: true) }
        }
    }
}

struct CustomAirPlayButton: View {
    var symbolName: String = "airplayaudio"

    private var safeSymbolName: String {
        if UIImage(systemName: symbolName) != nil { return symbolName }
        return "airplayaudio"
    }

    var body: some View {
        Button(action: {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                let routePicker = AVRoutePickerView(frame: .zero)
                routePicker.isHidden = true
                keyWindow.addSubview(routePicker)
                if let button = routePicker.subviews.first(where: { $0 is UIButton }) as? UIButton {
                    button.sendActions(for: .touchUpInside)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    routePicker.removeFromSuperview()
                }
            }
        }) {
            Image(systemName: safeSymbolName)
                .font(.title3) // <-- MODIFIED: Smaller icon
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 38, height: 38) // <-- MODIFIED: Smaller frame
        }
    }
}

// MARK: - Queue Views
private struct FixedQueueTopChrome: View {
    @ObservedObject var player: AudioPlayer
    let artworkURL: URL?
    @Binding var showingHistory: Bool
    var showHeroArtwork: Bool
    var animationProgress: CGFloat
    let onHistoryToggle: () -> Void
    @Binding var autoplayOn: Bool
    let onAutoplayToggle: () -> Void

    let queueHeaderTopInset: CGFloat
    let queueHeaderHeight: CGFloat
    let queueHeaderYOffset: CGFloat

    // Header background geometry + tuning
    let queueHeaderBGHeight: CGFloat              // total height (solid + fade)
    let queueHeaderQuickFadeHeight: CGFloat       // quick fade band at the bottom
    let queueHeaderBGTopOpacity: Double           // opacity of solid portion
    let queueHeaderBGFadeStop: CGFloat            // (kept for compatibility; unused)

    var body: some View {
        ZStack(alignment: .top) {
            // BACKGROUND: solid + quick fade at bottom
            VStack(spacing: 0) {
                // Solid region (fills from top down to start of fade)
                Rectangle()
                    .fill(Color.black.opacity(queueHeaderBGTopOpacity))
                    .frame(height: max(0, queueHeaderBGHeight - queueHeaderQuickFadeHeight))

                // Quick fade band to transparent at the bottom edge of the header
                LinearGradient(
                    colors: [
                        Color.black.opacity(queueHeaderBGTopOpacity),
                        Color.black.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: queueHeaderQuickFadeHeight)

                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            // CONTENT (unchanged)
            VStack(spacing: 0) {
                Color.clear.frame(height: queueHeaderTopInset)
                UnifiedNowPlayingHeader(
                    player: player,
                    artworkURL: artworkURL,
                    showHeroArtwork: showHeroArtwork,
                    anchorID: "DESTINATION_QUEUE",
                    animationProgress: animationProgress
                )
                .frame(height: queueHeaderHeight)
                .offset(y: queueHeaderYOffset)

                HStack {
                    Spacer(); QuickActionPillToggle(system: "clock", isOn: $showingHistory, action: onHistoryToggle); Spacer()
                    ShufflePill(player: player); Spacer(); RepeatPill(player: player); Spacer()
                    QuickActionPillToggle(system: "infinity", isOn: $autoplayOn, action: onAutoplayToggle); Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 145)
                .offset(y: -100)

                Color.clear.frame(height: 110)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
    
    private struct QuickActionPillToggle: View {
        let system: String; @Binding var isOn: Bool; var action: () -> Void
        var body: some View {
            Button(action: action) {
                Image(systemName: system).font(.system(size: 16, weight: .medium)).foregroundStyle(isOn ? .black : .white)
                    .frame(width: 72, height: 36).background(Capsule().fill(isOn ? Color.white : Color.white.opacity(0.25)))
                    .animation(.none, value: isOn)
            }.buttonStyle(PillButtonStyle())
        }
    }
    
    private struct ShufflePill: View {
        @ObservedObject var player: AudioPlayer
        private var isActive: Bool { player.shuffleEnabled }
        private var iconName: String { player.shuffleEnabled ? "shuffle" : "shuffle" } // Using simple shuffle for now
        var body: some View {
            Button { AudioPlayer.shared.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.system(size: 16, weight: .medium)).foregroundStyle(player.shuffleEnabled ? .black : .white)
                    .frame(width: 72, height: 36).background(Capsule().fill(player.shuffleEnabled ? Color.white : Color.white.opacity(0.25)))
                    .animation(.none, value: player.shuffleEnabled)
            }.buttonStyle(PillButtonStyle())
        }
    }
    
    private struct RepeatPill: View {
        @ObservedObject var player: AudioPlayer
        private var isActive: Bool { player.repeatMode != .off }
        private var iconName: String { player.repeatMode == .one ? "repeat.1" : "repeat" }
        var body: some View {
            Button { _ = AudioPlayer.shared.cycleRepeatMode() } label: {
                Image(systemName: iconName).font(.system(size: 16, weight: .medium)).foregroundStyle(isActive ? .black : .white)
                    .frame(width: 72, height: 36).background(Capsule().fill(isActive ? Color.white : Color.white.opacity(0.25)))
                    .animation(.none, value: player.repeatMode)
            }.buttonStyle(PillButtonStyle())
        }
    }
}
