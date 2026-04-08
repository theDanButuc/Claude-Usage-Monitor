#!/usr/bin/swift
// Generates AppIcon.iconset + AppIcon.icns
// Run: swift scripts/make_icon.swift
import AppKit

func makeFrame(size: Int) -> NSImage {
    let s = CGFloat(size)

    return NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        // ── Rounded-rect clip ─────────────────────────────────────────────
        let corner = s * 0.22
        let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                            cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.addPath(bgPath)
        ctx.clip()

        // ── Background gradient: bright forest green → deep pine ──────────
        let cs = CGColorSpaceCreateDeviceRGB()
        let grad = CGGradient(
            colorsSpace: cs,
            colors: [
                CGColor(red: 0.13, green: 0.62, blue: 0.30, alpha: 1.0),  // top-left
                CGColor(red: 0.02, green: 0.27, blue: 0.12, alpha: 1.0),  // bottom-right
            ] as CFArray,
            locations: [0.0, 1.0]
        )!
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: 0,   y: s),
            end:   CGPoint(x: s,   y: 0),
            options: [])

        // ── Subtle inner highlight ring ───────────────────────────────────
        let inset = s * 0.018
        let ringPath = CGPath(
            roundedRect: CGRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2),
            cornerWidth: corner - inset, cornerHeight: corner - inset, transform: nil)
        ctx.addPath(ringPath)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.setLineWidth(s * 0.022)
        ctx.strokePath()

        // ── Soft radial glow behind the tree ─────────────────────────────
        let glowGrad = CGGradient(
            colorsSpace: cs,
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.00),
            ] as CFArray,
            locations: [0.0, 1.0]
        )!
        ctx.drawRadialGradient(glowGrad,
            startCenter: CGPoint(x: s/2, y: s*0.48), startRadius: 0,
            endCenter:   CGPoint(x: s/2, y: s*0.48), endRadius: s * 0.45,
            options: [])

        // ── Tree SF Symbol (white) ────────────────────────────────────────
        let ptSize = s * 0.54
        let symCfg = NSImage.SymbolConfiguration(pointSize: ptSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

        if let sym = NSImage(systemSymbolName: "tree.fill",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(symCfg) {
            let tw = sym.size.width
            let th = sym.size.height
            sym.draw(in: NSRect(x: (s - tw) / 2,
                                y: (s - th) / 2 - s * 0.02,
                                width: tw, height: th))
        }

        return true
    }
}

// ── Build .iconset ─────────────────────────────────────────────────────────
let iconsetDir = "/tmp/AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: iconsetDir,
                                          withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x",1024),
]

for (name, size) in specs {
    let img = makeFrame(size: size)
    guard let tiff = img.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff),
          let png  = rep.representation(using: .png, properties: [:])
    else { print("⚠️  Failed \(name)"); continue }
    let path = "\(iconsetDir)/\(name).png"
    try! png.write(to: URL(fileURLWithPath: path))
    print("  ✓ \(name).png  (\(size)px)")
}

// ── iconutil → .icns ──────────────────────────────────────────────────────
let icnsPath = "/tmp/AppIcon.icns"
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments  = ["-c", "icns", "-o", icnsPath, iconsetDir]
task.launch(); task.waitUntilExit()

if task.terminationStatus == 0 {
    print("\n✅  AppIcon.icns → \(icnsPath)")
} else {
    print("❌  iconutil failed"); exit(1)
}
