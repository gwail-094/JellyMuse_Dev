import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

enum RepeatMode: Int { case off, all, one }

@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    static let shared = AudioPlayer()

    @Published var isPlaying = false
    @Published var currentTrack: JellyfinTrack?
    @Published var currentAlbumArtist: String?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLiveRadio = false
    @Published var currentRadio: RadioStation? = nil

    @Published private(set) var queue: [JellyfinTrack] = []
    @Published private(set) var currentQueueIndex: Int?
    @Published var upNext: [JellyfinTrack] = []
    @Published private(set) var history: [JellyfinTrack] = []

    @Published var autoplayEnabled = false
    @Published private(set) var infiniteQueue: [JellyfinTrack] = []
    
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleEnabled = false

    private let api = JellyfinAPIService.shared
    private let downloads = DownloadsAPI.shared
    
    private var player: AVQueuePlayer?
    private var timeObserverToken: Any?
    private var endObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var progressTimer: Timer?
    
    // AVQueuePlayer helpers
    private var itemToTrack: [AVPlayerItem:String] = [:] // map item → track.id
    private let lookaheadSeconds: Double = 12
    private var radioTimedMetadataKVO: NSKeyValueObservation?
    private var queueItemCancellable: AnyCancellable?
    private var boundaryTimeObservers: [Any]?
    
    // Interruption Handling
    private var interruptionCancellable: AnyCancellable? // ADDED

    private var durationHint: TimeInterval? = nil
    
    private let AA_DEBUG = true
    private var albumNameCache: [String: String] = [:]

    private func applyDuration(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        if seconds > duration {
            duration = seconds
            updateNowPlayingDurationAndRate()
        }
    }

    private var playbackQueue: [JellyfinTrack] = []
    private var currentIndex: Int?
    private var shuffleBaseline: [JellyfinTrack]? = nil

    private let stereoAttenuationDB: Float = -9.0
    private let multichannelAttenuationDB: Float = 0.0

    private let commandCenter = MPRemoteCommandCenter.shared()

    private func debugAnimatedArtworkSupport() {
        if AA_DEBUG {
            // ✅ [FIX] Updated to iOS 26.0 availability check
            if #available(iOS 26.0, *) {
                let supported = Set(MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys)
                print("AA 🔍 Animated Artwork Support Check:")
                print("AA 🔍 iOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
                print("AA 🔍 Supported keys: \(supported)")
                print("AA 🔍 3x4 supported: \(supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork))")
                print("AA 🔍 1x1 supported: \(supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork))")
            } else {
                print("AA 🔍 iOS version too old for animated artwork (need iOS 26+)")
            }
        }
    }
    
    override init() {
        super.init()
        configureAudioSession()
        setupRemoteCommandCenter()
        startInterruptionObserver() // ADDED
        
        debugAnimatedArtworkSupport()
        
        Task {
            await cleanOldCache(olderThan: 7 * 24 * 60 * 60) // 7 days
        }
    }

    // MARK: - Transport Control Helper
    
    private func enableTransportForOnDemand() {
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
    }

    // MARK: - Helper Functions
    
    private func stopRadioIfNeeded() {
        let rp = RadioAudioPlayer.shared
        if rp.isPlaying || rp.currentStation != nil {
            rp.stop()
            enableTransportForOnDemand()
        }
    }
    
    // MODIFIED: Removed setActive(true) and preferredBufferDuration
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // IMPORTANT: Remove .duckOthers / .mixWithOthers
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            // Removed setActive(true) and setPreferredIOBufferDuration(0.005)
            if AA_DEBUG { print("DEBUG: AudioSession category=.playback mode=.default") }
        } catch {
            print("ERROR: AudioSession setup failed: \(error)")
        }
    }
    
    private func activateAudioSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .default {
                try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            }
            try session.setActive(true, options: [])
            if AA_DEBUG {
                print("AudioSession ✅ active route=\(session.currentRoute.outputs.map{$0.portType.rawValue})")
            }
        } catch {
            print("AudioSession ⚠️ activation error:", (error as NSError).code, error.localizedDescription)
            if AA_DEBUG {
                print("AudioSession state: cat=\(session.category.rawValue) mode=\(session.mode.rawValue)")
            }
        }
    }

    // ADDED: Logic to resume only if the player was previously playing (via isPlaying flag)
    func resumeIfAppropriate() {
        // Only resume if we think we should be playing (i.e., user didn't manually pause)
        guard isPlaying else { return }
        
        // Re-activate just in case, then resume
        activateAudioSessionIfNeeded()
        player?.play()
        
        if AA_DEBUG { print("DEBUG: Interruption ended - attempting to resume playback.") }
        
        // Re-report progress as state might have changed during the brief pause
        if let currentTrack {
            api.reportNowPlayingProgress(
                itemId: currentTrack.id,
                position: player?.currentTime().seconds ?? 0,
                isPaused: false
            )
        }
    }
    
    // ADDED: Interruption observer logic
    func startInterruptionObserver() {
        interruptionCancellable =
            NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in
                guard let self else { return }

                guard
                    let info = note.userInfo,
                    let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
                else { return }

                switch type {
                case .began:
                    // iOS may auto-pause your player; just update UI if needed
                    if self.AA_DEBUG { print("DEBUG: AudioSession Interruption Began") }
                    break

                case .ended:
                    let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    
                    if self.AA_DEBUG {
                        let s = options.contains(.shouldResume) ? "shouldResume" : "NO-resume"
                        print("DEBUG: AudioSession Interruption Ended - Options: \(s)")
                    }

                    if options.contains(.shouldResume) {
                        // Re-activate just in case, then resume
                        try? AVAudioSession.sharedInstance().setActive(true) // Direct call is fine, but using your existing wrapper is safer.
                        self.resumeIfAppropriate()
                    }
                @unknown default: break
                }
            }
    }

    private func setupRemoteCommandCenter() {
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.resumePlayback() ?? .commandFailed
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pausePlayback() ?? .commandFailed
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextTrack(); return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.previousOrRestart()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime); return .success
        }
    }

    private func notifyNowPlayingChanged() {
        NotificationCenter.default.post(name: .jellyfinNowPlayingDidChange, object: nil)
    }

    private func startProgressTimer(for itemId: String) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.api.reportNowPlayingProgress(
                itemId: itemId,
                position: self.player?.currentTime().seconds ?? 0,
                isPaused: false
            )
        }
        if let t = progressTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func teardownCurrentItemButKeepQueue() {
        stopProgressTimer()
        cancelObservers()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        radioTimedMetadataKVO = nil
        
        queueItemCancellable?.cancel()
        queueItemCancellable = nil
        
        if let observers = boundaryTimeObservers {
            observers.forEach { player?.removeTimeObserver($0) }
        }
        boundaryTimeObservers = nil
        itemToTrack.removeAll()

        player?.pause()
        player = nil
        isPlaying = false

        currentTime = 0
        duration = 0
    }

    private func recomputeUpNext() {
        if let i = currentIndex, i + 1 < playbackQueue.count {
            upNext = Array(playbackQueue[(i + 1)...])
        } else {
            upNext = []
        }
    }

    private func pushToHistory(_ track: JellyfinTrack) {
        let id = track.id
        if history.last?.id != id {
            history.append(track)
            if history.count > 500 { history.removeFirst(history.count - 500) }
        }
    }

    func play(tracks: [JellyfinTrack], startIndex: Int = 0, albumArtist: String? = nil) {
        RadioAudioPlayer.shared.stop()
        enableTransportForOnDemand()

        guard !tracks.isEmpty, tracks.indices.contains(startIndex) else { return }

        if let prev = currentTrack {
            api.reportNowPlayingStopped(itemId: prev.id, position: player?.currentTime().seconds ?? 0)
            pushToHistory(prev)
        }

        teardownCurrentItemButKeepQueue()

        self.playbackQueue = tracks
        self.currentIndex = startIndex
        self.queue = tracks
        self.currentQueueIndex = startIndex
        self.recomputeUpNext()
        self.isLiveRadio = false
        self.currentRadio = nil

        let track = tracks[startIndex]
        
        if let ticks = track.runTimeTicks {
            let secs = TimeInterval(Double(ticks) / 10_000_000.0)
            self.durationHint = secs
            self.duration = secs
        } else {
            self.durationHint = nil
            self.duration = 0
        }

        print("▶️ AudioPlayer playing: \(track.name ?? "Unknown")")

        let trackId = track.id
        
        if let local = downloads.localURL(for: trackId) {
            let curItem = self.buildItem(for: track, url: local, headers: [:], isMultichannel: false)
            let qp = AVQueuePlayer(items: [curItem])
            qp.actionAtItemEnd = .advance
            qp.automaticallyWaitsToMinimizeStalling = true
            self.player = qp
            
            self.enqueueNextIfNeeded()
            self.installAdvanceObservers(on: qp, currentItem: curItem)

            self.finishStartPlayback(with: track, playerItem: curItem, albumArtist: albumArtist)
            return
        }

        api.preferredStreamChoice(for: trackId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] choice in
                guard let self else { return }
                guard let url = choice.url else { print("No stream URL"); return }

                let curItem = self.buildItem(for: track, url: url,
                                             headers: self.api.embyAuthHeaders,
                                             isMultichannel: choice.isMultichannel)

                let qp = AVQueuePlayer(items: [curItem])
                qp.actionAtItemEnd = .advance
                qp.automaticallyWaitsToMinimizeStalling = true
                self.player = qp
                
                self.enqueueNextIfNeeded()

                self.installAdvanceObservers(on: qp, currentItem: curItem)

                self.finishStartPlayback(with: track, playerItem: curItem, albumArtist: albumArtist)
            }
            .store(in: &cancellables)
    }

    private func finishStartPlayback(with track: JellyfinTrack,
                                     playerItem item: AVPlayerItem,
                                     albumArtist: String?) {
        self.isLiveRadio = false
        self.currentTrack = track
        self.currentAlbumArtist = albumArtist
        self.isPlaying = true

        addTimeObserver()
        setNowPlayingBaseInfo(for: track, albumArtist: albumArtist)
        
        if let hint = durationHint, hint > 0 {
            applyDuration(hint)
        }
        
        updateNowPlayingArtworkAsync(for: track)
        
        // ✅ [FIX] Updated to iOS 26.0 availability check
        if #available(iOS 26.0, *) {
            Task {
                await updateNowPlayingAnimatedArtwork(for: track)
            }
        }
        
        player?.preventsDisplaySleepDuringVideoPlayback = false
        player?.appliesMediaSelectionCriteriaAutomatically = true
        
        player?.play()
        notifyNowPlayingChanged()
        
        startProgressTimer(for: track.id)
        
        // Ensure the session is active before playback starts
        activateAudioSessionIfNeeded()
    }

    func togglePlayPause() {
        guard let p = player else { return }
        let stateStr = p.timeControlStatus == .playing ? "Paused" : "Playing"
        print("⏯️ AudioPlayer toggle: \(stateStr)")
        if p.timeControlStatus == .playing {
            _ = pausePlayback()
        } else {
            stopRadioIfNeeded()
            _ = resumePlayback()
        }
    }

    func nextTrack() {
        stopRadioIfNeeded()
        guard let qp = player else {
            if let auto = takeNextFromAutoplay() {
                play(tracks: [auto], startIndex: 0, albumArtist: auto.artists?.joined(separator: ", "))
            }
            return
        }
        
        enqueueNextIfNeeded()
        qp.advanceToNextItem()
        isPlaying = true
        qp.play()
    }

    func previousTrack() {
        stopRadioIfNeeded()
        guard let i = currentIndex, i > 0 else { seek(to: 0); return }
        play(tracks: playbackQueue, startIndex: i - 1, albumArtist: currentAlbumArtist)
    }
    
    func previousOrRestart(threshold: TimeInterval = 3.0) {
        guard !isLiveRadio else { return }

        let t = player?.currentTime().seconds ?? 0
        let canGoPrev = (currentIndex ?? 0) > 0

        if t.isFinite, t > threshold {
            seek(to: 0)
            return
        }

        if canGoPrev {
            previousTrack()
        } else {
            seek(to: 0)
        }
    }
    
    func toggleShuffle() {
        guard !playbackQueue.isEmpty else { return }

        if shuffleEnabled {
            if let base = shuffleBaseline {
                let currentId = currentTrack?.id
                playbackQueue = base
                if let id = currentId {
                    currentIndex = playbackQueue.firstIndex(where: { $0.id == id }) ?? currentIndex
                }
                queue = playbackQueue
                recomputeUpNext()
                rebuildQueuePlayerAfterShuffleChange()
            }
            shuffleBaseline = nil
            shuffleEnabled = false
            print("DEBUG: Shuffle OFF (restored original order)")
            return
        }

        shuffleBaseline = playbackQueue
        if let i = currentIndex {
            let head = Array(playbackQueue.prefix(i + 1))
            var tail = Array(playbackQueue.suffix(from: i + 1))
            if tail.count > 1 {
                var newTail = tail.shuffled()
                if newTail == tail && tail.count > 2 { newTail.shuffle() }
                playbackQueue = head + newTail
            }
        } else {
            playbackQueue.shuffle()
        }

        queue = playbackQueue
        recomputeUpNext()
        shuffleEnabled = true
        print("DEBUG: Shuffle ON (up next randomized)")
        
        rebuildQueuePlayerAfterShuffleChange()
    }

    private func rebuildQueuePlayerAfterShuffleChange() {
        guard let curIdx = currentIndex else { return }
        play(tracks: playbackQueue, startIndex: curIdx, albumArtist: currentAlbumArtist)
    }

    @discardableResult
    func cycleRepeatMode() -> RepeatMode {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        print("DEBUG: repeatMode = \(repeatMode)")
        return repeatMode
    }

    func setAutoplay(enabled: Bool, items: [JellyfinTrack]) {
        autoplayEnabled = enabled
        guard enabled else {
            infiniteQueue = []
            return
        }

        let currentId = currentTrack?.id
        var seen = Set<String>()
        let cleaned = items
            .filter { $0.id != currentId }
            .filter { seen.insert($0.id).inserted }

        infiniteQueue = cleaned
    }
    
    private func takeNextFromAutoplay() -> JellyfinTrack? {
        guard autoplayEnabled, !infiniteQueue.isEmpty else { return nil }
        return infiniteQueue.removeFirst()
    }
    
    func seek(to time: TimeInterval) {
        let range = player?.currentItem?.seekableTimeRanges.last?.timeRangeValue
        let maxT = range.map { ($0.start + $0.duration).seconds } ?? duration
        let target = min(max(0, time), maxT)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        updateNowPlayingElapsed()
    }

    func stop() {
        if isLiveRadio {
            stopRadio()
            return
        }
        if let cur = currentTrack {
            api.reportNowPlayingStopped(itemId: cur.id, position: player?.currentTime().seconds ?? 0)
        }

        stopProgressTimer()
        cancelObservers()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        radioTimedMetadataKVO = nil
        
        queueItemCancellable?.cancel()
        queueItemCancellable = nil

        if let observers = boundaryTimeObservers {
            observers.forEach { player?.removeTimeObserver($0) }
        }
        boundaryTimeObservers = nil

        player?.pause()
        player = nil
        isPlaying = false
        currentTrack = nil
        currentAlbumArtist = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        notifyNowPlayingChanged()

        queue.removeAll()
        currentQueueIndex = nil
        playbackQueue.removeAll()
        currentIndex = nil
        upNext.removeAll()
        
        repeatMode = .off
        shuffleEnabled = false
        shuffleBaseline = nil
        
        autoplayEnabled = false
        infiniteQueue.removeAll()
        itemToTrack.removeAll()
    }
    
    func playFromUpNextIndex(_ upNextIndex: Int) {
        stopRadioIfNeeded()
        guard let cur = currentIndex else { return }
        let target = cur + 1 + upNextIndex
        guard playbackQueue.indices.contains(target) else { return }
        play(tracks: playbackQueue, startIndex: target, albumArtist: currentAlbumArtist)
    }

    func playOneTrackThenResumeQueue(_ track: JellyfinTrack) {
        stopRadioIfNeeded()
        guard let cur = currentIndex, !playbackQueue.isEmpty else {
            play(tracks: [track], startIndex: 0, albumArtist: track.artists?.joined(separator: ", "))
            return
        }
        let insertAt = min(cur + 1, playbackQueue.count)
        playbackQueue.insert(track, at: insertAt)
        queue = playbackQueue
        recomputeUpNext()
        play(tracks: playbackQueue, startIndex: insertAt, albumArtist: currentAlbumArtist)
    }

    func playAutoplayFromIndex(_ index: Int) {
        stopRadioIfNeeded()
        guard autoplayEnabled, infiniteQueue.indices.contains(index) else { return }
        let selected = infiniteQueue[index]
        infiniteQueue.removeFirst(index + 1)
        if player == nil || playbackQueue.isEmpty || currentIndex == nil {
            play(tracks: [selected], startIndex: 0, albumArtist: selected.artists?.joined(separator: ", "))
        } else {
            let insertAt = min((currentIndex ?? 0) + 1, playbackQueue.count)
            playbackQueue.insert(selected, at: insertAt)
            queue = playbackQueue
            recomputeUpNext()
            play(tracks: playbackQueue, startIndex: insertAt, albumArtist: currentAlbumArtist)
        }
    }
    
    func moveUpNextItem(from fromUpNextIndex: Int, to toUpNextIndex: Int) {
        stopRadioIfNeeded()
        guard let cur = currentIndex else { return }
        let fromAbs = cur + 1 + fromUpNextIndex
        let toAbsRaw = cur + 1 + toUpNextIndex
        guard playbackQueue.indices.contains(fromAbs),
              playbackQueue.indices.contains(toAbsRaw) else { return }

        let item = playbackQueue.remove(at: fromAbs)
        let toAbs = (fromAbs < toAbsRaw) ? (toAbsRaw - 1) : toAbsRaw

        playbackQueue.insert(item, at: toAbs)
        queue = playbackQueue
        recomputeUpNext()
        
        if let cur = currentIndex {
            play(tracks: playbackQueue, startIndex: cur, albumArtist: currentAlbumArtist)
        }
    }

    func playRadio(_ station: RadioStation) {
        stop()
        let item = AVPlayerItem(url: station.streamURL)
        radioTimedMetadataKVO = item.observe(\.timedMetadata, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            let text = change.newValue??
                .compactMap { $0.value as? String }
                .first
            self.updateNowPlayingForRadio(station: station, liveText: text)
        }
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        self.player = AVQueuePlayer(playerItem: item)
        self.player?.automaticallyWaitsToMinimizeStalling = true
        self.player?.play()
        
        isLiveRadio = true
        currentRadio = station
        isPlaying = true
        currentTrack = nil
        currentAlbumArtist = nil
        currentTime = 0
        duration = 0
        updateNowPlayingForRadio(station: station, liveText: station.subtitle ?? "Live")
        notifyNowPlayingChanged()
    }

    func stopRadio() {
        guard isLiveRadio else { return }
        radioTimedMetadataKVO = nil
        player?.pause()
        player = nil
        isPlaying = false
        isLiveRadio = false
        currentRadio = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        notifyNowPlayingChanged()
    }

    private func makeWarmAsset(url: URL, headers: [String:String]) -> AVURLAsset {
        var opts: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        if !url.isFileURL {
            opts["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: opts)

        let keys = ["playable", "duration", "tracks"]
        asset.loadValuesAsynchronously(forKeys: keys, completionHandler: nil)

        return asset
    }

    private func buildItem(for track: JellyfinTrack, url: URL, headers: [String:String], isMultichannel: Bool) -> AVPlayerItem {
        let asset = makeWarmAsset(url: url, headers: headers)

        let item = AVPlayerItem(asset: asset)
        
        item.preferredForwardBufferDuration = 20
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        item.publisher(for: \.duration, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cm in
                let s = cm.seconds
                if s.isFinite, s > 0 {
                    self?.applyDuration(s)
                } else if let hint = self?.durationHint {
                    self?.applyDuration(hint)
                }
            }
            .store(in: &cancellables)

        item.publisher(for: \.seekableTimeRanges, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ranges in
                guard let tr = ranges.last?.timeRangeValue else { return }
                let end = (tr.start + tr.duration).seconds
                if end.isFinite, end > 0 {
                    self?.applyDuration(end)
                }
            }
            .store(in: &cancellables)

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in
                guard let self else { return }
                switch st {
                case .readyToPlay:
                    let s = item.duration.seconds
                    if s.isFinite, s > 0 { applyDuration(s) }
                    else if let hint = durationHint { applyDuration(hint) }

                    if self.player?.timeControlStatus != .playing {
                        self.player?.play()
                        self.isPlaying = true
                        self.updateNowPlayingDurationAndRate()
                    }
                case .failed:
                    print("ERROR: Item failed: \(item.error?.localizedDescription ?? "nil")")
                    if let ev = item.errorLog()?.events.first {
                        print("ERROR LOG: \(ev.errorComment ?? "") | \(ev.uri ?? "")")
                    }
                case .unknown:
                    print("DEBUG: Item status unknown (loading)")
                @unknown default: break
                }
            }
            .store(in: &cancellables)

        item.publisher(for: \.isPlaybackBufferEmpty).sink { _ in }.store(in: &cancellables)
        item.publisher(for: \.isPlaybackBufferFull).sink { _ in }.store(in: &cancellables)
        item.publisher(for: \.isPlaybackLikelyToKeepUp).sink { _ in }.store(in: &cancellables)

        let gainDB: Float = isMultichannel ? multichannelAttenuationDB : stereoAttenuationDB
        applyGain(item, linearGain: dbToLinear(gainDB))
        itemToTrack[item] = track.id
        return item
    }

    private func enqueueNextIfNeeded() {
        guard let qp = player,
              let i = currentIndex else { return }
        let nextIdx = i + 1
        guard playbackQueue.indices.contains(nextIdx) else { return }

        if qp.items().count > 1 { return }

        let nextTrack = playbackQueue[nextIdx]

        if let local = downloads.localURL(for: nextTrack.id) {
            let it = buildItem(for: nextTrack, url: local, headers: [:], isMultichannel: false)
            qp.insert(it, after: qp.currentItem)
        } else {
            api.preferredStreamChoice(for: nextTrack.id)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] choice in
                    guard let self, let qp = self.player, let url = choice.url else { return }
                    let it = self.buildItem(for: nextTrack, url: url,
                                             headers: self.api.embyAuthHeaders,
                                             isMultichannel: choice.isMultichannel)
                    if qp.items().count == 1 {
                        qp.insert(it, after: qp.currentItem)
                    }
                }
                .store(in: &cancellables)
        }
    }
    
    private func scheduleLookaheadBoundary(on item: AVPlayerItem) {
        guard item.duration.isNumeric, item.duration.seconds.isFinite else { return }
        let t = max(0.5, item.duration.seconds - lookaheadSeconds)
        let boundary = [NSValue(time: CMTime(seconds: t, preferredTimescale: 600))]
        
        if let observers = boundaryTimeObservers {
            observers.forEach { player?.removeTimeObserver($0) }
            boundaryTimeObservers = nil
        }
        
        let token = player?.addBoundaryTimeObserver(forTimes: boundary, queue: .main) { [weak self] in
            self?.enqueueNextIfNeeded()
        }
        if let token {
            boundaryTimeObservers = [token]
        }
    }

    private func installAdvanceObservers(on qp: AVQueuePlayer, currentItem: AVPlayerItem) {
        queueItemCancellable?.cancel()
        
        queueItemCancellable = qp.publisher(for: \.currentItem, options: [.new])
          .receive(on: DispatchQueue.main)
          .sink { [weak self] newItem in
              guard let self else { return }
              
              guard let item = newItem else {
                  self.handleItemEnded(isAutomaticAdvance: true)
                  return
              }

              if let id = self.itemToTrack[item],
                  let idx = self.playbackQueue.firstIndex(where: { $0.id == id }) {
                  
                  if let prevTrack = self.currentTrack {
                      self.api.reportNowPlayingStopped(itemId: prevTrack.id,
                                                       position: prevTrack.runTimeTicks.map { TimeInterval(Double($0) / 10_000_000.0) } ?? self.duration)
                      self.pushToHistory(prevTrack)
                  }
                  
                  self.currentIndex = idx
                  self.currentQueueIndex = idx
                  self.recomputeUpNext()

                  let track = self.playbackQueue[idx]
                  self.currentTrack = track
                  self.currentAlbumArtist = self.currentAlbumArtist
                  
                  self.api.reportNowPlayingStart(itemId: track.id)
                  self.api.markItemPlayed(track.id)
                  self.startProgressTimer(for: track.id)

                  self.setNowPlayingBaseInfo(for: track, albumArtist: self.currentAlbumArtist)
                  self.updateNowPlayingArtworkAsync(for: track)
                  // ✅ [FIX] Updated to iOS 26.0 availability check
                  if #available(iOS 26.0, *) {
                      Task {
                          await self.updateNowPlayingAnimatedArtwork(for: track)
                      }
                  }
                  self.notifyNowPlayingChanged()

                  self.scheduleLookaheadBoundary(on: item)
                  
                  self.enqueueNextIfNeeded()
              }
          }
    }

    @MainActor
    private func handleItemEnded(isAutomaticAdvance: Bool = false) {
        stopProgressTimer()
        
        if isAutomaticAdvance && repeatMode != .one {
            guard let i = currentIndex else { stop(); return }
            let next = i + 1
            
            if repeatMode == .all && !playbackQueue.isEmpty {
                play(tracks: playbackQueue, startIndex: 0, albumArtist: currentAlbumArtist)
                return
            }

            if let auto = takeNextFromAutoplay() {
                playbackQueue.append(auto)
                queue = playbackQueue
                recomputeUpNext()
                play(tracks: playbackQueue, startIndex: next, albumArtist: currentAlbumArtist)
                return
            }

            stop()
            return
        }
        
        let pos = { let s = player?.currentTime().seconds ?? duration
            return (s.isFinite && !s.isNaN && s >= 0) ? s : 0 }()

        if let cur = currentTrack {
            pushToHistory(cur)
            api.reportNowPlayingStopped(itemId: cur.id, position: pos)
        }

        if repeatMode == .one {
            guard let i = currentIndex else { return }
            play(tracks: playbackQueue, startIndex: i, albumArtist: currentAlbumArtist)
            return
        }

        stop()
    }

    private func addTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }

        timeObserverToken = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 2),
            queue: .main
        ) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds
            self.updateNowPlayingElapsed()
        }
    }

    private func cancelObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let observers = boundaryTimeObservers {
            observers.forEach { player?.removeTimeObserver($0) }
            boundaryTimeObservers = nil
        }
        
        queueItemCancellable?.cancel()
        queueItemCancellable = nil
        
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        
        if radioTimedMetadataKVO != nil {
            radioTimedMetadataKVO = nil
        }
        
        if interruptionCancellable != nil { // CANCELLABLE CLEANUP
            interruptionCancellable?.cancel()
            interruptionCancellable = nil
        }

        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
    
    // MARK: - setNowPlayingBaseInfo
    private func setNowPlayingBaseInfo(for track: JellyfinTrack, albumArtist: String?) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle]  = systemNowPlayingTitle(for: track)
        info[MPMediaItemPropertyArtist] = albumArtist ?? (track.artists?.joined(separator: ", ") ?? "")
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func updateNowPlayingForRadio(station: RadioStation, liveText: String?) {
        var title = station.name
        var artist: String? = liveText

        if let t = liveText, let dash = t.firstIndex(of: "-") {
            artist = String(t[..<dash]).trimmingCharacters(in: .whitespaces)
            title  = String(t[t.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
        }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let img = UIImage(named: station.imageName ?? "") {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlayingDurationAndRate() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingArtworkAsync(for track: JellyfinTrack) {
        let imageId = track.albumId ?? track.id
        guard let url = api.imageURL(for: imageId) else { return }

        Task.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                info[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    // MARK: - Animated Artwork
    
    private enum AAKey: String { case k1x1 = "1x1", k3x4 = "3x4" }

    private var animatedBaseURL: URL? {
        URL(string: "http://192.168.1.169/media/music")
    }

    private func artistAndAlbumNames(for track: JellyfinTrack) async -> (String, String)? {
        let artist = currentAlbumArtist ?? track.artists?.first
        guard let artist, !artist.isEmpty else {
            if AA_DEBUG { print("AA ⚠️ Missing artist for track \(track.id)") }
            return nil
        }
        guard let albumName = await resolvedAlbumName(for: track), !albumName.isEmpty else {
            if AA_DEBUG { print("AA ⚠️ Missing albumName for track \(track.id)") }
            return nil
        }
        return (artist, albumName)
    }

    private func resolvedAlbumName(for track: JellyfinTrack) async -> String? {
        guard let albumId = track.albumId, !albumId.isEmpty else {
            if AA_DEBUG { print("AA ⚠️ No albumId on track \(track.id)") }
            return nil
        }

        if let cached = albumNameCache[albumId], !cached.isEmpty {
            if AA_DEBUG { print("AA 💾 albumName (cached):", cached) }
            return cached
        }

        if let fetched = await fetchAlbumName(by: albumId), !fetched.isEmpty {
            albumNameCache[albumId] = fetched
            if AA_DEBUG { print("AA ⬇️ albumName (fetched):", fetched) }
            return fetched
        }

        if AA_DEBUG { print("AA ❌ Could not resolve album name for albumId=\(albumId)") }
        return nil
    }

    private func fetchAlbumName(by albumId: String) async -> String? {
        guard !api.serverURL.isEmpty, !api.authToken.isEmpty else {
            if AA_DEBUG { print("AA ❌ Missing serverURL/authToken") }
            return nil
        }
        guard let url = URL(string: api.serverURL + "Items/" + albumId) else {
            if AA_DEBUG { print("AA ❌ Bad URL for albumId:", albumId) }
            return nil
        }

        var req = URLRequest(url: url)
        req.addValue(api.authorizationHeader(withToken: api.authToken), forHTTPHeaderField: "X-Emby-Authorization")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                if AA_DEBUG { print("AA ❌ HTTP \(http.statusCode) for albumId:", albumId) }
                return nil
            }
            struct Item: Decodable { let Name: String? }
            let item = try JSONDecoder().decode(Item.self, from: data)
            return item.Name
        } catch {
            if AA_DEBUG { print("AA ❌ fetchAlbumName error:", error.localizedDescription) }
            return nil
        }
    }
    
    private func sanitizeForPath(_ s: String) -> String {
        return s.replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func sanitizeForFilename(_ s: String) -> String {
        let unsafe = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return s.components(separatedBy: unsafe).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
    }
    
    private func logAnimationInhibitors() {
        #if os(iOS)
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if AA_DEBUG {
            print("AA ⚙️ LowPowerMode=\(lpm) ReduceMotion=\(reduceMotion)")
            print("AA ⚙️ Auto-Play Animated Images must be ON in Settings ▸ Accessibility ▸ Motion")
        }
        // ✅ [FIX] Corrected conditional compilation directive syntax
        #endif
    }

    private func remoteAnimatedURL(for track: JellyfinTrack,
                                     variant: AAKey,
                                     ext: String) async -> URL? {
        guard let base = animatedBaseURL else { return nil }
        guard let (artist, albumName) = await artistAndAlbumNames(for: track) else { return nil }

        let artistPath = sanitizeForPath(artist)
        let albumPath  = sanitizeForPath(albumName)

        let url = base
            .appendingPathComponent(artistPath, isDirectory: true)
            .appendingPathComponent(albumPath,  isDirectory: true)
            .appendingPathComponent("cover_\(variant.rawValue).\(ext)")

        if AA_DEBUG { print("AA 🌐 remote \(variant.rawValue): \(url.absoluteString)") }
        return url
    }

    private func ensureLocal(url: URL, suggestedName: String, expectedMIMEs: Set<String>) async -> URL? {
        let dst = localCacheURL(filename: suggestedName)
        if FileManager.default.fileExists(atPath: dst.path) { return dst }

        do {
            var req = URLRequest(url: url)
            req.setValue(expectedMIMEs.joined(separator: ", "), forHTTPHeaderField: "Accept")

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                if AA_DEBUG, let http = resp as? HTTPURLResponse {
                    print("AA ❌ HTTP \(http.statusCode) for \(url.lastPathComponent)")
                }
                return nil
            }

            let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let ok = expectedMIMEs.contains(where: { mime.hasPrefix($0) })
            guard ok else {
                if AA_DEBUG { print("AA ❌ Unexpected MIME \(mime) for \(url.lastPathComponent)") }
                return nil
            }

            try data.write(to: dst, options: .atomic)
            return dst
        } catch {
            if AA_DEBUG { print("AA ❌ download failed \(url.lastPathComponent): \(error)") }
            return nil
        }
    }
    
    private func localCacheURL(filename: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("AnimatedArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename, isDirectory: false)
    }
    
    private func cleanOldCache(olderThan seconds: TimeInterval) async {
        let dir = localCacheURL(filename: "noop").deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [URLResourceKey.contentModificationDateKey]) else { return }
        
        let now = Date()
        var removed = 0
        for file in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modDate = attrs[FileAttributeKey.modificationDate] as? Date else { continue }
            
            if now.timeIntervalSince(modDate) > seconds {
                try? FileManager.default.removeItem(at: file)
                removed += 1
            }
        }
        if AA_DEBUG && removed > 0 {
            print("AA 🗑️ Cleaned \(removed) old cache file(s)")
        }
    }

    // ✅ [FIX] Updated to iOS 26.0 availability
    @available(iOS 26.0, *)
    private func firstAvailablePreview(for track: JellyfinTrack,
                                         variant: AAKey) async -> UIImage? {
        if AA_DEBUG { print("AA 🔔 preview handler fired for", variant.rawValue) }
        
        guard let albumName = await resolvedAlbumName(for: track) else {
            if AA_DEBUG { print("AA ❌ no album name for preview cache") }
            return nil
        }
        let albumKey = sanitizeForFilename(albumName)
        
        for ext in ["png", "jpg"] {
            if let remote = await remoteAnimatedURL(for: track, variant: variant, ext: ext) {
                if AA_DEBUG { print("AA 🌐 preview URL:", remote.absoluteString) }
                let name = "preview_\(variant.rawValue)_\(albumKey).\(ext)"
                let mimeSet: Set<String> = (ext == "png") ? ["image/png"] : ["image/jpeg", "image/jpg"]
                if let local = await ensureLocal(url: remote, suggestedName: name, expectedMIMEs: mimeSet) {
                    if let img = UIImage(contentsOfFile: local.path) {
                        if AA_DEBUG { print("AA 🖼️ preview ok (\(variant.rawValue)) → \(local.lastPathComponent)") }
                        return img
                    } else if AA_DEBUG {
                        print("AA ⚠️ preview not available for", variant.rawValue, "ext:", ext)
                    }
                }
            }
        }
        if AA_DEBUG { print("AA ❌ no preview image for", variant.rawValue) }
        return nil
    }

    // ✅ [FIX] Updated to iOS 26.0 availability
    @available(iOS 26.0, *)
    private func localVideoURL(for track: JellyfinTrack,
                                 variant: AAKey) async -> URL? {
        if AA_DEBUG { print("AA 🔔 video handler fired for", variant.rawValue) }
        guard let remote = await remoteAnimatedURL(for: track, variant: variant, ext: "mp4") else {
            if AA_DEBUG { print("AA ❌ no remote mp4 URL for", variant.rawValue) }
            return nil
        }
        if AA_DEBUG { print("AA 🌐 video URL:", remote.absoluteString) }
        
        guard let albumName = await resolvedAlbumName(for: track) else {
            if AA_DEBUG { print("AA ❌ no album name for video cache") }
            return nil
        }
        let albumKey = sanitizeForFilename(albumName)
        let name = "video_\(variant.rawValue)_\(albumKey).mp4"
        
        let mimeSet: Set<String> = ["video/mp4", "application/octet-stream"]
        let file = await ensureLocal(url: remote, suggestedName: name, expectedMIMEs: mimeSet)
        
        if let file {
            let asset = AVURLAsset(url: file)
            let ok = await (try? asset.load(.tracks))?.contains { $0.mediaType == .video } ?? false
            if !ok {
                if AA_DEBUG { print("AA ❌ cached mp4 has no video tracks; removing:", file.lastPathComponent) }
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            if AA_DEBUG { print("AA 🎞️ video (\(variant.rawValue)) local:", file.path, "exists:", true) }
        }
        return file
    }

    // ✅ [FIX] Updated to iOS 26.0 availability
    @available(iOS 26.0, *)
    private func makeAnimatedArtwork(for track: JellyfinTrack,
                                     variant: AAKey) -> MPMediaItemAnimatedArtwork {
        let artworkID = "\((track.albumId ?? track.id))_\(variant.rawValue)"

        return MPMediaItemAnimatedArtwork(
            artworkID: artworkID,
            previewImageRequestHandler: { _ in
                await self.firstAvailablePreview(for: track, variant: variant)
            },
            videoAssetFileURLRequestHandler: { _ in
                await self.localVideoURL(for: track, variant: variant)
            }
        )
    }

    // ✅ [FIX] Updated to iOS 26.0 availability
    @available(iOS 26.0, *)
    @MainActor
    private func updateNowPlayingAnimatedArtwork(for track: JellyfinTrack) async {
        if AA_DEBUG { print("AA 🚀 updateNowPlayingAnimatedArtwork called for track: \(track.name ?? "Unknown")") }
        
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            if AA_DEBUG { print("AA ❌ No nowPlayingInfo available") }
            return
        }

        let supported = Set(MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys)

        if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) {
            if AA_DEBUG { print("AA 🎬 Creating 3x4 animated artwork...") }
            let tall = makeAnimatedArtwork(for: track, variant: .k3x4)
            info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = tall
            if AA_DEBUG { print("AA ➕ set 3x4 artwork object") }
        } else {
            if AA_DEBUG { print("AA ⚠️ 3x4 not supported on this surface") }
        }
        
        if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) {
            if AA_DEBUG { print("AA 🎬 Creating 1x1 animated artwork...") }
            let square = makeAnimatedArtwork(for: track, variant: .k1x1)
            info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = square
            if AA_DEBUG { print("AA ➕ set 1x1 artwork object") }
        }


        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        
        if AA_DEBUG {
            let hasTall = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoProperty3x4AnimatedArtwork] != nil
            let hasSquare = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoProperty1x1AnimatedArtwork] != nil
            print("AA 📦 nowPlayingInfo has 3x4:", hasTall, "has 1x1:", hasSquare)
        }
    }
    
    func clearAnimatedArtworkCache() {
        let dir = localCacheURL(filename: "noop").deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        if AA_DEBUG { print("AA 🧹 Cleared AnimatedArtwork cache at \(dir.path)") }
    }

    private func dbToLinear(_ db: Float) -> Float { pow(10.0, db / 20.0) }

    private func applyGain(_ item: AVPlayerItem, linearGain: Float) {
        let params = AVMutableAudioMixInputParameters(track: nil)
        params.setVolume(linearGain, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    @discardableResult
    private func resumePlayback() -> MPRemoteCommandHandlerStatus {
        stopRadioIfNeeded()
        enableTransportForOnDemand()
        
        // Ensure the session is active before playback
        activateAudioSessionIfNeeded()
        
        guard let p = player else { return .commandFailed }
        p.play()
        isPlaying = true
        if let currentTrack {
            api.reportNowPlayingProgress(
                itemId: currentTrack.id,
                position: player?.currentTime().seconds ?? 0,
                isPaused: false
            )
        }
        updateNowPlayingDurationAndRate()
        notifyNowPlayingChanged()
        return .success
    }

    @discardableResult
    private func pausePlayback() -> MPRemoteCommandHandlerStatus {
        guard let p = player else { return .commandFailed }
        p.pause()
        isPlaying = false
        if let currentTrack {
            api.reportNowPlayingProgress(
                itemId: currentTrack.id,
                position: player?.currentTime().seconds ?? 0,
                isPaused: true
            )
        }
        updateNowPlayingDurationAndRate()
        notifyNowPlayingChanged()
        return .success
    }
}

extension AudioPlayer {
    func queueNext(_ track: JellyfinTrack) {
        if player == nil || playbackQueue.isEmpty || currentIndex == nil {
            play(tracks: [track], startIndex: 0, albumArtist: nil)
            return
        }
        let insertAt = min((currentIndex ?? 0) + 1, playbackQueue.count)
        playbackQueue.insert(track, at: insertAt)
        queue = playbackQueue
        recomputeUpNext()
        
        if let qp = player {
            qp.items().count == 1 || qp.items().isEmpty ? enqueueNextIfNeeded() : nil
        }
        if AA_DEBUG { print("DEBUG: queued next \(track.name ?? "?")") }
    }

    func queueLast(_ track: JellyfinTrack) {
        if player == nil || playbackQueue.isEmpty || currentIndex == nil {
            play(tracks: [track], startIndex: 0, albumArtist: nil)
            return
        }
        playbackQueue.append(track)
        queue = playbackQueue
        recomputeUpNext()
        
        if let qp = player {
            enqueueNextIfNeeded()
        }
        if AA_DEBUG { print("DEBUG: queued last \(track.name ?? "?")") }
    }
}

// MARK: - Explicit Marker Utility
extension AudioPlayer {
    private func systemNowPlayingTitle(for track: JellyfinTrack) -> String {
        let base = track.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "Unknown"
        
        let isExplicit = track.isExplicit ||
            (track.tags?.contains { $0.caseInsensitiveCompare("Explicit") == .orderedSame } ?? false)
        
        guard isExplicit else { return base }
        
        if base.contains("🅴") { return base }
        
        return base + " 🅴"
    }
}
