import Foundation
import Metal

public let probeKernelName = "writeProbePixels"

private struct ProbeError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

public func loadProbeLibrary(
    device: any MTLDevice,
    reportPath: (URL) -> Void = { _ in }
) throws -> any MTLLibrary {
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
        library = try device.makeDefaultLibrary(bundle: Bundle.module)
    } catch {
        throw ProbeError("Metal library load failed at \(url.path): \(error.localizedDescription)")
    }
    reportPath(url)

    guard library.makeFunction(name: probeKernelName) != nil else {
        throw ProbeError(
            "Metal function \(probeKernelName) missing in \(url.path). Found \(library.functionNames)"
        )
    }
    return library
}
