import Metal

/// Filters a layer's occlusion mask with the sun's image: the mean over an ellipse with semi-axes
/// `a` across and `b` along the azimuth (mask rows run across). Row prefix sums, then a sum of
/// horizontal chords per texel, so a flat region stays exactly flat (SPEC 4.1: a disk, not a blur).
struct SunImageFilter {
    /// The sun's image for one mask. Leaves in a real crown spread over a metre or more of height,
    /// so the image (and the blur of an edge) changes from place to place: its size is scaled by
    /// 2^(spread · n), n a smooth noise in −1…1 over the layer (stop B: a uniform blur looked wrong).
    struct Image {
        var semiAxes = SIMD2<Float>(0, 0)   // across, along; texels
        var origin = SIMD2<Float>(0, 0)     // mask origin, texels
        var stride: Float = 1               // millimetres per texel
        var spread: Float = 0
    }

    private let prefixPipeline: any MTLComputePipelineState
    private let chordPipeline: any MTLComputePipelineState

    init(device: any MTLDevice, library: any MTLLibrary) throws {
        prefixPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "prefixRows")!)
        chordPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "chordFilter")!)
    }

    /// - Parameters:
    ///   - mask: rgba16Float transmission. `prefix`: rgba32Float, one texel wider. `filtered`: like `mask`.
    func encode(mask: any MTLTexture, prefix: any MTLTexture, filtered: any MTLTexture, image: Image,
                into compute: any MTLComputeCommandEncoder) {
        compute.setComputePipelineState(prefixPipeline)
        compute.setTexture(mask, index: 0)
        compute.setTexture(prefix, index: 1)
        compute.dispatchThreads(MTLSize(width: mask.height, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        var image = image
        compute.setComputePipelineState(chordPipeline)
        compute.setTexture(mask, index: 0)
        compute.setTexture(prefix, index: 1)
        compute.setTexture(filtered, index: 2)
        compute.setBytes(&image, length: MemoryLayout<Image>.stride, index: 0)
        compute.dispatchThreads(MTLSize(width: mask.width, height: mask.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }
}
