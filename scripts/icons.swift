// 用系统SVG解码器生成不透明的iOS图标。
import AppKit
import ImageIO

let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("src/app/icons")
let vector = NSImage(contentsOf: folder.appendingPathComponent("AppIcon.svg"))!
for (side, name) in [(512, "AppIcon512.png"), (120, "AppIcon60x60@2x.png"), (180, "AppIcon60x60@3x.png"),
                     (152, "AppIcon76x76@2x~ipad.png"), (167, "AppIcon83.5x83.5@2x~ipad.png")] {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    vector.draw(in: NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination), "Unable to save \(name)")
    print("Generated \(name): \(side)px")
}
