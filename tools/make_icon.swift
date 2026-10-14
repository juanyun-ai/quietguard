// Vector redrawing of the shield / pulse concept for small macOS app icons.
// This is an original native rendering, not a claim that the earlier PNG was imported.
import AppKit
import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let iconset = output.appendingPathComponent("QuietGuard.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1) }
let teal = rgb(28, 206, 178), mint = rgb(162, 255, 211)
func shield() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 512,y: 184))
    p.curve(to: NSPoint(x: 764,y: 286), controlPoint1: NSPoint(x: 595,y: 234), controlPoint2: NSPoint(x: 682,y: 261))
    p.curve(to: NSPoint(x: 790,y: 328), controlPoint1: NSPoint(x: 784,y: 292), controlPoint2: NSPoint(x: 790,y: 308))
    p.line(to: NSPoint(x: 790,y: 495))
    p.curve(to: NSPoint(x: 512,y: 840), controlPoint1: NSPoint(x: 790,y: 656), controlPoint2: NSPoint(x: 684,y: 775))
    p.curve(to: NSPoint(x: 234,y: 495), controlPoint1: NSPoint(x: 340,y: 775), controlPoint2: NSPoint(x: 234,y: 656))
    p.line(to: NSPoint(x: 234,y: 328))
    p.curve(to: NSPoint(x: 260,y: 286), controlPoint1: NSPoint(x: 234,y: 308), controlPoint2: NSPoint(x: 240,y: 292))
    p.curve(to: NSPoint(x: 512,y: 184), controlPoint1: NSPoint(x: 342,y: 261), controlPoint2: NSPoint(x: 429,y: 234))
    p.close(); return p
}
func pulse() -> NSBezierPath {
    let p = NSBezierPath(); p.move(to: NSPoint(x: 303,y: 530)); p.line(to: NSPoint(x: 365,y: 530))
    p.curve(to: NSPoint(x: 420,y: 499), controlPoint1: NSPoint(x: 394,y: 530), controlPoint2: NSPoint(x: 401,y: 483))
    p.curve(to: NSPoint(x: 462,y: 584), controlPoint1: NSPoint(x: 440,y: 515), controlPoint2: NSPoint(x: 444,y: 613))
    p.line(to: NSPoint(x: 513,y: 398))
    p.curve(to: NSPoint(x: 535,y: 398), controlPoint1: NSPoint(x: 519,y: 373), controlPoint2: NSPoint(x: 529,y: 373))
    p.line(to: NSPoint(x: 585,y: 622))
    p.curve(to: NSPoint(x: 605,y: 622), controlPoint1: NSPoint(x: 590,y: 645), controlPoint2: NSPoint(x: 599,y: 642))
    p.line(to: NSPoint(x: 631,y: 550))
    p.curve(to: NSPoint(x: 663,y: 531), controlPoint1: NSPoint(x: 638,y: 529), controlPoint2: NSPoint(x: 649,y: 525))
    p.curve(to: NSPoint(x: 713,y: 539), controlPoint1: NSPoint(x: 682,y: 537), controlPoint2: NSPoint(x: 690,y: 539))
    return p
}
func render(_ size: Int, menu: Bool = false) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let c = context.cgContext
    c.translateBy(x: 0, y: CGFloat(size)); c.scaleBy(x: CGFloat(size)/1024, y: -CGFloat(size)/1024)
    if menu {
        let trans = NSAffineTransform(); trans.translateX(by: -165, yBy: -175); trans.scale(by: 1.31); trans.concat()
        NSColor.black.setStroke(); let s = shield(); s.lineWidth = 55; s.lineJoinStyle = .round; s.stroke()
        let p = pulse(); p.lineWidth = 60; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
    } else {
        let base = NSBezierPath(roundedRect: NSRect(x: 54,y: 54,width: 916,height: 916), xRadius: 205,yRadius: 205)
        NSGradient(starting: rgb(37,58,65), ending: rgb(11,21,29))!.draw(in: base, angle: 90)
        rgb(70,91,96).withAlphaComponent(0.55).setStroke(); base.lineWidth = 3; base.stroke()
        let s = shield(); NSGradient(starting: rgb(30,55,59), ending: rgb(13,28,34))!.draw(in: s, angle: 90)
        teal.setStroke(); s.lineWidth = 23; s.lineJoinStyle = .round; s.stroke()
        let p = pulse(); mint.setStroke(); p.lineWidth = 30; p.lineJoinStyle = .round; p.lineCapStyle = .round; p.stroke()
        let star = NSBezierPath(); star.move(to: NSPoint(x: 659,y: 355))
        star.curve(to: NSPoint(x: 693,y: 393), controlPoint1: NSPoint(x: 662,y: 381), controlPoint2: NSPoint(x: 670,y: 390))
        star.curve(to: NSPoint(x: 659,y: 431), controlPoint1: NSPoint(x: 670,y: 397), controlPoint2: NSPoint(x: 662,y: 405))
        star.curve(to: NSPoint(x: 625,y: 393), controlPoint1: NSPoint(x: 655,y: 405), controlPoint2: NSPoint(x: 647,y: 397))
        star.curve(to: NSPoint(x: 659,y: 355), controlPoint1: NSPoint(x: 647,y: 390), controlPoint2: NSPoint(x: 655,y: 381))
        star.close(); mint.setFill(); star.fill()
        // Three restrained circuit nodes, omitted by the separate menu symbol.
        teal.setStroke()
        for (x,y,bottom) in [(457.0,665.0,711.0),(512.0,636.0,755.0),(555.0,697.0,740.0)] {
            let line=NSBezierPath(); line.move(to:NSPoint(x:x,y:y+10)); line.line(to:NSPoint(x:x,y:bottom)); line.lineWidth=9; line.lineCapStyle = .round; line.stroke()
            let dot=NSBezierPath(ovalIn:NSRect(x:x-10,y:y-10,width:20,height:20)); dot.lineWidth=7; dot.stroke()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16,32,128,256,512] {
    for scale in [1,2] {
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        try render(base*scale).write(to: iconset.appendingPathComponent(name))
    }
}
try render(1024).write(to: output.appendingPathComponent("QuietGuard-AppIcon-1024.png"))
try render(128).write(to: output.appendingPathComponent("QuietGuardMark.png"))
try render(18,menu:true).write(to: output.appendingPathComponent("QuietGuardMenu.png"))
try render(36,menu:true).write(to: output.appendingPathComponent("QuietGuardMenu@2x.png"))
print("Rendered icon master, ten ICNS representations, sidebar image, and 1x/2x template menu icons.")
