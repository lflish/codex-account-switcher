// Original three-quota slots + return track. Shared geometry for app and tray.
// Run from repository root: swift scripts/generate-original-icons.swift
import AppKit
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func glyph(_ color: NSColor) {
    color.setFill()
    for (x, height) in [(3.0,4.0),(7.0,6.0),(11.0,8.0)] {
        NSBezierPath(roundedRect:NSRect(x:x,y:6,width:2.5,height:height),xRadius:1.25,yRadius:1.25).fill()
    }
    color.setStroke()
    let p = NSBezierPath()
    p.lineWidth = 1.5; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to:NSPoint(x:13,y:4.5)); p.line(to:NSPoint(x:13,y:3.75))
    p.curve(to:NSPoint(x:11.5,y:2.5),controlPoint1:NSPoint(x:13,y:2.75),controlPoint2:NSPoint(x:12.25,y:2.5))
    p.line(to:NSPoint(x:2.5,y:2.5)); p.stroke()
    let arrow = NSBezierPath(); arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to:NSPoint(x:4,y:4)); arrow.line(to:NSPoint(x:2.5,y:2.5)); arrow.line(to:NSPoint(x:4,y:1)); arrow.stroke()
}
func png(_ path: String, pixels: Int, app: Bool, white: Bool = false) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let transform = NSAffineTransform()
    if app {
        transform.scale(by:CGFloat(pixels)/1024); transform.concat()
        NSColor(calibratedRed:0.22,green:0.25,blue:0.75,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:96,y:96,width:832,height:832),xRadius:186,yRadius:186).fill()
        let t = NSAffineTransform(); t.translateX(by:144,yBy:168); t.scale(by:46); t.concat()
        glyph(.white)
    } else { transform.scale(by:CGFloat(pixels)/16); transform.concat(); glyph(white ? .white : .black) }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(path))
}
try png("assets/app-icon-1024.png",pixels:1024,app:true)
try png("assets/account-switcher-logo.png",pixels:256,app:false)
try png("assets/account-switcher-logo-white.png",pixels:256,app:false,white:true)
try png("Sources/CodexAccountSwitcher/Resources/account-switcher-logo.png",pixels:256,app:false)
let iconset = "assets/OriginalAppIcon.iconset"
try FileManager.default.createDirectory(at:root.appendingPathComponent(iconset),withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    try png("\(iconset)/icon_\(size)x\(size).png",pixels:size,app:true)
    try png("\(iconset)/icon_\(size)x\(size)@2x.png",pixels:size*2,app:true)
}
let packager = Process()
packager.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
packager.arguments = ["-c", "icns", iconset, "-o", "assets/AppIcon.icns"]
try packager.run(); packager.waitUntilExit()
guard packager.terminationStatus == 0 else { fatalError("iconutil failed; PNGs were rendered but ICNS was not updated") }
try FileManager.default.removeItem(at:root.appendingPathComponent(iconset))
print("Rendered original geometric resources and packaged standard multi-size AppIcon.icns")
