// LyricsView.swift (Adjusted)
import SwiftUI
import Foundation

// Per-line measured heights
private struct LineHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// Bounds of the ACTIVE main line (for overlay placement)
private struct ActiveLineBoundsKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>],
                       nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// ─────────────────────────────────────────────
// Dots animation (intro / instrumental gaps)
// ─────────────────────────────────────────────
private struct LyricDotsTimeline: View {
    let startWallTime: Date
    let duration: TimeInterval
    private let breathePeriod: Double = 4.5
    private let breatheAmp: CGFloat = 0.2
    private let preBurstStart: Double = 0.85
    private let burstStart: Double = 0.95
    private let preBurstBoost: CGFloat = 0.18
    private let baseOpacity: CGFloat = 0.9

    var body: some View {
        TimelineView(.animation) { ctx in
            let pRaw = ctx.date.timeIntervalSince(startWallTime) / max(0.001, duration)
            let p = clamp(pRaw, 0.0, 1.0)

            let omega = 2 * .pi / breathePeriod
            let breathe = 1 + breatheAmp * CGFloat(sin(ctx.date.timeIntervalSinceReferenceDate * omega))

            let preBurstT = clamp((p - preBurstStart) / (burstStart - preBurstStart), 0.0, 1.0)
            let preBurst = 1 + preBurstBoost * easeInQuad(preBurstT)

            let collapseT = clamp((p - burstStart) / (1 - burstStart), 0.0, 1.0)
            let collapse = 1 - easeOutCubic(collapseT)

            let scale = breathe * preBurst * collapse
            let opacity = baseOpacity * collapse

            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    let offset = 0.33 * Double(i)
                    let v = clamp((p - offset) * 3, 0.0, 1.0)
                    Circle().frame(width: 14 + 4 * v, height: 14 + 4 * v)
                        .opacity(0.25 + 0.75 * v)
                }
            }
            .frame(height: 24)
            .scaleEffect(scale)
            .opacity(opacity)
            .animation(nil, value: ctx.date)
        }
    }
}

// MARK: - Reusable View Components

private struct WrappingLyricLayers: View {
    let text: String
    let isActive: Bool
    let fontSize: CGFloat
    let weight: Font.Weight
    let lineSpacing: CGFloat
    let leading: CGFloat
    let trailing: CGFloat
    let whiteScaleX: CGFloat
    let whiteScaleY: CGFloat
    let whiteShadowOpacity: CGFloat
    let extraTrailingWhenActive: CGFloat
    let alignRight: Bool

    var body: some View {
        // base layout (does all wrapping)
        let base = Text(text)
            .foregroundStyle(.secondary)        // <-- FIX 4: Use .secondary for upcoming/past
            .opacity(isActive ? 0 : 1.0)         // <-- FIX 4: Use 1.0 opacity
            .lineLimit(1000)
            .allowsTightening(false)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(3)

        // overlay (visual only; doesn't affect wrapping)
        return base
            .overlay(alignment: alignRight ? .trailing : .leading) {
                Text(text)
                    .foregroundStyle(.white)
                    .opacity(isActive ? 1 : 0)
                    .scaleEffect(x: isActive ? whiteScaleX : 1.0,
                                 y: isActive ? whiteScaleY : 1.0,
                                 anchor: alignRight ? .trailing : .leading)
                    .shadow(color: .white.opacity(isActive ? whiteShadowOpacity : 0),
                            radius: isActive ? 6 : 0, x: 0, y: 0)
                    .lineLimit(1000)
                    .allowsTightening(false)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(0)
                    .allowsHitTesting(false)
            }
            .font(.system(size: fontSize, weight: weight))
            .multilineTextAlignment(alignRight ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
            .lineSpacing(lineSpacing)
            // swap paddings logically: "leading" always means the visual start side
            .padding(.leading, leading)
            .padding(.trailing, trailing + extraTrailingWhenActive)
            .compositingGroup()
    }
}


private struct MainLyricRow: View {
    let text: String
    let isActive: Bool
    let blur: CGFloat
    let leftInset: CGFloat
    let rightInset: CGFloat
    let fontSize: CGFloat
    let extraTop: CGFloat
    let liftUp: CGFloat
    let shouldLift: Bool
    let alignRight: Bool
    let activeReserve: CGFloat  // NEW

    var body: some View {
        WrappingLyricLayers(
            text: text,
            isActive: isActive,
            fontSize: fontSize,
            weight: .bold,
            lineSpacing: 4,
            leading: alignRight ? rightInset : leftInset,
            trailing: alignRight ? leftInset  : rightInset,
            whiteScaleX: 1.02,
            whiteScaleY: 1.02,
            whiteShadowOpacity: 0.18,
            extraTrailingWhenActive: activeReserve, // use the param
            alignRight: alignRight
        )
        .blur(radius: blur)
        .padding(.top, extraTop)
        .offset(y: shouldLift ? -liftUp : 0)
    }
}



private struct CreditsRow: View {
    let text: String
    let activeByPenult: Bool
    let blur: CGFloat
    let leftInset: CGFloat
    let rightInset: CGFloat
    let fontSize: CGFloat
    let weight: Font.Weight
    let liftUp: CGFloat
    let shouldLift: Bool

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.system(size: fontSize, weight: weight))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(nil)
            .allowsTightening(false)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
            .padding(.leading, leftInset)
            .padding(.trailing, rightInset + (activeByPenult ? 12 : 0))
            .blur(radius: activeByPenult ? 0 : blur)
            .scaleEffect(x: activeByPenult ? 1.04 : 1.0, y: activeByPenult ? 1.01 : 1.0, anchor: .leading)
            .shadow(color: .white.opacity(activeByPenult ? 0.06 : 0), radius: activeByPenult ? 3 : 0)
            .offset(y: shouldLift ? -liftUp : 0)
            .animation(.easeInOut(duration: 0.22), value: activeByPenult)
    }
}

private struct AsideItem: View {
    let text: String
    let isOn: Bool
    let blur: CGFloat
    let leftInset: CGFloat
    let rightInset: CGFloat
    let fontSize: CGFloat
    let weight: Font.Weight
    let lineSpacing: CGFloat

    var body: some View {
        WrappingLyricLayers(
            text: text,
            isActive: isOn,
            fontSize: fontSize,
            weight: weight,
            lineSpacing: lineSpacing,
            leading: leftInset,
            trailing: rightInset,
            whiteScaleX: 1.0,
            whiteScaleY: 1.0,
            whiteShadowOpacity: 0.12,
            extraTrailingWhenActive: 12,
            alignRight: false // Asides are always left-aligned
        )
        .blur(radius: isOn ? 0 : blur)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

private struct ForesideItem: View {
    let text: String
    let isOn: Bool
    let blur: CGFloat
    let leftInset: CGFloat
    let rightInset: CGFloat
    let fontSize: CGFloat
    let weight: Font.Weight
    let lineSpacing: CGFloat

    var body: some View {
        WrappingLyricLayers(
            text: text,
            isActive: isOn,
            fontSize: fontSize,
            weight: weight,
            lineSpacing: lineSpacing,
            leading: leftInset,
            trailing: rightInset,
            whiteScaleX: 1.0,
            whiteScaleY: 0.985,
            whiteShadowOpacity: 0.12,
            extraTrailingWhenActive: 12,
            alignRight: false // Foresides are always left-aligned
        )
        .blur(radius: isOn ? 0 : blur)
        .animation(.spring(response: 0.22, dampingFraction: 0.95), value: isOn)
    }
}


struct LyricsView: View {
    let lyrics: String
    let currentTime: TimeInterval

    @State private var lyricLines: [LyricLine] = []

    // State
    @State private var showDots: Bool = false
    @State private var dotGapStartWall: Date = .init()
    @State private var dotGapDuration: TimeInterval = 0
    @State private var ripple: Set<Int> = []
    @State private var perLineHeights: [Int: CGFloat] = [:]
    @State private var measuredSingleLine: CGFloat = 36
    @State private var foresideStackHeight: CGFloat = 0

    // ── TUNING ─────────────────────────────────
    var rippleDepth: Int        = 10
    var rippleStagger: Double   = 0.10
    var rippleDuration: Double = 0.50
    var extendToBottom: Bool = false
    var pastLift: CGFloat = 10
    var rowSpacing: CGFloat = 32
    var cascadeReserve: CGFloat = 24
    var activeTopOffset: CGFloat = 220
    var leftInset: CGFloat = 30
    var rightWrapInset: CGFloat = 65
    var lyricFontSize: CGFloat = 35
    var pastBlurRadius: CGFloat = 3.0
    var futureBlurStart: CGFloat = 1.5
    var futureBlurStep: CGFloat  = 1.0
    var futureBlurMax: CGFloat   = 12.0
    var introFirstBlur: CGFloat = 0.8
    var introFutureExtra: CGFloat = 0.6
    var creditsFontSize: CGFloat = 17
    var creditsWeight: Font.Weight = .semibold
    var asideFontSize: CGFloat = 22
    var asideWeight: Font.Weight = .semibold
    var asideLineSpacing: CGFloat = 2
    var asideTopGap: CGFloat = 10
    var asideStackSpacing: CGFloat = 6
    var foresideFontSize: CGFloat = 22
    var foresideWeight: Font.Weight = .semibold
    var foresideLineSpacing: CGFloat = 2
    var foresideTopGap: CGFloat = 10
    var foresideStackSpacing: CGFloat = 6
    
    // Duet (right-aligned) spacing tweaks
    var duetRightTighten: CGFloat = 12   // how much to reduce right-edge padding
    var duetRightActiveReserve: CGFloat = 12 // active reserve on the right (default left is 24)


    // How long a {q} line should keep its white highlight after the next line starts
    var quickLinger: TimeInterval = 0.22    // tune 0.16–0.28 to taste

    private func hasQuickFlag(_ text: String) -> Bool {
        text.contains("{q}")
    }
    private func stripQuickFlag(_ text: String) -> String {
        text.replacingOccurrences(of: "{q}", with: "")
    }

    // ── Derived indices ───────────────────────
    private var firstNonBlankIndex: Int? {
        lyricLines.firstIndex { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var lastNonBlankIndex: Int? {
        lyricLines.lastIndex { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var penultimateNonBlankIndex: Int? {
        guard let last = lastNonBlankIndex else { return nil }
        return lyricLines[..<last].lastIndex { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // Penultimate index/time helpers
    private var penultimateIndex: Int? { penultimateNonBlankIndex }

    private var penultReached: Bool {
        guard let p = penultimateIndex else { return false }
        return currentTime >= lyricLines[p].time
    }

    // Which line should behave as the "active" anchor for highlight/blur/scroll
    private var persistentActiveIndex: Int? {
        penultReached ? penultimateIndex : currentMainIndex
    }

    // ── Helpers ───────────────────────────────
    private func trimLeadingLyricPadding(_ s: String) -> String {
        // Removes spaces, tabs, NBSP, BOM only from the START (not trailing)
        let pattern = #"^[\u{FEFF}\u{00A0}\t ]+"#
        return s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    
    private func isBracketed(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("[") && t.hasSuffix("]") && !t.hasPrefix("[[") && t.count >= 2
    }
    private func stripBrackets(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[") { t.removeFirst() }
        if t.hasSuffix("]") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isForeside(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("[[") && t.hasSuffix("]]") && t.count >= 4
    }
    private func stripForeside(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[[") { t.removeFirst(2) }
        if t.hasSuffix("]]") { t.removeLast(2) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func foresideIndicesForMain(_ mainIdx: Int?) -> [Int] {
        guard let a = mainIdx, a > 0, a < lyricLines.count else { return [] }
        var out: [Int] = []
        var i = a - 1
        while i >= 0, isForeside(lyricLines[i].text) {
            out.append(i); i -= 1
        }
        return out.reversed()
    }

    private func bracketedIndicesForMain(_ mainIdx: Int?) -> [Int] {
        guard let a = mainIdx, a >= 0, a < lyricLines.count else { return [] }
        let nextMain = lyricLines.dropFirst(a + 1).firstIndex { !isBracketed($0.text) && !isForeside($0.text) }
            ?? lyricLines.endIndex
        return Array((a + 1)..<nextMain).filter { isBracketed(lyricLines[$0].text) }
    }

    private func asideIsActive(_ idx: Int) -> Bool {
        guard idx >= 0, idx < lyricLines.count else { return false }
        return currentTime >= lyricLines[idx].time
    }

    private func activeMainIndex(for t: TimeInterval) -> Int? {
        guard !lyricLines.isEmpty else { return nil }

        if let i = firstNonBlankIndex,
            lyricLines[i].time <= 0.20,
            !lyricLines[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let next = nextTimestamp(after: i) ?? .greatestFiniteMagnitude
            if t < next - 0.001 { return i }
        }

        let lookahead: TimeInterval = 0.60
        let base = lyricLines.lastIndex {
            $0.time <= t + lookahead && !isBracketed($0.text) && !isForeside($0.text)
        } ?? lyricLines.lastIndex { $0.time <= t + lookahead }

        if let b = base {
            let nextMain = lyricLines.dropFirst(b + 1).firstIndex { !isBracketed($0.text) && !isForeside($0.text) }
            if let n = nextMain {
                let fores = foresideIndicesForMain(n)
                if let earliest = fores.min(by: { lyricLines[$0].time < lyricLines[$1].time }),
                    lyricLines[earliest].time <= t {
                    return n
                }
            }
            return b
        }

        if let firstMain = lyricLines.firstIndex(where: { !isBracketed($0.text) && !isForeside($0.text) }) {
            let fores = foresideIndicesForMain(firstMain)
            if let earliest = fores.min(by: { lyricLines[$0].time < lyricLines[$1].time }),
                lyricLines[earliest].time <= t { return firstMain }
        }
        return base
    }

    private var currentMainIndex: Int? { activeMainIndex(for: currentTime) }

    private func nextTimestamp(after idx: Int) -> TimeInterval? {
        guard idx >= 0 && idx < lyricLines.count else { return nil }
        let current = lyricLines[idx].time
        return lyricLines.dropFirst(idx + 1).first(where: { $0.time > current })?.time
    }

    private func blurForLine(at idx: Int, activeMain: Int?) -> CGFloat {
        if let a = activeMain {
            if idx == a { return 0 }
            if idx < a { return pastBlurRadius }
            let stepIndex = max(0, (idx - a) - 1)
            return min(futureBlurStart + CGFloat(stepIndex) * futureBlurStep, futureBlurMax)
        } else {
            guard let first = firstNonBlankIndex else { return 0 }
            if idx == first { return introFirstBlur }
            if idx > first {
                let stepIndex = max(0, (idx - first) - 1)
                return min(futureBlurStart + introFutureExtra + CGFloat(stepIndex) * futureBlurStep, futureBlurMax)
            }
            return pastBlurRadius
        }
    }

    private var introDotsActive: Bool {
        guard let first = firstNonBlankIndex else { return false }
        return currentMainIndex == nil && lyricLines[first].time > 0.20
    }

    private func updateDotSegment() {
        let now = Date()
        guard !lyricLines.isEmpty else { showDots = false; return }

        if let active = currentMainIndex,
            lyricLines[active].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let nextTime = nextTimestamp(after: active) {
            let startTime = lyricLines[active].time
            dotGapDuration = max(0.001, nextTime - startTime)
            dotGapStartWall = now.addingTimeInterval(-(currentTime - startTime))
            showDots = true; return
        }

        if currentMainIndex == nil, let first = firstNonBlankIndex {
            let firstTime = lyricLines[first].time
            if firstTime > 0 {
                dotGapDuration = firstTime
                dotGapStartWall = now.addingTimeInterval(-currentTime)
                showDots = true; return
            }
        }
        showDots = false
    }

    private func triggerRipple(from activeIndex: Int) {
        let indices = (1...rippleDepth).map { activeIndex + $0 }.filter { $0 < lyricLines.count }
        withAnimation(.none) { ripple = Set(indices) }
        for (i, idx) in indices.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + rippleStagger * Double(i + 1)) {
                withAnimation(.easeOut(duration: rippleDuration)) { _ = ripple.remove(idx) }
            }
        }
    }

    private var anchorTargetID: AnyHashable? {
        if introDotsActive { return -1 }
        if penultReached { return penultimateIndex }
        if let i = currentMainIndex { return i }
        return firstNonBlankIndex
    }

    private func creditsIsActive(nowMain: Int?) -> Bool {
        guard let penult = penultimateNonBlankIndex else { return false }
        return nowMain == penult
    }

    private func foresidePad(for idx: Int) -> CGFloat {
        guard let a = persistentActiveIndex, idx == a else { return 0 }
        let hasFores = !foresideIndicesForMain(a).isEmpty
        return hasFores ? max(0, foresideStackHeight + foresideTopGap) : 0
    }

    // ─────────────────────────────────────────
    // View
    // ─────────────────────────────────────────
    var body: some View {
        GeometryReader { screenGeo in
            ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: rowSpacing) {
                            let a = persistentActiveIndex ?? -1
                            let activeH = perLineHeights[a] ?? measuredSingleLine
                            let centerComp = max(0, (activeH - measuredSingleLine) / 2)
                            Color.clear.frame(height: max(0, activeTopOffset - centerComp))

                            if introDotsActive, showDots {
                                LyricDotsTimeline(startWallTime: dotGapStartWall,
                                                  duration: dotGapDuration > 0 ? dotGapDuration : (firstNonBlankIndex.map { lyricLines[$0].time } ?? 1))
                                    .frame(height: measuredSingleLine)
                                    .padding(.leading, leftInset)
                                    .padding(.trailing, rightWrapInset)
                                    .id(-1)
                            }

                            if lyricLines.isEmpty {
                                Text("No lyrics available.")
                                    .font(.system(size: 25, weight: .bold))
                                    .foregroundStyle(.secondary) // Secondary is the default non-active color
                                    .padding(.leading, leftInset)
                                    .padding(.trailing, rightWrapInset)
                            } else {
                                ForEach(Array(lyricLines.enumerated()), id: \.element.id) { idx, line in
                                    let rawText = line.text
                                    // <<< CHANGE APPLIED HERE
                                    let displayText = trimLeadingLyricPadding(stripQuickFlag(rawText))
                                    // FIXED: This line is changed to remove the dependency on 'duetAlign'
                                    let isDuetR = false // Placeholder logic removed

                                    let isBlank = rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    let isMainActive = (idx == (persistentActiveIndex ?? -1))
                                    let isCredits = (idx == lastNonBlankIndex)
                                    let isAsideLine = isBracketed(rawText)
                                    let isForesideLine = isForeside(rawText)

                                    // Keep original blur ladder anchored to persistentActiveIndex:
                                    let progressive = blurForLine(at: idx, activeMain: persistentActiveIndex)

                                    // Extra linger only if this main line is flagged {q}
                                    let quick = hasQuickFlag(rawText)
                                    let nextStart = nextTimestamp(after: idx) ?? .greatestFiniteMagnitude

                                    // A line shows as active (white) if it's the current anchor OR it's a {q} line within linger window
                                    let showAsActive = isMainActive || (quick && currentTime >= lyricLines[idx].time && currentTime < nextStart + quickLinger)

                                    // Final blur for this row
                                    let blur = showAsActive ? 0 : progressive
                                    
                                    if isBlank {
                                        if isMainActive {
                                            LyricDotsTimeline(startWallTime: dotGapStartWall, duration: dotGapDuration)
                                                .frame(height: measuredSingleLine)
                                                .padding(.leading, leftInset)
                                                .padding(.trailing, rightWrapInset)
                                                .padding(.top, ripple.contains(idx) ? cascadeReserve : 0)
                                                .id(idx)
                                        } else {
                                            Color.clear.frame(height: 0).id(idx)
                                        }

                                    } else if isAsideLine || isForesideLine {
                                        Color.clear.frame(height: 0).id(idx)

                                    } else if isCredits {
                                        CreditsRow(
                                            text: displayText,
                                            activeByPenult: penultReached,
                                            blur: blur,
                                            leftInset: leftInset,
                                            rightInset: rightWrapInset,
                                            fontSize: creditsFontSize,
                                            weight: creditsWeight,
                                            liftUp: pastLift,
                                            shouldLift: idx < (persistentActiveIndex ?? -1)
                                        )
                                        .padding(.top, ripple.contains(idx) ? cascadeReserve : 0)
                                        .id(idx)
                                        .background(GeometryReader { g in
                                            Color.clear.preference(key: LineHeightKey.self, value: [idx: g.size.height])
                                        })

                                    } else {
                                        
                                        // For right-aligned rows, reduce the visual right padding by duetRightTighten.
                                        // Because of the leading/trailing swap, lowering `leftInset` tightens the right edge.
                                        let leftInsetForRow = isDuetR ? max(0, leftInset - duetRightTighten) : leftInset

                                        // Use a smaller active reserve on the right for right-aligned rows
                                        let reserve = isDuetR ? duetRightActiveReserve : 24
                                        
                                        MainLyricRow(
                                            text: displayText,
                                            isActive: showAsActive,
                                            blur: blur,
                                            leftInset: leftInsetForRow,     // <-- tightened when right-aligned
                                            rightInset: rightWrapInset,
                                            fontSize: lyricFontSize,
                                            extraTop: (ripple.contains(idx) ? cascadeReserve : 0) + foresidePad(for: idx),
                                            liftUp: pastLift,
                                            shouldLift: idx < (persistentActiveIndex ?? -1),
                                            alignRight: isDuetR,
                                            activeReserve: reserve          // <-- smaller on right-aligned rows
                                        )
                                        .id(idx)
                                        .background(GeometryReader { g in
                                            Color.clear.preference(key: LineHeightKey.self, value: [idx: g.size.height])
                                        })
                                        .anchorPreference(key: ActiveLineBoundsKey.self, value: .bounds) { anchor in
                                            showAsActive ? [idx: anchor] : [:]
                                        }
                                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isMainActive)
                                        .animation(.easeOut(duration: rippleDuration), value: ripple)
                                    }
                                }
                            }
                            Color.clear.frame(height: extendToBottom ? screenGeo.size.height / 3 : screenGeo.size.height / 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onPreferenceChange(LineHeightKey.self) { perLineHeights = $0 }

                    // ===== Overlays (Asides/Foresides) =====
                    .overlayPreferenceValue(ActiveLineBoundsKey.self) { anchors in
                        GeometryReader { proxy in
                            if let a = persistentActiveIndex, let anchor = anchors[a] {
                                let rect = proxy[anchor]
                                VStack(alignment: .leading, spacing: asideStackSpacing) {
                                    ForEach(bracketedIndicesForMain(a), id: \.self) { bIdx in
                                        AsideItem(
                                            text: stripBrackets(lyricLines[bIdx].text),
                                            isOn: asideIsActive(bIdx),
                                            blur: blurForLine(at: bIdx, activeMain: persistentActiveIndex),
                                            leftInset: leftInset,
                                            rightInset: rightWrapInset,
                                            fontSize: asideFontSize,
                                            weight: asideWeight,
                                            lineSpacing: asideLineSpacing
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(.top, rect.maxY + asideTopGap)
                                .allowsHitTesting(false)
                                .animation(.easeOut(duration: 0.18), value: persistentActiveIndex)
                            }
                        }
                    }
                    .overlayPreferenceValue(ActiveLineBoundsKey.self) { anchors in
                        GeometryReader { proxy in
                            if let a = persistentActiveIndex, let anchor = anchors[a] {
                                let rect = proxy[anchor]
                                VStack(alignment: .leading, spacing: foresideStackSpacing) {
                                    ForEach(foresideIndicesForMain(a), id: \.self) { fIdx in
                                        ForesideItem(
                                            text: stripForeside(lyricLines[fIdx].text),
                                            isOn: (currentTime + 0.05) >= lyricLines[fIdx].time,
                                            blur: blurForLine(at: fIdx, activeMain: persistentActiveIndex),
                                            leftInset: leftInset,
                                            rightInset: rightWrapInset,
                                            fontSize: foresideFontSize,
                                            weight: foresideWeight,
                                            lineSpacing: foresideLineSpacing
                                        )
                                    }
                                }
                                .background(
                                    GeometryReader { g in
                                        Color.clear
                                            .onAppear  { foresideStackHeight = g.size.height }
                                            .onChange(of: g.size.height) { _, h in foresideStackHeight = h }
                                    }
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(.top, max(0, rect.minY - foresideTopGap - foresideStackHeight))
                                .allowsHitTesting(false)
                                .zIndex(4)
                            }
                        }
                    }

                    // Hidden single-line probe for height measurement
                    Text("Ay")
                        .font(.system(size: lyricFontSize, weight: .bold))
                        .lineSpacing(4)
                        .padding(.leading, leftInset)
                        .padding(.trailing, rightWrapInset)
                        .fixedSize()
                        .hidden()
                        .background(
                            GeometryReader { g in
                                Color.clear.onAppear { measuredSingleLine = g.size.height }
                            }
                        )
                }
                .onAppear {
                    lyricLines = parsePreservingBlanks(lyrics: lyrics)
                    updateDotSegment()
                    DispatchQueue.main.async {
                        if let target = anchorTargetID { proxy.scrollTo(target, anchor: .top) }
                    }
                }
                .onChange(of: lyrics) { _, newLyrics in
                    lyricLines = parsePreservingBlanks(lyrics: newLyrics)
                    updateDotSegment()
                }
                .onChange(of: persistentActiveIndex ?? -1) { _, newActive in
                    updateDotSegment()
                    if newActive >= 0 { triggerRipple(from: newActive) }
                    if let target = anchorTargetID {
                        withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(target, anchor: .top) }
                    }
                }
                .onChange(of: currentTime) { _ in updateDotSegment() }
            }
        }
    }
}

// ─────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────
private func clamp<T: Comparable>(_ x: T, _ a: T, _ b: T) -> T { min(max(x, a), b) }
private func easeInQuad(_ t: Double) -> CGFloat { CGFloat(t * t) }
private func easeOutCubic(_ t: Double) -> CGFloat { let u = 1 - t; return CGFloat(1 - u*u*u) }
