#!/usr/bin/env python3
"""The portal's series preview keeps the grey levels of the series' window.

`/image.png` and `/image.jpg` draw the image number, and a play mark for a
movie, over the preview. They did it with an image made by a drawing handler,
which is rendered in the colour space of the screen: the greys came out colour
matched from generic grey to sRGB, 102 as 121 and 153 as 169. The overlay is
now drawn into a bitmap of the preview's own colour space.

The production composition is executed on a grey and on a colour image; the
drawing-handler path is measured beside it as the discriminating case.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


MAIN = r'''
import AppKit
_ = NSApplication.shared
func grey() -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 1,
                               hasAlpha: false, isPlanar: false, colorSpaceName: .calibratedWhite, bytesPerRow: 64, bitsPerPixel: 8)!
    for y in 0..<64 { for x in 0..<64 { rep.bitmapData![y * 64 + x] = x < 32 ? 102 : 153 } }
    let image = NSImage(); image.addRepresentation(rep); return image
}
func colour() -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 3,
                               hasAlpha: false, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 192, bitsPerPixel: 24)!
    for i in 0..<(64 * 64) { rep.bitmapData![i * 3] = 200; rep.bitmapData![i * 3 + 1] = 50; rep.bitmapData![i * 3 + 2] = 25 }
    let image = NSImage(); image.addRepresentation(rep); return image
}
func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
    var value = [Int](repeating: 0, count: 5)
    rep.getPixel(&value, atX: x, y: y)
    return Array(value[0..<rep.samplesPerPixel])
}
func decoded(_ data: Data?) -> NSBitmapImageRep { NSBitmapImageRep(data: data!)! }
var out: [String: Any] = [:]

let source = grey()
var bounds = NSRect.zero
let composed = source.horosBitmapInOwnColorSpace { b in
    bounds = b
    ("1 / 3" as NSString).draw(at: NSPoint(x: 1, y: b.height - 16), withAttributes: [.foregroundColor: NSColor.white])
}!
out["bounds"] = [bounds.width, bounds.height]
out["size"] = [composed.pixelsWide, composed.pixelsHigh, composed.samplesPerPixel]
out["left"] = pixel(composed, 8, 40)
out["right"] = pixel(composed, 48, 40)
// The number is at the top left: some pixel there is lighter than the image under it.
var lightest = 0
for y in 0..<16 { for x in 0..<30 { lightest = max(lightest, pixel(composed, x, y)[0]) } }
out["textLightest"] = lightest
out["png"] = [pixel(decoded(composed.representation(using: .png, properties: [:])), 8, 40)[0],
              pixel(decoded(composed.representation(using: .png, properties: [:])), 48, 40)[0]]
out["jpeg"] = [pixel(decoded(composed.representation(using: .jpeg, properties: [.compressionFactor: 0.8])), 8, 40)[0],
               pixel(decoded(composed.representation(using: .jpeg, properties: [.compressionFactor: 0.8])), 48, 40)[0]]
out["pngSamples"] = decoded(composed.representation(using: .png, properties: [:])).samplesPerPixel
// Without an overlay the pixels are the source's.
let plain = source.horosBitmapInOwnColorSpace(overlay: nil)!
out["plain"] = [pixel(plain, 8, 8)[0], pixel(plain, 48, 8)[0]]
// A colour image keeps its components.
let rgb = colour().horosBitmapInOwnColorSpace { _ in }!
out["rgb"] = Array(pixel(rgb, 20, 20).prefix(3))
// An image whose size in points is not its size in pixels: the overlay is laid out in points, the pixels are kept.
let scaled = grey(); scaled.size = NSSize(width: 32, height: 32)
var scaledBounds = NSRect.zero
let scaledOut = scaled.horosBitmapInOwnColorSpace { b in scaledBounds = b }!
out["scaled"] = [scaledOut.pixelsWide, scaledOut.pixelsHigh, Int(scaledBounds.width), Int(scaledBounds.height), pixel(scaledOut, 8, 40)[0], pixel(scaledOut, 48, 40)[0]]
// Nothing to draw gives nothing.
out["empty"] = NSImage(size: .zero).horosBitmapInOwnColorSpace(overlay: nil) == nil
// The discriminating case: what the drawing handler gave.
let handler = NSImage(size: source.size, flipped: false) { b in source.draw(in: b, from: .zero, operation: .copy, fraction: 1); return true }
if let rep = handler.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) {
    out["handler"] = [pixel(rep, 8 * rep.pixelsWide / 64, rep.pixelsHigh / 2)[0], pixel(rep, 48 * rep.pixelsWide / 64, rep.pixelsHigh / 2)[0]]
    out["handlerSpace"] = rep.colorSpace.localizedName ?? ""
}
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
'''

with tempfile.TemporaryDirectory(prefix='horos-preview-grey-') as scratch:
    work = Path(scratch)
    (work / 'main.swift').write_text(MAIN)
    built = subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/OwnColorSpaceBitmap.swift'), str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True, timeout=300)
    require(built.returncode == 0, 'the composition does not compile: ' + built.stderr[-600:])
    if built.returncode == 0:
        ran = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=60)
        require(ran.returncode == 0, 'the composition failed: ' + ran.stderr[-400:])
        out = json.loads(ran.stdout) if ran.returncode == 0 else {}
        require(out.get('left') == [102] and out.get('right') == [153], 'the composed preview moved the greys: %s %s' % (out.get('left'), out.get('right')))
        require(out.get('size') == [64, 64, 1] and out.get('bounds') == [64, 64], 'the composed preview is %s over %s' % (out.get('size'), out.get('bounds')))
        require(out.get('textLightest', 0) > 200, 'the image number was not drawn (lightest pixel %s)' % out.get('textLightest'))
        require(out.get('png') == [102, 153] and out.get('pngSamples') == 1, 'the PNG of the preview has %s' % out.get('png'))
        require(all(abs(a - b) <= 3 for a, b in zip(out.get('jpeg', [0, 0]), [102, 153])), 'the JPEG of the preview has %s' % out.get('jpeg'))
        require(out.get('plain') == [102, 153], 'without an overlay the greys are %s' % out.get('plain'))
        require(out.get('rgb') == [200, 50, 25], 'a colour preview has %s' % out.get('rgb'))
        require(out.get('scaled') == [64, 64, 32, 32, 102, 153], 'an image scaled in points gives %s' % out.get('scaled'))
        require(out.get('empty') is True, 'an empty image gives a bitmap')
        if out.get('handler'):
            print('drawing handler, for comparison: %s in %s' % (out['handler'], out.get('handlerSpace')))

portal = (root / 'Horos/Sources/WebPortalConnection+Data.swift').read_text()
require(portal.count('.horosBitmapInOwnColorSpace {') == 2, 'the preview and the movie frames are not both composed in their own colour space')
require('NSImage(size: source.size, flipped: false)' not in portal, 'a portal image is still composed by a drawing handler')
require('let imageRep = composed ?? image?.tiffRepresentation' in portal, 'the encoded preview is not the composed bitmap')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the portal preview is composed in its own colour space, and its greys are those of the window')
