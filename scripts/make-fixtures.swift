// Draws the reading backgrounds for nagi-render (M1-PLAN 7.4): body text in light and dark.
// usage: swift scripts/make-fixtures.swift   (writes Fixtures/reading-{light,dark}.png)
import AppKit

let size = NSSize(width: 2560, height: 1440)
let paragraph = """
木漏れ日が美しいのは、太陽が点ではなく円盤だからである。葉の隙間はピンホールとして働き、地面に太陽の像を結ぶ。高い梢の隙間は大きく柔らかい円になり、低い枝の葉は形のわかる鋭い影になる。 \
The body text gives fixed reference points: it must stay readable under the shade, and the penumbrae must not band. \
手が止まると現れ、手を動かすと引く。風が止むと海が凪ぐ、が名前の由来である。
"""

for (name, background, foreground) in [("light", NSColor.white, NSColor(white: 0.12, alpha: 1)),
                                        ("dark", NSColor(white: 0.12, alpha: 1), NSColor(white: 0.88, alpha: 1))] {
    // A fixed pixel size and sRGB, whatever display this runs on.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        .retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    background.setFill()
    NSRect(origin: .zero, size: size).fill()
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 10
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 30), .foregroundColor: foreground, .paragraphStyle: style,
    ]
    let text = Array(repeating: paragraph, count: 6).joined(separator: "\n\n")
    (text as NSString).draw(in: NSRect(x: 160, y: 80, width: size.width - 320, height: size.height - 160),
                            withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Fixtures/reading-\(name).png"))
    print("Fixtures/reading-\(name).png")
}
