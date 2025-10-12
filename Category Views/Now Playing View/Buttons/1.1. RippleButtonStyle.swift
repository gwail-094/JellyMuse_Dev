//
//  RippleButtonStyle.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 12.10.2025.
//


import SwiftUI
import UIKit

// MARK: Ripple (big round buttons: play/prev/next)
struct RippleButtonStyle: ButtonStyle {
    let size: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: size, height: size)
                .opacity(pressed ? 0.35 : 0)
                .scaleEffect(pressed ? 1.0 : 1.4)
                .animation(pressed ? .none : .easeOut(duration: 0.4), value: pressed)
            configuration.label
        }
        .frame(width: size, height: size)
    }
}

// MARK: Small circular buttons (favorite, more/ellipsis, etc.)
struct CircularButtonStyle: ButtonStyle {
    var size: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.10))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: Capsule “pill” buttons (shuffle/repeat/autoplay toggles)
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: Optional: tiny helper for bounce-on-tap scale
struct BounceOnTap: ViewModifier {
    @State private var scale: CGFloat = 1.0
    var down: CGFloat = 0.60
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: scale) { _ in } // keep SwiftUI happy
            .simultaneousGesture(TapGesture().onEnded {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { scale = down }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { scale = 1.0 }
                }
            })
    }
}
extension View { func bounceOnTap(_ down: CGFloat = 0.60) -> some View { modifier(BounceOnTap(down: down)) } }

// MARK: Optional: light haptics
enum Haptic {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}