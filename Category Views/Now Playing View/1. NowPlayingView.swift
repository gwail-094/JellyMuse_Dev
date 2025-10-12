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


// MARK: - Swipe To Change Track Helpers

private enum SwipeDirection { case left, right }

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound).self
    }
}

private struct SwipeToChangeTrackModifier: ViewModifier {
    @ObservedObject private var audioPlayer = AudioPlayer.shared

    // State for animations
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var viewScale: CGFloat = 1.0
    @State private var viewOpacity: Double = 1.0
    @State private var lastSwipeDirection: SwipeDirection? = nil

    // Animation constants
    private let swipeThreshold: CGFloat = 80
    private let maxVisualDrag: CGFloat = 100
    private let springResponse: Double = 0.32
    private let springDamping: Double = 0.85

    func body(content: Content) -> some View {
        let contentKey = audioPlayer.currentTrack?.id ?? "none"

        let moveTransition: AnyTransition = .asymmetric(
            insertion: .move(edge: (lastSwipeDirection == .left) ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: (lastSwipeDirection == .left) ? .leading : .trailing).combined(with: .opacity)
        )

        // The gradient mask that appears during the drag
        let fadeMask = HStack(spacing: 0) {
            LinearGradient(gradient: Gradient(colors: [.clear, .black]), startPoint: .leading, endPoint: .trailing)
                .frame(width: 30) // Fade width on the left (for artwork)
            Rectangle().fill(Color.black) // Solid (visible) center
            LinearGradient(gradient: Gradient(colors: [.black, .clear]), startPoint: .leading, endPoint: .trailing)
                .frame(width: 60) // Wider fade on the right (for buttons)
        }

        content
            .id(contentKey)
            .offset(x: dragOffset)
            .scaleEffect(viewScale)
            .opacity(viewOpacity)
            .transition(moveTransition)
            .animation(.spring(response: springResponse, dampingFraction: springDamping), value: contentKey)
            .mask {
                // Only apply the fade mask when the user is dragging
                if isDragging {
                    fadeMask
                } else {
                    Rectangle().fill(Color.black)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isDragging) // Animate the mask's appearance
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        if !isDragging { isDragging = true }

                        let rawDx = value.translation.width
                        dragOffset = rawDx.clamped(to: -maxVisualDrag...maxVisualDrag)
                        
                        let dragProgress = min(abs(rawDx) / swipeThreshold, 1.0)
                        viewScale = 1.0 - (dragProgress * 0.05)
                        viewOpacity = 1.0 - (dragProgress * 0.3)
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let velocity = value.velocity.width
                        
                        isDragging = false
                        withAnimation(.spring(response: springResponse, dampingFraction: springDamping)) {
                            dragOffset = 0
                            viewScale = 1.0
                            viewOpacity = 1.0
                        }
                        
                        let didSwipe = abs(dx) > swipeThreshold || abs(velocity) > 300
                        guard didSwipe else { return }

                        if dx < 0 { // Swiped left
                            lastSwipeDirection = .left
                            audioPlayer.nextTrack()
                        } else { // Swiped right
                            lastSwipeDirection = .right
                            audioPlayer.previousTrack()
                        }
                    }
            )
    }
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

// MARK: - Static Background View
private struct StaticGradientBackground: View {
    let colors: [Color]

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                MeshGradient(
                    width: 2,
                    height: 2,
                    points: [
                        .init(x: 0.0, y: 0.0),
                        .init(x: 1.0, y: 0.0),
                        .init(x: 0.0, y: 1.0),
                        .init(x: 1.0, y: 1.0)
                    ],
                    colors: Array(colors.prefix(4)).padTo4(with: .black)
                )
                .ignoresSafeArea()
            } else {
                LinearGradient(
                    gradient: Gradient(colors: Array(colors.prefix(4))),
                    startPoint: .bottom,
                    endPoint: .top
                )
                .ignoresSafeArea()
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
                        if let albumName = player.currentAlbumArtist, !albumName.isEmpty {
                            Button("Go to Album", systemImage: "square.stack") { goToAlbum() }
                        }
                        if !artist.isEmpty {
                            Button("Go to Artist", systemImage: "music.microphone") { goToArtist() }
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
            .modifier(SwipeToChangeTrackModifier())
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
                        Button("Create Station", systemImage: "dot.radiowaves.left.and.right") { createStation() }
                        Button("Go to Album", systemImage: "square.stack") { goToAlbum() }
                        Button("Go to Artist", systemImage: "person.crop.square") { goToArtist() }
                        Divider()
                        Button(isFaved ? "Unfavorite" : "Favorite", systemImage: isFaved ? "star.slash" : "star") { onFavoriteTap() }
                        Button("Download", systemImage: "arrow.down.circle") { download() }
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
    
    @State private var nextButtonScale: CGFloat = 1.0
    @State private var previousButtonScale: CGFloat = 1.0
    
    let mode: ControlsViewMode
    let visible: Bool
    let showingLyrics: Bool
    let showingQueue: Bool
    let backgroundColors: [Color]
    @Binding var volume: Float
    let progressBinding: Binding<Double>
    let volumeBinding: Binding<Double>
    let onLyricsToggle: () -> Void
    let onQueueToggle: () -> Void
    let onRevealAndReschedule: () -> Void
    let hasLyricsAvailable: Bool
    let routeSymbolName: String
    let titleReveal: CGFloat
    let chromeOpacity: Double
    let isFaved: Bool
    let onFavoriteTap: () -> Void
    let createStation: () -> Void
    let goToAlbum: () -> Void
    let goToArtist: () -> Void
    // REMOVED: favoriteAnimationTrigger parameter
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
    private let panelBackgroundVerticalOffset: CGFloat = 50
    private let controlsLift: CGFloat = 60
    private var artistLabelText: String {
        player.currentAlbumArtist ?? (player.currentTrack?.artists?.joined(separator: ", ") ?? "")
    }
    private var needsBackground: Bool { mode == .lyrics || mode == .queue }
    private var contentYOffset: CGFloat { controlsLift }
    private var yOffset: CGFloat {
        switch mode {
        case .main:     return 0
        case .lyrics: return visible ? 0 : (panelHeight + 100)
        case .queue:    return visible ? 0 : (panelHeight + 100)
        }
    }
    private var opacity: Double {
        switch mode {
        case .main:     return 1.0
        case .lyrics: return visible ? 1.0 : 0.0
        case .queue:    return visible ? 1.0 : 0.0
        }
    }

    var body: some View {
        let panelAreaHeight = panelHeight + panelSafeBottom
        ZStack {
            if needsBackground { panelBackground(panelAreaHeight: panelAreaHeight) }
            VStack(spacing: 20) {
                ZStack {
                    Color.clear.frame(height: reservedTitleRowHeight)
                    titleAndButtonsContent
                        .opacity(titleReveal)
                        .offset(y: (1 - titleReveal) * -18)
                        .animation(.snappy(duration: 0.28, extraBounce: 0), value: titleReveal)
                }
                lowerControls
            }
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 40 + panelSafeBottom)
            .frame(height: panelHeight, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: -contentYOffset)
        }
        .contentShape(BottomSlab(height: panelAreaHeight))
        .zIndex(50)
        .offset(y: yOffset)
        .opacity(opacity)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: visible)
    }

    private func panelBackground(panelAreaHeight: CGFloat) -> some View {
        let gradient = LinearGradient(gradient: Gradient(colors: backgroundColors), startPoint: .bottom, endPoint: .top)
        return gradient
            .opacity(chromeOpacity)
            .overlay(.ultraThinMaterial.opacity(0.25 * chromeOpacity))
            .mask {
                VStack(spacing: 0) {
                    Spacer()
                    LinearGradient(stops: [.init(color: .black, location: 0.0), .init(color: .black, location: 0.75), .init(color: .clear, location: 1.0)], startPoint: .bottom, endPoint: .top)
                        .frame(height: panelAreaHeight + panelBackgroundVerticalOffset)
                }.ignoresSafeArea()
            }.allowsHitTesting(false)
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
                        if let albumName = player.currentAlbumArtist, !albumName.isEmpty {
                            Button("Go to Album", systemImage: "square.stack") { goToAlbum() }
                        }
                        if !artistLabelText.isEmpty {
                            Button("Go to Artist", systemImage: "music.microphone") { goToArtist() }
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
                        Button("Create Station", systemImage: "dot.radiowaves.left.and.right") { createStation() }
                        Button("Go to Album", systemImage: "square.stack") { goToAlbum() }
                        Button("Go to Artist", systemImage: "person.crop.square") { goToArtist() }
                        Divider()
                        Button(isFaved ? "Unfavorite" : "Favorite", systemImage: isFaved ? "star.slash" : "star") { onFavoriteTap() }
                        Button("Download", systemImage: "arrow.down.circle") { download() }
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
            // MARK: EDIT 3 - START
            VStack(spacing: 0) {
                // Elastic progress slider with built-in time labels
                ElasticSlider(
                    value: progressBinding,
                    in: 0...(player.duration.isFinite && player.duration > 0 ? player.duration : 1),
                    leadingLabel: {
                        Text(timeString(player.currentTime))
                            .font(.caption.monospacedDigit())
                            .padding(.top, 11)
                    },
                    trailingLabel: {
                        Text("-\(timeString(max(0, player.duration - player.currentTime)))")
                            .font(.caption.monospacedDigit())
                            .padding(.top, 11)
                    }
                )
                .sliderStyle(.playbackProgress)
                .frame(height: 56)
                .padding(.horizontal, 16)
                // quality badge centered, sitting just under the track
                .overlay(alignment: .bottom) {
                    Group {
                        if let badge = qualityBadgeAsset {
                            Image(badge.name)
                                .resizable()
                                .scaledToFit()
                                .frame(height: badgeHeight)
                                .accessibilityLabel(Text(badge.label))
                                .transition(.opacity)
                        }
                    }
                    .offset(y: -8)
                }
            }
            // MARK: EDIT 3 - END
            
            // Transport
            HStack(spacing: 48) {
                PlayerButton(
                    label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 24, weight: .semibold))
                    },
                    onPressed: { onRevealAndReschedule(); AudioPlayer.shared.previousTrack() }
                )

                PlayerButton(
                    label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 38, weight: .regular))
                            .contentTransition(.symbolEffect(.replace))
                    },
                    onPressed: { onRevealAndReschedule(); AudioPlayer.shared.togglePlayPause() }
                )

                PlayerButton(
                    label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 24, weight: .semibold))
                    },
                    onPressed: { onRevealAndReschedule(); AudioPlayer.shared.nextTrack() }
                )
            }
            .playerButtonStyle(.transport)      // ⬅️ apply the shared look
            .foregroundStyle(.white)

            VStack(spacing: 20) {
                // MARK: EDIT 4 - START
                ElasticSlider(
                    value: volumeBinding,
                    in: 0...1,
                    leadingLabel: {
                        Image(systemName: "speaker.fill")
                            .padding(.trailing, 10)
                    },
                    trailingLabel: {
                        Image(systemName: "speaker.wave.3.fill")
                            .padding(.leading, 10)
                    }
                )
                .sliderStyle(.volume)
                .frame(height: 50)
                .padding(.horizontal, 16)
                // MARK: EDIT 4 - END
                bottomActionButtons
            }.padding(.top, 10)
        }
    }

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
            Spacer()
            CustomAirPlayButton(symbolName: routeSymbolName)
                .padding(.horizontal, CGFloat(4))
            Spacer()
            Button(action: onQueueToggle) {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(showingQueue ? .black : Color.white.opacity(0.6))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(showingQueue ? Color.white : Color.clear))
            }
            .buttonStyle(.plain)
            Spacer()
        }.foregroundStyle(.white)
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite && !t.isNaN && t >= 0 else { return "0:00" }
        let seconds = Int(t.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}


// MARK: - Main View
struct NowPlayingView: View {
    let onDismiss: () -> Void
    
    @ObservedObject private var player = AudioPlayer.shared
    @State private var volume: Float = AVAudioSession.sharedInstance().outputVolume
    
    // FIX: Added missing environment for scene phase
    @Environment(\.scenePhase) var scenePhase: ScenePhase
    
    // START: Edits for 4 & 5 (local favorite state)
    @State private var localFaves = Set<String>()
    
    private var currentID: String? { player.currentTrack?.id }
    private var isFaved: Bool { currentID.map { localFaves.contains($0) } ?? false }
    
    private func onFavoriteTap() {
        guard let id = currentID else { return }
        if localFaves.contains(id) { localFaves.remove(id) } else { localFaves.insert(id) }
        // TODO: replace with real API call later
    }
    private func createStation()  { /* TODO: hook up */ }
    private func goToAlbum()      { /* TODO: navigate */ }
    private func goToArtist()     { /* TODO: navigate */ }
    private func download()       { /* TODO: download */ }
    // END: Edits for 4 & 5

    @State private var viewWidth: CGFloat = 0
    @State private var backgroundColors: [Color] = [Color(uiColor: .darkGray), Color(uiColor: .black)]
    @State private var vibrantBaseColor: UIColor = .systemPurple

    @State private var showingLyrics: Bool = false
    @State private var showingQueue: Bool = false
    @State private var showingHistory: Bool = false

    @State private var controlsVisible: Bool = true
    @State private var autoHideTask: DispatchWorkItem?

    @State private var lyricsText: String? = nil
    @State private var cancellables = Set<AnyCancellable>()
    @State private var hasLyricsAvailable: Bool = false

    @State private var isLoadingAutoplay: Bool = false
    @State private var autoplayTopGap: CGFloat = 12

    @State private var isReorderingQueue: Bool = false
    @State private var queueScrollView: UIScrollView? = nil

    @State private var dismissDragOffset: CGFloat = 0
    @State private var isDismissingInteractively = false
    
    @State private var routeSymbolName: String = "airplayaudio" // default/fallback
    private let routeDidChange = NotificationCenter.default.publisher(
        for: AVAudioSession.routeChangeNotification
    )
    
    @State private var artworkScale: CGFloat = 1.0
    @State private var artworkShadowRadius: CGFloat = 24
    @State private var artworkShadowOpacity: CGFloat = 0.35
    @State private var artworkShadowY: CGFloat = 14
    
    // NEW: Track the direction of the hero animation
    @State private var heroDirection: HeroDirection = .toHeader
    
    // MARK: - Poster state (Full Screen Video)
    @State private var heroPosterPlayer: AVPlayer? = nil
    @State private var posterReady = false // Renamed from videoReadyPoster
    private var isMainMode: Bool { !showingLyrics && !showingQueue }
    
    // NEW: Hide the big square whenever the hero is on top of it (±a small threshold)
    // FIX: Only apply the hiding logic if a hero poster exists, preventing black screen fallback.
    private var heroNearCenter: Bool {
        hasHeroPoster && (animationProgress < 0.08)
    }

    // NEW: Dynamic opacity for the moving square based on direction
    private var heroArtworkOpacity: Double {
        switch heroDirection {
        case .toHeader:
            // FIXED (5): Faster fade-in (0→1 over ~18% of the motion)
            return Double(min(1, max(0, animationProgress / 0.18))) // was 0.25
        case .toCenter:
            // Slight fade-out *during* the slide back (ends around ~65% opacity)
            // animationProgress goes 1→0 while closing, so tie it to that:
            return Double(animationProgress)
        }
    }
    
    @State private var posterVisible = false
    private let posterFadeDuration: Double = 0.35
    
    @State private var bgBlend: CGFloat = 0 // 0 = covernp only, 1 = mesh/chrome only
    private var meshOpacity: Double      { Double(bgBlend) }
    private var posterBlendOpacity: Double { Double(1 - bgBlend) }   // used for video layer
    private var chromeOpacity: Double { Double(bgBlend) }           // used by header + controls backgrounds
    
    private let pausedScale: CGFloat = 0.75
    private let playOvershootScale: CGFloat = 1.1

    // How much the poster should "track" the hero slide (tweak to taste)
    private let posterMoveY: CGFloat = -72   // FIXED: was -90
    private let posterScaleDrop: CGFloat = 0.05 // FIXED: was 0.06

    private var posterParallaxScale: CGFloat {
        // When opening (toHeader), animationProgress 0→1: scale 1 → (1 - posterScaleDrop)
        // When closing (toCenter), animationProgress 1→0 goes back the other way.
        1 - posterScaleDrop * animationProgress
    }

    private var posterParallaxOffset: CGSize {
        // Simple, convincing parallax: drift upward as the square flies toward the header.
        .init(width: 0, height: posterMoveY * animationProgress)
    }

    private let heroAnimation: Animation = .interactiveSpring(response: 0.40, dampingFraction: 0.92, blendDuration: 0.12) // FIXED: Tighter spring
    
    // MARK: - Hero Animation Properties
    @State private var artworkFrames: [String: Anchor<CGRect>] = [:]
    @State private var animationProgress: CGFloat = 0
    @State private var showHeroArtwork: Bool = false
    
    // START: Step 1 - Compute once, gate everything (NEW STATE)
    @State private var albumTags: [String]? = nil // NEW
    @State private var albumPosterURL: URL? = nil // NEW
    
    private var hasHeroPoster: Bool { albumPosterURL != nil } // NEW
    // END: Step 1 - Compute once, gate everything

    private let headerHeight: CGFloat = 115
    private let lyricsTopFadeHeight: CGFloat = 120
    private let panelHeight: CGFloat = 320
    private let panelSafeBottom: CGFloat = 34
    private let controlsLift: CGFloat = 40

    // NEW: Computed property for empty state
    private var isEmptyState: Bool {
        player.currentTrack == nil && !player.isPlaying
    }

    private var artworkURL: URL? {
        if let track = player.currentTrack {
            return JellyfinAPIService.shared.imageURL(for: track.albumId ?? track.id)
        }
        return nil
    }
    
    // REMOVED: Old hasHeroPoster (replaced by new one that checks albumPosterURL)
    // REMOVED: Old shouldShowSquare property

    // MARK: - Poster Logic Helpers
    
    // NEW: Step 1 - Album-only poster URL resolver (no track fallback)
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

    // MODIFIED: Step 2 - Use the new state variable as the source of truth
    private func nowPlayingPosterURL() -> URL? { albumPosterURL }

    private func makeCellularOKAsset(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true
        ])
    }
    
    // NEW: Step 2 - Load album tags and decide on poster mode
    private func loadAlbumTagsIfNeeded() {
        albumTags = nil
        albumPosterURL = nil

        guard let albumId = player.currentTrack?.albumId else {
            // No album ⇒ no poster mode
            disablePosterModeInstant()
            return
        }

        JellyfinAPIService.shared.fetchItem(id: albumId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }) { item in
                self.albumTags = item.tags
                self.albumPosterURL = posterURLFrom(tags: item.tags)

                if self.albumPosterURL != nil {
                    // Enable poster path
                    self.loadNowPlayingPoster()
                } else {
                    // Hard fallback to classic UI (no fades)
                    self.disablePosterModeInstant()
                }
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

        // When ready: play → mark ready
        item.publisher(for: \.status).sink { status in
            if status == .readyToPlay {
                p.play()
                posterReady = true
                // NEW: kick off the crossfade (with optional delay)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { // <-- Optional delay
                    withAnimation(.easeInOut(duration: posterFadeDuration)) {
                        posterVisible = true
                    }
                }
            }
            // NEW: If loading fails, ensure poster stays hidden
            else if status == .failed {
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        posterVisible = false
                    }
                }
            }
        }.store(in: &cancellables)

        // Loop mechanism
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
    
    // Clamp 0…1
    @inline(__always)
    private func clamp01(_ t: CGFloat) -> CGFloat { max(0, min(1, t)) }

    // Smooth ease (cosine) so fade doesn’t feel linear/clunky
    @inline(__always)
    private func ease(_ t: CGFloat) -> CGFloat {
        let x = clamp01(t)
        return (1 - cos(.pi * x)) * 0.5
    }

    // Direction-aware easing (opening should ease-out; closing ease-in)
    private func easedProgress() -> CGFloat {
        switch heroDirection {
        case .toHeader: return ease(animationProgress)      // 0→1 ease-out feel
        case .toCenter: return 1 - ease(1 - animationProgress) // 1→0 ease-in feel
        }
    }

    // How much we want the *poster* visible vs the *gradient* during the slide
    // 1 → poster fully visible, 0 → poster fully hidden (gradient fully visible)
    private var posterBlend: CGFloat {
        guard hasHeroPoster else { return 0 } // if no video, show gradient
        // While opening (toHeader): 0→1 progress → fade poster OUT
        // While closing (toCenter): 1→0         → fade poster IN
        // This is symmetrical because you’re animating animationProgress both ways.
        return 1 - easedProgress() // ⬅️ Use easedProgress here
    }

    // Final layer opacities
    private var posterCompositeOpacity: Double {
        (posterVisible ? Double(posterBlend) : 0.0)
    }
    private var backgroundCompositeOpacity: Double {
        1.0 - posterCompositeOpacity
    }
            
    // NEW: Crossfade helper using easeInOut for smooth opacity transitions
    private func crossfadePoster(to visible: Bool, duration: Double? = nil) {
        withAnimation(.easeInOut(duration: duration ?? posterFadeDuration)) {
            posterVisible = visible
        }
    }

    private let volumeDidChange = NotificationCenter.default.publisher(for: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"))
    private var headerFadeTopColor: Color { backgroundColors.last ?? .black }
    
    // Step 2: Extract complex LinearGradient to a computed property
    private var headerFade: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: headerFadeTopColor.opacity(0.95), location: 0.00),
                .init(color: headerFadeTopColor.opacity(0.70), location: 0.65),
                .init(color: .clear,                                     location: 1.00)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    // NEW: Step 2 - Instantly fall back to classic UI (no fades, reset flags)
    private func disablePosterModeInstant() {
        posterVisible = false
        heroPosterPlayer?.pause()
        heroPosterPlayer = nil
        bgBlend = 0         // mesh visible on main
        showHeroArtwork = false
        animationProgress = 0   // ensure the big square is fully visible
    }
    
    // NEW: Step 4 - Centralize the chrome blend with instant change if no poster
    private func setChromeBlend(open: Bool) {
        if hasHeroPoster {
            withAnimation(.easeInOut(duration: 0.22)) { bgBlend = open ? 1 : 0 }
        } else {
            bgBlend = open ? 1 : 0
        }
    }


    // Base gradient/color for the entire view (used when no mesh is active)
    private var baseBackgroundLayer: some View {
        LinearGradient(gradient: Gradient(colors: backgroundColors), startPoint: .bottom, endPoint: .top)
            .ignoresSafeArea()
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
            // The grabber is no longer here.
            Spacer(minLength: 40)
            mainArtworkPlaceholder
            Spacer().frame(height: 400)
        }
        .opacity(1 - animationProgress)
        .allowsHitTesting(!(showingLyrics || showingQueue))
        .contentShape(Rectangle())
        .gesture(dismissDragGesture)
    }
    
    // MARK: - A. Make the square static (no video)
    // 3) Apply to the square artwork (center)
    private var mainArtworkPlaceholder: some View {
        let side = (viewWidth > 0 ? viewWidth : UIScreen.main.bounds.width) - 52

        // MODIFIED: Step 3 - Updated squareOpacity calculation
        let squareOpacity: Double = {
            if !hasHeroPoster { return 1.0 }               // always show classic art
            if isMainMode { return posterVisible ? 0.0 : 1.0 } // fade only when poster is up
            return 1.0
        }()
        
        return ArtworkView(url: artworkURL)
            .frame(width: side, height: side)
            .cornerRadius(12)
            // MODIFIED: Use the new squareOpacity logic
            .opacity(squareOpacity * ((showHeroArtwork || heroNearCenter) ? 0 : 1))
            .allowsHitTesting(squareOpacity > 0.001 && !(showHeroArtwork || heroNearCenter)) // FIXED: Prevent hits when near center/hidden
            .scaleEffect(artworkScale)
            .shadow(color: Color.black.opacity(artworkShadowOpacity),
                    radius: artworkShadowRadius,
                    y: artworkShadowY)
            .animation(.snappy(duration: 0.28, extraBounce: 0), value: artworkScale)
            .animation(.easeInOut(duration: posterFadeDuration), value: posterVisible) // ⬅️ NEW: fade-out with poster
            .anchorPreference(key: AnchorKey.self, value: .bounds) { ["SOURCE": $0] }
    }
    
    // 🟢 FIX: Extracted video layer to solve compiler timeout and cropping issue
    private var fullScreenPosterLayer: some View {
        Group {
            if let player = heroPosterPlayer {
                VideoPlayerView(
                    player: player,
                    gravity: .resizeAspectFill,
                    onReady: {
                        Task { @MainActor in posterReady = true } // FIXED: MainActor check
                    },
                    onFail: {
                        Task { @MainActor in // FIXED: MainActor check
                            posterReady = false
                            withAnimation(.easeInOut(duration: 0.2)) {
                                posterVisible = false
                            }
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .scaleEffect(posterParallaxScale)
                .offset(posterParallaxOffset)
                .animation(.easeInOut(duration: 0.35), value: animationProgress)
                // ⛔️ no .opacity here anymore — it's controlled outside
            }
        }
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in Color.clear.onAppear { self.viewWidth = geometry.size.width } }

            // MODIFIED: Step 3 - Updated background ZStack
            ZStack {
                // Mesh background always there
                StaticGradientBackground(colors: backgroundColors)
                    .opacity(hasHeroPoster ? meshOpacity : 1) // fully visible if no poster

                // Poster only when available
                if hasHeroPoster, heroPosterPlayer != nil {
                    fullScreenPosterLayer
                        .opacity(posterVisible ? posterBlendOpacity : 0)
                }
            }
            .id(player.currentTrack?.id)
            .offset(y: -dismissDragOffset) // <-- Offset the background layer
            
            VolumeControlView(volume: $volume).frame(width: 0, height: 0).hidden()

            // FIX: Extracted complex view to a computed property to help the compiler
            contentBody
            
            // Controls are now conditional on empty state
            if !isEmptyState {
                UnifiedControlsView(
                    player: player,
                    mode: showingLyrics ? .lyrics : (showingQueue ? .queue : .main),
                    visible: controlsVisible && !isReorderingQueue,
                    showingLyrics: showingLyrics,
                    showingQueue: showingQueue,
                    backgroundColors: backgroundColors,
                    volume: $volume,
                    // MARK: EDIT 2 - START
                    progressBinding: progressSecondsBinding,
                    // MARK: EDIT 2 - END
                    volumeBinding: volumeBinding,
                    onLyricsToggle: { toggleLyrics() },
                    onQueueToggle: { toggleQueue() },
                    onRevealAndReschedule: revealControlsAndReschedule,
                    hasLyricsAvailable: hasLyricsAvailable,
                    routeSymbolName: routeSymbolName,
                    titleReveal: 1 - animationProgress, // <-- new
                    chromeOpacity: chromeOpacity,
                    // START: Edits for 4 & 5 (pass favorite actions/state to controls)
                    isFaved: isFaved,
                    onFavoriteTap: onFavoriteTap,
                    createStation: createStation,
                    goToAlbum: goToAlbum,
                    goToArtist: goToArtist,
                    // REMOVED: favoriteAnimationTrigger parameter
                    download: download
                    // END: Edits for 4 & 5
                )
                .animation(.easeInOut(duration: 0.3), value: animationProgress)
            }
            
            if showingLyrics && !controlsVisible {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(height: 240)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .onTapGesture { revealControlsAndReschedule() }
                    .zIndex(60)
            }
        }
        .offset(y: dismissDragOffset)
        .preferredColorScheme(.dark)
        .overlayPreferenceValue(AnchorKey.self) { anchors in
            heroAnimationLayer(anchors: anchors)
        }
        .foregroundStyle(.white)       // <- default text/icon color is white
        .tint(.white)          // <- default control tint is white
        
        .onChange(of: player.currentTrack) { _, track in
            if track == nil {
                showingLyrics = false
                showingQueue  = false
                animationProgress = 0
                showHeroArtwork = false
                controlsVisible = true
                
                // NEW: if the queue is finished, close the view
                if player.upNext.isEmpty {
                    onDismiss()
                }
            }
        }
        
        // Load/Unload poster & update colors/lyrics
        .onChange(of: player.currentTrack?.id) { _, _ in
            updateBackgroundColors(from: artworkURL)
            checkLyricsAvailability()
            if showingLyrics { loadLyrics() }

            // MODIFIED: Step 5 - Decide path based on album tags
            loadAlbumTagsIfNeeded()  // will call loadNowPlayingPoster() or disablePosterModeInstant()
        }
        
        // Control poster playback and close controls/lyrics
        .onChange(of: showingLyrics) { _, isShowing in
            handleModeChange(isShowingLyrics: isShowing)
            if isShowing { heroPosterPlayer?.pause() } else { heroPosterPlayer?.play() }
        }
        .onChange(of: showingQueue) { _, isShowing in
            if !isShowing { showingHistory = false; isReorderingQueue = false; controlsVisible = true }
            if isShowing { heroPosterPlayer?.pause() } else { heroPosterPlayer?.play() }
        }
        
        // Other animations/states
        .onChange(of: hasLyricsAvailable) { _, available in
            // If user is looking at lyrics and the next track has none, close lyrics.
            if showingLyrics && !available {
                toggleLyrics()
            }
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying {
                // PAUSE → PLAY (Two-part overshoot animation)
                // Part 1: Slowly animate to the overshoot size.
                withAnimation(.easeInOut(duration: 1.0)) {
                    artworkScale = playOvershootScale // 1.03
                    artworkShadowRadius = 24
                    artworkShadowOpacity = 0.35
                    artworkShadowY = 14
                }
                
                // Part 2: After the first animation, smoothly settle back to the final size.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        artworkScale = 1.0
                    }
                }
            } else {
                // PLAY → PAUSE: Use a single, very slow ease-in-out animation.
                withAnimation(.easeInOut(duration: 100)) {
                    artworkScale = pausedScale // 0.75
                    artworkShadowRadius = 3.0
                    artworkShadowOpacity = 0.20
                    artworkShadowY = 1.5
                }
            }
        }

        // Lifecycle Hooks
        .onAppear {
            volume = getSystemVolume()
            updateBackgroundColors(from: artworkURL)
            checkLyricsAvailability()
            refreshRouteSymbol()
            
            loadAlbumTagsIfNeeded() // MODIFIED: Step 5 - Load poster logic based on album tags
            
            if player.isPlaying {
                artworkScale = 1.0
                artworkShadowRadius = 24
                artworkShadowOpacity = 0.35
                artworkShadowY = 14
            } else {
                artworkScale = pausedScale
                artworkShadowRadius = 1.0   // Very slight radius on initial load if paused
                artworkShadowOpacity = 0.05 // Very slight opacity on initial load if paused
                artworkShadowY = 0.5        // Very slight Y offset on initial load if paused
            }
        }
        // 4) onChange(of: scenePhase): pause/play video (kept as is, controls for app backgrounding)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                heroPosterPlayer?.play()
            case .inactive, .background:
                heroPosterPlayer?.pause()
            @unknown default: break
            }
        }
        // NEW: Add onDisappear to clean up player
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

    // FIX: Extracted complex view body to fix compiler timeout
    @ViewBuilder
    private var contentBody: some View {
        ZStack(alignment: .top) {
            if isEmptyState {
                VStack(spacing: 12) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 56, weight: .light))
                        .opacity(0.8)
                    Text("Nothing Playing")
                        .font(.headline)
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
                // Content views are now layered underneath the grabber
                mainArtworkView

                lyricsFullScreen
                    .opacity(showingLyrics ? 1 : 0)
                    .allowsHitTesting(showingLyrics)

                queueFullScreen
                    .opacity(showingQueue ? 1 : 0)
                    .allowsHitTesting(showingQueue)
                
                // The grabber is now here, on top of everything else
                topGrabber
            }
        }
        .frame(maxWidth: 430)
    }

    // START: Edits for 2 (Drag-to-dismiss bar: lower + longer)
    private var topGrabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.6))
            .frame(width: 60, height: 5)    // <-- Thinner
            .padding(.top, 18)        // <-- Lower
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .allowsHitTesting(false) // So it doesn't block content underneath
    }
    // END: Edits for 2
    
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
            ZStack {
                headerFade
                    .ignoresSafeArea(edges: .top).allowsHitTesting(false)
                
                UnifiedNowPlayingHeader(
                    player: player,
                    artworkURL: artworkURL,
                    showHeroArtwork: showHeroArtwork,
                    anchorID: "DESTINATION_LYRICS",
                    animationProgress: animationProgress
                )
                .offset(y: -15)
            }
            .opacity(chromeOpacity)
            .frame(height: 170)
            .contentShape(Rectangle())
            .gesture(dismissDragGesture)
        }
    }
    
    private var queueFullScreen: some View {
        let topInset: CGFloat = 10, headerHeight: CGFloat = 40, pillsHeight: CGFloat = 145, spacingBelowHeader: CGFloat = 110
        let chromeHeight = topInset + headerHeight + pillsHeight + spacingBelowHeader
        let contentOpacity = max(0, (animationProgress - 0.5) * 2)
        
        return ZStack(alignment: .top) {
            Group {
                if showingHistory {
                    historyScrollableContent.transition(.crossZoom)
                } else {
                    queueScrollableContent(chromeHeight: chromeHeight)
                        .transition(.crossZoom)
                        .opacity(contentOpacity)
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.9), value: showingHistory)
            
            FixedQueueTopChrome(
                player: player,
                artworkURL: artworkURL,
                backgroundColors: backgroundColors,
                showingHistory: $showingHistory,
                showHeroArtwork: showHeroArtwork,
                animationProgress: animationProgress,
                chromeOpacity: chromeOpacity,
                onHistoryToggle: { withAnimation { showingHistory.toggle() } },
                autoplayOn: Binding(get: { player.autoplayEnabled }, set: { _ in }),
                onAutoplayToggle: toggleAutoPlay
            )
            .zIndex(1)
            .gesture(dismissDragGesture)
        }.overlay(queueBottomFadeOverlay, alignment: .bottom)
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
                let scaledW = sourceRect.width  * scaleStart
                let scaledH = sourceRect.height * scaleStart
                let dx = (scaledW - sourceRect.width) / 2
                let dy = (scaledH - sourceRect.height) / 2
                let scaledSource = CGRect(
                    x: sourceRect.minX - dx,
                    y: sourceRect.minY - dy,
                    width: scaledW,
                    height: scaledH
                )

                let diffSize   = CGSize(width: destRect.width - scaledSource.width,
                                        height: destRect.height - scaledSource.height)
                let diffOrigin = CGPoint(x: destRect.minX - scaledSource.minX,
                                         y: destRect.minY - scaledSource.minY)
                
                let srcCorner: CGFloat = 12
                let destCorner: CGFloat = 8 // <-- ADJUST THIS VALUE FOR THE FINAL CORNER RADIUS
                let cornerRadius = srcCorner + (destCorner - srcCorner) * animationProgress
                
                let liveCenterShadow: (opacity: CGFloat, radius: CGFloat, y: CGFloat) = (
                    opacity: artworkShadowOpacity,
                    radius:  artworkShadowRadius,
                    y:       artworkShadowY
                )

                let zeroShadow: (opacity: CGFloat, radius: CGFloat, y: CGFloat) = (0, 0, 0)

                let startShadow = (heroDirection == .toHeader) ? liveCenterShadow : zeroShadow
                let endShadow   = (heroDirection == .toHeader) ? zeroShadow       : liveCenterShadow

                let t = animationProgress
                let sOpacity: CGFloat = max(0, lerp(startShadow.opacity, endShadow.opacity, t))
                let sRadius:  CGFloat = max(0, lerp(startShadow.radius,  endShadow.radius,  t))
                let sY:       CGFloat =       lerp(startShadow.y,       endShadow.y,       t)
                
                ArtworkView(url: artworkURL)
                    .frame(
                        width:  scaledSource.width  + diffSize.width * animationProgress,
                        height: scaledSource.height + diffSize.height * animationProgress
                    )
                    .cornerRadius(cornerRadius)
                    .shadow(
                        color: Color.black.opacity(Double(sOpacity)),
                        radius: sRadius,
                        y: sY
                    )
                    .offset(
                        x: scaledSource.minX + diffOrigin.x * animationProgress,
                        y: scaledSource.minY + diffOrigin.y * animationProgress
                    )
                    .opacity(showHeroArtwork ? heroArtworkOpacity : 0)
                    .allowsHitTesting(false)
            }
        }
    }
    
    // MODIFIED: Step 4 - Toggle lyrics logic updated to use setChromeBlend
    private func toggleLyrics() {
        if showingLyrics {
            // CLOSE -> back to main
            heroDirection = .toCenter
            showHeroArtwork = true

            if hasHeroPoster, let p = heroPosterPlayer {
                p.play()
                crossfadePoster(to: true)
            }
            withAnimation(heroAnimation) { animationProgress = 0 }
            setChromeBlend(open: false) // <— NEW: Use helper

            Task { try? await Task.sleep(for: .seconds(0.40))
                showingLyrics = false
                showHeroArtwork = false
            }
        } else {
            // OPEN lyrics
            if showingQueue { showingQueue = false }

            heroDirection = .toHeader
            showingLyrics = true
            showHeroArtwork = true

            if hasHeroPoster {
                crossfadePoster(to: false, duration: 0.16)
                heroPosterPlayer?.pause()
            }
            withAnimation(heroAnimation) { animationProgress = 1 }
            setChromeBlend(open: true) // <— NEW: Use helper

            Task { try? await Task.sleep(for: .seconds(0.40))
                showHeroArtwork = false
            }
        }
    }
    
    // MODIFIED: Step 4 - Toggle queue logic updated to use setChromeBlend
    private func toggleQueue() {
        if showingQueue {
            // CLOSE queue -> back to full-screen
            heroDirection = .toCenter
            showHeroArtwork = true

            if hasHeroPoster, let p = heroPosterPlayer {
                p.play()
                crossfadePoster(to: true)
            }
            withAnimation(heroAnimation) { animationProgress = 0 }
            setChromeBlend(open: false) // <— NEW: Use helper

            Task { try? await Task.sleep(for: .seconds(0.40))
                showingQueue = false
                showHeroArtwork = false
            }
        } else {
            // OPEN queue
            if showingLyrics { showingLyrics = false }

            heroDirection = .toHeader
            showingQueue = true
            showHeroArtwork = true

            if hasHeroPoster {
                crossfadePoster(to: false, duration: 0.16)
                heroPosterPlayer?.pause()
            }
            withAnimation(heroAnimation) {
                animationProgress = 1
            }
            setChromeBlend(open: true) // <— NEW: Use helper

            Task { try? await Task.sleep(for: .seconds(0.40))
                showHeroArtwork = false
            }
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
    
    private func queueScrollableContent(chromeHeight: CGFloat) -> some View {
        ScrollViewReader { _ in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: chromeHeight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Continue Playing").font(.headline)
                        if let container = player.currentAlbumArtist, !container.isEmpty {
                            Text("From \(container)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 8)
                    QueueListContent_Tighter(player: player, upNext: player.upNext, onTapItem: { idx in AudioPlayer.shared.playFromUpNextIndex(idx) }, onReorderBegan: { withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { isReorderingQueue = true } }, onReorderEnded: { withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { isReorderingQueue = false } }, autoScrollBy: { dy in
                        guard let sv = queueScrollView else { return 0 }
                        let oldY = sv.contentOffset.y; let inset = sv.adjustedContentInset; let minY = -inset.top
                        let maxY = max(minY, sv.contentSize.height - sv.bounds.height + inset.bottom); let newY = min(max(oldY + dy, minY), maxY)
                        if newY != oldY { sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: newY), animated: false) }
                        return newY - oldY
                    })
                    AutoPlaySection(autoplayOn: Binding(get: { player.autoplayEnabled }, set: { _ in }), items: player.infiniteQueue, isLoading: isLoadingAutoplay, onTurnOn: toggleAutoPlay, onSelect: { idx, _ in AudioPlayer.shared.playAutoplayFromIndex(idx) })
                        .padding(.top, autoplayTopGap)
                }.background(ScrollViewIntrospector(scrollView: $queueScrollView))
            }.coordinateSpace(name: "QueueScroll")
        }.scrollIndicators(.visible).safeAreaPadding(.bottom, panelHeight + panelSafeBottom + controlsLift).edgesIgnoringSafeArea(.top)
    }

    private var historyScrollableContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 10 + 40 + 145 + 110)
                if player.history.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock").font(.largeTitle).opacity(0.6)
                        Text("No history yet").font(.headline).opacity(0.8)
                        Text("Play some music, then come back here.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 24).padding(.horizontal, 24)
                } else {
                    let items = player.history.reversed()
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                            Button { AudioPlayer.shared.playOneTrackThenResumeQueue(t) } label: {
                                HStack(spacing: 12) {
                                    ItemImage(url: JellyfinAPIService.shared.imageURL(for: t.albumId ?? t.id), cornerRadius: 6).frame(width: 42, height: 42)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(t.name ?? "—").font(.body).lineLimit(1)
                                        Text(t.artists?.joined(separator: ", ") ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 12)
                                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                }.padding(.horizontal, 20).padding(.vertical, 6)
                            }.buttonStyle(.plain)
                            if i < items.count - 1 { Divider().opacity(0.28).padding(.leading, 42 + 12 + 2) }
                        }
                    }.padding(.top, 2)
                }
                Color.clear.frame(height: 160)
            }
        }.scrollIndicators(.visible).safeAreaPadding(.bottom, panelHeight + panelSafeBottom + controlsLift).edgesIgnoringSafeArea(.top)
    }

    private var queueBottomFadeOverlay: some View {
        LinearGradient(colors: [(backgroundColors.first ?? .black).opacity(0.9), .clear], startPoint: .bottom, endPoint: .top)
            .frame(height: 120).allowsHitTesting(false)
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
            routeSymbolName = "airplayaudio"
            return
        }

        // First specialize by *name* (most specific)
        let name = output.portName.lowercased()

        // AirPods family
        if name.contains("airpods max")       { routeSymbolName = "airpods.max"; return }
        if name.contains("airpods pro")       { routeSymbolName = "airpods.pro"; return }
        if name.contains("airpods gen 4")     { routeSymbolName = "airpods.gen4"; return }
        if name.contains("airpods gen 3")     { routeSymbolName = "airpods.gen3"; return }
        if name.contains("airpods")           { routeSymbolName = "airpods"; return }

        // Beats family
        if name.contains("fit pro") || name.contains("fitpro") {
            routeSymbolName = "beats.fitpro"; return
        }
        if name.contains("studiobuds+") || name.contains("studio buds+") || name.contains("studiobeats plus") {
            routeSymbolName = "beats.studiobuds"; return
        }
        if name.contains("studiobuds") || name.contains("studio buds") || name.contains("studiobeats") {
            routeSymbolName = "beats.studiobuds"; return
        }
        if name.contains("solobuds")          { routeSymbolName = "beats.solobuds"; return }
        if name.contains("beats") && (name.contains("earphones") || name.contains("earbuds")) {
            routeSymbolName = "beats.earphones"; return
        }
        if name.contains("beats") && (name.contains("solo") || name.contains("studio") || name.contains("headphone")) {
            routeSymbolName = "beats.headphones"; return
        }

        // HomePod family (AirPlay route with a well-known name)
        if name.contains("homepod mini")      { routeSymbolName = "homepod.mini"; return }
        if name.contains("homepod")           { routeSymbolName = "homepod"; return }

        // Apple wired EarPods
        if name.contains("earpods")           { routeSymbolName = "earpods"; return }

        // Generic “headphones” wording in name
        if name.contains("headphone")         { routeSymbolName = "headphones"; return }

        // If name didn’t match, use *port type* (broad fallback)
        switch output.portType {
        case .airPlay:
            routeSymbolName = "airplayaudio"

        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            // Could be many things; generic headphones is safest
            routeSymbolName = "headphones"

        case .headphones, .headsetMic, .lineOut:
            // Wired headphones/line-out
            routeSymbolName = "headphones"

        case .builtInSpeaker:
            routeSymbolName = "airplayaudio"

        default:
            // Unknown → AirPlay glyph is a nice neutral
            routeSymbolName = "airplayaudio"
        }
    }

    private func checkLyricsAvailability() {
        guard let trackId = player.currentTrack?.id else {
            hasLyricsAvailable = false
            return
        }
        // Quick probe: fetch and only keep the boolean.
        JellyfinAPIService.shared.fetchLyricsSmart(for: trackId)
            .map { text in
                guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
                return true
            }
            .replaceError(with: false)
            .receive(on: DispatchQueue.main)
            .sink { available in
                self.hasLyricsAvailable = available
            }
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
        if player.autoplayEnabled { AudioPlayer.shared.setAutoplay(enabled: false, items: []) }
        else { AudioPlayer.shared.setAutoplay(enabled: true, items: []); loadAutoplay() }
    }
    private func loadAutoplay() {
        guard let track = player.currentTrack else { return }; isLoadingAutoplay = true
        func mix(for seed: String, limit: Int = 50) -> AnyPublisher<[JellyfinTrack], Never> {
            JellyfinAPIService.shared.fetchInstantMix(itemId: seed, limit: limit)
                .map { tracks in return tracks }.replaceError(with: []).eraseToAnyPublisher()
        }
        let first = mix(for: track.id, limit: 60)
        let publisher: AnyPublisher<[JellyfinTrack], Never>
        if let albumId = track.albumId {
            publisher = first.flatMap { $0.isEmpty ? mix(for: albumId, limit: 60) : Just($0).eraseToAnyPublisher() }.eraseToAnyPublisher()
        } else { publisher = first }
        publisher.receive(on: DispatchQueue.main).sink { tracks in
            self.isLoadingAutoplay = false; AudioPlayer.shared.setAutoplay(enabled: AudioPlayer.shared.autoplayEnabled, items: tracks)
        }.store(in: &cancellables)
    }
    
    // NEW Helper Function for Step 2
    private func paletteFrom(_ colors: UIImageColors, limit: Int = 4) -> [Color] {
        var ui: [UIColor] = []
        if let p = colors.primary { ui.append(p) }
        if let s = colors.secondary { ui.append(s) }
        if let d = colors.detail { ui.append(d) }
        if let b = colors.background { ui.append(b) }

        // de-duplicate near-grays/near-blacks a bit while keeping variety
        // (super light/black already get down-weighted in your score func)
        return Array(ui.prefix(limit)).map { Color($0) }
    }

    // MODIFIED Function for Step 2
    private func updateBackgroundColors(from url: URL?) {
        let fallbackColors = [Color(uiColor: .darkGray), Color(uiColor: .black)]
        guard let url else {
            self.backgroundColors = fallbackColors
            return
        }

        if let cached = ColorCache.shared.get(forKey: url.absoluteString) {
            self.backgroundColors = cached.map { Color($0) }
            if let firstColor = cached.first { self.vibrantBaseColor = firstColor }
            return
        }

        Task.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }

            image.getColors(quality: .high) { colors in
                guard let colors else {
                    Task { @MainActor in self.backgroundColors = fallbackColors }
                    return
                }
                
                // 1. Pick the single most vibrant color as our base
                let vibrant = pickVibrantColor(from: colors)
                let vibrantHSV = vibrant.hsv
                
                // 2. Generate a cohesive, Apple Music-style palette from that single color
                let palette = [
                    // Color 1: The original vibrant color
                    Color(vibrant),
                    
                    // Color 2: A slightly brighter, more saturated version
                    Color(vibrant.adjusted(
                        saturation: min(1.0, vibrantHSV.s + 0.1),
                        brightness: min(1.0, vibrantHSV.v + 0.15)
                    )),
                    
                    // Color 3: A darker, slightly desaturated version for depth
                    Color(vibrant.adjusted(
                        saturation: max(0, vibrantHSV.s - 0.1),
                        brightness: max(0, vibrantHSV.v - 0.2)
                    )),
                    
                    // Color 4: A very dark, almost-black version of the vibrant hue
                    Color(vibrant.adjusted(brightness: 0.2))
                ]
                
                // 3. Cache and apply the new palette
                ColorCache.shared.set(palette.map { UIColor($0) }, forKey: url.absoluteString)
                
                Task { @MainActor in
                    self.backgroundColors = palette
                    self.vibrantBaseColor = vibrant
                }
            }
        }
    }
    private func pickVibrantColor(from colors: UIImageColors) -> UIColor {
        let candidates = [colors.primary, colors.secondary, colors.detail].compactMap { $0 }
        func score(_ c: UIColor) -> CGFloat {
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0; c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            let sat = max(0, s - 0.08); let valTarget: CGFloat = 0.6; let valScore = 1 - min(1, abs(v - valTarget) / 0.6)
            let whiteBlackPenalty: CGFloat = (v < 0.12 || v > 0.93) ? 0.4 : 0.0
            return sat * 0.75 + valScore * 0.35 - whiteBlackPenalty
        }
        if let best = candidates.max(by: { score($0) < score($1) }) { return best }
        return colors.background ?? .darkGray
    }
    private func gradientFromVibrant(_ base: UIColor) -> [Color] {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0; base.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let bottom = UIColor(hue: h, saturation: min(1, s * 0.95 + 0.05), brightness: max(0.16, v * 0.38), alpha: a)
        let top = UIColor(hue: h, saturation: max(0.15, s * 0.85), brightness: min(0.92, max(0.28, v * 0.82 + 0.08)), alpha: a)
        return [Color(bottom), Color(top)]
    }
    
    // NEW: Linear Interpolation helper
    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
    
    private var progressBinding: Binding<Double> {
        Binding<Double>(get: { let d = player.duration; guard d > 0, d.isFinite else { return 0 }; return min(1, max(0, player.currentTime / d)) },
                        set: { newPct in revealControlsAndReschedule(); let d = player.duration; guard d > 0, d.isFinite else { return }; AudioPlayer.shared.seek(to: d * newPct) })
    }
    // MARK: EDIT 1 - START
    private var progressSecondsBinding: Binding<Double> {
        Binding<Double>(
            get: { player.currentTime },
            set: { newSec in
                revealControlsAndReschedule()
                AudioPlayer.shared.seek(to: newSec)
            }
        )
    }
    // MARK: EDIT 1 - END
    private var volumeBinding: Binding<Double> {
        Binding<Double>(get: { Double(self.volume) }, set: { revealControlsAndReschedule(); self.volume = Float($0) })
    }
    private func getSystemVolume() -> Float { AVAudioSession.sharedInstance().outputVolume }
    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite && !t.isNaN && t >= 0 else { return "0:00" }; let seconds = Int(t.rounded()); return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Slider type
enum SliderType { case progress, volume }

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

    // If a symbol doesn’t exist on this iOS version, gracefully fall back.
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


struct ExpandingSlider: View {
    @Binding var value: Double
    let type: SliderType
    @State private var isDragging = false
    @State private var isTouched = false

    // New state to manage relative dragging
    @State private var dragStartValue: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Both the track and the fill are now simple Rectangles
                Rectangle().fill(Color.white.opacity(0.3))
                Rectangle().fill(Color.white.opacity(0.7))
                    .frame(width: CGFloat(value) * geometry.size.width)
            }
            .drawingGroup()
            .frame(height: isDragging || isTouched ? 15 : 8)
            .frame(maxHeight: .infinity, alignment: .center)
            .clipShape(Capsule()) // <-- CHANGED BACK TO CAPSULE for perfectly round ends
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3.0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                        }
                        
                        let translationPercentage = gesture.translation.width / geometry.size.width
                        let newValue = (dragStartValue ?? value) + translationPercentage
                        
                        value = min(max(0, newValue), 1)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartValue = nil
                    }
            )
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        isTouched = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if !isDragging {
                                isTouched = false
                            }
                        }
                    }
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging || isTouched)
        }
        .frame(height: 44)
    }
}

// MARK: - Queue Views
private struct TopChromeBackground: View {
    let colors: [Color]; let height: CGFloat; let fadeLength: CGFloat; private let bleed: CGFloat = 120
    var body: some View {
        let tint = (colors.last ?? .black)
        tint.frame(height: height + bleed).offset(y: -bleed).overlay(Color.black.opacity(0.15))
            .mask(VStack(spacing: 0) {
                Rectangle().fill(Color.white).frame(height: height + bleed - fadeLength)
                LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: fadeLength)
            }.offset(y: -bleed)).ignoresSafeArea().allowsHitTesting(false)
    }
}

private struct FixedQueueTopChrome: View {
    @ObservedObject var player: AudioPlayer
    let artworkURL: URL?
    let backgroundColors: [Color]
    @Binding var showingHistory: Bool
    var showHeroArtwork: Bool
    var animationProgress: CGFloat // NEW: Added
    let chromeOpacity: Double
    let onHistoryToggle: () -> Void
    @Binding var autoplayOn: Bool
    let onAutoplayToggle: () -> Void

    var body: some View {
        let topInset: CGFloat = 10, headerHeight: CGFloat = 40, pillsHeight: CGFloat = 145, spacingBelowHeader: CGFloat = 110, extraOpaqueBottom: CGFloat = -10, fadeLength: CGFloat = 15
        let chromeHeight = topInset + headerHeight + pillsHeight + spacingBelowHeader + extraOpaqueBottom
        VStack(spacing: 0) {
            TopChromeBackground(colors: backgroundColors, height: chromeHeight, fadeLength: fadeLength)
                .overlay(VStack(spacing: 0) {
                    Color.clear.frame(height: topInset)
                    // NEW: Pass animationProgress to the header
                    UnifiedNowPlayingHeader(
                        player: player,
                        artworkURL: artworkURL,
                        showHeroArtwork: showHeroArtwork,
                        anchorID: "DESTINATION_QUEUE",
                        animationProgress: animationProgress
                    )
                    .frame(height: headerHeight)
                    .offset(y: -15)

                    HStack {
                        Spacer(); QuickActionPillToggle(system: "clock", isOn: $showingHistory, action: onHistoryToggle); Spacer()
                        ShufflePill(player: player); Spacer(); RepeatPill(player: player); Spacer()
                        QuickActionPillToggle(system: "infinity", isOn: $autoplayOn, action: onAutoplayToggle); Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: pillsHeight)
                    
                    Divider().opacity(0.32)
                    Color.clear.frame(height: spacingBelowHeader)
                }
                    .opacity(chromeOpacity)
                )
        }.frame(maxWidth: .infinity, alignment: .top)
    }
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

private struct AutoPlaySection: View {
    @Binding var autoplayOn: Bool; let items: [JellyfinTrack]; let isLoading: Bool; let onTurnOn: () -> Void; let onSelect: (Int, JellyfinTrack) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AutoPlay").font(.headline).padding(.horizontal, 20)
            if !autoplayOn {
                HStack(spacing: 12) {
                    Image(systemName: "infinity").font(.system(size: 18, weight: .semibold))
                    Text("To keep music playing, turn on AutoPlay.").font(.subheadline).foregroundStyle(.secondary); Spacer()
                    Button("Turn On") { onTurnOn() }.font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(Color.white.opacity(0.18)))
                }.padding(.horizontal, 20).padding(.vertical, 12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08))).padding(.horizontal, 20).padding(.top, 2)
            } else if isLoading {
                HStack(spacing: 8) { ProgressView(); Text("Building your mix…").font(.subheadline).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 20).padding(.vertical, 8)
            } else if items.isEmpty {
                Text("No suggestions yet.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { i in
                        let t = items[i]
                        Button { onSelect(i, t) } label: {
                            HStack(spacing: 12) {
                                ItemImage(url: JellyfinAPIService.shared.imageURL(for: t.albumId ?? t.id), cornerRadius: 6).frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.name ?? "—").font(.body).lineLimit(1)
                                    Text(t.artists?.joined(separator: ", ") ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 12)
                                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                            }.padding(.horizontal, 20).padding(.vertical, 6)
                        }.buttonStyle(.plain)
                        if i < items.count - 1 { Divider().opacity(0.28).padding(.leading, 40 + 12 + 2) }
                    }
                }
            }
        }
    }
}

private struct QueueListContent_Tighter: View {
    @ObservedObject var player: AudioPlayer; let upNext: [JellyfinTrack]; let onTapItem: (Int) -> Void; let onReorderBegan: () -> Void; let onReorderEnded: () -> Void; let autoScrollBy: (_ dy: CGFloat) -> CGFloat
    @State private var dragging: DragInfo? = nil; @State private var displayLink: CADisplayLink? = nil; @State private var lastTimestamp: CFTimeInterval = 0; @State private var scrollVelocity: CGFloat = 0; @State private var displayLinkProxy: DisplayLinkProxy? = nil
    private let rowHeight: CGFloat = 56, moveTrigger: CGFloat = 0.33, minAutoSpeed: CGFloat = 60, maxAutoSpeed: CGFloat = 260, cover: CGFloat = 42, titleSpacing: CGFloat = 1
    private var dividerLeftInset: CGFloat { cover + 12 + 2 }
    struct DragInfo: Equatable { var index: Int; var translation: CGFloat }
    private func targetIndex(for d: DragInfo) -> Int {
        let raw = d.translation / rowHeight; let delta: Int = (raw >= 0) ? Int(floor(raw + moveTrigger)) : Int(ceil(raw - moveTrigger)); return max(0, min(upNext.count - 1, d.index + delta))
    }
    private func displacement(for index: Int) -> CGFloat {
        guard let d = dragging else { return 0 }; if index == d.index { return d.translation }; let target = targetIndex(for: d)
        if target == d.index { return 0 }; if target > d.index { if index > d.index && index <= target { return -rowHeight } } else { if index >= target && index < d.index { return rowHeight } }; return 0
    }
    private func updateEdgeAutoScroll(forLocalY y: CGFloat) {
        let viewportH = UIScreen.main.bounds.height, topZone = viewportH * 0.20, bottomZoneStart = viewportH * (1.0 - 0.33)
        if y < topZone { let depth = max(0, (topZone - y) / topZone); let speed = minAutoSpeed + (maxAutoSpeed - minAutoSpeed) * depth; scrollVelocity = -speed; ensureDisplayLink() }
        else if y > bottomZoneStart { let depth = max(0, (y - bottomZoneStart) / (viewportH - bottomZoneStart)); let speed = minAutoSpeed + (maxAutoSpeed - minAutoSpeed) * depth; scrollVelocity = +speed; ensureDisplayLink() }
        else { scrollVelocity = 0; stopDisplayLinkIfIdle() }
    }
    private func ensureDisplayLink() {
        guard displayLink == nil else { return }; let proxy = DisplayLinkProxy { [self] timestamp in
            if lastTimestamp == 0 { lastTimestamp = timestamp; return }; let dt = max(0, timestamp - lastTimestamp); lastTimestamp = timestamp; guard scrollVelocity != 0 else { stopDisplayLink(); return }
            let dy = scrollVelocity * CGFloat(dt); let applied = autoScrollBy(dy); if applied == 0 { stopDisplayLink(); return }; if var d = dragging { d.translation += applied; dragging = d }
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:))); link.add(to: RunLoop.main, forMode: .common); displayLink = link; displayLinkProxy = proxy
    }
    private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil; displayLinkProxy = nil; lastTimestamp = 0 }
    private func stopDisplayLinkIfIdle() { if scrollVelocity == 0 { stopDisplayLink() } }
    private func handleGesture(for index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.15, maximumDistance: 12).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("QueueScroll")))
            .onChanged { value in
                switch value {
                case .first(true): if dragging == nil { dragging = .init(index: index, translation: 0); onReorderBegan(); UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                case .second(true, let drag?): guard var d = dragging, d.index == index else { return }; d.translation = drag.translation.height; dragging = d; updateEdgeAutoScroll(forLocalY: drag.location.y)
                default: break
                }
            }.onEnded { _ in
                stopDisplayLink(); scrollVelocity = 0; guard let d = dragging else { return }; let target = targetIndex(for: d)
                if target != d.index { AudioPlayer.shared.moveUpNextItem(from: d.index, to: target) }; dragging = nil; onReorderEnded(); UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
    }
    var body: some View {
        VStack(spacing: 0) {
            if upNext.isEmpty {
                VStack(spacing: 10) { Image(systemName: "music.note.list").font(.largeTitle).opacity(0.6); Text("No upcoming tracks").font(.headline).opacity(0.8); Text("Start a playlist or album to see what's next.").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.top, 24).padding(.horizontal, 24)
            } else {
                ForEach(Array(upNext.enumerated()), id: \.element.id) { (i, track) in
                    VStack(spacing: 0) {
                        Row(track: track, subtitle: (track.artists ?? []).joined(separator: ", "), cover: cover, index: i, onTap: { onTapItem(i) }).id(track.id).padding(.vertical, 2).padding(.horizontal, 20).zIndex(dragging?.index == i ? 2 : 0).offset(y: displacement(for: i))
                            .transaction { t in t.animation = (dragging?.index == i) ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.78) }
                        if i < upNext.count - 1 { Divider().opacity(0.32).padding(.leading, dividerLeftInset).offset(y: displacement(for: i + 1) == rowHeight ? rowHeight : 0).animation(.interactiveSpring(response: 0.18, dampingFraction: 0.78), value: dragging) }
                    }
                }.padding(.top, 2)
            }
            Color.clear.frame(height: 160)
        }
    }
    private func Row(track: JellyfinTrack, subtitle: String, cover: CGFloat, index: Int, onTap: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ItemImage(url: JellyfinAPIService.shared.imageURL(for: (track.albumId ?? track.id)), cornerRadius: 6).frame(width: cover, height: cover)
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: titleSpacing) {
                    HStack(spacing: 6) {
                        Text(track.name ?? "Unknown title").font(.body).lineLimit(1)
                        if trackIsExplicit(track.tags) { InlineExplicitBadge() }
                    }
                    if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).contentShape(Rectangle()).gesture(handleGesture(for: index))
        }.padding(.vertical, 6).shadow(color: Color.black.opacity((dragging?.index == index) ? 0.25 : 0), radius: 10, y: 6)
            .scaleEffect((dragging?.index == index) ? 1.02 : 1.0).animation(.easeInOut(duration: 0.10), value: dragging)
    }
}

private final class DisplayLinkProxy: NSObject {
    let block: (CFTimeInterval) -> Void
    init(_ block: @escaping (CFTimeInterval) -> Void) { self.block = block }
    @objc func tick(_ link: CADisplayLink) { block(link.timestamp) }
}

// MARK: - History & Transitions
private struct ZoomOpacity: ViewModifier {
    let scale: CGFloat; let opacity: Double; let anchor: UnitPoint
    func body(content: Content) -> some View { content.scaleEffect(scale).opacity(opacity) }
}

private extension AnyTransition {
    static var crossZoom: AnyTransition {
        .asymmetric(insertion: .modifier(active: ZoomOpacity(scale: 0.88, opacity: 0.0, anchor: .top), identity: ZoomOpacity(scale: 1.0,  opacity: 1.0, anchor: .top)),
                      removal: .modifier(active: ZoomOpacity(scale: 0.88, opacity: 0.0, anchor: .top), identity: ZoomOpacity(scale: 1.0,  opacity: 1.0, anchor: .top)))
    }
}

private struct ScrollViewIntrospector: UIViewRepresentable {
    @Binding var scrollView: UIScrollView?
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero); DispatchQueue.main.async { self.scrollView = v.enclosingScrollView() }; return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { self.scrollView = uiView.enclosingScrollView() }
    }
}

private extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        var v: UIView? = self
        while let cur = v { if let s = cur as? UIScrollView { return s }; v = cur.superview }; return nil
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
