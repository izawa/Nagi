import AppKit
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import ScreenCaptureKit
import SpikeLog

/// S2 numeric check of WindowServer's premultiplied compositing.
@MainActor final class CompositeProbe {
    private struct Patch {
        let name: String
        let alpha: Double
        let color: SIMD3<Double>
    }

    private struct Sample {
        let gray: Double
        let patch: Patch
        let center: CGPoint
        let baselineCenter: CGPoint
    }

    private enum CapturePath: String {
        case halfFloat = "half-float"
        case bgra = "bgra-srgb"

        var format: OSType { self == .halfFloat ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA }
        var colorSpace: CFString { self == .halfFloat ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.sRGB }
        var bytesPerPixel: Int { self == .halfFloat ? 8 : 4 }
    }

    init(options: Options) {
        Task {
            do {
                try await run(options: options)
                AppDelegate.quit(reason: "done")
            } catch {
                emitError(error)
                AppDelegate.quit(reason: "error")
            }
        }
    }

    private func run(options: Options) async throws {
        let grays = [0.1, 0.5, 0.75]
        let panels = FixtureWindows.frames()
        guard panels.count == grays.count else {
            throw ProbeError("Run Fixture --scene panels --grays 0.1,0.5,0.75 first (found \(panels.count) windows)")
        }
        let frame = panels.reduce(CGRect.null) { $0.union($1) }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) }) else {
            throw ProbeError("The Fixture panels must fit on one display")
        }

        let window = OverlayWindow.make(frame: frame, options: options)
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        window.contentView = container

        let metal = SpikeMetal()
        let pipeline = metal.pipeline(fragment: "markerFragment", format: .rgba16Float)
        let scale = screen.backingScaleFactor
        let side: CGFloat = 40
        let gap: CGFloat = 20
        let accent = SIMD3(0.04, 0.08, 0.02)
        // Two rows per panel. The upper row is light brighter than white once unpremultiplied (C/a > 1),
        // the range an EDR highlight would use.
        let rows: [[Patch]] = [[
            Patch(name: "darken", alpha: 0.08, color: .zero),
            Patch(name: "tint", alpha: 0.20, color: accent),
            Patch(name: "additive-zero", alpha: 0, color: accent),
            Patch(name: "additive-epsilon", alpha: 1.0 / 1024, color: accent),
            Patch(name: "witness", alpha: 1, color: SIMD3(0.2, 0.4, 0.6)),
        ], [1.5, 2, 3].map { ratio in
            Patch(name: "bright-\(ratio)", alpha: 0.3, color: SIMD3(repeating: 0.3 * ratio))
        }]
        let wholeLayer = SIMD4<Float>(0, 0, Float(side * scale), Float(side * scale))
        var layers: [(CAMetalLayer, MarkerUniforms)] = []
        var samples: [Sample] = []
        for (panel, gray) in zip(panels, grays) {
            // Center the row on a grid cell near one quarter of the window height.
            let content = NSWindow.contentRect(forFrameRect: panel, styleMask: .titled)
            let distanceFromTop = content.maxY - (panel.minY + panel.height / 4)
            let firstRowY = content.maxY - ((distanceFromTop / gap).rounded(.down) + 0.5) * gap
            for (row, patches) in rows.enumerated() {
            let centerY = firstRowY + CGFloat(row) * 3 * gap  // stays on a grid cell centre
            for (index, patch) in patches.enumerated() {
                // The inset places the patch and gap centers 5 pt from a vertical grid line.
                let x = content.minX + 25 + CGFloat(index) * (side + gap)
                let layer = CAMetalLayer()
                layer.frame = CGRect(x: x - frame.minX, y: centerY - side / 2 - frame.minY, width: side, height: side)
                metal.configure(layer, format: .rgba16Float, edr: true, pointSize: layer.frame.size, scale: scale)
                container.layer?.addSublayer(layer)
                let uniforms = MarkerUniforms(rects: (wholeLayer, .zero),
                                              color: SIMD4(SIMD3<Float>(patch.color), Float(patch.alpha)))
                layers.append((layer, uniforms))
                samples.append(Sample(gray: gray, patch: patch, center: CGPoint(x: x + side / 2, y: centerY),
                                      baselineCenter: CGPoint(x: x + side + gap / 2, y: centerY)))
            }
            }
        }

        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for attempt in 0..<2 {
            if attempt == 1 { try await Task.sleep(for: .milliseconds(500)) }
            for (layer, uniforms) in layers {
                metal.draw(layer, pipeline: pipeline, uniforms: uniforms) { _ in }
            }
        }
        // The EDR headroom takes about 2 s to ramp after EDR content appears (S1).
        try await Task.sleep(for: .seconds(3))
        SpikeLog.emit("s2n-screens", ["screens": OverlayProbe.describeScreens()])

        guard let overlayScreen = window.screen,
              let displayID = overlayScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ProbeError("The overlay has no display ID")
        }
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID.uint32Value }) else {
            throw ProbeError("The overlay display is unavailable to ScreenCaptureKit")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixelScale = Double(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((Double(display.width) * pixelScale).rounded())
        config.height = Int((Double(display.height) * pixelScale).rounded())
        config.showsCursor = false

        let measurements: [[String: any Sendable]]
        do {
            measurements = try await capture(.halfFloat, filter: filter, config: config,
                                             screenFrame: overlayScreen.frame, samples: samples)
        } catch let mismatch as BaselineMismatch {
            throw mismatch
        } catch {
            measurements = try await capture(.bgra, filter: filter, config: config,
                                             screenFrame: overlayScreen.frame, samples: samples)
        }
        for measurement in measurements { SpikeLog.emit("s2n-patch", measurement) }
    }

    private func capture(_ path: CapturePath, filter: SCContentFilter, config: SCStreamConfiguration,
                         screenFrame: CGRect, samples: [Sample]) async throws -> [[String: any Sendable]] {
        config.captureDynamicRange = path == .halfFloat ? .hdrLocalDisplay : .SDR
        config.pixelFormat = path.format
        config.colorSpaceName = path.colorSpace
        var fields: [String: any Sendable] = ["path": path.rawValue, "requestedColorSpace": path.colorSpace as String]
        defer { SpikeLog.emit("s2n-capture", fields) }
        do {
            let screenshot = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
            guard let buffer = CMSampleBufferGetImageBuffer(screenshot) else {
                throw ProbeError("The screenshot has no pixel buffer")
            }
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let colorSpace = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue()
            fields["pixelFormat"] = String(decoding: (0..<4).reversed().map {
                UInt8(truncatingIfNeeded: format >> ($0 * 8))
            }, as: UTF8.self)
            fields["width"] = width
            fields["height"] = height
            fields["colorSpace"] = colorSpace.map { space in
                space.name.map { $0 as String } ?? "<unnamed>"
            } ?? "<none>"
            fields["colorPrimaries"] = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
            fields["transferFunction"] = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
            guard format == path.format, width == config.width, height == config.height else {
                throw ProbeError("ScreenCaptureKit returned an unexpected pixel format or size")
            }
            let equivalentSpace = path == .halfFloat ? CGColorSpace.linearDisplayP3 : CGColorSpace.extendedSRGB
            if let name = colorSpace?.name, name != path.colorSpace, name != equivalentSpace {
                throw ProbeError("ScreenCaptureKit returned an unexpected color space")
            }
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                throw ProbeError("Couldn't lock the screenshot pixel buffer")
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw ProbeError("The screenshot pixel buffer has no base address")
            }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let measurements = try samples.map { sample in
                let baseline = try mean(at: sample.baselineCenter)
                // The Fixture must run with --grays 0.1,0.5,0.75 and nothing may cover the panels. Otherwise
                // stop before logging any value: it would be another app's content, not a measurement.
                let nominal = sample.gray <= 0.04045 ? sample.gray / 12.92 : pow((sample.gray + 0.055) / 1.055, 2.4)
                guard abs(baseline.y - nominal) < 0.05 else {
                    throw BaselineMismatch(errorDescription: "the background next to \(sample.patch.name) on gray \(sample.gray) isn't the Fixture's gray")
                }
                let measured = try mean(at: sample.center)
                let expected = baseline * (1 - sample.patch.alpha) + sample.patch.color
                return [
                    "nominalGray": sample.gray, "patch": sample.patch.name, "alpha": sample.patch.alpha,
                    "premultipliedRGB": rgb(sample.patch.color), "baselineRGB": rgb(baseline),
                    "measuredRGB": rgb(measured), "expectedRGB": rgb(expected), "residualRGB": rgb(measured - expected),
                ] as [String: any Sendable]
            }
            fields["used"] = true
            return measurements

            func mean(at point: CGPoint) throws -> SIMD3<Double> {
                // AppKit's global coordinates are y-up. Screenshot rows start at the top of this display.
                let x = Int(((point.x - screenFrame.minX) * CGFloat(width) / screenFrame.width).rounded()) - 8
                let y = Int(((screenFrame.maxY - point.y) * CGFloat(height) / screenFrame.height).rounded()) - 8
                guard x >= 0, y >= 0, x + 16 <= width, y + 16 <= height else {
                    throw ProbeError("A 16×16 sample falls outside the screenshot")
                }
                var sum = SIMD3<Double>.zero
                for row in y..<(y + 16) {
                    for column in x..<(x + 16) {
                        let pixel = base.advanced(by: row * rowBytes + column * path.bytesPerPixel)
                        if path == .halfFloat {
                            sum += SIMD3(half(at: 0), half(at: 2), half(at: 4))
                        } else {
                            sum += SIMD3(linear(at: 2), linear(at: 1), linear(at: 0))
                        }

                        func half(at offset: Int) -> Double {
                            let bits = pixel.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                            return Double(Float16(bitPattern: UInt16(littleEndian: bits)))
                        }
                        func linear(at offset: Int) -> Double {
                            let value = Double(pixel.load(fromByteOffset: offset, as: UInt8.self)) / 255
                            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                        }
                    }
                }
                let result = sum / 256
                guard rgb(result).allSatisfy(\.isFinite) else { throw ProbeError("The screenshot contains nonfinite RGB") }
                return path == .halfFloat ? result : try linearSRGBToP3(result)
            }
        } catch {
            fields["used"] = false
            fields["error"] = error.localizedDescription
            throw error
        }
    }

    private func rgb(_ color: SIMD3<Double>) -> [Double] { [color.x, color.y, color.z] }

    private func linearSRGBToP3(_ color: SIMD3<Double>) throws -> SIMD3<Double> {
        let source = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let destination = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        guard let components = CGColor(colorSpace: source, components: [color.x, color.y, color.z, 1])?
            .converted(to: destination, intent: .relativeColorimetric, options: nil)?.components else {
            throw ProbeError("Couldn't convert linear sRGB samples to linear Display P3")
        }
        return SIMD3(components[0], components[1], components[2])
    }
}

/// A sample's background is not the Fixture's panel gray, so no value from this capture is logged.
private struct BaselineMismatch: LocalizedError {
    let errorDescription: String?
}
