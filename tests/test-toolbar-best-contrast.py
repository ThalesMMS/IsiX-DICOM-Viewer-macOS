#!/usr/bin/env python3
"""#892: the Best toolbar icon stays visible on light and dark toolbars and palettes."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


mpr = sources.source_text('MPRController')
require('ToolbarImage.appearanceAdaptive(named: "BestRendering.pdf")' in mpr,
        'MPRController does not load the Best artwork through the appearance-adaptive helper')
require('NSImage(named: "BestRendering.pdf")' not in mpr,
        'MPRController still loads the black Best artwork as is')
vr = sources.source_text('VRController')
require('[HorosToolbarImage appearanceAdaptiveImageNamed: CaptureToolbarItemIdentifier]' in vr,
        'VRController does not load the Best artwork through the appearance-adaptive helper')

code = r'''
import AppKit

// Mean luminance of the drawn icon (alpha-weighted) and its opaque bounding box.
func measure(_ image: NSImage, _ appearance: NSAppearance.Name) -> (lum: Double, cover: Double, box: NSSize) {
 let side = 64
 let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
 rep.size = NSSize(width: 32, height: 32)
 NSGraphicsContext.saveGraphicsState()
 NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
 NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
  image.draw(in: NSRect(origin: .zero, size: image.size))
 }
 NSGraphicsContext.restoreGraphicsState()
 var lum = 0.0, alpha = 0.0
 var minX = side, minY = side, maxX = -1, maxY = -1
 for y in 0..<side { for x in 0..<side {
  let c = rep.colorAt(x: x, y: y)!
  let a = Double(c.alphaComponent)
  guard a > 0.05 else { continue }
  // colorAt returns premultiplied-free components for a deviceRGB rep.
  lum += a * Double(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
  alpha += a
  minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
 } }
 return (alpha > 0 ? lum / alpha : 0, alpha / Double(side * side),
         NSSize(width: CGFloat(maxX - minX + 1) / 2, height: CGFloat(maxY - minY + 1) / 2))
}

// The image as a toolbar button shows it, inside a window of the given
// appearance, over a mid-gray background: the share of bright and of dark pixels.
func buttonPixels(_ button: NSButton, _ window: NSWindow, _ appearance: NSAppearance.Name) -> (bright: Int, dark: Int) {
 window.appearance = NSAppearance(named: appearance)
 let view = window.contentView!
 view.needsDisplay = true
 view.displayIfNeeded()
 let rep = view.bitmapImageRepForCachingDisplay(in: button.frame)!
 view.cacheDisplay(in: button.frame, to: rep)
 var bright = 0, dark = 0
 for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
  let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
  let l = Double(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
  if l > 0.85 { bright += 1 } else if l < 0.15 { dark += 1 }
 } }
 return (bright, dark)
}

@main struct Test {
 static func main() {
  setvbuf(stdout, nil, _IONBF, 0)
  _ = NSApplication.shared
  let best = NSImage(contentsOfFile: CommandLine.arguments[1])!
  let reset = NSImage(contentsOfFile: CommandLine.arguments[2])!

  // Before #892: the shipped artwork is black, whatever the appearance.
  let before = measure(ToolbarImage.fitting(best)!, .darkAqua)
  precondition(before.lum < 0.3, "the original Best artwork really is dark (\(before.lum))")

  let adaptive = ToolbarImage.appearanceAdaptive(best)!
  precondition(best.size == NSSize(width: 737, height: 709), "shared instance not resized")
  precondition(max(adaptive.size.width, adaptive.size.height) <= ToolbarImage.defaultSize)
  precondition(abs(adaptive.size.width / adaptive.size.height - 737.0 / 709.0) < 0.001, "aspect ratio kept")
  let item = NSToolbarItem(itemIdentifier: .init("BestRendering.pdf"))
  item.image = adaptive
  ToolbarImage.normalize(for: item)
  precondition(item.image === adaptive, "the toolbar policy keeps the adaptive image")

  let dark = measure(adaptive, .darkAqua)
  let light = measure(adaptive, .aqua)
  let resetDark = measure(ToolbarImage.fitting(reset)!, .darkAqua)
  precondition(dark.lum > 0.9, "Best is light on a dark toolbar (\(dark.lum))")
  precondition(light.lum < 0.3, "Best keeps its dark artwork on a light toolbar (\(light.lum))")
  precondition(abs(dark.cover - light.cover) < 0.02, "same silhouette in both modes")
  precondition(dark.box.width >= resetDark.box.width * 0.95 && dark.box.height >= resetDark.box.height * 0.9,
               "Best fills the toolbar box like Reset (\(dark.box) vs \(resetDark.box))")
  let hc = measure(adaptive, .accessibilityHighContrastDarkAqua)
  precondition(hc.lum > 0.9, "increased-contrast dark appearance counts as dark")

  // A button that already drew the icon follows a later appearance change,
  // in both directions: the drawing handler is not a stale cache.
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                        styleMask: [.borderless], backing: .buffered, defer: false)
  let content = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
  content.wantsLayer = true
  content.layer?.backgroundColor = NSColor(deviceWhite: 0.5, alpha: 1).cgColor
  window.contentView = content
  let button = NSButton(frame: NSRect(x: 16, y: 16, width: 32, height: 32))
  button.isBordered = false
  button.imageScaling = .scaleProportionallyDown
  button.image = adaptive
  content.addSubview(button)
  let b1 = buttonPixels(button, window, .darkAqua)
  let b2 = buttonPixels(button, window, .aqua)
  let b3 = buttonPixels(button, window, .darkAqua)
  precondition(b1.bright > 100 && b1.dark < b1.bright / 10, "button draws the light icon in dark mode (\(b1))")
  precondition(b2.dark > 100 && b2.bright < b2.dark / 10, "button draws the dark icon in light mode (\(b2))")
  precondition(b3.bright == b1.bright && b3.dark == b1.dark, "back in dark mode, the light icon again (\(b3))")

  print("PASS: Best artwork light on dark (\(String(format: "%.2f", dark.lum))), dark on light (\(String(format: "%.2f", light.lum))), same size as Reset, follows appearance changes in a button")
 }
}
'''

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)

with tempfile.TemporaryDirectory(prefix='horos-toolbar-best-') as folder:
    p = Path(folder)
    (p / 'test.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(root / 'Horos/Sources/ToolbarImage.swift'), str(p / 'test.swift'),
                    '-framework', 'AppKit', '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test'), str(root / 'Horos/Resources/Icons/BestRendering.pdf'),
                    str(root / 'Horos/Resources/Icons/Reset.pdf')], check=True)
