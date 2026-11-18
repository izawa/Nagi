import AppKit
import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit
import SpikeLog
import Synchronization

/// S4: ScreenCaptureKit capture of the main display, zero-copy into Metal (granted variants only).
///
/// The probe shows its own marker and samples a few named screen points in every frame on the GPU:
/// `own` (this app's marker), `readOnly` and `none` (the S6 markers of a `--run markers` process)
/// and `flash` (the Fixture's flash window, which keeps frames coming). Only those few pixels reach
/// the CPU, and only a colour label (marker colours, black, white or other) is logged, never values.
/// Run only one Fixture process (`--scene flash`) so `flash` is found.
/// - `--filter self` excludes this app's windows; `--filter none` captures everything (control).
/// - `--trials N`: N fresh streams, each started, held until the first frame, stopped, then watched
///   for 1 s. Without it: one stream until shortly before `--duration`; halfway through, the own
///   marker window is recreated and the content filter refreshed.
@MainActor final class CaptureProbe {
    private let options: Options
    private let screen: NSScreen
    private let ownFrame: NSRect
    private let sampler: FrameSampler
    private var ownMarker: NSWindow?

    init(options: Options) {
        self.options = options
        screen = NSScreen.main ?? NSScreen.screens[0]
        let pair = MarkerPairProbe.frames(on: screen)
        ownFrame = pair.readOnly.offsetBy(dx: -(MarkerPairProbe.size + 40), dy: 0)
        var points: [(String, NSPoint)] = [
            ("own", ownFrame.center), ("readOnly", pair.readOnly.center), ("none", pair.none.center),
        ]
        if let flash = FixtureWindows.frames().first { points.append(("flash", flash.center)) }
        if let watch = options.watch {
            if screen.frame.contains(watch) {
                points.append(("watch", watch))
            } else {
                SpikeLog.emit("error", ["message": "--watch \(watch) is outside the main display \(screen.frame)"])
            }
        }
        let screen = screen
        let scale = screen.backingScaleFactor * options.captureScale
        sampler = FrameSampler(points: points.map { name, point in (name, Self.pixel(point, on: screen, scale: scale)) })
        showOwnMarker()
        Task { await run() }
    }

    private func run() async {
        do {
            if options.trials > 0 {
                // Per trial: up to 5 s for the first frame, 1 s watching after stop, about 1 s of setup.
                guard options.duration >= Double(options.trials) * 7 + 5 else {
                    throw ProbeError("--trials \(options.trials) needs --duration of at least \(options.trials * 7 + 5)")
                }
                var firstFrameMs: [Double] = []
                for trial in 1...options.trials {
                    if let ms = try await runTrial(trial) { firstFrameMs.append(ms) }
                }
                SpikeLog.emit("s4-trials", ["trials": options.trials, "firstFrameMs": Percentiles(firstFrameMs).fields])
            } else {
                try await runContinuous()
            }
            AppDelegate.quit(reason: "done")
        } catch {
            emitError(error)
            AppDelegate.quit(reason: "error")
        }
    }

    /// Returns the time from the start call to the first complete frame, or nil on timeout.
    private func runTrial(_ trial: Int) async throws -> Double? {
        let requested = now()
        let stream = try await makeStream()
        let created = now()
        sampler.reset()
        try await stream.startCapture()
        let started = now()
        let first = await waitForFirstFrame(timeout: 5)
        let stopping = now()
        try await stream.stopCapture()
        let stopped = now()
        sampler.markStopped(at: stopped)
        try await Task.sleep(for: .seconds(1))
        try stream.removeStreamOutput(sampler, type: .screen)
        // Late completions must not leak into the next trial.
        guard await waitForGPU() else { throw ProbeError("GPU work of trial \(trial) did not finish") }
        let summary = sampler.summary()
        let firstFrameMs = first.map { ($0 - created) * 1000 }
        SpikeLog.emit("s4-trial", [
            "trial": trial, "setupMs": (created - requested) * 1000, "startCallMs": (started - created) * 1000,
            "firstFrameMs": firstFrameMs ?? -1, "stopCallMs": (stopped - stopping) * 1000, "summary": summary,
        ])
        return firstFrameMs
    }

    private func runContinuous() async throws {
        let stream = try await makeStream()
        sampler.reset()
        try await stream.startCapture()
        SpikeLog.emit("s4-started", ["filter": options.filter])
        let hold = max(options.duration - 4, 2)
        try await Task.sleep(for: .seconds(hold / 2))
        // Exclusion must survive a new window from the same app, and a refreshed filter.
        showOwnMarker()
        SpikeLog.emit("s4-own-marker-recreated", ["windowNumber": ownMarker?.windowNumber ?? -1])
        try await Task.sleep(for: .seconds(2))
        try await stream.updateContentFilter(try await makeFilter().filter)
        SpikeLog.emit("s4-filter-refreshed")
        try await Task.sleep(for: .seconds(hold / 2 - 2))
        try await stream.stopCapture()
        sampler.markStopped(at: now())
        try await Task.sleep(for: .seconds(2))
        try stream.removeStreamOutput(sampler, type: .screen)
        guard await waitForGPU() else { throw ProbeError("GPU work did not finish after stop") }
        SpikeLog.emit("s4-summary", ["summary": sampler.summary()])
        sampler.flush()
    }

    private func waitForFirstFrame(timeout: Double) async -> Double? {
        let deadline = now() + timeout
        while now() < deadline {
            if let first = sampler.firstFrameAt { return first }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    /// Returns false if GPU work is still in flight after 1 s.
    private func waitForGPU() async -> Bool {
        for _ in 0..<500 where sampler.inFlight > 0 { try? await Task.sleep(for: .milliseconds(2)) }
        return sampler.inFlight == 0
    }

    private func makeFilter() async throws -> (filter: SCContentFilter, display: SCDisplay) {
        // Not on-screen only: an app is listed only if it has a listed window, and a window ordered in
        // a moment ago may not be on screen yet, which made the self-exclusion fail now and then.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ProbeError("no SCDisplay for the main screen")
        }
        guard options.filter == "self" else { return (SCContentFilter(display: display, excludingWindows: []), display) }
        let me = content.applications.filter { $0.processID == getpid() }
        guard !me.isEmpty else {
            let bundleID = Bundle.main.bundleIdentifier
            let ownWindowIDs = Set([ownMarker?.windowNumber].compactMap { $0 }.map(CGWindowID.init))
            SpikeLog.emit("s4-content-diagnosis", [
                "applications": content.applications.count, "windows": content.windows.count,
                "appsWithOwnBundleID": content.applications.filter { $0.bundleIdentifier == bundleID }.map(\.processID),
                "ownWindowsListed": content.windows.filter { ownWindowIDs.contains($0.windowID) }
                    .map { "\($0.windowID) app=\($0.owningApplication?.processID ?? -1)" },
                "pid": getpid(),
            ])
            throw ProbeError("this app is not in SCShareableContent")
        }
        return (SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), display)
    }

    private func makeStream() async throws -> SCStream {
        let (filter, display) = try await makeFilter()
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor * options.captureScale
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: sampler)
        try stream.addStreamOutput(sampler, type: .screen, sampleHandlerQueue: sampler.queue)
        SpikeLog.emit("s4-stream", ["filter": options.filter, "width": config.width, "height": config.height])
        return stream
    }

    private func showOwnMarker() {
        ownMarker?.orderOut(nil)
        ownMarker = MarkerWindow.make(frame: ownFrame, options: options, color: MarkerWindow.purple)
        ownMarker?.orderFrontRegardless()
    }

    /// Cocoa screen point -> pixel in a capture of `screen` (top-left origin).
    private static func pixel(_ point: NSPoint, on screen: NSScreen, scale: CGFloat) -> SIMD2<UInt32> {
        return SIMD2(UInt32(max(0, (point.x - screen.frame.minX) * scale)), UInt32(max(0, (screen.frame.maxY - point.y) * scale)))
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// Logs an error with its domain and code, so a TCC denial can be told apart from other failures.
func emitError(_ error: any Error, event: String = "error") {
    let ns = error as NSError
    SpikeLog.emit(event, ["message": error.localizedDescription, "domain": ns.domain, "code": ns.code])
}

struct ProbeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

/// p50, p95 and max of a list of milliseconds.
struct Percentiles {
    let fields: [String: any Sendable]

    init(_ values: [Double]) {
        let sorted = values.sorted()
        guard let max = sorted.last else { fields = ["count": 0]; return }
        func at(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        fields = ["count": sorted.count, "p50": at(0.5), "p95": at(0.95), "max": max]
    }
}

/// Receives frames on its own queue, wraps each IOSurface as a Metal texture without copying,
/// reads the named points on the GPU and keeps the frame alive until that GPU work completes.
/// Metal objects are immutable after init and thread-safe; mutable state is behind `state`.
final class FrameSampler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "FrameSampler")
    private let names: [String]
    private let device = MTLCreateSystemDefaultDevice()!
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let pointBuffer: any MTLBuffer
    private let cache: CVMetalTextureCache
    private let state = Mutex(State())
    private static let maxInFlight = 3

    private struct State {
        var firstFrameAt: Double?
        var stoppedAt: Double?
        var complete = 0, started = 0, otherStatus = 0, afterStop = 0, dropped = 0, noSurface = 0, surfaceMismatch = 0
        var sampled = 0, sampleFailed = 0
        var inFlight = 0
        var latenciesMs: [Double] = []
        var arrivedBeforeDisplayTime = 0
        var lastLabels: [String: String] = [:]
        var labelChanges = 0
    }

    init(points: [(String, SIMD2<UInt32>)]) {
        names = points.map(\.0)
        commandQueue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: Self.kernelSource, options: nil)
        pipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "samplePoints")!)
        let coordinates = points.map(\.1)
        let device = device
        pointBuffer = coordinates.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.cache = cache!
        super.init()
    }

    var firstFrameAt: Double? { state.withLock { $0.firstFrameAt } }
    var inFlight: Int { state.withLock { $0.inFlight } }

    func reset() { state.withLock { $0 = State() } }

    func markStopped(at time: Double) { state.withLock { $0.stoppedAt = time } }

    func flush() { CVMetalTextureCacheFlush(cache, 0) }

    func summary() -> [String: any Sendable] {
        state.withLock { s in
            ["complete": s.complete, "started": s.started, "otherStatus": s.otherStatus,
             "sampled": s.sampled, "sampleFailed": s.sampleFailed, "callbacksAfterStop": s.afterStop,
             "droppedInFlight": s.dropped, "noSurface": s.noSurface, "surfaceMismatch": s.surfaceMismatch,
             "inFlightAtSummary": s.inFlight, "labelChanges": s.labelChanges,
             // From the frame's display time (when WindowServer showed that screen content) to the
             // callback: the capture delay for any change on screen, Fixture flash or not.
             "displayToCallbackMs": Percentiles(s.latenciesMs).fields,
             // Frames whose callback came before their stated display time (not in the percentiles).
             "arrivedBeforeDisplayTime": s.arrivedBeforeDisplayTime]
        }
    }

    /// The stream stopped by itself: the permission was revoked, or the user stopped it from the menu bar.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        emitError(error, event: "s4-stream-stopped")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let arrival = ProcessInfo.processInfo.systemUptime
        let arrivalMach = mach_absolute_time()
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let accepted: Bool = state.withLock { s in
            if let stopped = s.stoppedAt, arrival > stopped { s.afterStop += 1 }
            // `.started` is the first frame after startup; it counts when it carries an image.
            let hasImage = sampleBuffer.imageBuffer != nil
            switch status {
            case .complete: s.complete += 1
            case .started where hasImage: s.started += 1
            default: s.otherStatus += 1; return false
            }
            if s.firstFrameAt == nil { s.firstFrameAt = arrival }
            if let displayTime = info[.displayTime] as? UInt64 {
                if arrivalMach > displayTime {
                    s.latenciesMs.append(Self.milliseconds(fromMach: arrivalMach - displayTime))
                } else {
                    s.arrivedBeforeDisplayTime += 1
                }
            }
            guard s.inFlight < Self.maxInFlight else { s.dropped += 1; return false }
            s.inFlight += 1
            return true
        }
        guard accepted else { return }
        if !sample(sampleBuffer) {
            state.withLock { $0.inFlight -= 1; $0.sampleFailed += 1 }
        }
    }

    /// Returns false if no GPU work was submitted.
    private func sample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            state.withLock { $0.noSurface += 1 }
            return false
        }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
                                                  0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture),
              let commands = commandQueue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder(),
              let output = device.makeBuffer(length: names.count * MemoryLayout<UInt32>.stride) else { return false }
        // Zero copy: the texture must be backed by the very IOSurface the frame came in.
        if texture.iosurface.map(IOSurfaceGetID) != IOSurfaceGetID(surface) { state.withLock { $0.surfaceMismatch += 1 } }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(pointBuffer, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes([UInt32(texture.width), UInt32(texture.height)], length: 8, index: 2)
        encoder.setBytes(Self.labelColors, length: Self.labelColors.count * MemoryLayout<SIMD4<Float>>.stride, index: 3)
        encoder.dispatchThreads(MTLSize(width: names.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: names.count, height: 1, depth: 1))
        encoder.endEncoding()
        // The frame (pixel buffer and CVMetalTexture) stays alive until the GPU has read it.
        nonisolated(unsafe) let keepAlive = (pixelBuffer, cvTexture, output)
        commands.addCompletedHandler { [self] buffer in
            guard buffer.status == .completed else {
                state.withLock { $0.inFlight -= 1; $0.sampleFailed += 1 }
                return
            }
            let indices = keepAlive.2.contents().bindMemory(to: UInt32.self, capacity: names.count)
            record((0..<names.count).map { Self.labelNames[min(Int(indices[$0]), Self.labelNames.count - 1)] })
        }
        commands.commit()
        return true
    }

    private func record(_ labels: [String]) {
        let current = Dictionary(uniqueKeysWithValues: zip(names, labels))
        let changed: Bool = state.withLock { s in
            s.inFlight -= 1
            s.sampled += 1
            guard current != s.lastLabels else { return false }
            s.lastLabels = current
            s.labelChanges += 1
            return true
        }
        if changed { SpikeLog.emit("s4-sample", ["labels": current]) }
    }

    /// The kernel classifies each sRGB-encoded pixel against these colours on the GPU and returns only
    /// the index (the last name, "other", when none is within 0.12), so no pixel value reaches the CPU.
    private static let labelNames = ["orange", "purple", "black", "white", "other"]
    private static let labelColors: [SIMD4<Float>] = [MarkerWindow.orange, MarkerWindow.purple, .zero, .one]
        .map { SIMD4($0, 0) }

    private static func milliseconds(fromMach ticks: UInt64) -> Double {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(ticks) * Double(base.numer) / Double(base.denom) / 1_000_000
    }

    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void samplePoints(texture2d<float, access::read> frame [[texture(0)]],
                             constant uint2 *points [[buffer(0)]],
                             device uint *out [[buffer(1)]],
                             constant uint2 &size [[buffer(2)]],
                             constant float4 *colors [[buffer(3)]],
                             uint i [[thread_position_in_grid]]) {
        float3 rgb = frame.read(min(points[i], size - 1)).rgb;
        uint label = 4;
        for (uint c = 0; c < 4 && label == 4; c++) {
            if (all(abs(rgb - colors[c].rgb) < 0.12)) { label = c; }
        }
        out[i] = label;
    }
    """
}
