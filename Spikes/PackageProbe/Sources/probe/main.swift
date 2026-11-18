import Darwin
import Foundation
import Metal
import ProbeShaders

private func fail(_ message: String) -> Never {
    print("FAIL \(message)")
    exit(1)
}

private func runProbe() throws -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else {
        fail("No system default Metal device")
    }
    let library = try loadProbeLibrary(device: device) { url in
        print("metallib: \(url.path)")
    }
    guard let function = library.makeFunction(name: probeKernelName) else {
        fail("Metal function \(probeKernelName) missing")
    }
    let pipeline = try device.makeComputePipelineState(function: function)

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: 2, height: 2, mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = .shaderWrite
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        fail("Could not create the 2x2 rgba16Float texture")
    }
    guard let queue = device.makeCommandQueue(),
          let commands = queue.makeCommandBuffer(),
          let encoder = commands.makeComputeCommandEncoder() else {
        fail("Could not create the Metal command queue, buffer, or compute encoder")
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
        let detail = commands.error?.localizedDescription ?? String(describing: commands.status)
        fail("Metal command buffer failed: \(detail)")
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
    let passed = zip(pixels.joined(), expected.joined()).allSatisfy { actual, target in
        abs(actual - target) <= 0.001
    }
    print("\(passed ? "PASS" : "FAIL") pixels \(pixels), expected \(expected)")
    return passed
}

do {
    exit(try runProbe() ? 0 : 1)
} catch {
    fail(error.localizedDescription)
}
