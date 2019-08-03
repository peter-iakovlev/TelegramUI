import Foundation
import SwiftSignalKit
import Postbox
import CoreMedia
import TelegramUIPrivateModule
import TelegramCore
import FFMpeg

private struct StreamContext {
    let index: Int
    let codecContext: FFMpegAVCodecContext?
    let fps: CMTime
    let timebase: CMTime
    let duration: CMTime
    let decoder: MediaTrackFrameDecoder
    let rotationAngle: Double
    let aspect: Double
}

struct FFMpegMediaFrameSourceDescription {
    let duration: CMTime
    let decoder: MediaTrackFrameDecoder
    let rotationAngle: Double
    let aspect: Double
}

struct FFMpegMediaFrameSourceDescriptionSet {
    let audio: FFMpegMediaFrameSourceDescription?
    let video: FFMpegMediaFrameSourceDescription?
    let extraVideoFrames: [MediaTrackDecodableFrame]
}

private final class InitializedState {
    fileprivate let avIoContext: FFMpegAVIOContext
    fileprivate let avFormatContext: FFMpegAVFormatContext
    
    fileprivate let audioStream: StreamContext?
    fileprivate let videoStream: StreamContext?
    
    init(avIoContext: FFMpegAVIOContext, avFormatContext: FFMpegAVFormatContext, audioStream: StreamContext?, videoStream: StreamContext?) {
        self.avIoContext = avIoContext
        self.avFormatContext = avFormatContext
        self.audioStream = audioStream
        self.videoStream = videoStream
    }
}

struct FFMpegMediaFrameSourceStreamContextInfo {
    let duration: CMTime
    let decoder: MediaTrackFrameDecoder
}

struct FFMpegMediaFrameSourceContextInfo {
    let audioStream: FFMpegMediaFrameSourceStreamContextInfo?
    let videoStream: FFMpegMediaFrameSourceStreamContextInfo?
}

private var maxOffset: Int = 0

private func readPacketCallback(userData: UnsafeMutableRawPointer?, buffer: UnsafeMutablePointer<UInt8>?, bufferSize: Int32) -> Int32 {
    let context = Unmanaged<FFMpegMediaFrameSourceContext>.fromOpaque(userData!).takeUnretainedValue()
    guard let postbox = context.postbox, let resourceReference = context.resourceReference, let streamable = context.streamable else {
        return 0
    }
    
    var fetchedCount: Int32 = 0
    
    var fetchedData: Data?
    
    /*#if DEBUG
    maxOffset = max(maxOffset, context.readingOffset + Int(bufferSize))
    print("maxOffset \(maxOffset)")
    #endif*/
    
    let resourceSize: Int = resourceReference.resource.size ?? Int(Int32.max - 1)
    let readCount = min(resourceSize - context.readingOffset, Int(bufferSize))
    let requestRange: Range<Int> = context.readingOffset ..< (context.readingOffset + readCount)
    
    if let maximumFetchSize = context.maximumFetchSize {
        context.touchedRanges.insert(integersIn: requestRange)
        var totalCount = 0
        for range in context.touchedRanges.rangeView {
            totalCount += range.count
        }
        if totalCount > maximumFetchSize {
            context.readingError = true
            return 0
        }
    }
    
    if streamable {
        let data: Signal<Data, NoError>
        data = postbox.mediaBox.resourceData(resourceReference.resource, size: resourceSize, in: requestRange, mode: .complete)
        if readCount == 0 {
            fetchedData = Data()
        } else {
            if let tempFilePath = context.tempFilePath, let fileData = (try? Data(contentsOf: URL(fileURLWithPath: tempFilePath), options: .mappedRead))?.subdata(in: requestRange) {
                fetchedData = fileData
            } else {
                let semaphore = DispatchSemaphore(value: 0)
                let _ = context.currentSemaphore.swap(semaphore)
                var completedRequest = false
                let disposable = data.start(next: { data in
                    if data.count == readCount {
                        fetchedData = data
                        completedRequest = true
                        semaphore.signal()
                    }
                })
                semaphore.wait()
                let _ = context.currentSemaphore.swap(nil)
                disposable.dispose()
                if !completedRequest {
                    context.readingError = true
                    return 0
                }
            }
        }
    } else {
        if let tempFilePath = context.tempFilePath, let fileSize = fileSize(tempFilePath) {
            let fd = open(tempFilePath, O_RDONLY, S_IRUSR)
            if fd >= 0 {
                let readingOffset = context.readingOffset
                let readCount = max(0, min(fileSize - readingOffset, Int(bufferSize)))
                let range = readingOffset ..< (readingOffset + readCount)
                
                lseek(fd, off_t(range.lowerBound), SEEK_SET)
                var data = Data(count: readCount)
                data.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                    let readBytes = read(fd, bytes, readCount)
                    assert(readBytes <= readCount)
                }
                fetchedData = data
                close(fd)
            }
        } else {
            let data = postbox.mediaBox.resourceData(resourceReference.resource, pathExtension: nil, option: .complete(waitUntilFetchStatus: false))
            let semaphore = DispatchSemaphore(value: 0)
            let _ = context.currentSemaphore.swap(semaphore)
            let readingOffset = context.readingOffset
            var completedRequest = false
            let disposable = data.start(next: { next in
                if next.complete {
                    let readCount = max(0, min(next.size - readingOffset, Int(bufferSize)))
                    let range = readingOffset ..< (readingOffset + readCount)
                    
                    let fd = open(next.path, O_RDONLY, S_IRUSR)
                    if fd >= 0 {
                        lseek(fd, off_t(range.lowerBound), SEEK_SET)
                        var data = Data(count: readCount)
                        data.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                            let readBytes = read(fd, bytes, readCount)
                            assert(readBytes <= readCount)
                        }
                        fetchedData = data
                        close(fd)
                    }
                    completedRequest = true
                    semaphore.signal()
                }
            })
            semaphore.wait()
            let _ = context.currentSemaphore.swap(nil)
            disposable.dispose()
            if !completedRequest {
                context.readingError = true
                return 0
            }
        }
    }
    if let fetchedData = fetchedData {
        fetchedData.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
            memcpy(buffer, bytes, fetchedData.count)
        }
        fetchedCount = Int32(fetchedData.count)
        context.readingOffset += Int(fetchedCount)
    }
    
    if context.closed {
        context.readingError = true
        return 0
    }
    return fetchedCount
}

private func seekCallback(userData: UnsafeMutableRawPointer?, offset: Int64, whence: Int32) -> Int64 {
    let context = Unmanaged<FFMpegMediaFrameSourceContext>.fromOpaque(userData!).takeUnretainedValue()
    guard let postbox = context.postbox, let resourceReference = context.resourceReference, let streamable = context.streamable, let statsCategory = context.statsCategory else {
        return 0
    }
    
    var result: Int64 = offset
    
    let resourceSize: Int
    if let size = resourceReference.resource.size {
        resourceSize = size
    } else {
        if !streamable {
            if let tempFilePath = context.tempFilePath, let fileSize = fileSize(tempFilePath) {
                resourceSize = fileSize
            } else {
                var resultSize: Int = Int(Int32.max - 1)
                let data = postbox.mediaBox.resourceData(resourceReference.resource, pathExtension: nil, option: .complete(waitUntilFetchStatus: false))
                let semaphore = DispatchSemaphore(value: 0)
                let _ = context.currentSemaphore.swap(semaphore)
                var completedRequest = false
                let disposable = data.start(next: { next in
                    if next.complete {
                        resultSize = Int(next.size)
                        completedRequest = true
                        semaphore.signal()
                    }
                })
                semaphore.wait()
                let _ = context.currentSemaphore.swap(nil)
                disposable.dispose()
                if !completedRequest {
                    context.readingError = true
                    return 0
                }
                resourceSize = resultSize
            }
        } else {
            resourceSize = Int(Int32.max - 1)
        }
    }
    
    if (whence & FFMPEG_AVSEEK_SIZE) != 0 {
        result = Int64(resourceSize == Int(Int32.max - 1) ? 0 : resourceSize)
    } else {
        context.readingOffset = Int(min(Int64(resourceSize), offset))
        
        if context.readingOffset != context.requestedDataOffset {
            context.requestedDataOffset = context.readingOffset
            
            if context.readingOffset >= resourceSize {
                context.fetchedDataDisposable.set(nil)
            } else {
                if streamable {
                    if context.tempFilePath == nil {
                        let fetchRange: Range<Int> = context.readingOffset ..< Int(Int32.max)
                        context.fetchedDataDisposable.set(fetchedMediaResource(postbox: postbox, reference: resourceReference, range: (fetchRange, .elevated), statsCategory: statsCategory, preferBackgroundReferenceRevalidation: streamable).start())
                    }
                } else if !context.requestedCompleteFetch && context.fetchAutomatically {
                    context.requestedCompleteFetch = true
                    if context.tempFilePath == nil {
                        context.fetchedDataDisposable.set(fetchedMediaResource(postbox: postbox, reference: resourceReference, statsCategory: statsCategory, preferBackgroundReferenceRevalidation: streamable).start())
                    }
                }
            }
        }
    }
    
    if context.closed {
        context.readingError = true
        return 0
    }
    
    return result
}

final class FFMpegMediaFrameSourceContext: NSObject {
    private let thread: Thread
    
    var closed = false
    
    fileprivate var postbox: Postbox?
    fileprivate var resourceReference: MediaResourceReference?
    fileprivate var tempFilePath: String?
    fileprivate var streamable: Bool?
    fileprivate var statsCategory: MediaResourceStatsCategory?
    
    private let ioBufferSize = 1 * 1024
    fileprivate var readingOffset = 0
    
    fileprivate var requestedDataOffset: Int?
    fileprivate let fetchedDataDisposable = MetaDisposable()
    fileprivate let fetchedFullDataDisposable = MetaDisposable()
    fileprivate var requestedCompleteFetch = false
    
    fileprivate var readingError = false {
        didSet {
            self.fetchedDataDisposable.dispose()
            self.fetchedFullDataDisposable.dispose()
        }
    }
    
    private var initializedState: InitializedState?
    private var packetQueue: [FFMpegPacket] = []
    
    private var preferSoftwareDecoding: Bool = false
    fileprivate var fetchAutomatically: Bool = true
    fileprivate var maximumFetchSize: Int? = nil
    fileprivate var mediaSeekState: MediaSeekState = .unknown
    fileprivate var touchedRanges = IndexSet()
    
    let currentSemaphore = Atomic<DispatchSemaphore?>(value: nil)
    
    init(thread: Thread) {
        self.thread = thread
    }
    
    deinit {
        assert(Thread.current === self.thread)
        
        self.fetchedDataDisposable.dispose()
        self.fetchedFullDataDisposable.dispose()
    }
    
    func initializeState(postbox: Postbox, resourceReference: MediaResourceReference, tempFilePath: String?, streamable: Bool, video: Bool, preferSoftwareDecoding: Bool, fetchAutomatically: Bool, maximumFetchSize: Int?, mediaSeekState: MediaSeekState) {
        if self.readingError || self.initializedState != nil {
            return
        }
        
        let _ = FFMpegMediaFrameSourceContextHelpers.registerFFMpegGlobals
        
        self.postbox = postbox
        self.resourceReference = resourceReference
        self.tempFilePath = tempFilePath
        self.streamable = streamable
        self.statsCategory = video ? .video : .audio
        self.preferSoftwareDecoding = preferSoftwareDecoding
        self.fetchAutomatically = fetchAutomatically
        self.maximumFetchSize = maximumFetchSize
        self.mediaSeekState = mediaSeekState
        
        var preferSoftwareAudioDecoding = false
        if case let .media(media, _) = resourceReference, let file = media.media as? TelegramMediaFile {
            if file.isInstantVideo {
                preferSoftwareAudioDecoding = true
            }
        }
        
        if streamable {
            if self.tempFilePath == nil {
                self.fetchedDataDisposable.set(fetchedMediaResource(postbox: postbox, reference: resourceReference, range: (0 ..< Int(Int32.max), .elevated), statsCategory: self.statsCategory ?? .generic, preferBackgroundReferenceRevalidation: streamable).start())
            }
        } else if !self.requestedCompleteFetch && self.fetchAutomatically {
            self.requestedCompleteFetch = true
            if self.tempFilePath == nil {
                self.fetchedFullDataDisposable.set(fetchedMediaResource(postbox: postbox, reference: resourceReference, statsCategory: self.statsCategory ?? .generic, preferBackgroundReferenceRevalidation: streamable).start())
            }
        }
        
        let avFormatContext = FFMpegAVFormatContext()
        
        guard let avIoContext = FFMpegAVIOContext(bufferSize: Int32(self.ioBufferSize), opaqueContext: Unmanaged.passUnretained(self).toOpaque(), readPacket: readPacketCallback, seek: seekCallback) else {
            self.readingError = true
            return
        }
        
        avFormatContext.setIO(avIoContext)
        
        if !avFormatContext.openInput() {
            self.readingError = true
            return
        }
        if (mediaSeekState != .inProgress) {
            // do the most expensive call in FFMPEG seeking pipeline only when it is not "in progress" seeking
            if !avFormatContext.findStreamInfo() {
                self.readingError = true;
                return
            }
        }
        
        var videoStream: StreamContext?
        var audioStream: StreamContext?
        
        for streamIndexNumber in avFormatContext.streamIndices(for: FFMpegAVFormatStreamTypeVideo) {
            let streamIndex = streamIndexNumber.int32Value
            if avFormatContext.isAttachedPic(atStreamIndex: streamIndex) {
                continue
            }
            
            let codecId = avFormatContext.codecId(atStreamIndex: streamIndex)
            
            let fpsAndTimebase = avFormatContext.fpsAndTimebase(forStreamIndex: streamIndex, defaultTimeBase: CMTimeMake(1, 40000))
            let (fps, timebase) = (fpsAndTimebase.fps, fpsAndTimebase.timebase)
            
            let duration = CMTimeMake(avFormatContext.duration(atStreamIndex: streamIndex), timebase.timescale)
            
            let metrics = avFormatContext.metricsForStream(at: streamIndex)
            
            let rotationAngle: Double = metrics.rotationAngle
            let aspect = Double(metrics.width) / Double(metrics.height)
            
            if self.preferSoftwareDecoding {
                if let codec = FFMpegAVCodec.find(forId: codecId) {
                    let codecContext = FFMpegAVCodecContext(codec: codec)
                    if (mediaSeekState == .inProgress) {
                        codecContext.flushBuffers()
                    }
                    if avFormatContext.codecParams(atStreamIndex: streamIndex, to: codecContext) {
                        if codecContext.open() {
                            videoStream = StreamContext(index: Int(streamIndex), codecContext: codecContext, fps: fps, timebase: timebase, duration: duration, decoder: FFMpegMediaVideoFrameDecoder(codecContext: codecContext), rotationAngle: rotationAngle, aspect: aspect)
                            break
                        }
                    }
                }
            } else if codecId == FFMpegCodecIdMPEG4 {
                if let videoFormat = FFMpegMediaFrameSourceContextHelpers.createFormatDescriptionFromMpeg4CodecData(UInt32(kCMVideoCodecType_MPEG4Video), metrics.width, metrics.height, metrics.extradata, metrics.extradataSize) {
                    videoStream = StreamContext(index: Int(streamIndex), codecContext: nil, fps: fps, timebase: timebase, duration: duration, decoder: FFMpegMediaPassthroughVideoFrameDecoder(videoFormat: videoFormat, rotationAngle: rotationAngle), rotationAngle: rotationAngle, aspect: aspect)
                    break
                }
            } else if codecId == FFMpegCodecIdH264 {
                if let videoFormat = FFMpegMediaFrameSourceContextHelpers.createFormatDescriptionFromAVCCodecData(UInt32(kCMVideoCodecType_H264), metrics.width, metrics.height, metrics.extradata, metrics.extradataSize) {
                    videoStream = StreamContext(index: Int(streamIndex), codecContext: nil, fps: fps, timebase: timebase, duration: duration, decoder: FFMpegMediaPassthroughVideoFrameDecoder(videoFormat: videoFormat, rotationAngle: rotationAngle), rotationAngle: rotationAngle, aspect: aspect)
                    break
                }
            } else if codecId == FFMpegCodecIdHEVC {
                if let videoFormat = FFMpegMediaFrameSourceContextHelpers.createFormatDescriptionFromHEVCCodecData(UInt32(kCMVideoCodecType_HEVC), metrics.width, metrics.height, metrics.extradata, metrics.extradataSize) {
                    videoStream = StreamContext(index: Int(streamIndex), codecContext: nil, fps: fps, timebase: timebase, duration: duration, decoder: FFMpegMediaPassthroughVideoFrameDecoder(videoFormat: videoFormat, rotationAngle: rotationAngle), rotationAngle: rotationAngle, aspect: aspect)
                    break
                }
            }
        }
        
        for streamIndexNumber in avFormatContext.streamIndices(for: FFMpegAVFormatStreamTypeAudio) {
            
            if (mediaSeekState == .inProgress) {
                // audio is not required when seek is in progress
                continue
            }
            
            let streamIndex = streamIndexNumber.int32Value
            let codecId = avFormatContext.codecId(atStreamIndex: streamIndex)
            
            var codec: FFMpegAVCodec?
            
            if codec == nil {
                codec = FFMpegAVCodec.find(forId: codecId)
            }
            
            if let codec = codec {
                let codecContext = FFMpegAVCodecContext(codec: codec)
                if avFormatContext.codecParams(atStreamIndex: streamIndex, to: codecContext) {
                    if codecContext.open() {
                        let fpsAndTimebase = avFormatContext.fpsAndTimebase(forStreamIndex: streamIndex, defaultTimeBase: CMTimeMake(1, 40000))
                        let (fps, timebase) = (fpsAndTimebase.fps, fpsAndTimebase.timebase)
                        
                        let duration = CMTimeMake(avFormatContext.duration(atStreamIndex: streamIndex), timebase.timescale)
                        
                        audioStream = StreamContext(index: Int(streamIndex), codecContext: codecContext, fps: fps, timebase: timebase, duration: duration, decoder: FFMpegAudioFrameDecoder(codecContext: codecContext), rotationAngle: 0.0, aspect: 1.0)
                        break
                    }
                }
            }
        }
        
        self.initializedState = InitializedState(avIoContext: avIoContext, avFormatContext: avFormatContext, audioStream: audioStream, videoStream: videoStream)
        
        if streamable {
            if self.tempFilePath == nil {
                self.fetchedFullDataDisposable.set(fetchedMediaResource(postbox: postbox, reference: resourceReference, range: (0 ..< Int(Int32.max), .default), statsCategory: self.statsCategory ?? .generic, preferBackgroundReferenceRevalidation: streamable).start())
            }
            self.requestedCompleteFetch = true
        }
    }
    
    private func readPacket() -> FFMpegPacket? {
        if !self.packetQueue.isEmpty {
            return self.packetQueue.remove(at: 0)
        } else {
            return self.readPacketInternal()
        }
    }
    
    private func readPacketInternal() -> FFMpegPacket? {
        guard let initializedState = self.initializedState else {
            return nil
        }
        
        let packet = FFMpegPacket()
        if initializedState.avFormatContext.readFrame(into: packet) {
            return packet
        } else {
            return nil
        }
    }
    
    func takeFrames(until: Double) -> (frames: [MediaTrackDecodableFrame], endOfStream: Bool) {
        if self.readingError {
            return ([], true)
        }
        
        guard let initializedState = self.initializedState else {
            return ([], true)
        }
        
        var videoTimestamp: Double?
        if initializedState.videoStream == nil {
            videoTimestamp = Double.infinity
        }
        
        var audioTimestamp: Double?
        if initializedState.audioStream == nil {
            audioTimestamp = Double.infinity
        }
        
        var frames: [MediaTrackDecodableFrame] = []
        var endOfStream = false
        
        while !self.readingError && ((videoTimestamp == nil || videoTimestamp!.isLess(than: until)) || (audioTimestamp == nil || audioTimestamp!.isLess(than: until))) {
            if let packet = self.readPacket() {
                if let videoStream = initializedState.videoStream, Int(packet.streamIndex) == videoStream.index {
                    let frame = videoFrameFromPacket(packet, videoStream: videoStream)
                    frames.append(frame)
                    
                    if videoTimestamp == nil || videoTimestamp! < CMTimeGetSeconds(frame.pts) {
                        videoTimestamp = CMTimeGetSeconds(frame.pts)
                    }
                } else if let audioStream = initializedState.audioStream, Int(packet.streamIndex) == audioStream.index {
                    let packetPts = packet.pts
                    
                    let pts = CMTimeMake(packetPts, audioStream.timebase.timescale)
                    let dts = CMTimeMake(packet.dts, audioStream.timebase.timescale)
                    
                    let duration: CMTime
                    
                    let frameDuration = packet.duration
                    if frameDuration != 0 {
                        duration = CMTimeMake(frameDuration * audioStream.timebase.value, audioStream.timebase.timescale)
                    } else {
                        duration = audioStream.fps
                    }
                    
                    let frame = MediaTrackDecodableFrame(type: .audio, packet: packet, pts: pts, dts: dts, duration: duration)
                    frames.append(frame)
                    
                    if audioTimestamp == nil || audioTimestamp! < CMTimeGetSeconds(pts) {
                        audioTimestamp = CMTimeGetSeconds(pts)
                    }
                }
            } else {
                endOfStream = true
                break
            }
        }
        
        return (frames, endOfStream)
    }
    
    func contextInfo() -> FFMpegMediaFrameSourceContextInfo? {
        if let initializedState = self.initializedState {
            var audioStreamContext: FFMpegMediaFrameSourceStreamContextInfo?
            var videoStreamContext: FFMpegMediaFrameSourceStreamContextInfo?
            
            if let audioStream = initializedState.audioStream {
                audioStreamContext = FFMpegMediaFrameSourceStreamContextInfo(duration: audioStream.duration, decoder: audioStream.decoder)
            }
            
            if let videoStream = initializedState.videoStream {
                videoStreamContext = FFMpegMediaFrameSourceStreamContextInfo(duration: videoStream.duration, decoder: videoStream.decoder)
            }
            
            return FFMpegMediaFrameSourceContextInfo(audioStream: audioStreamContext, videoStream: videoStreamContext)
        }
        return nil
    }
    
    func seek(timestamp: Double, completed: ((FFMpegMediaFrameSourceDescriptionSet, CMTime)?) -> Void) {
        if let initializedState = self.initializedState {
            self.packetQueue.removeAll()
            
            for stream in [initializedState.videoStream, initializedState.audioStream] {
                if let stream = stream {
                    let pts = CMTimeMakeWithSeconds(timestamp, stream.timebase.timescale)
                    initializedState.avFormatContext.seekFrame(forStreamIndex: Int32(stream.index), pts: pts.value)
                    break
                }
            }
            
            var audioDescription: FFMpegMediaFrameSourceDescription?
            var videoDescription: FFMpegMediaFrameSourceDescription?
            
            if let audioStream = initializedState.audioStream {
                audioDescription = FFMpegMediaFrameSourceDescription(duration: audioStream.duration, decoder: audioStream.decoder, rotationAngle: 0.0, aspect: 1.0)
            }
            
            if let videoStream = initializedState.videoStream {
                videoDescription = FFMpegMediaFrameSourceDescription(duration: videoStream.duration, decoder: videoStream.decoder, rotationAngle: videoStream.rotationAngle, aspect: videoStream.aspect)
            }
            
            var actualPts: CMTime = CMTimeMake(0, 1)
            var extraVideoFrames: [MediaTrackDecodableFrame] = []
            if timestamp.isZero || initializedState.videoStream == nil {
                for _ in 0 ..< 24 {
                    if let packet = self.readPacketInternal() {
                        if let videoStream = initializedState.videoStream, Int(packet.streamIndex) == videoStream.index {
                            self.packetQueue.append(packet)
                            let pts = CMTimeMake(packet.pts, videoStream.timebase.timescale)
                            actualPts = pts
                            break
                        } else if let audioStream = initializedState.audioStream, Int(packet.streamIndex) == audioStream.index {
                            self.packetQueue.append(packet)
                            let pts = CMTimeMake(packet.pts, audioStream.timebase.timescale)
                            actualPts = pts
                            break
                        }
                    } else {
                        break
                    }
                }
            } else if let videoStream = initializedState.videoStream {
                let extraVideoFramesLimitSeconds: Double = {
                    if (mediaSeekState == .inProgress) {
                        // Higher values produce more CPU overhead.
                        // Also values smaller than 1.0/videoFPS (e.g. 0.01) produce +5-10% CPU overhead.
                        return 0.05
                    } else {
                        return 0.5
                    }
                }()
                
                let targetPts = CMTimeMakeWithSeconds(Float64(timestamp), videoStream.timebase.timescale)
                let limitPts = CMTimeMakeWithSeconds(Float64(timestamp + extraVideoFramesLimitSeconds), videoStream.timebase.timescale)
                var audioPackets: [FFMpegPacket] = []
                while !self.readingError {
                    if let packet = self.readPacket() {
                        if let videoStream = initializedState.videoStream, Int(packet.streamIndex) == videoStream.index {
                            let frame = videoFrameFromPacket(packet, videoStream: videoStream)
                            extraVideoFrames.append(frame)
                            
                            if CMTimeCompare(frame.dts, limitPts) >= 0 && CMTimeCompare(frame.pts, limitPts) >= 0 {
                                break
                            }
                        } else if let audioStream = initializedState.audioStream, Int(packet.streamIndex) == audioStream.index {
                            audioPackets.append(packet)
                        }
                    } else {
                        break
                    }
                }
                if !extraVideoFrames.isEmpty {
                    var closestFrame: MediaTrackDecodableFrame?
                    for frame in extraVideoFrames {
                        if CMTimeCompare(frame.pts, targetPts) >= 0 {
                            if let closestFrameValue = closestFrame {
                                if CMTimeCompare(frame.pts, closestFrameValue.pts) < 0 {
                                    closestFrame = frame
                                }
                            } else {
                                closestFrame = frame
                            }
                        }
                    }
                    if let closestFrame = closestFrame {
                        actualPts = closestFrame.pts
                    }
                }
                if let audioStream = initializedState.audioStream {
                    self.packetQueue.append(contentsOf: audioPackets.filter({ packet in
                        let pts = CMTimeMake(packet.pts, audioStream.timebase.timescale)
                        if CMTimeCompare(pts, actualPts) >= 0 {
                            return true
                        } else {
                            return false
                        }
                    }))
                }
            }
            
            completed((FFMpegMediaFrameSourceDescriptionSet(audio: audioDescription, video: videoDescription, extraVideoFrames: extraVideoFrames), actualPts))
        } else {
            completed(nil)
        }
    }
}

private func videoFrameFromPacket(_ packet: FFMpegPacket, videoStream: StreamContext) -> MediaTrackDecodableFrame {
    let packetPts = packet.pts
    
    let pts = CMTimeMake(packetPts, videoStream.timebase.timescale)
    let dts = CMTimeMake(packet.dts, videoStream.timebase.timescale)
    
    let duration: CMTime
    
    let frameDuration = packet.duration
    if frameDuration != 0 {
        duration = CMTimeMake(frameDuration * videoStream.timebase.value, videoStream.timebase.timescale)
    } else {
        duration = videoStream.fps
    }
    
    return MediaTrackDecodableFrame(type: .video, packet: packet, pts: pts, dts: dts, duration: duration)
}
