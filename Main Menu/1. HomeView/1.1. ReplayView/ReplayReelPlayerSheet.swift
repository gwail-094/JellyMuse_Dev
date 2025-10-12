import SwiftUI
import AVKit

struct ReplayReelPlayerSheet: View {
    let year: Int

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var currentIndex: Int = 1
    @State private var maxIndex: Int = 1 // bump later when you add 2.mp4, 3.mp4...

    private let base = URL(string: "http://192.168.1.169/replay/reels")!

    private func urlFor(index: Int) -> URL {
        base.appendingPathComponent("\(year)/\(index).mp4")
    }

    @MainActor
    private func load(index: Int) {
        let url = urlFor(index: index)
        let item = AVPlayerItem(url: url)
        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        p.actionAtItemEnd = .pause
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        p.play()
    }

    @MainActor
    private func goNext() {
        guard currentIndex < maxIndex else { return }
        currentIndex += 1
        load(index: currentIndex)
    }

    @MainActor
    private func goPrev() {
        guard currentIndex > 1 else { return }
        currentIndex -= 1
        load(index: currentIndex)
    }

    var body: some View {
        ZStack {
            if let player {
                // VideoPlayer automatically handles the AVPlayer lifecycle within its view scope.
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // Tap zones
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { goPrev() }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { goNext() }
            }
            .ignoresSafeArea()

            // Top UI
            VStack {
                HStack {
                    Button {
                        // Dismissing the sheet triggers .onDisappear, where the cleanup happens.
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("Highlight Reel \(year)")
                        .font(.headline)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)

                Spacer()

                HStack(spacing: 6) {
                    ForEach(1...maxIndex, id: \.self) { i in
                        Circle()
                            .frame(width: i == currentIndex ? 10 : 6, height: i == currentIndex ? 10 : 6)
                            .opacity(i == currentIndex ? 1 : 0.5)
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            currentIndex = 1
            maxIndex = 1 // set >1 when you add more files
            load(index: 1)
        }
        .onDisappear {
            // MARK: CRITICAL FIX for stopping audio playback
            // 1. Pause playback
            player?.pause()
            // 2. Explicitly remove the current item to free up system resources and the audio session.
            player?.replaceCurrentItem(with: nil)
            // 3. Release the AVPlayer object itself.
            player = nil
        }
    }
}
