//
//  NowPlayingQueueContent.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 13.10.2025.
//

import SwiftUI
import Combine

// MARK: - Main Extracted View
struct NowPlayingQueueContent: View {
    // MARK: - Properties

    // State & Bindings from Parent
    @ObservedObject var player: AudioPlayer
    @Binding var isReorderingQueue: Bool
    @Binding var queueScrollView: UIScrollView?
    @Binding var isLoadingAutoplay: Bool
    @Binding var showingHistory: Bool
    
    // Read-only values from Parent
    let animationProgress: CGFloat
    let chromeHeight: CGFloat
    let panelHeight: CGFloat
    let panelSafeBottom: CGFloat
    let controlsLift: CGFloat
    let autoplayTopGap: CGFloat
    let showAutoplaySection: Bool

    // Actions from Parent
    let toggleAutoPlay: () -> Void

    // MARK: - Body

    var body: some View {
        let contentOpacity = max(0, (animationProgress - 0.5) * 2)
        
        Group {
            if showingHistory {
                historyScrollableContent
                    .transition(.crossZoom)
            } else {
                queueScrollableContent(chromeHeight: chromeHeight)
                    .transition(.crossZoom)
                    .opacity(contentOpacity) // This opacity is intentionally only on the main queue view
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.9), value: showingHistory)
    }

    // MARK: - Scrollable Content Views (Moved from NowPlayingView)

    private func queueScrollableContent(chromeHeight: CGFloat) -> some View {
        ScrollViewReader { _ in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: chromeHeight)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Continue Playing").font(.headline)
                        if let albumId = player.currentTrack?.albumId, !albumId.isEmpty {
                            AlbumNameView(albumId: albumId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 8)
                    
                    QueueListContent_Tighter(player: player, upNext: player.upNext, onTapItem: { idx in AudioPlayer.shared.playFromUpNextIndex(idx) }, onReorderBegan: { withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { isReorderingQueue = true } }, onReorderEnded: { withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { isReorderingQueue = false } }, autoScrollBy: { dy in
                        guard let sv = queueScrollView else { return 0 }
                        let oldY = sv.contentOffset.y; let inset = sv.adjustedContentInset; let minY = -inset.top
                        let maxY = max(minY, sv.contentSize.height - sv.bounds.height + inset.bottom); let newY = min(max(oldY + dy, minY), maxY)
                        if newY != oldY { sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: newY), animated: false) }
                        return newY - oldY
                    })
                    
                    // WRAPPED IN CONDITIONAL - only show when showAutoplaySection is true
                    if showAutoplaySection {
                        AutoPlaySection(
                            autoplayOn: Binding(get: { player.autoplayEnabled }, set: { _ in }),
                            items: player.infiniteQueue,
                            isLoading: isLoadingAutoplay,
                            onTurnOn: toggleAutoPlay,
                            onSelect: { idx, _ in AudioPlayer.shared.playAutoplayFromIndex(idx) }
                        )
                        .padding(.top, autoplayTopGap)
                        .transition(.opacity)
                    }
                }
                .background(ScrollViewIntrospector(scrollView: $queueScrollView))
            }
            .coordinateSpace(name: "QueueScroll")
        }
        .scrollIndicators(.visible)
        .safeAreaPadding(.bottom, panelHeight + panelSafeBottom + controlsLift)
        .edgesIgnoringSafeArea(.top)
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
}


// MARK: - Helper Views & Classes (Moved from NowPlayingView.swift)

@inline(__always)
fileprivate func trackIsExplicit(_ tags: [String]?) -> Bool {
    guard let tags else { return false }
    return tags.contains { $0.caseInsensitiveCompare("Explicit") == .orderedSame }
}

fileprivate struct InlineExplicitBadge: View {
    var body: some View {
        Text("🅴")
            .font(.system(size: 17.5).bold())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Explicit")
    }
}

fileprivate struct AutoPlaySection: View {
    @Binding var autoplayOn: Bool; let items: [JellyfinTrack]; let isLoading: Bool; let onTurnOn: () -> Void; let onSelect: (Int, JellyfinTrack) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AutoPlay").font(.headline).padding(.horizontal, 20)
            if !autoplayOn {
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

fileprivate struct QueueListContent_Tighter: View {
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

fileprivate final class DisplayLinkProxy: NSObject {
    let block: (CFTimeInterval) -> Void
    init(_ block: @escaping (CFTimeInterval) -> Void) { self.block = block }
    @objc func tick(_ link: CADisplayLink) { block(link.timestamp) }
}

fileprivate struct ScrollViewIntrospector: UIViewRepresentable {
    @Binding var scrollView: UIScrollView?
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero); DispatchQueue.main.async { self.scrollView = v.enclosingScrollView() }; return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { self.scrollView = uiView.enclosingScrollView() }
    }
}

fileprivate extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        var v: UIView? = self
        while let cur = v { if let s = cur as? UIScrollView { return s }; v = cur.superview }; return nil
    }
}

// MARK: - History & Transitions
fileprivate struct ZoomOpacity: ViewModifier {
    let scale: CGFloat; let opacity: Double; let anchor: UnitPoint
    func body(content: Content) -> some View { content.scaleEffect(scale).opacity(opacity) }
}

fileprivate extension AnyTransition {
    static var crossZoom: AnyTransition {
        .asymmetric(insertion: .modifier(active: ZoomOpacity(scale: 0.88, opacity: 0.0, anchor: .top), identity: ZoomOpacity(scale: 1.0,  opacity: 1.0, anchor: .top)),
                      removal: .modifier(active: ZoomOpacity(scale: 0.88, opacity: 0.0, anchor: .top), identity: ZoomOpacity(scale: 1.0,  opacity: 1.0, anchor: .top)))
    }
}

// MARK: - Album Name Helper View
fileprivate struct AlbumNameView: View {
    let albumId: String
    @State private var albumName: String?
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        if let name = albumName {
            Text("From \(name)")
        } else {
            Text("Loading...")
                .onAppear {
                    loadAlbumName()
                }
        }
    }
    
    private func loadAlbumName() {
        JellyfinAPIService.shared.fetchAlbumById(albumId)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    print("ERROR: Failed to fetch album name: \(error)")
                }
            }) { album in
                self.albumName = album?.name
            }
            .store(in: &cancellables)
    }
}
