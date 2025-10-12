import SwiftUI
import UIKit // Required for UIImpactFeedbackGenerator

fileprivate func mpLog(_ msg: String) {
    print("🎵MiniPlayer:", msg)
}

private enum PlayerSource {
    case radio
    case jellyfin
    case none
}

// Helper to clamp values
private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private enum SwipeDirection { case left, right }

struct MiniPlayerView: View {
    @ObservedObject private var apiService = JellyfinAPIService.shared
    @ObservedObject private var audioPlayer = AudioPlayer.shared
    @ObservedObject private var radioPlayer = RadioAudioPlayer.shared

    @State private var showFullScreenPlayer = false
    
    // Enhanced swipe state with Apple Music-like feel
    @State private var textDragX: CGFloat = 0
    @State private var textIsDragging = false
    @State private var textScale: CGFloat = 1.0
    @State private var textOpacity: Double = 1.0

    // Enhanced animation and haptics
    @State private var lastSwipeDirection: SwipeDirection? = nil
    @State private var didHapticThisDrag = false
    @State private var dragProgress: Double = 0.0 // 0.0 to 1.0 for smooth transitions
    
    private let hapticLight = UIImpactFeedbackGenerator(style: .light)
    private let hapticMedium = UIImpactFeedbackGenerator(style: .medium)
    private let hapticSelection = UISelectionFeedbackGenerator()

    @State private var hasShownFirstTrack = false

    // Apple Music-like timing constants
    private let swipeThreshold: CGFloat = 80
    private let maxVisualDrag: CGFloat = 100
    private let dragScaleFactor: CGFloat = 0.02
    private let dragOpacityFactor: Double = 0.3
    
    // Fixed fade parameters - simplified and working
    private let fadeWidth: CGFloat = 12
    private let fadeGutter: CGFloat = 0

    private var shouldShowTextFade: Bool {
        textIsDragging && abs(textDragX) > 10
    }

    // UI constants
    private let barHeight: CGFloat = 56
    private let coverSize: CGFloat = 36
    private let corner: CGFloat = 6
    private let hSpacing: CGFloat = 10
    private let ctlSpacing: CGFloat = 16
    private let vContentPad: CGFloat = 6

    @State private var playPulse = false
    @State private var nextAnimating = false

    // Cover state
    @State private var currentCoverImage: UIImage? = nil
    @State private var isLoadingImage = false
    @State private var coverTask: URLSessionDataTask? = nil
    @State private var lastRequestedTrackId: String = ""

    // Apple Music-like animation timings
    private let playPauseSpringResponse: Double = 0.35
    private let playPauseSpringDamping: Double = 0.70
    private let slideTransitionDuration: Double = 0.28
    private let slideSpringResponse: Double = 0.32
    private let slideSpringDamping: Double = 0.85

    private var currentSource: PlayerSource {
        if audioPlayer.currentTrack != nil {
            return .jellyfin
        } else if radioPlayer.isPlaying {
            return .radio
        } else {
            return .none
        }
    }
    
    // Fixed fade mask - much simpler and actually works
    @ViewBuilder
    private var textFadeMask: some View {
        HStack(spacing: 0) {
            // Left fade edge
            LinearGradient(
                gradient: Gradient(colors: [.clear, .black]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            
            // Center fully opaque
            Rectangle()
                .fill(Color.black)
            
            // Right fade edge
            LinearGradient(
                gradient: Gradient(colors: [.black, .clear]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
        }
    }

    @ViewBuilder
    private func slidingTextStack(source: PlayerSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            titleView(source: source)
                .lineLimit(1)
                .truncationMode(.tail)

            subtitleView(source: source)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
    
    // Enhanced animated text content with Apple Music-like transitions
    @ViewBuilder
    private func AnimatedTextContent(source: PlayerSource, contentKey: String, isInitialInsert: Bool) -> some View {
        let moveTransition: AnyTransition = .asymmetric(
            insertion: .move(edge: (lastSwipeDirection == .left) ? .trailing : .leading)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.95)),
            removal: .move(edge: (lastSwipeDirection == .left) ? .leading : .trailing)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.95))
        )
        
        slidingTextStack(source: source)
            .id(contentKey)
            .offset(x: textDragX)
            .scaleEffect(textScale)
            .opacity(textOpacity)
            .animation(.spring(response: slideSpringResponse, dampingFraction: slideSpringDamping), value: textDragX)
            .animation(.spring(response: slideSpringResponse, dampingFraction: slideSpringDamping), value: textScale)
            .animation(.spring(response: slideSpringResponse, dampingFraction: slideSpringDamping), value: textOpacity)
            .transition(isInitialInsert ? .identity : moveTransition)
            .animation(
                (isInitialInsert && lastSwipeDirection == nil) ? nil :
                .spring(response: slideSpringResponse, dampingFraction: slideSpringDamping),
                value: contentKey
            )
    }

    // Enhanced sliding text section with better drag feedback
    @ViewBuilder
    private func SlidingTextSectionView(source: PlayerSource, hasTrack: Bool) -> some View {
        ZStack {
            let contentKey: String = {
                switch source {
                case .jellyfin: return audioPlayer.currentTrack?.id ?? "none"
                case .radio: return radioPlayer.currentMeta?.display ?? radioPlayer.currentStation?.name ?? "radio-none"
                case .none: return "none"
                }
            }()

            let isInitialInsert = (!hasShownFirstTrack && contentKey != "none")

            AnimatedTextContent(source: source, contentKey: contentKey, isInitialInsert: isInitialInsert)
        }
        .clipped(antialiased: true)
        .compositingGroup()
        .mask {
            if shouldShowTextFade {
                textFadeMask
            } else {
                Rectangle().fill(Color.black)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shouldShowTextFade)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !textIsDragging, source != .none else { return }
            mpLog("tap (text) → showFullScreenPlayer=true")
            showFullScreenPlayer = true
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _, newID in
            if !hasShownFirstTrack, newID != nil {
                hasShownFirstTrack = true
                lastSwipeDirection = nil
            }
        }
        .onChange(of: radioPlayer.currentStation?.name) { _, newName in
            if !hasShownFirstTrack, newName != nil {
                hasShownFirstTrack = true
                lastSwipeDirection = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    if !textIsDragging {
                        textIsDragging = true
                        didHapticThisDrag = false
                        hapticLight.prepare()
                        hapticMedium.prepare()
                        hapticSelection.prepare()
                    }

                    // Enhanced visual feedback during drag
                    let rawDx = value.translation.width
                    let dx = rawDx.clamped(to: -maxVisualDrag...maxVisualDrag)
                    
                    // Calculate progress for smooth visual feedback
                    dragProgress = min(abs(rawDx) / swipeThreshold, 1.0)
                    
                    // Apply Apple Music-like scaling and opacity effects
                    let scaleReduction = dragProgress * dragScaleFactor
                    textScale = 1.0 - scaleReduction
                    textOpacity = 1.0 - (dragProgress * dragOpacityFactor)
                    
                    textDragX = dx

                    // Enhanced haptic feedback with different intensities
                    if !didHapticThisDrag && abs(rawDx) >= swipeThreshold * 0.6 {
                        hapticSelection.selectionChanged()
                        didHapticThisDrag = true
                    }
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let velocity = value.velocity.width
                    
                    // Reset visual feedback with smooth animation
                    withAnimation(.spring(response: slideSpringResponse, dampingFraction: slideSpringDamping)) {
                        textDragX = 0
                        textScale = 1.0
                        textOpacity = 1.0
                        dragProgress = 0.0
                    }
                    
                    DispatchQueue.main.async {
                        textIsDragging = false
                        didHapticThisDrag = false
                    }
                    
                    if !hasShownFirstTrack && hasTrack {
                        hasShownFirstTrack = true
                    }

                    guard hasTrack else { return }

                    // Enhanced swipe detection with velocity consideration
                    let swipeThresholdWithVelocity = swipeThreshold - (abs(velocity) * 0.02)
                    let shouldTrigger = abs(dx) >= swipeThresholdWithVelocity || abs(velocity) > 300

                    if dx <= -swipeThresholdWithVelocity || (dx < 0 && abs(velocity) > 300) {
                        // Swipe LEFT → next
                        lastSwipeDirection = .left
                        hapticMedium.impactOccurred()
                        
                        withAnimation(.spring(response: slideSpringResponse, dampingFraction: slideSpringDamping)) {
                            // Trigger removal transition
                        }
                        
                        if source == .jellyfin {
                            audioPlayer.nextTrack()
                        }
                        
                    } else if dx >= swipeThresholdWithVelocity || (dx > 0 && abs(velocity) > 300) {
                        // Swipe RIGHT → previous
                        lastSwipeDirection = .right
                        hapticMedium.impactOccurred()
                        
                        withAnimation(.spring(response: slideSpringResponse, dampingFraction: slideSpringDamping)) {
                            // Trigger removal transition
                        }
                        
                        if source == .jellyfin {
                            audioPlayer.previousTrack()
                        }
                        
                    } else {
                        // Snap back with subtle haptic
                        hapticLight.impactOccurred()
                    }
                }
        )
    }

    var body: some View {
        let source = currentSource
        let hasTrack = source == .radio || (source == .jellyfin && audioPlayer.currentTrack != nil)

        HStack(spacing: hSpacing) {
            // Cover
            coverView(source: source)
                .frame(width: coverSize, height: coverSize)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard source != .none else { return }
                    mpLog("tap (cover) → showFullScreenPlayer=true")
                    showFullScreenPlayer = true
                }

            // Title + Artist
            SlidingTextSectionView(source: source, hasTrack: hasTrack)

            // Controls
            controlsView(source: source, hasTrack: hasTrack)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, vContentPad)
        .frame(height: barHeight)
        .contentShape(Rectangle())
        .foregroundStyle(.primary)
        .tint(.primary)
        .symbolRenderingMode(.monochrome)
            
        .fullScreenCover(isPresented: $showFullScreenPlayer) {
            Group {
                switch source {
                case .radio:
                    RadioNowPlayingView(onDismiss: { showFullScreenPlayer = false })
                        .onAppear { mpLog("presented RadioNowPlayingView") }
                case .jellyfin:
                    NowPlayingView(onDismiss: { showFullScreenPlayer = false })
                        .onAppear { mpLog("presented NowPlayingView") }
                case .none:
                    EmptyView()
                }
            }
            .onAppear { mpLog("fullScreenCover content built → source=\(source)") }
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _, newID in
            guard currentSource == .jellyfin else { return }
            guard let newID else {
                coverTask?.cancel()
                coverTask = nil
                currentCoverImage = nil
                isLoadingImage = false
                lastRequestedTrackId = ""
                return
            }
            if newID != lastRequestedTrackId {
                loadCoverImage()
            }
        }
        .onChange(of: radioPlayer.isPlaying) { _, isOn in
            if isOn {
                coverTask?.cancel()
                coverTask = nil
                currentCoverImage = nil
            } else {
                if currentCoverImage == nil, audioPlayer.currentTrack?.id != nil {
                    loadCoverImage()
                }
            }
        }
        .onChange(of: radioPlayer.currentArtwork) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) { /* animation trigger */ }
        }
        .onAppear {
            switch currentSource {
            case .jellyfin:
                if currentCoverImage == nil, audioPlayer.currentTrack?.id != nil {
                    loadCoverImage()
                }
            case .radio, .none:
                break
            }
        }
    }

    // MARK: - Content Views

    @ViewBuilder
    private func titleView(source: PlayerSource) -> some View {
        switch source {
        case .radio:
            if let station = radioPlayer.currentStation {
                Text(station.name)
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Text("Live Radio")
                    .font(.system(size: 13, weight: .semibold))
            }
        case .jellyfin:
            if let track = audioPlayer.currentTrack {
                Text(currentTitle(for: track))
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Text("Not Playing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        case .none:
            Text("Not Playing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func subtitleView(source: PlayerSource) -> some View {
        switch source {
        case .radio:
            if let station = radioPlayer.currentStation {
                Text(radioPlayer.currentMeta?.display ?? radioPlayer.liveText ?? station.subtitle ?? "Live Radio")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("Live Radio")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .jellyfin:
            if let track = audioPlayer.currentTrack {
                Text(currentArtist(for: track))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(" ")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .none:
            Text(" ")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controlsView(source: PlayerSource, hasTrack: Bool) -> some View {
        HStack(spacing: ctlSpacing) {
            // Play/Pause button with enhanced animation
            Button {
                guard hasTrack else { return }
                withAnimation(.spring(response: playPauseSpringResponse,
                                      dampingFraction: playPauseSpringDamping)) {
                    playPulse.toggle()
                }

                switch source {
                case .radio:
                    radioPlayer.togglePlayPause()
                case .jellyfin:
                    audioPlayer.togglePlayPause()
                case .none:
                    break
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: playPauseSpringResponse,
                                          dampingFraction: playPauseSpringDamping)) {
                        playPulse = false
                    }
                }
            } label: {
                let isPlaying = switch source {
                case .radio: radioPlayer.isPlaying
                case .jellyfin: audioPlayer.isPlaying
                case .none: false
                }
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .scaleEffect(playPulse ? 0.88 : 1.0)
            }
            .disabled(!hasTrack)
            .opacity(hasTrack ? 1 : 0.55)

            // Next / Stop button with enhanced animation
            Button {
                switch source {
                case .radio:
                    radioPlayer.stop()
                case .jellyfin:
                    guard hasTrack else { return }
                    withAnimation(.spring(response: slideSpringResponse, dampingFraction: slideSpringDamping)) {
                        nextAnimating = true
                    }
                    lastSwipeDirection = .left
                    audioPlayer.nextTrack()
                    DispatchQueue.main.asyncAfter(deadline: .now() + slideTransitionDuration) {
                        withAnimation(.spring(response: slideSpringResponse, dampingFraction: slideSpringDamping)) {
                            nextAnimating = false
                        }
                    }
                case .none:
                    break
                }
            } label: {
                let iconName = switch source {
                case .radio: "stop.fill"
                case .jellyfin: "forward.fill"
                case .none: "stop.fill"
                }
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .offset(x: (source == .jellyfin && nextAnimating) ? 6 : 0)
                    .opacity((source == .jellyfin && nextAnimating) ? 0.7 : 1)
                    .scaleEffect((source == .jellyfin && nextAnimating) ? 0.95 : 1.0)
                    .animation(.spring(response: slideSpringResponse, dampingFraction: slideSpringDamping), value: nextAnimating)
            }
            .disabled(!hasTrack || source == .none)
            .opacity((!hasTrack || source == .none) ? 0.55 : 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cover

    private func coverView(source: PlayerSource) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))

            switch source {
            case .radio:
                if let art = radioPlayer.currentArtwork {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .id(art)
                } else if let imageName = radioPlayer.currentStation?.imageName,
                          let image = UIImage(named: imageName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            case .jellyfin:
                if let image = currentCoverImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if isLoadingImage {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            case .none:
                Image(systemName: "music.note")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    // MARK: - Image Loading (unchanged from your original)
    private func loadCoverImage() {
        coverTask?.cancel(); coverTask = nil
        isLoadingImage = false
        currentCoverImage = nil

        guard let t = audioPlayer.currentTrack else {
            mpLog("no current track → clearing art")
            lastRequestedTrackId = ""
            return
        }

        lastRequestedTrackId = t.id
        mpLog("track ids → albumId=\(t.albumId ?? "nil"), id=\(t.id)")

        let candidates = buildCoverURLs(for: t)
        if candidates.isEmpty {
            mpLog("no candidate URLs for track \(t.id)")
            return
        }

        mpLog("trying \(candidates.count) cover URL(s)")
        tryLoadNext(from: candidates, index: 0, revalidateIfZeroBytes: true)
    }

    private func tryLoadNext(from candidates: [URL], index: Int, revalidateIfZeroBytes: Bool) {
        guard index < candidates.count else {
            isLoadingImage = false
            mpLog("exhausted candidates → showing placeholder")
            return
        }
            
        let currentTrackId = audioPlayer.currentTrack?.id
        guard lastRequestedTrackId == currentTrackId else {
            mpLog("track changed while fetching → abort")
            return
        }

        let url = candidates[index]
        isLoadingImage = true

        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad
        req.timeoutInterval = 15
        req.setValue("image/avif,image/webp,image/jpeg,image/png,*/*;q=0.1", forHTTPHeaderField: "Accept")

        mpLog("GET \(url.absoluteString)")
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                let currentTrackId = self.audioPlayer.currentTrack?.id
                guard self.lastRequestedTrackId == currentTrackId else {
                    self.isLoadingImage = false
                    mpLog("response ignored (track changed)")
                    return
                }

                func fallbackNext(_ reason: String) {
                    mpLog("fallback → \(reason)")
                    self.isLoadingImage = false
                    self.tryLoadNext(from: candidates, index: index + 1, revalidateIfZeroBytes: true)
                }

                if let err = err as NSError? {
                    if err.code == NSURLErrorCancelled {
                        mpLog("fetch cancelled")
                        return
                    }
                    fallbackNext("network error: \(err.localizedDescription)")
                    return
                }

                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1
                let mime = http?.mimeType ?? "unknown"
                let size = data?.count ?? 0
                mpLog("HTTP \(code) | MIME \(mime) | \(size) bytes")

                guard let data, size > 0 else {
                    if revalidateIfZeroBytes {
                        mpLog("zero bytes → revalidate")
                        self.tryRevalidate(url: url) {
                            self.tryLoadNext(from: candidates, index: index, revalidateIfZeroBytes: false)
                        }
                    } else {
                        fallbackNext("zero bytes after revalidate")
                    }
                    return
                }

                if let img = UIImage(data: data) {
                    self.currentCoverImage = img
                    self.isLoadingImage = false
                    mpLog("✅ image decoded OK (\(size) bytes)")
                } else {
                    fallbackNext("decoder failed for MIME \(mime)")
                }
            }
        }
        coverTask = task
        task.resume()
    }

    private func tryRevalidate(url: URL, then retry: @escaping () -> Void) {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadRevalidatingCacheData
        req.timeoutInterval = 15
        req.setValue("image/avif,image/webp,image/jpeg,image/png,*/*;q=0.1", forHTTPHeaderField: "Accept")

        let t = URLSession.shared.dataTask(with: req) { _, _, _ in
            DispatchQueue.main.async { retry() }
        }
        t.resume()
    }

    private func buildCoverURLs(for t: JellyfinTrack) -> [URL] {
        var urls: [URL] = []

        func tweak(_ base: URL?, format: String) -> URL? {
            guard var c = base.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
            var q = c.queryItems ?? []
            func set(_ name: String, _ value: String) {
                if let i = q.firstIndex(where: { $0.name == name }) { q[i].value = value }
                else { q.append(.init(name: name, value: value)) }
            }
            set("maxHeight", "600")
            set("quality", "90")
            set("format", format)
            if q.first(where: { $0.name == "enableImageEnhancers" }) == nil {
                q.append(.init(name: "enableImageEnhancers", value: "false"))
            }
            c.queryItems = q
            return c.url
        }

        if let albumId = t.albumId, !albumId.isEmpty {
            if let u = tweak(apiService.imageURL(for: albumId), format: "jpg") { urls.append(u) }
            if let u = tweak(apiService.imageURL(for: albumId), format: "png") { urls.append(u) }
        }

        let trackId = t.id
        if let u = tweak(apiService.imageURL(for: trackId), format: "jpg") { urls.append(u) }
        if let u = tweak(apiService.imageURL(for: trackId), format: "png") { urls.append(u) }

        return urls
    }

    // MARK: - Helpers

    private func currentTitle(for track: JellyfinTrack) -> String {
        let raw = track.name ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private func currentArtist(for track: JellyfinTrack) -> String {
        if let names = track.artists, !names.isEmpty {
            let joined = names.joined(separator: ", ")
            return joined.isEmpty ? "Unknown Artist" : joined
        }
        return "Unknown Artist"
    }
}
