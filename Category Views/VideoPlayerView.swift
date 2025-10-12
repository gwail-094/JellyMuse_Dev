//
//  VideoPlayerView.swift
//  JellyMuse
//
//  Created by Ardit Sejdiu on 12.09.2025.
//


import SwiftUI
import AVKit

struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer?
    var gravity: AVLayerVideoGravity = .resizeAspect
    var onReady: (() -> Void)? = nil
    var onFail: (() -> Void)? = nil

    func makeUIView(context: Context) -> PlayerContainer {
            let v = PlayerContainer()
            v.backgroundColor = .clear
            v.playerLayer.videoGravity = gravity
            v.playerLayer.player = player

        // Observe current item if available
        if let item = player?.currentItem {
            context.coordinator.observe(item: item, onReady: onReady, onFail: onFail)
        }

        // Loop
        context.coordinator.loopToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { _ in
            player?.seek(to: .zero)
            player?.play()
        }

        player?.play()
        return v
    }

    func updateUIView(_ uiView: PlayerContainer, context: Context) {
        // Swap the player if it changed
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player?.pause()
            uiView.playerLayer.player = player
            player?.play()

            // Re-observe new item
            context.coordinator.teardown()
            if let item = player?.currentItem {
                context.coordinator.observe(item: item, onReady: onReady, onFail: onFail)
            }
        }
    }

    static func dismantleUIView(_ uiView: PlayerContainer, coordinator: Coordinator) {
        uiView.playerLayer.player?.pause()
        uiView.playerLayer.player = nil
        if let token = coordinator.loopToken {
            NotificationCenter.default.removeObserver(token)
            coordinator.loopToken = nil
        }
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class PlayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator: NSObject {
        private var statusObs: NSKeyValueObservation?
        var loopToken: NSObjectProtocol?

        func observe(item: AVPlayerItem, onReady: (() -> Void)?, onFail: (() -> Void)?) {
            statusObs = item.observe(\.status, options: [.initial, .new]) { it, _ in
                switch it.status {
                case .readyToPlay: onReady?()
                case .failed: onFail?()
                default: break
                }
            }
        }
        func teardown() { statusObs = nil }
    }
}
