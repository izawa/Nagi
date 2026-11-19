import CoreGraphics
import Foundation
import ImageIO
import Metal
import NagiKit
import UniformTypeIdentifiers

/// Off-screen rendering for nagi-render, the gallery and tests (SPEC 3.12).
@MainActor extension FrameRenderer {
    /// Renders one frame over `background` and returns what the screen would show:
    /// encoded Display P3, composited the way WindowServer does (SPEC 3.5).
    public func renderOffscreen(_ frame: FrameState, view: DisplayView, strength: Double = 1,
                                background: Background) throws -> any MTLTexture {
        let size = view.pixelSize
        let base = try background.makeTexture(size: size, renderer: self)
        let screen = try makeTexture(size: size, storage: .shared)
        guard let commandBuffer = queue.makeCommandBuffer() else { throw NagiCoreError("no command buffer") }
        update(frame)
        try encodeScreen(frame, view: view, strength: strength, background: base, into: screen, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return screen
    }

    /// The premultiplied linear overlay alone (what the live path hands to WindowServer).
    public func renderOverlay(_ frame: FrameState, view: DisplayView, strength: Double = 1) throws -> any MTLTexture {
        let overlay = try makeTexture(size: view.pixelSize, storage: .shared)
        guard let commandBuffer = queue.makeCommandBuffer() else { throw NagiCoreError("no command buffer") }
        update(frame)
        try encode(frame, view: view, strength: strength, into: overlay, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw error }
        return overlay
    }
}

/// What is under the overlay in an off-screen render.
public enum Background: Sendable {
    /// A flat sRGB gray.
    case gray(Double)
    /// An image file, scaled to fill.
    case image(URL)

    /// The background as encoded Display P3 in the working format.
    @MainActor public func makeTexture(size: SIMD2<Int>, renderer: FrameRenderer) throws -> any MTLTexture {
        let pixels = try encodedDisplayP3(size: size)
        let texture = try renderer.makeTexture(size: size, storage: .shared)
        let halves = pixels.map(Float16.init)
        halves.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: size.x * 8)
        }
        return texture
    }

    /// RGBA float components in Display P3 (encoded), row-major from the top.
    private func encodedDisplayP3(size: SIMD2<Int>) throws -> [Float] {
        var pixels = [Float](repeating: 0, count: size.x * size.y * 4)
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let info = CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: size.x, height: size.y,
                                          bitsPerComponent: 32, bytesPerRow: size.x * 16, space: space,
                                          bitmapInfo: info) else {
                throw NagiCoreError("could not make a bitmap context")
            }
            let rect = CGRect(x: 0, y: 0, width: size.x, height: size.y)
            switch self {
            case let .gray(value):
                context.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
                context.fill(rect)
            case let .image(url):
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw NagiCoreError("could not read \(url.path)")
                }
                context.interpolationQuality = .high
                context.draw(image, in: rect)
            }
        }
        return pixels
    }
}

/// Reading textures back, for nagi-render and tests.
public enum TextureReader {
    /// RGBA of a shared rgba16Float texture, row-major from the top.
    public static func pixels(of texture: any MTLTexture) -> [SIMD4<Float>] {
        var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        halves.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return stride(from: 0, to: halves.count, by: 4).map {
            SIMD4(Float(halves[$0]), Float(halves[$0 + 1]), Float(halves[$0 + 2]), Float(halves[$0 + 3]))
        }
    }

    /// Writes encoded Display P3 pixels as a 16-bit PNG tagged Display P3. Values above 1
    /// (EDR) are clipped: a PNG cannot show them.
    public static func writePNG(_ texture: any MTLTexture, to url: URL) throws {
        let pixels = pixels(of: texture)
        var words = [UInt16]()
        words.reserveCapacity(pixels.count * 4)
        for pixel in pixels {
            for channel in 0..<3 {
                let value = pixel[channel].isFinite ? min(max(pixel[channel], 0), 1) : 0
                words.append(UInt16((value * 65535).rounded()))
            }
            words.append(65535)
        }
        let data = words.withUnsafeBytes { Data($0) } as CFData
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 16,
                                  bitsPerPixel: 64, bytesPerRow: texture.width * 8,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NagiCoreError("could not write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NagiCoreError("could not write \(url.path)") }
    }
}
