// nagi-render: renders effects off screen and writes what the screen would show as a PNG
// (SPEC 3.12). The implementer looks at the image and fixes the effect.
//
//   nagi-render komorebi --at 2026-06-21T12:00:00+09:00 --depth 35 --presence 1 --appearance light \
//     --seed 42 --background gray:0.9 --size 1600x1000 --physical-mm 400x250 --output noon.png
//
// Effects: the app's catalog, plus "patch" (a flat premultiplied colour, for calibration).
// --param key=value sets an effect parameter (number, true/false, or a choice key).

import CoreGraphics
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
    let frame = FrameState(time: options.time, deltaTime: 1.0 / 60, date: options.date, phase: .calm,
                           presence: options.presence, depth: options.depth, appearance: options.appearance,
                           seed: options.seed)
    let screen = try renderer.renderOffscreen(frame, view: view, strength: options.strength, background: options.background)
    try TextureReader.writePNG(screen, to: options.output)
    print(options.output.path)
}

struct Options {
    var date = Date()
    var time = 0.0
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
            case "--depth": depth = try number(value())
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
                parameters[parts[0]] = Double(parts[1]).map { .number($0) }
                    ?? (["true", "false"].contains(parts[1]) ? .flag(parts[1] == "true") : .choice(parts[1]))
            case "--output": output = URL(fileURLWithPath: try value())
            default: throw usage()
            }
            index += 1
        }
    }
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
    usage: nagi-render <effect[,effect…]> [--at ISO8601] [--time s] [--depth s] [--presence 0…1] \
    [--strength 0…1] [--appearance light|dark] [--seed n] [--background gray:<0…1>|<image>] \
    [--size WxH] [--physical-mm WxH] [--param key=value]… [--output file.png]
    """)
}

do {
    try MainActor.assumeIsolated { try run() }
} catch {
    FileHandle.standardError.write(Data("nagi-render: \(error.localizedDescription)\n".utf8))
    exit(1)
}
