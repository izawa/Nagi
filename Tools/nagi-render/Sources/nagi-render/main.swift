// nagi-render: renders effects off screen to a PNG or a numbered PNG sequence (SPEC 3.12).
// --time starts the animation and wind clocks; --frames and --fps step them together.
//
//   nagi-render komorebi --at 2026-06-21T12:00:00+09:00 --depth 35 --presence 1 --appearance light \
//     --seed 42 --background gray:0.9 --size 1600x1000 --physical-mm 400x250 --output noon.png
//
// Effects: the app's catalog, plus "patch" (a flat premultiplied colour, for calibration).
// --param key=value sets an effect parameter (number, true/false, or a choice key).

import CoreGraphics
import ImageIO
import DebugEffects
import EffectCatalog
import Foundation
import Metal
import NagiCore
import NagiKit

@MainActor func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let effectList = arguments.first, !effectList.hasPrefix("--") else { throw usage() }
    arguments.removeFirst()
    let options = try Options(arguments)

    let available: [any Effect.Type] = EffectCatalog.all + [PatchEffect.self]
    let ids = effectList.split(separator: ",").map(String.init)
    guard Set(ids).count == ids.count else { throw NagiCoreError("an effect is listed twice") }
    let types = try ids.map { id in
        guard let type = available.first(where: { $0.descriptor.id == id }) else {
            throw NagiCoreError("unknown effect \(id); known: \(available.map { $0.descriptor.id }.joined(separator: ", "))")
        }
        return type
    }
    guard let device = MTLCreateSystemDefaultDevice() else { throw NagiCoreError("no Metal device") }
    let renderer = try FrameRenderer(device: device, effects: types)
    renderer.parameters = Dictionary(uniqueKeysWithValues: types.map { ($0.descriptor.id, options.parameters) })

    let points = CGSize(width: Double(options.size.x) / 2, height: Double(options.size.y) / 2)
    let view = DisplayView(id: 1, pixelSize: options.size, scale: 2, frameInDesktop: CGRect(origin: .zero, size: points),
                           physicalSize: options.physicalSize, edrHeadroom: 1, potentialEDRHeadroom: 1)
    let location = options.location ?? EnvironmentModel.defaultLocation(at: options.date)
    // The same weather hints the live engine mixes in (NagiEngine).
    var weather = options.weather
    weather.cloudBias = types.compactMap { $0.descriptor.weatherHint?.cloudBias }.reduce(0, +)
    let deltaTime = options.frames == 1 ? 1.0 / 60 : 1.0 / options.fps
    for index in 0..<options.frames {
        try autoreleasepool {
            let elapsed = Double(index) / options.fps
            let time = options.time + elapsed
            let date = options.date.addingTimeInterval(elapsed)
            let environment = EnvironmentModel.environment(at: date, location: location, windTime: time, seed: options.seed,
                                                           weather: weather)
            let frame = FrameState(time: time, deltaTime: deltaTime, date: date, phase: .calm,
                                   presence: options.presence, depth: max(0, options.depth + options.depthRate * elapsed),
                                   appearance: options.appearance,
                                   seed: options.seed, environment: environment)
            let output = options.outputURL(for: index)
            if options.debugAlpha {
                // Stretch each frame's alpha so its peak is white.
                let overlay = try renderer.renderOverlay(frame, view: view, strength: options.strength)
                try writeAlpha(TextureReader.pixels(of: overlay), size: options.size, to: output)
            } else {
                let screen = try renderer.renderOffscreen(frame, view: view, strength: options.strength, background: options.background)
                try TextureReader.writePNG(screen, to: output)
            }
            print(output.path)
        }
    }
}

struct Options {
    var date = Date()
    var time = 0.0
    var frames = 1
    /// Depth gained per second of a sequence (1 = deepening in real time).
    var depthRate = 0.0
    /// Clear by default, so a comparison does not depend on the weather.
    var weather = EnvironmentModel.Weather(sky: .clear)
    private var cloudPass = false
    var fps = 30.0
    var depth = 60.0
    var presence = 1.0
    var strength = 1.0
    var appearance = Appearance.light
    var seed: UInt64 = 1
    var background = Background.gray(0.9)
    var size = SIMD2(1600, 1000)
    var physicalSize: SIMD2<Double>?
    var parameters: [String: ParameterValue] = [:]
    var output = URL(fileURLWithPath: "nagi.png")
    var location: GeoLocation?
    var debugAlpha = false

    init(_ arguments: [String]) throws {
        var index = 0
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw usage() }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--at":
                guard let parsed = ISO8601DateFormatter().date(from: try value()) else { throw usage() }
                date = parsed
            case "--time": time = try number(value())
            case "--frames":
                guard let count = Int(try value()), count > 0 else { throw usage() }
                frames = count
            case "--fps":
                fps = try number(value())
                guard fps > 0 else { throw usage() }
            case "--sky":
                switch try value() {
                case "clear": weather.sky = .clear; cloudPass = false
                case "natural": weather.sky = .natural; cloudPass = false
                case "pass": cloudPass = true
                default: throw usage()
                }
            case "--depth": depth = try number(value())
            case "--depth-rate": depthRate = try number(value())
            case "--presence": presence = try unit(value())
            case "--strength": strength = try unit(value())
            case "--appearance":
                switch try value() {
                case "light": appearance = .light
                case "dark": appearance = .dark
                default: throw usage()
                }
            case "--seed":
                guard let parsed = UInt64(try value()) else { throw usage() }
                seed = parsed
            case "--background":
                let text = try value()
                background = text.hasPrefix("gray:") ? .gray(try number(String(text.dropFirst(5))))
                    : .image(URL(fileURLWithPath: text))
            case "--size":
                size = try pair(value()) { Int($0) }
                guard size.x > 0, size.y > 0, size.x <= 16384, size.y <= 16384 else { throw usage() }
            case "--physical-mm": physicalSize = try pair(value()) { Double($0) }
            case "--param":
                let parts = try value().split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw usage() }
                parameters[parts[0]] = ParameterValue(parsing: parts[1])
            case "--output": output = URL(fileURLWithPath: try value())
            case "--debug-alpha":
                debugAlpha = true
                index += 1
                continue
            case "--location":
                let latLon = try pair(value().replacingOccurrences(of: ",", with: "x")) { Double($0) }
                location = GeoLocation(latitude: latLon.x, longitude: latLon.y)
            default: throw usage()
            }
            index += 1
        }
        if cloudPass { weather.sky = .cloudPass(start: time) }
    }

    func outputURL(for index: Int) -> URL {
        guard frames > 1 else { return output }
        let base = output.pathExtension.lowercased() == "png" ? output.deletingPathExtension() : output
        return URL(fileURLWithPath: base.path + String(format: "-%04ld.png", index))
    }
}

func writeAlpha(_ pixels: [SIMD4<Float>], size: SIMD2<Int>, to url: URL) throws {
    let peak = max(pixels.map(\.w).max() ?? 0, 1e-6)
    let bytes = pixels.map { UInt8(min(max($0.w / peak, 0), 1) * 255) }
    let data = Data(bytes) as CFData
    guard let provider = CGDataProvider(data: data),
          let image = CGImage(width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size.x,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw NagiCoreError("could not write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NagiCoreError("could not write \(url.path)") }
    print("alpha peak \(peak)")
}

func number(_ text: String) throws -> Double {
    guard let value = Double(text), value.isFinite else { throw usage() }
    return value
}

func unit(_ text: String) throws -> Double {
    let value = try number(text)
    guard (0...1).contains(value) else { throw usage() }
    return value
}

func pair<T: SIMDScalar>(_ text: String, _ parse: (String) -> T?) throws -> SIMD2<T> {
    let parts = text.split(separator: "x").map { parse(String($0)) }
    guard parts.count == 2, let x = parts[0], let y = parts[1] else { throw usage() }
    return SIMD2(x, y)
}

func usage() -> NagiCoreError {
    NagiCoreError("""
    usage: nagi-render <effect[,effect…]> [--at ISO8601] [--time s] [--frames N] [--fps F] [--depth s] [--depth-rate r] [--presence 0…1] \
    [--strength 0…1] [--appearance light|dark] [--seed n] [--background gray:<0…1>|<image>] \
    [--size WxH] [--physical-mm WxH] [--location lat,lon] [--sky clear|natural|pass] [--param key=value]… \
    [--debug-alpha] [--output file.png]
    --frames defaults to 1. Sequences default to 30 fps and write file-0000.png, file-0001.png, …
    --sky defaults to clear; pass is one cloud crossing the sun, starting at --time.
    """)
}

do {
    try MainActor.assumeIsolated { try run() }
} catch {
    FileHandle.standardError.write(Data("nagi-render: \(error.localizedDescription)\n".utf8))
    exit(1)
}
