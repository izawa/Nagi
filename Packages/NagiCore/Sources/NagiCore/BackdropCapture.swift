import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ScreenCaptureKit
import Synchronization

@MainActor public final class BackdropCapture {
    public enum Stop: Sendable {
        case userStopped, notPermitted, failed(String)
    }

    /// Screen Recording permission as reported by the system now.
    public static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }
    /// Requested frame rate for the next start.
    public var framesPerSecond = 60
    /// Called once if setup fails or a stream stops unexpectedly.
    public var onStop: ((Stop) -> Void)?

    private let log: @MainActor (String) -> Void
    private let cache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "Nagi.BackdropCapture")
    private var generation: UUID?
    private var startTime: TimeInterval = 0
    private var streams: [UInt32: (stream: SCStream, output: CaptureOutput)] = [:]
    private var frames: [UInt32: CaptureFrame] = [:]

    public init(device: any MTLDevice, log: @escaping @MainActor (String) -> Void) {
        self.log = log
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.cache = cache
    }

    isolated deinit { endStreams(keepingFrames: false) }

    /// Fetches fresh shareable content and starts one self-excluding stream per display, each at
    /// the given pixel size (the overlay's drawable, so the backdrop lines up with it).
    public func start(displays: [UInt32: SIMD2<Int>]) {
        stop()
        guard !displays.isEmpty else { return }
        let id = UUID()
        generation = id
        startTime = ProcessInfo.processInfo.systemUptime
        let fps = Int32(clamping: max(1, framesPerSecond))
        log("capture start (\(fps) fps)")
        Task { [self] in
            guard generation == id else { return }
            guard Self.isPermitted else { return finish(.notPermitted, id: id) }
            guard let cache else { return finish(.failed("texture cache unavailable"), id: id) }
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                return finish(Self.stopReason(error, operation: "shareable content"), id: id)
            }
            guard generation == id else { return }
            let ownApp = content.applications.filter { $0.processID == getpid() }
            guard !ownApp.isEmpty else { return finish(.failed("self-exclusion unavailable"), id: id) }

            for (displayID, size) in displays where streams[displayID] == nil {
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    return finish(.failed("display \(displayID) unavailable"), id: id)
                }
                let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
                let output = CaptureOutput(cache: cache) { [weak self] in
                    guard let self, generation == id, let pending = streams[displayID]?.output.takePending() else { return }
                    publish(pending, for: displayID)
                } onStop: { [weak self] reason in
                    self?.finish(reason, id: id)
                }
                let stream = SCStream(filter: filter, configuration: Self.configuration(size: size, fps: fps), delegate: output)
                do {
                    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
                    streams[displayID] = (stream, output)
                    try await stream.startCapture()
                } catch {
                    return finish(Self.stopReason(error, operation: "start stream"), id: id)
                }
                // A stop during startCapture can reach the stream before it has started.
                guard generation == id else {
                    try? await stream.stopCapture()
                    return
                }
            }
        }
    }

    private func publish(_ pending: CaptureOutput.Pending, for display: UInt32) {
        if frames.updateValue(pending.frame, forKey: display) == nil {
            let latency = Int((pending.firstArrival - startTime) * 1000)
            log("capture first frame display \(display) (\(latency) ms)")
        }
    }

    private static func configuration(size: SIMD2<Int>, fps: Int32) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = size.x
        config.height = size.y
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.displayP3
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 3
        return config
    }

    /// Stops accepting frames and keeps the latest complete frame per display.
    public func freeze() {
        guard generation != nil else { return }
        endStreams(keepingFrames: true)
        log("capture frozen")
    }

    /// Stops all streams and releases their frames.
    public func stop() {
        guard generation != nil || !frames.isEmpty else { return }
        endStreams(keepingFrames: false)
        log("capture stopped")
    }

    nonisolated static func stopReason(_ error: any Error, operation: String) -> Stop {
        let code = (error as NSError).code
        switch code {
        case -3801: return .notPermitted
        case -3817: return .userStopped
        default: return .failed("\(operation) (\(code))")
        }
    }

    private func finish(_ reason: Stop, id: UUID) {
        guard generation == id else { return }
        endStreams(keepingFrames: false)
        log("capture stopped: \(reason)")
        onStop?(reason)
    }

    private func endStreams(keepingFrames: Bool) {
        generation = nil
        for (display, entry) in streams {
            if let pending = entry.output.takePending(closing: true), keepingFrames { publish(pending, for: display) }
            entry.stream.stopCapture(completionHandler: nil)
        }
        streams.removeAll()
        if !keepingFrames {
            frames.removeAll()
            if let cache { CVMetalTextureCacheFlush(cache, 0) }
        }
    }

    /// Lends the latest encoded Display P3 texture until the command buffer completes.
    public func backdrop(for display: UInt32, commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        guard let frame = frames[display] else { return nil }
        commandBuffer.addCompletedHandler { @Sendable _ in withExtendedLifetime(frame) {} }
        return frame.texture
    }
}

// The capture queue creates this immutable frame. Metal only reads its IOSurface.
private struct CaptureFrame: @unchecked Sendable {
    let sample: CMSampleBuffer
    let cvTexture: CVMetalTexture
    let texture: any MTLTexture

    init?(_ sample: CMSampleBuffer, cache: CVMetalTextureCache) {
        guard let pixels = sample.imageBuffer else { return nil }
        var wrapper: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixels, nil, .bgra8Unorm, CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels),
            0, &wrapper)
        guard result == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else { return nil }
        self.sample = sample
        self.cvTexture = wrapper
        self.texture = texture
    }
}

private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias Pending = (frame: CaptureFrame, firstArrival: TimeInterval)

    private let cache: CVMetalTextureCache
    private let onFrame: @MainActor @Sendable () -> Void
    private let onStop: @MainActor @Sendable (BackdropCapture.Stop) -> Void
    // A busy main actor needs just one notification and the newest complete frame.
    private let state = Mutex((open: true, pending: Optional<Pending>.none))

    init(cache: CVMetalTextureCache, onFrame: @escaping @MainActor @Sendable () -> Void,
         onStop: @escaping @MainActor @Sendable (BackdropCapture.Stop) -> Void) {
        self.cache = cache
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func takePending(closing: Bool = false) -> Pending? {
        state.withLock {
            if closing { $0.open = false }
            defer { $0.pending = nil }
            return $0.pending
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let frame = CaptureFrame(sampleBuffer, cache: cache) else { return }
        let notify = state.withLock {
            guard $0.open else { return false }
            let notify = $0.pending == nil
            let firstArrival = $0.pending?.firstArrival ?? ProcessInfo.processInfo.systemUptime
            $0.pending = (frame, firstArrival)
            return notify
        }
        if notify {
            Task { @MainActor [onFrame] in onFrame() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let reason = BackdropCapture.stopReason(error, operation: "stream stopped")
        Task { @MainActor [onStop] in onStop(reason) }
    }
}
