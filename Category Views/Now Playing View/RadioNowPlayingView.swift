//
//  RadioNowPlayingView.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 11.09.2025.
//

import SwiftUI
import MediaPlayer
import AVKit
import CoreImage
import UIKit

// A simplified "Now Playing" view specifically for live radio.
// All shared components have been removed to prevent redeclaration errors.
struct RadioNowPlayingView: View {
    let onDismiss: () -> Void
    
    @ObservedObject private var radioPlayer = RadioAudioPlayer.shared
    @State private var volume: Float = AVAudioSession.sharedInstance().outputVolume

    // UI State
    @State private var viewWidth: CGFloat = 0
    @State private var dismissDragOffset: CGFloat = 0
    @State private var isDismissingInteractively = false
    
    // --- MODIFICATION 1: Dynamic Background ---
    // Replaced the static let with a @State var to allow dynamic updates.
    @State private var backgroundColors: [Color] = [Color(.darkGray), Color(.black)]

    // ---- Color cache (by asset name) ----
    private static var radioColorCache = NSCache<NSString, NSArray>()

    // Average color → tasteful gradient
    private func gradientFrom(image: UIImage) -> [Color] {
        guard let avg = averageUIColor(from: image) else {
            return [Color(.darkGray), Color(.black)]
        }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 1
        avg.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let bottom = UIColor(hue: h,
                             saturation: min(1, s * 0.95 + 0.05),
                             brightness: max(0.16, v * 0.38),
                             alpha: a)
        let top = UIColor(hue: h,
                          saturation: max(0.15, s * 0.85),
                          brightness: min(0.92, max(0.28, v * 0.82 + 0.08)),
                          alpha: a)
        return [Color(bottom), Color(top)]
    }

    private func averageUIColor(from image: UIImage) -> UIColor? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        let vector = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                      parameters: [kCIInputImageKey: input, kCIInputExtentKey: vector]),
              let output = filter.outputImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: kCFNull!])
        ctx.render(output, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
        return UIColor(red: CGFloat(bytes[0]) / 255,
                       green: CGFloat(bytes[1]) / 255,
                       blue: CGFloat(bytes[2]) / 255,
                       alpha: 1)
    }

    private func updateBackgroundFromStation() {
        guard let name = radioPlayer.currentStation?.imageName,
              let img = UIImage(named: name) else {
            backgroundColors = [Color(.darkGray), Color(.black)]
            return
        }
        if let cached = Self.radioColorCache.object(forKey: name as NSString) as? [UIColor], cached.count == 2 {
            backgroundColors = cached.map(Color.init)
            return
        }
        let grad = gradientFrom(image: img)
        Self.radioColorCache.setObject(grad.map { UIColor($0) } as NSArray, forKey: name as NSString)
        backgroundColors = grad
    }
    
    private func updateBackgroundFrom(image: UIImage) {
        let grad = gradientFrom(image: image)
        backgroundColors = grad
    }
    // --- END MODIFICATION 1 ---
    
    private let volumeDidChange = NotificationCenter.default.publisher(
        for: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification")
    )

    // MARK: - Main Body
    
    var body: some View {
        ZStack {
            // Read the screen width once
            GeometryReader { geometry in
                Color.clear.onAppear { self.viewWidth = geometry.size.width }
            }

            // Background gradient and vignette
            backgroundLayer
                .overlay(vignetteOverlay)

            // Hidden UIKit view to control system volume
            VolumeControlView(volume: $volume)
                .frame(width: 0, height: 0)
                .hidden()

            VStack(spacing: 0) {
                topGrabber
                Spacer()
                stationArtwork
                Spacer()
            }
            .frame(maxWidth: 430)

            // Simplified controls for radio
            RadioControlsView(
                radioPlayer: radioPlayer,
                volumeBinding: volumeBinding
            )
        }
        .offset(y: dismissDragOffset)
        .gesture(dismissDragGesture) // Attach dismiss gesture to the whole view
        .preferredColorScheme(.dark)
        // --- MODIFICATION 1: Hooking up the background update ---
        .onAppear {
            volume = AVAudioSession.sharedInstance().outputVolume
            updateBackgroundFromStation() // <-- Added
        }
        .onChange(of: radioPlayer.currentStation?.imageName) { _, _ in
            updateBackgroundFromStation() // <-- Added
        }
        // --- END MODIFICATION 1 ---
        .onReceive(volumeDidChange) { notification in
            if let newVolume = notification.userInfo?["AVSystemController_AudioVolumeNotificationParameter"] as? Float {
                self.volume = newVolume
            }
        }
    }

    // MARK: - View Components

    private var backgroundLayer: some View {
        LinearGradient(gradient: Gradient(colors: backgroundColors),
                       startPoint: .bottom, endPoint: .top)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: backgroundColors) // Animate color changes
    }

    private var vignetteOverlay: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.58), location: 0.00),
                .init(color: Color.black.opacity(0.34), location: 0.35),
                .init(color: (backgroundColors.last ?? .black).opacity(0.0), location: 0.62)
            ],
            startPoint: .bottom, endPoint: .top
        )
        .blendMode(.multiply)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: backgroundColors) // Animate vignette changes
    }
    
    private var topGrabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.5))
            .frame(width: 48, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
    }

    private var stationArtwork: some View {
        let side = (viewWidth > 0 ? viewWidth : UIScreen.main.bounds.width) - 52

        return ZStack {
            if let img = radioPlayer.currentArtwork {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 25, y: 15)
                    .onAppear { updateBackgroundFrom(image: img) }
                    .onChange(of: radioPlayer.currentArtwork) { _, newImg in
                        if let newImg { updateBackgroundFrom(image: newImg) }
                    }
            } else if let name = radioPlayer.currentStation?.imageName, let img = UIImage(named: name) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 25, y: 15)
                    .onAppear { updateBackgroundFromStation() }
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: side, height: side)
                    .overlay(
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .resizable().scaledToFit()
                            .frame(width: side * 0.4, height: side * 0.4)
                            .foregroundColor(.secondary.opacity(0.8))
                    )
                    .shadow(color: .black.opacity(0.45), radius: 25, y: 15)
                    .onAppear { updateBackgroundFromStation() }
            }
        }
        .padding(.top, 10)
        .offset(y: -180)
    }


    // MARK: - Gestures & Bindings

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if !isDismissingInteractively && value.translation.height > 0 {
                    isDismissingInteractively = true
                }
                if isDismissingInteractively {
                    dismissDragOffset = max(0, value.translation.height * 0.95)
                }
            }
            .onEnded { value in
                guard isDismissingInteractively else { return }
                let shouldDismiss = value.predictedEndTranslation.height > 240 || dismissDragOffset > 160

                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    if shouldDismiss { onDismiss() }
                    dismissDragOffset = 0
                }
                isDismissingInteractively = false
            }
    }

    private var volumeBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(self.volume) },
            set: { self.volume = Float($0) }
        )
    }
}

// MARK: - Radio Controls Subview
private struct RadioControlsView: View {
    @ObservedObject var radioPlayer: RadioAudioPlayer
    let volumeBinding: Binding<Double>
    
    // --- MODIFICATION 2: "LIVE bar" ---
    // Live bar tunables
    private let liveBarImageName = "livebar"  // name of your asset
    private let liveBarWidth: CGFloat  = 350  // tweak freely
    private let liveBarHeight: CGFloat = 33   // tweak freely
    // --- END MODIFICATION 2 ---
    
    private let panelHeight: CGFloat = 320
    private let panelSafeBottom: CGFloat = 34
    private let controlsLift: CGFloat = 40
    
    var body: some View {
        VStack(spacing: 20) {
            // Station Title & Live Text
            titleArea
            
            // Playback & Volume Controls
            lowerControls
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 20 + panelSafeBottom)
        .frame(height: panelHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .offset(y: -controlsLift)
        .zIndex(50)
    }
    
    private var titleArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(radioPlayer.currentStation?.name ?? "Live Radio")
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)

            Text(radioPlayer.liveText ?? radioPlayer.currentStation?.subtitle ?? "Streaming live")
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 56)
    }
    
    private var lowerControls: some View {
        VStack(spacing: 20) {
            // --- MODIFICATION 2: "LIVE bar" ---
            // LIVE bar
            Image(liveBarImageName)
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .antialiased(true)
                .frame(width: liveBarWidth, height: liveBarHeight)
                .opacity(0.95)
                .accessibilityLabel("Live")
            // --- END MODIFICATION 2 ---

            // Main play/pause button
            HStack(spacing: 60) {
                Button(action: {
                    radioPlayer.togglePlayPause()
                }) {
                    Image(systemName: radioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44, weight: .regular))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(height: 56)

            // Volume slider and bottom actions
            VStack(spacing: 30) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "speaker.fill")
                    ExpandingSlider(value: volumeBinding, type: .volume)
                        .frame(height: 44)
                    Image(systemName: "speaker.wave.3.fill")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                bottomActionButtons
            }
            .padding(.top, 10)
        }
    }
    
    private var bottomActionButtons: some View {
        HStack {
            Spacer()

            Button(action: {}, label: {
                Image(systemName: "quote.bubble")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            })
            .disabled(true)

            Spacer()

            CustomAirPlayButton()
                .padding(.horizontal, CGFloat(4))

            Spacer()

            Button(action: {}, label: {
                Image(systemName: "list.bullet")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            })
            .disabled(true)

            Spacer()
        }
        .font(.title2)
        .foregroundStyle(.primary)
    }
}
