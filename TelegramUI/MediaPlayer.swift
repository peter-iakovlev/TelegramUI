import Foundation
import SwiftSignalKit
import Postbox
import CoreMedia
import TelegramCore

private let traceEvents = false

private struct MediaPlayerControlTimebase {
    let timebase: CMTimebase
    let isAudio: Bool
}

private enum MediaPlayerPlaybackAction {
    case play
    case pause
}

private final class MediaPlayerLoadedState {
    let frameSource: MediaFrameSource
    let mediaBuffers: MediaPlaybackBuffers
    let controlTimebase: MediaPlayerControlTimebase
    var extraVideoFrames: ([MediaTrackFrame], CMTime)?
    var lostAudioSession: Bool = false
    
    init(frameSource: MediaFrameSource, mediaBuffers: MediaPlaybackBuffers, controlTimebase: MediaPlayerControlTimebase) {
        self.frameSource = frameSource
        self.mediaBuffers = mediaBuffers
        self.controlTimebase = controlTimebase
    }
}

private struct MediaPlayerSeekState {
    let duration: Double
}

private enum MediaPlayerState {
    case empty
    case seeking(frameSource: MediaFrameSource, timestamp: Double, seekState: MediaPlayerSeekState?, disposable: Disposable, action: MediaPlayerPlaybackAction, enableSound: Bool)
    case paused(MediaPlayerLoadedState)
    case playing(MediaPlayerLoadedState)
}

enum MediaPlayerActionAtEnd {
    case loop((() -> Void)?)
    case action(() -> Void)
    case loopDisablingSound(() -> Void)
    case stop
}

enum MediaPlayerPlayOnceWithSoundActionAtEnd {
    case loop
    case loopDisablingSound
    case stop
    case repeatIfNeeded
}

enum MediaPlayerSeek {
    case none
    case start
    case automatic
    case timecode(Double)
}

enum MediaPlayerStreaming {
    case none
    case conservative
    case earlierStart
    
    var enabled: Bool {
        if case .none = self {
            return false
        } else {
            return true
        }
    }
    
    var parameters: (Double, Double, Double) {
        switch self {
            case .none, .conservative:
                return (1.0, 2.0, 3.0)
            case .earlierStart:
                return (1.0, 1.0, 2.0)
        }
    }
}

private final class MediaPlayerAudioRendererContext {
    let renderer: MediaPlayerAudioRenderer
    var requestedFrames = false
    
    init(renderer: MediaPlayerAudioRenderer) {
        self.renderer = renderer
    }
}

private final class MediaPlayerContext {
    private let queue: Queue
    private let audioSessionManager: ManagedAudioSession
    
    private let postbox: Postbox
    private let resourceReference: MediaResourceReference
    private let tempFilePath: String?
    private let streamable: MediaPlayerStreaming
    private let video: Bool
    private let preferSoftwareDecoding: Bool
    private var enableSound: Bool
    private var baseRate: Double
    private let fetchAutomatically: Bool
    private var playAndRecord: Bool
    private var keepAudioSessionWhilePaused: Bool
    private var continuePlayingWithoutSoundOnLostAudioSession: Bool
    
    private var seekId: Int = 0
    
    private var state: MediaPlayerState = .empty
    private var audioRenderer: MediaPlayerAudioRendererContext?
    private var forceAudioToSpeaker = false
    fileprivate let videoRenderer: VideoPlayerProxy
    
    private var tickTimer: SwiftSignalKit.Timer?
    
    private var lastStatusUpdateTimestamp: Double?
    private let playerStatus: Promise<MediaPlayerStatus>
    
    fileprivate var actionAtEnd: MediaPlayerActionAtEnd = .stop
    
    private var stoppedAtEnd = false
    
    init(queue: Queue, audioSessionManager: ManagedAudioSession, playerStatus: Promise<MediaPlayerStatus>, postbox: Postbox, resourceReference: MediaResourceReference, tempFilePath: String?, streamable: MediaPlayerStreaming, video: Bool, preferSoftwareDecoding: Bool, playAutomatically: Bool, enableSound: Bool, baseRate: Double, fetchAutomatically: Bool, playAndRecord: Bool, keepAudioSessionWhilePaused: Bool, continuePlayingWithoutSoundOnLostAudioSession: Bool) {
        assert(queue.isCurrent())
        
        self.queue = queue
        self.audioSessionManager = audioSessionManager
        self.playerStatus = playerStatus
        self.postbox = postbox
        self.resourceReference = resourceReference
        self.tempFilePath = tempFilePath
        self.streamable = streamable
        self.video = video
        self.preferSoftwareDecoding = preferSoftwareDecoding
        self.enableSound = enableSound
        self.baseRate = baseRate
        self.fetchAutomatically = fetchAutomatically
        self.playAndRecord = playAndRecord
        self.keepAudioSessionWhilePaused = keepAudioSessionWhilePaused
        self.continuePlayingWithoutSoundOnLostAudioSession = continuePlayingWithoutSoundOnLostAudioSession
        
        self.videoRenderer = VideoPlayerProxy(queue: queue)
        
        self.videoRenderer.visibilityUpdated = { [weak self] value in
            assert(queue.isCurrent())
            
            if let strongSelf = self, !strongSelf.enableSound || strongSelf.continuePlayingWithoutSoundOnLostAudioSession {
                switch strongSelf.state {
                    case .empty:
                        if value && playAutomatically {
                            strongSelf.play()
                        }
                    case .paused:
                        if value {
                            strongSelf.play()
                        }
                    case .playing:
                        if !value {
                            strongSelf.pause(lostAudioSession: false)
                        }
                    case let .seeking(_, _, _, _, action, _):
                        switch action {
                            case .pause:
                                if value {
                                    strongSelf.play()
                                }
                            case .play:
                                if !value {
                                    strongSelf.pause(lostAudioSession: false)
                                }
                        }
                }
            }
        }
        
        self.videoRenderer.takeFrameAndQueue = (queue, { [weak self] in
            assert(queue.isCurrent())
            
            if let strongSelf = self {
                var maybeLoadedState: MediaPlayerLoadedState?
                
                switch strongSelf.state {
                    case .empty:
                        return .noFrames
                    case let .paused(state):
                        maybeLoadedState = state
                    case let .playing(state):
                        maybeLoadedState = state
                    case .seeking:
                        return .noFrames
                }
                
                if let loadedState = maybeLoadedState, let videoBuffer = loadedState.mediaBuffers.videoBuffer {
                    if let (extraVideoFrames, atTime) = loadedState.extraVideoFrames {
                        loadedState.extraVideoFrames = nil
                        return .restoreState(extraVideoFrames, atTime)
                    } else {
                        return videoBuffer.takeFrame()
                    }
                } else {
                    return .noFrames
                }
            } else {
                return .noFrames
            }
        })
    }
    
    deinit {
        assert(self.queue.isCurrent())
        
        self.tickTimer?.invalidate()
        
        if case let .seeking(_, _, _, disposable, _, _) = self.state {
            disposable.dispose()
        }
    }
    
    fileprivate func seek(timestamp: Double) {
        assert(self.queue.isCurrent())
        
        let action: MediaPlayerPlaybackAction
        switch self.state {
            case .empty, .paused:
                action = .pause
            case .playing:
                action = .play
            case let .seeking(_, _, _, _, currentAction, _):
                action = currentAction
        }
        self.seek(timestamp: timestamp, action: action)
    }
    
    fileprivate func seek(timestamp: Double, action: MediaPlayerPlaybackAction) {
        assert(self.queue.isCurrent())
        
        var loadedState: MediaPlayerLoadedState?
        var seekState: MediaPlayerSeekState?
        switch self.state {
            case .empty:
                break
            case let .playing(currentLoadedState):
                loadedState = currentLoadedState
            case let .paused(currentLoadedState):
                loadedState = currentLoadedState
            case let .seeking(previousFrameSource, previousTimestamp, seekStateValue, previousDisposable, _, previousEnableSound):
                if previousTimestamp.isEqual(to: timestamp) && self.enableSound == previousEnableSound {
                    self.state = .seeking(frameSource: previousFrameSource, timestamp: previousTimestamp, seekState: seekStateValue, disposable: previousDisposable, action: action, enableSound: self.enableSound)
                    return
                } else {
                    seekState = seekStateValue
                    previousDisposable.dispose()
                }
        }
        
        self.tickTimer?.invalidate()
        var loadedDuration: Double?
        if let loadedState = loadedState {
            self.seekId += 1
            
            if loadedState.controlTimebase.isAudio {
                self.audioRenderer?.renderer.setRate(0.0)
            } else {
                if !CMTimebaseGetRate(loadedState.controlTimebase.timebase).isEqual(to: 0.0) {
                    CMTimebaseSetRate(loadedState.controlTimebase.timebase, 0.0)
                }
            }
            let currentTimestamp = CMTimeGetSeconds(CMTimebaseGetTime(loadedState.controlTimebase.timebase))
            var duration: Double = 0.0
            var videoStatus: MediaTrackFrameBufferStatus?
            if let videoTrackFrameBuffer = loadedState.mediaBuffers.videoBuffer {
                videoStatus = videoTrackFrameBuffer.status(at: currentTimestamp)
                duration = max(duration, CMTimeGetSeconds(videoTrackFrameBuffer.duration))
            }
            
            var audioStatus: MediaTrackFrameBufferStatus?
            if let audioTrackFrameBuffer = loadedState.mediaBuffers.audioBuffer {
                audioStatus = audioTrackFrameBuffer.status(at: currentTimestamp)
                duration = max(duration, CMTimeGetSeconds(audioTrackFrameBuffer.duration))
            }
            loadedDuration = duration
            let status = MediaPlayerStatus(generationTimestamp: CACurrentMediaTime(), duration: duration, dimensions: CGSize(), timestamp: min(max(timestamp, 0.0), duration), baseRate: self.baseRate, seekId: self.seekId, status: .buffering(initial: false, whilePlaying: action == .play), soundEnabled: self.enableSound)
            self.playerStatus.set(.single(status))
        } else {
            let duration = seekState?.duration ?? 0.0
            let status = MediaPlayerStatus(generationTimestamp: CACurrentMediaTime(), duration: duration, dimensions: CGSize(), timestamp: min(max(timestamp, 0.0), duration), baseRate: self.baseRate, seekId: self.seekId, status: .buffering(initial: false, whilePlaying: action == .play), soundEnabled: self.enableSound)
            self.playerStatus.set(.single(status))
        }
        
        let frameSource = FFMpegMediaFrameSource(queue: self.queue, postbox: self.postbox, resourceReference: self.resourceReference, tempFilePath: self.tempFilePath, streamable: self.streamable.enabled, video: self.video, preferSoftwareDecoding: self.preferSoftwareDecoding, fetchAutomatically: self.fetchAutomatically, stallDuration: self.streamable.parameters.0, lowWaterDuration: self.streamable.parameters.1, highWaterDuration: self.streamable.parameters.2)
        let disposable = MetaDisposable()
        let updatedSeekState: MediaPlayerSeekState?
        if let loadedDuration = loadedDuration {
            updatedSeekState = MediaPlayerSeekState(duration: loadedDuration)
        } else {
            updatedSeekState = seekState
        }
        self.state = .seeking(frameSource: frameSource, timestamp: timestamp, seekState: updatedSeekState, disposable: disposable, action: action, enableSound: self.enableSound)
        
        self.lastStatusUpdateTimestamp = nil
        
        let seekResult = frameSource.seek(timestamp: timestamp)
        |> deliverOn(self.queue)
        
        disposable.set(seekResult.start(next: { [weak self] seekResult in
            if let strongSelf = self {
                var result: MediaFrameSourceSeekResult?
                seekResult.with { object in
                    assert(strongSelf.queue.isCurrent())
                    result = object
                }
                if let result = result {
                    strongSelf.seekingCompleted(seekResult: result)
                } else {
                    assertionFailure()
                }
            }
        }, error: { _ in
        }))
    }
    
    fileprivate func seekingCompleted(seekResult: MediaFrameSourceSeekResult) {
        if traceEvents {
            print("seekingCompleted at \(CMTimeGetSeconds(seekResult.timestamp))")
        }
        
        assert(self.queue.isCurrent())
        
        guard case let .seeking(frameSource, _, _, _, action, _) = self.state else {
            assertionFailure()
            return
        }
        
        var buffers = seekResult.buffers
        if !self.enableSound {
            buffers = MediaPlaybackBuffers(audioBuffer: nil, videoBuffer: buffers.videoBuffer)
        }
        
        buffers.audioBuffer?.statusUpdated = { [weak self] in
            self?.tick()
        }
        buffers.videoBuffer?.statusUpdated = { [weak self] in
            self?.tick()
        }
        let controlTimebase: MediaPlayerControlTimebase
        
        if let _ = buffers.audioBuffer {
            let renderer: MediaPlayerAudioRenderer
            if let currentRenderer = self.audioRenderer, !currentRenderer.requestedFrames {
                renderer = currentRenderer.renderer
            } else {
                self.audioRenderer?.renderer.stop()
                self.audioRenderer = nil
                
                let queue = self.queue
                renderer = MediaPlayerAudioRenderer(audioSession: .manager(self.audioSessionManager), playAndRecord: self.playAndRecord, forceAudioToSpeaker: self.forceAudioToSpeaker, baseRate: self.baseRate, updatedRate: { [weak self] in
                    queue.async {
                        if let strongSelf = self {
                            strongSelf.tick()
                        }
                    }
                }, audioPaused: { [weak self] in
                    queue.async {
                        if let strongSelf = self {
                            if strongSelf.enableSound {
                                if strongSelf.continuePlayingWithoutSoundOnLostAudioSession {
                                    strongSelf.continuePlayingWithoutSound()
                                } else {
                                    strongSelf.pause(lostAudioSession: true)
                                }
                            } else {
                                strongSelf.seek(timestamp: 0.0, action: .play)
                            }
                        }
                    }
                })
                self.audioRenderer = MediaPlayerAudioRendererContext(renderer: renderer)
                renderer.start()
            }
            
            controlTimebase = MediaPlayerControlTimebase(timebase: renderer.audioTimebase, isAudio: true)
        } else {
            self.audioRenderer?.renderer.stop()
            self.audioRenderer = nil
            
            var timebase: CMTimebase?
            CMTimebaseCreateWithMasterClock(nil, CMClockGetHostTimeClock(), &timebase)
            controlTimebase = MediaPlayerControlTimebase(timebase: timebase!, isAudio: false)
            CMTimebaseSetTime(timebase!, seekResult.timestamp)
        }
        
        let loadedState = MediaPlayerLoadedState(frameSource: frameSource, mediaBuffers: buffers, controlTimebase: controlTimebase)
        loadedState.extraVideoFrames = (seekResult.extraDecodedVideoFrames, seekResult.timestamp)
        
        if let audioRenderer = self.audioRenderer?.renderer {
            let queue = self.queue
            audioRenderer.flushBuffers(at: seekResult.timestamp, completion: { [weak self] in
                queue.async { [weak self] in
                    if let strongSelf = self {
                        switch action {
                            case .play:
                                strongSelf.state = .playing(loadedState)
                                strongSelf.audioRenderer?.renderer.start()
                            case .pause:
                                strongSelf.state = .paused(loadedState)
                        }
                        
                        strongSelf.lastStatusUpdateTimestamp = nil
                        strongSelf.tick()
                    }
                }
            })
        } else {
            switch action {
                case .play:
                    self.state = .playing(loadedState)
                case .pause:
                    self.state = .paused(loadedState)
            }
            
            self.lastStatusUpdateTimestamp = nil
            self.tick()
        }
    }
    
    fileprivate func play() {
        assert(self.queue.isCurrent())
        
        switch self.state {
            case .empty:
                self.lastStatusUpdateTimestamp = nil
                if self.enableSound {
                    let queue = self.queue
                    let renderer = MediaPlayerAudioRenderer(audioSession: .manager(self.audioSessionManager), playAndRecord: self.playAndRecord, forceAudioToSpeaker: self.forceAudioToSpeaker, baseRate: self.baseRate, updatedRate: { [weak self] in
                        queue.async {
                            if let strongSelf = self {
                                strongSelf.tick()
                            }
                        }
                    }, audioPaused: { [weak self] in
                        queue.async {
                            if let strongSelf = self {
                                if strongSelf.enableSound {
                                    if strongSelf.continuePlayingWithoutSoundOnLostAudioSession {
                                        strongSelf.continuePlayingWithoutSound()
                                    } else {
                                        strongSelf.pause(lostAudioSession: true)
                                    }
                                } else {
                                    strongSelf.seek(timestamp: 0.0, action: .play)
                                }
                            }
                        }
                    })
                    self.audioRenderer = MediaPlayerAudioRendererContext(renderer: renderer)
                    renderer.start()
                }
                self.seek(timestamp: 0.0, action: .play)
            case let .seeking(frameSource, timestamp, seekState, disposable, _, enableSound):
                self.state = .seeking(frameSource: frameSource, timestamp: timestamp, seekState: seekState, disposable: disposable, action: .play, enableSound: enableSound)
                self.lastStatusUpdateTimestamp = nil
            case let .paused(loadedState):
                if loadedState.lostAudioSession {
                    let timestamp = CMTimeGetSeconds(CMTimebaseGetTime(loadedState.controlTimebase.timebase))
                    self.seek(timestamp: timestamp, action: .play)
                } else {
                    self.lastStatusUpdateTimestamp = nil
                    if self.stoppedAtEnd {
                        self.seek(timestamp: 0.0, action: .play)
                    } else {
                        self.state = .playing(loadedState)
                        self.tick()
                    }
                }
            case .playing:
                break
        }
    }
    
    fileprivate func playOnceWithSound(playAndRecord: Bool, seek: MediaPlayerSeek = .start) {
        assert(self.queue.isCurrent())
        
        if !self.enableSound {
            self.lastStatusUpdateTimestamp = nil
            self.enableSound = true
            self.playAndRecord = playAndRecord
            
            var loadedState: MediaPlayerLoadedState?
            switch self.state {
                case .empty:
                    break
                case let .playing(currentLoadedState):
                    loadedState = currentLoadedState
                case let .paused(currentLoadedState):
                    loadedState = currentLoadedState
                case let .seeking(_, timestamp, _, disposable, action, _):
                    self.state = .empty
                    disposable.dispose()
                    self.seek(timestamp: timestamp, action: action)
            }
            
            var timestamp: Double
            if case let .timecode(time) = seek {
                timestamp = time
            }
            else if let loadedState = loadedState, case .none = seek {
                timestamp = CMTimeGetSeconds(CMTimebaseGetTime(loadedState.controlTimebase.timebase))
                if let duration = self.currentDuration() {
                    if timestamp > duration - 2.0 {
                        timestamp = 0.0
                    }
                }
            } else {
                timestamp = 0.0
            }
            self.seek(timestamp: timestamp, action: .play)
        } else {
            if case let .timecode(time) = seek {
                self.seek(timestamp: Double(time), action: .play)
            }
            else if case .playing = self.state {
            } else {
                self.play()
            }
        }
    }
    
    fileprivate func continuePlayingWithoutSound() {
        if self.enableSound {
            self.lastStatusUpdateTimestamp = nil
            
            var loadedState: MediaPlayerLoadedState?
            switch self.state {
                case .empty:
                    break
                case let .playing(currentLoadedState):
                    loadedState = currentLoadedState
                case let .paused(currentLoadedState):
                    loadedState = currentLoadedState
                case let .seeking(_, timestamp, _, disposable, action, _):
                    if self.enableSound {
                        self.state = .empty
                        disposable.dispose()
                        self.enableSound = false
                        self.seek(timestamp: timestamp, action: action)
                    }
            }
            
            if let loadedState = loadedState {
                self.enableSound = false
                self.playAndRecord = false
                
                var timestamp = CMTimeGetSeconds(CMTimebaseGetTime(loadedState.controlTimebase.timebase))
                if let duration = self.currentDuration(), timestamp > duration - 2.0 {
                    timestamp = 0.0
                }
                self.seek(timestamp: timestamp, action: .play)
            }
        }
    }
    
    fileprivate func setContinuePlayingWithoutSoundOnLostAudioSession(_ value: Bool) {
        if self.continuePlayingWithoutSoundOnLostAudioSession != value {
            self.continuePlayingWithoutSoundOnLostAudioSession = value
        }
    }
    
    fileprivate func setBaseRate(_ baseRate: Double) {
        self.baseRate = baseRate
        self.lastStatusUpdateTimestamp = nil
        self.tick()
        self.audioRenderer?.renderer.setBaseRate(baseRate)
    }
    
    fileprivate func setForceAudioToSpeaker(_ value: Bool) {
        if self.forceAudioToSpeaker != value {
            self.forceAudioToSpeaker = value
            
            self.audioRenderer?.renderer.setForceAudioToSpeaker(value)
        }
    }
    
    fileprivate func setKeepAudioSessionWhilePaused(_ value: Bool) {
        if self.keepAudioSessionWhilePaused != value {
            self.keepAudioSessionWhilePaused = value
            
            var isPlaying = false
            switch self.state {
                case .playing:
                    isPlaying = true
                case let .seeking(_, _, _, _, action, _):
                    switch action {
                        case .play:
                            isPlaying = true
                        default:
                            break
                    }
                default:
                    break
            }
            if value && !isPlaying {
                self.audioRenderer?.renderer.stop()
            } else {
                self.audioRenderer?.renderer.start()
            }
        }
    }
    
    fileprivate func pause(lostAudioSession: Bool) {
        assert(self.queue.isCurrent())
        
        switch self.state {
            case .empty:
                break
            case let .seeking(frameSource, timestamp, seekState, disposable, _, enableSound):
                self.state = .seeking(frameSource: frameSource, timestamp: timestamp, seekState: seekState, disposable: disposable, action: .pause, enableSound: enableSound)
                self.lastStatusUpdateTimestamp = nil
            case let .paused(loadedState):
                if lostAudioSession {
                    loadedState.lostAudioSession = true
                }
            case let .playing(loadedState):
                if lostAudioSession {
                    loadedState.lostAudioSession = true
                }
                self.state = .paused(loadedState)
                self.lastStatusUpdateTimestamp = nil
                self.tick()
        }
    }
    
    fileprivate func togglePlayPause() {
        assert(self.queue.isCurrent())
        
        switch self.state {
            case .empty:
                self.play()
            case let .seeking(_, _, _, _, action, _):
                switch action {
                    case .play:
                        self.pause(lostAudioSession: false)
                    case .pause:
                        self.play()
                }
            case .paused:
                if !self.enableSound {
                    self.playOnceWithSound(playAndRecord: false, seek: .none)
                } else {
                    self.play()
                }
            case .playing:
                self.pause(lostAudioSession: false)
        }
    }
    
    private func currentDuration() -> Double? {
        var maybeLoadedState: MediaPlayerLoadedState?
        switch self.state {
            case let .paused(state):
                maybeLoadedState = state
            case let .playing(state):
                maybeLoadedState = state
            default:
                break
        }
        
        guard let loadedState = maybeLoadedState else {
            return nil
        }
        
        var duration: Double = 0.0
        if let videoTrackFrameBuffer = loadedState.mediaBuffers.videoBuffer {
            duration = max(duration, CMTimeGetSeconds(videoTrackFrameBuffer.duration))
        }

        if let audioTrackFrameBuffer = loadedState.mediaBuffers.audioBuffer {
            duration = max(duration, CMTimeGetSeconds(audioTrackFrameBuffer.duration))
        }
        return duration
    }
    
    private func tick() {
        self.tickTimer?.invalidate()
        
        var maybeLoadedState: MediaPlayerLoadedState?
        
        switch self.state {
            case .empty:
                return
            case let .paused(state):
                maybeLoadedState = state
            case let .playing(state):
                maybeLoadedState = state
            case .seeking:
                return
        }
        
        guard let loadedState = maybeLoadedState else {
            return
        }
        
        let timestamp = CMTimeGetSeconds(CMTimebaseGetTime(loadedState.controlTimebase.timebase))
        if traceEvents {
            print("tick at \(timestamp)")
        }
        
        var duration: Double = 0.0
        var videoStatus: MediaTrackFrameBufferStatus?
        if let videoTrackFrameBuffer = loadedState.mediaBuffers.videoBuffer {
            videoStatus = videoTrackFrameBuffer.status(at: timestamp)
            duration = max(duration, CMTimeGetSeconds(videoTrackFrameBuffer.duration))
        }
        
        var audioStatus: MediaTrackFrameBufferStatus?
        if let audioTrackFrameBuffer = loadedState.mediaBuffers.audioBuffer {
            audioStatus = audioTrackFrameBuffer.status(at: timestamp)
            duration = max(duration, CMTimeGetSeconds(audioTrackFrameBuffer.duration))
        }
        
        var performActionAtEndNow = false
        
        var worstStatus: MediaTrackFrameBufferStatus?
        for status in [videoStatus, audioStatus] {
            if let status = status {
                if let worst = worstStatus {
                    switch status {
                        case .buffering:
                            worstStatus = status
                        case let .full(currentFullUntil):
                            switch worst {
                                case .buffering:
                                    worstStatus = worst
                                case let .full(worstFullUntil):
                                    if currentFullUntil < worstFullUntil {
                                        worstStatus = status
                                    } else {
                                        worstStatus = worst
                                    }
                                case .finished:
                                    worstStatus = status
                            }
                        case let .finished(currentFinishedAt):
                            switch worst {
                                case .buffering, .full:
                                    worstStatus = worst
                                case let .finished(worstFinishedAt):
                                    if currentFinishedAt < worstFinishedAt {
                                        worstStatus = worst
                                    } else {
                                        worstStatus = status
                                    }
                            }
                    }
                } else {
                    worstStatus = status
                }
            }
        }
        
        var rate: Double
        var buffering = false
        
        if let worstStatus = worstStatus, case let .full(fullUntil) = worstStatus, fullUntil.isFinite {
            if case .playing = self.state {
                rate = self.baseRate
                
                let nextTickDelay = max(0.0, fullUntil - timestamp) / self.baseRate
                let tickTimer = SwiftSignalKit.Timer(timeout: nextTickDelay, repeat: false, completion: { [weak self] in
                    self?.tick()
                }, queue: self.queue)
                self.tickTimer = tickTimer
                tickTimer.start()
            } else {
                rate = 0.0
            }
        } else if let worstStatus = worstStatus, case let .finished(finishedAt) = worstStatus, finishedAt.isFinite {
            let nextTickDelay = max(0.0, finishedAt - timestamp) / self.baseRate
            if nextTickDelay.isLessThanOrEqualTo(0.0) {
                rate = 0.0
                performActionAtEndNow = true
            } else {
                if case .playing = self.state {
                    rate = self.baseRate
                    
                    let tickTimer = SwiftSignalKit.Timer(timeout: nextTickDelay, repeat: false, completion: { [weak self] in
                        self?.tick()
                    }, queue: self.queue)
                    self.tickTimer = tickTimer
                    tickTimer.start()
                } else {
                    rate = 0.0
                }
            }
        } else {
            buffering = true
            rate = 0.0
        }
        
        var reportRate = rate
        
        if loadedState.controlTimebase.isAudio {
            if !rate.isZero {
                self.audioRenderer?.renderer.start()
            }
            self.audioRenderer?.renderer.setRate(rate)
            if !rate.isZero, let audioRenderer = self.audioRenderer {
                let timebaseRate = CMTimebaseGetRate(audioRenderer.renderer.audioTimebase)
                if !timebaseRate.isEqual(to: rate) {
                    reportRate = timebaseRate
                }
            }
        } else {
            if !CMTimebaseGetRate(loadedState.controlTimebase.timebase).isEqual(to: rate) {
                CMTimebaseSetRate(loadedState.controlTimebase.timebase, rate)
            }
        }
        
        if let videoTrackFrameBuffer = loadedState.mediaBuffers.videoBuffer, videoTrackFrameBuffer.hasFrames {
            self.videoRenderer.state = (loadedState.controlTimebase.timebase, true, videoTrackFrameBuffer.rotationAngle, videoTrackFrameBuffer.aspect)
        }
        
        if let audioRenderer = self.audioRenderer, let audioTrackFrameBuffer = loadedState.mediaBuffers.audioBuffer, audioTrackFrameBuffer.hasFrames {
            let queue = self.queue
            audioRenderer.requestedFrames = true
            audioRenderer.renderer.beginRequestingFrames(queue: queue.queue, takeFrame: { [weak audioTrackFrameBuffer] in
                assert(queue.isCurrent())
                if let audioTrackFrameBuffer = audioTrackFrameBuffer {
                    return audioTrackFrameBuffer.takeFrame()
                } else {
                    return .noFrames
                }
            })
        }
        
        var statusTimestamp = CACurrentMediaTime()
        let playbackStatus: MediaPlayerPlaybackStatus
        if buffering {
            var whilePlaying = false
            if case .playing = self.state {
                whilePlaying = true
            }
            playbackStatus = .buffering(initial: false, whilePlaying: whilePlaying)
        } else if !rate.isZero {
            if reportRate.isZero {
                //playbackStatus = .buffering(initial: false, whilePlaying: true)
                playbackStatus = .playing
                statusTimestamp = 0.0
            } else {
                playbackStatus = .playing
            }
        } else {
            playbackStatus = .paused
        }
        if self.lastStatusUpdateTimestamp == nil || self.lastStatusUpdateTimestamp! < statusTimestamp + 500 {
            lastStatusUpdateTimestamp = statusTimestamp
            var reportTimestamp = timestamp
            if case .seeking(_, timestamp, _, _, _, _) = self.state {
                reportTimestamp = timestamp
            }
            let status = MediaPlayerStatus(generationTimestamp: statusTimestamp, duration: duration, dimensions: CGSize(), timestamp: min(max(reportTimestamp, 0.0), duration), baseRate: self.baseRate, seekId: self.seekId, status: playbackStatus, soundEnabled: self.enableSound)
            self.playerStatus.set(.single(status))
        }
        
        if performActionAtEndNow {
            switch self.actionAtEnd {
                case let .loop(f):
                    self.stoppedAtEnd = false
                    self.seek(timestamp: 0.0, action: .play)
                    f?()
                case .stop:
                    self.stoppedAtEnd = true
                    self.pause(lostAudioSession: false)
                case let .action(f):
                    self.stoppedAtEnd = true
                    self.pause(lostAudioSession: false)
                    f()
                case let .loopDisablingSound(f):
                    self.stoppedAtEnd = false
                    self.enableSound = false
                    self.seek(timestamp: 0.0, action: .play)
                    f()
            }
        } else {
            self.stoppedAtEnd = false
        }
    }
}

enum MediaPlayerPlaybackStatus: Equatable {
    case playing
    case paused
    case buffering(initial: Bool, whilePlaying: Bool)
    
    static func ==(lhs: MediaPlayerPlaybackStatus, rhs: MediaPlayerPlaybackStatus) -> Bool {
        switch lhs {
            case .playing:
                if case .playing = rhs {
                    return true
                } else {
                    return false
                }
            case .paused:
                if case .paused = rhs {
                    return true
                } else {
                    return false
                }
            case let .buffering(initial, whilePlaying):
                if case .buffering(initial, whilePlaying) = rhs {
                    return true
                } else {
                    return false
                }
        }
    }
}

struct MediaPlayerStatus: Equatable {
    let generationTimestamp: Double
    let duration: Double
    let dimensions: CGSize
    let timestamp: Double
    let baseRate: Double
    let seekId: Int
    let status: MediaPlayerPlaybackStatus
    let soundEnabled: Bool
}

final class MediaPlayer {
    private let queue = Queue()
    private var contextRef: Unmanaged<MediaPlayerContext>?
    
    private let statusValue = Promise<MediaPlayerStatus>()
    
    var status: Signal<MediaPlayerStatus, NoError> {
        return self.statusValue.get()
    }
    
    var actionAtEnd: MediaPlayerActionAtEnd = .stop {
        didSet {
            let value = self.actionAtEnd
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    context.actionAtEnd = value
                }
            }
        }
    }
    
    init(audioSessionManager: ManagedAudioSession, postbox: Postbox, resourceReference: MediaResourceReference, tempFilePath: String? = nil, streamable: MediaPlayerStreaming, video: Bool, preferSoftwareDecoding: Bool, playAutomatically: Bool = false, enableSound: Bool, baseRate: Double = 1.0, fetchAutomatically: Bool, playAndRecord: Bool = false, keepAudioSessionWhilePaused: Bool = false, continuePlayingWithoutSoundOnLostAudioSession: Bool = false) {
        self.queue.async {
            let context = MediaPlayerContext(queue: self.queue, audioSessionManager: audioSessionManager, playerStatus: self.statusValue, postbox: postbox, resourceReference: resourceReference, tempFilePath: tempFilePath, streamable: streamable, video: video, preferSoftwareDecoding: preferSoftwareDecoding, playAutomatically: playAutomatically, enableSound: enableSound, baseRate: baseRate, fetchAutomatically: fetchAutomatically, playAndRecord: playAndRecord, keepAudioSessionWhilePaused: keepAudioSessionWhilePaused, continuePlayingWithoutSoundOnLostAudioSession: continuePlayingWithoutSoundOnLostAudioSession)
            self.contextRef = Unmanaged.passRetained(context)
        }
    }
    
    deinit {
        let contextRef = self.contextRef
        self.queue.async {
            contextRef?.release()
        }
    }
    
    func play() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.play()
            }
        }
    }
    
    func playOnceWithSound(playAndRecord: Bool, seek: MediaPlayerSeek = .start) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.playOnceWithSound(playAndRecord: playAndRecord, seek: seek)
            }
        }
    }
    
    func continuePlayingWithoutSound() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.continuePlayingWithoutSound()
            }
        }
    }
    
    func setContinuePlayingWithoutSoundOnLostAudioSession(_ value: Bool) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setContinuePlayingWithoutSoundOnLostAudioSession(value)
            }
        }
    }
    
    func setForceAudioToSpeaker(_ value: Bool) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setForceAudioToSpeaker(value)
            }
        }
    }
    
    func setKeepAudioSessionWhilePaused(_ value: Bool) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setKeepAudioSessionWhilePaused(value)
            }
        }
    }
    
    func pause() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.pause(lostAudioSession: false)
            }
        }
    }
    
    func togglePlayPause() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.togglePlayPause()
            }
        }
    }
    
    fileprivate var lastSeekCallTime: DispatchTime = .now()
    
    // Calls only one action within specified time interval.
    // Other actions are ignored.
    private func debounceSeek(withTimeInterval timeInterval: TimeInterval,
                              forceInstantUpdate: Bool = false,
                              action: @escaping ()->Void) {
        
        func dispatchTimeInterval(_ withTimeInterval: TimeInterval) -> DispatchTimeInterval {
            return DispatchTimeInterval.nanoseconds(Int(withTimeInterval * Double(NSEC_PER_SEC)))
        }
        
        let nextCallTime = lastSeekCallTime + dispatchTimeInterval(timeInterval)
        if DispatchTime.now() >= nextCallTime || forceInstantUpdate {
            lastSeekCallTime = .now()
            self.queue.async {
                // instant seek
                action()
            }
        } else {
            self.queue.after(timeInterval) { [weak self] in
                guard let self = self else { return }
                let nextCallTime = self.lastSeekCallTime + dispatchTimeInterval(timeInterval)
                if !self.ignoreFurtherDebouncedUpdates && (DispatchTime.now() >= nextCallTime) {
                    // debounced seek
                    action()
                    self.lastSeekCallTime = .now()
                }
            }
        }
    }
    
    // Continuous seek performance overview
    //
    // iPhone 7
    //   480p video
    //     playback - 18% CPU
    //     8 FPS continuous seek - 40% CPU
    //     15 FPS continuous seek - 60% CPU
    //   1080p video
    //     playback - 18% CPU
    //     8 FPS continuous seek - 85% CPU
    //     15 FPS continuous seek - 120% CPU
    fileprivate let debouncedSeekTargetFPS: Double = 8.0
    
    // used to ignore all the delayed seeks after an immediate one
    fileprivate var ignoreFurtherDebouncedUpdates: Bool = false
    
    func seek(timestamp: Double, play: Bool? = nil, debounce: Bool = false) {

        ignoreFurtherDebouncedUpdates = !debounce
        debounceSeek(withTimeInterval: 1.0 / debouncedSeekTargetFPS, forceInstantUpdate: !debounce) {
            if let context = self.contextRef?.takeUnretainedValue() {
                if let play = play {
                    context.seek(timestamp: timestamp, action: play ? .play : .pause)
                } else {
                    context.seek(timestamp: timestamp)
                }
            }
        }
    }
    
    func setBaseRate(_ baseRate: Double) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setBaseRate(baseRate)
            }
        }
    }
    
    func attachPlayerNode(_ node: MediaPlayerNode) {
        let nodeRef: Unmanaged<MediaPlayerNode> = Unmanaged.passRetained(node)
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.videoRenderer.attachNodeAndRelease(nodeRef)
            } else {
                Queue.mainQueue().async {
                    nodeRef.release()
                }
            }
        }
    }
}
