import Foundation
import Metal

public let probeKernelName = "writeProbePixels"

private struct ProbeError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

public struct ProbeResult: Sendable {
    public let passed: Bool
    public let pixels: [[Float]]
    public let expected: [[Float]]
    public let metallibPath: String
}

public func loadProbeLibrary(device: any MTLDevice) throws -> (library: any MTLLibrary, url: URL) {
    // Bundle.module traps if the bundle is absent. Check the app and CLI layouts first.
    let bundleName = "PackageProbe_ProbeShaders.bundle"
    let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        .compactMap { $0?.appendingPathComponent(bundleName) }
    guard candidates.contains(where: { Bundle(url: $0) != nil }) else {
        throw ProbeError("Resource bundle missing. Checked \(candidates.map(\.path))")
    }

    let bundle = Bundle.module
    guard let url = bundle.url(forResource: "default", withExtension: "metallib") else {
        let contents = try? FileManager.default.subpathsOfDirectory(atPath: bundle.bundlePath).sorted()
        throw ProbeError(
            "default.metallib missing in \(bundle.bundlePath). Bundle contents: \(contents ?? ["<unreadable>"])"
        )
    }

    let library: any MTLLibrary
    do {
        library = try device.makeDefaultLibrary(bundle: bundle)
    } catch {
        throw ProbeError("Metal library load failed at \(url.path): \(error.localizedDescription)")
    }
    guard library.makeFunction(name: probeKernelName) != nil else {
        throw ProbeError(
            "Metal function \(probeKernelName) missing in \(url.path). Found \(library.functionNames)"
        )
    }
    return (library, url)
}

/// Runs the probe kernel on a 2x2 rgba16Float texture and compares the four pixels.
public func runProbe(device: any MTLDevice) throws -> ProbeResult {
    let (library, url) = try loadProbeLibrary(device: device)
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: probeKernelName)!)

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: 2, height: 2, mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = .shaderWrite
    guard let texture = device.makeTexture(descriptor: descriptor),
          let queue = device.makeCommandQueue(),
          let commands = queue.makeCommandBuffer(),
          let encoder = commands.makeComputeCommandEncoder() else {
        throw ProbeError("Could not create the texture, command queue, buffer, or compute encoder")
    }

    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.dispatchThreadgroups(
        MTLSize(width: 1, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 2, height: 2, depth: 1)
    )
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    guard commands.status == .completed else {
        throw ProbeError("Metal command buffer failed: \(commands.error?.localizedDescription ?? "\(commands.status)")")
    }

    var channels = [Float16](repeating: 0, count: 2 * 2 * 4)
    channels.withUnsafeMutableBytes { bytes in
        texture.getBytes(
            bytes.baseAddress!, bytesPerRow: 2 * 4 * MemoryLayout<Float16>.stride,
            from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0
        )
    }
    let pixels = stride(from: 0, to: channels.count, by: 4).map { offset in
        channels[offset..<(offset + 4)].map { Float($0) }
    }
    let expected: [[Float]] = [
        [0, 0.5, 1, 1], [0.25, 0.5, 1, 1],
        [0.5, 0.5, 1, 1], [0.75, 0.5, 1, 1],
    ]
    let passed = zip(pixels.joined(), expected.joined()).allSatisfy { abs($0 - $1) <= 0.001 }
    return ProbeResult(passed: passed, pixels: pixels, expected: expected, metallibPath: url.path)
}
