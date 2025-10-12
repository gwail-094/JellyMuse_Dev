// MusicBackgroundView.swift
// JellyMuse
//
// Apple Music-style background system

import SwiftUI
import UIKit

/// Apple Music-style background that adapts to album artwork
struct MusicBackgroundView: View {
    // Extracted colors from artwork (2-4 colors work best)
    let colors: [Color]
    
    // Optional: subtle bass response (0...1)
    var bassLevel: CGFloat = 0
    
    // Style preferences
    var usesMesh: Bool = true  // Use mesh on iOS 18+, gradient fallback
    var animateTransitions: Bool = true
    
    var body: some View {
        Group {
            if #available(iOS 18.0, *), usesMesh {
                meshBackground
            } else {
                gradientBackground
            }
        }
        .ignoresSafeArea()
    }
    
    // MARK: - iOS 18+ Mesh Gradient
    @available(iOS 18.0, *)
    private var meshBackground: some View {
        TimelineView(.animation(minimumInterval: 0.5)) { timeline in
            meshContent(for: timeline)
        }
    }
    
    @available(iOS 18.0, *)
    @ViewBuilder
    private func meshContent(for timeline: TimelineViewDefaultContext) -> some View {
        let meshColors = paddedColors(to: 9)
        let t = timeline.date.timeIntervalSinceReferenceDate
        let breathe = sin(t * 0.15) * 0.02
        let bassInfluence = bassLevel * 0.03
        let points = meshPoints(breathe: breathe + bassInfluence)
        
        MeshGradient(
            width: 3,
            height: 3,
            points: points,
            colors: meshColors
        )
        .blur(radius: 60)
    }
    
    @available(iOS 18.0, *)
    private func meshPoints(breathe: CGFloat) -> [SIMD2<Float>] {
        let base: [SIMD2<Float>] = [
            .init(0.0, 0.0), .init(0.5, 0.0), .init(1.0, 0.0),
            .init(0.0, 0.5), .init(0.5, 0.5), .init(1.0, 0.5),
            .init(0.0, 1.0), .init(0.5, 1.0), .init(1.0, 1.0)
        ]
        
        let breatheF = Float(breathe)
        let edgeMultiplier: Float = 0.4
        
        return base.enumerated().map { (index, pt) -> SIMD2<Float> in
            switch index {
            case 4:
                return .init(pt.x + breatheF, pt.y + breatheF * 0.7)
            case 1, 3, 5, 7:
                let dx = breatheF * edgeMultiplier
                let dy = breatheF * edgeMultiplier * 0.7
                return .init(pt.x + dx, pt.y + dy)
            default:
                return pt
            }
        }
    }
    
    // MARK: - Fallback Gradient
    private var gradientBackground: some View {
        let gradColors = paddedColors(to: 4) // Use all 4 colors for richness
        
        return ZStack {
            // Use the darkest color as a subtle base
            (gradColors[3])
            
            // Layer multiple radial gradients for a more complex blend
            RadialGradient(
                colors: [gradColors[0].opacity(0.8), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 700
            )
            
            RadialGradient(
                colors: [gradColors[1].opacity(0.7), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 600
            )
            
            RadialGradient(
                colors: [gradColors[2].opacity(0.6), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 500
            )
            
            bassPulseLayer(colors: gradColors)
        }
        .blur(radius: 80) // Soften everything into a smooth blend
    }

    @ViewBuilder
    private func bassPulseLayer(colors: [Color]) -> some View {
        if bassLevel > 0.1 {
            RadialGradient(
                colors: [colors[1].opacity(bassLevel * 0.3), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 400
            )
            .blendMode(.plusLighter)
        }
    }
    
    // MARK: - Helpers
    private func paddedColors(to count: Int) -> [Color] {
        guard !colors.isEmpty else {
            return Array(repeating: .gray, count: count)
        }
            
        if colors.count >= count {
            return Array(colors.prefix(count))
        }
            
        var result = colors
        while result.count < count {
            let base = result[result.count % colors.count]
            result.append(base.opacity(0.7))
        }
        return Array(result.prefix(count))
    }
}

// MARK: - Color Extraction Improvements
extension UIColor {
    /// Enhanced HSV-based color manipulation
    func adjusted(
        hueShift: CGFloat = 0,
        saturation: CGFloat? = nil,
        brightness: CGFloat? = nil
    ) -> UIColor {
        let current = hsv
        return UIColor(
            hue: (current.h + hueShift).truncatingRemainder(dividingBy: 1.0),
            saturation: saturation ?? current.s,
            brightness: brightness ?? current.v,
            alpha: current.a
        )
    }
}
