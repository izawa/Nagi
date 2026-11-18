import Foundation
import Metal
import ProbeShaders

guard let device = MTLCreateSystemDefaultDevice() else {
    print("FAIL No system default Metal device")
    exit(1)
}
do {
    let result = try runProbe(device: device)
    print("metallib: \(result.metallibPath)")
    print("\(result.passed ? "PASS" : "FAIL") pixels \(result.pixels), expected \(result.expected)")
    exit(result.passed ? 0 : 1)
} catch {
    print("FAIL \(error.localizedDescription)")
    exit(1)
}
