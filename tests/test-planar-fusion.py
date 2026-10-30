#!/usr/bin/env python3
"""The planar Metal renderer draws a fused series over the image.

A 2D viewer with a fused series (`view.blendingView`, PET over CT) used to be
refused by the planar snapshot, so it drew with «Original renderer (Metal
paused)». The host draws the image, then `[blendingView drawRectIn:...]` with
GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA: the fused series through its scalar CLUT
program, with its own window and the table `loadTextureIn:blending:YES` builds -
the colours the PET CLUT mode gives, its channel factors, and its alpha table -
and with its own origin, scale, rotation, flips and pixel ratio in the frame it
is handed, the image's. Only in the key view, and only while the two series'
locations are in sync. Under a fusion the image itself is added to the clear
colour (GL_ONE, GL_ONE), which is white under the B/W Inverse CLUT.

Checked here:

* the sources: the snapshot no longer refuses a fusion; it attaches the fused
  series under the host's conditions, with that table and that mapping, and a
  white CLUT for the image under a white clear colour; a colour fused series is
  tabled as loadTextureIn:blending:YES tables it, with the fusion's alpha table;
  DCMView draws the fused series itself only when Metal did not;
* the mapping: `horosPixelAt:drawnIn:` as DCMView+PlanarSnapshot.swift writes
  it, over IsiXImaging's PlanarPresentation, and
  the view's `ConvertFromNSView2GL:` and `ConvertFromUpLeftView2GL:` as
  DCMView+WindowLevel+Coordinates.swift writes them, compiled as they are over
  a double of DCMView with the same horos_* state: for random frames, backing
  scales, zooms, rotations, origins, flips and pixel ratios, the mirror for a
  fused view equals, bit for bit, the host's `ConvertFromUpLeftView2GL:` on
  that view with the image's drawing frame, the frame drawRectIn: draws it in;
* the composition, on both backends, at texel centres of both layers: outside
  the fused image the image's CLUT colour, opaque; over it the fused CLUT colour
  blended source-alpha over the image's, with the fused table's alpha column,
  within one level of the exact value (the blend's own rounding), for a
  float, a flipped and an opacity-table fused series; the Metal 4 pilot equal
  to Metal 3 byte for byte;
* the fusion factor: a changed alpha column uploads only the fused table and
  keeps both images, and a changed image window keeps the fused textures;
  alpha 0 leaves the image, alpha 255 the fused colours;
* a colour fused series: its ARGB bytes through the alpha, red, green and
  blue tables, blended source-alpha with the tabled alpha byte, the Metal 4 pilot
  identical; one with a fusion of its own is not drawn.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import random
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


# The original renderer, the reference these checks port, has left the view;
# it is read from the last revision that retains it, the parent of the commit
# that presented the viewer with Metal and removed its tiles.
import history_reference
ORIGINAL_RENDERER = history_reference.before_text_removed('Horos/Sources/DCMView.m', 'static void DrawGLImageTile (')
if ORIGINAL_RENDERER is None:
    print('skipped: needs the history back to the original renderer; a shallow clone does not carry it', file=sys.stderr)
    sys.exit(2)
ORIGINAL_SOURCES = ('Horos/Sources/DCMView.m', 'Horos/Sources/LegacyScalarCLUT.swift')


def read(path):
    if revision or path in ORIGINAL_SOURCES:
        return subprocess.check_output(['git', '-C', str(root), 'show', (revision or ORIGINAL_RENDERER) + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


failures = []
# The snapshot and the mirror are Swift (DCMView+PlanarSnapshot.swift), the
# mirror's arithmetic and the tables IsiXImaging's PlanarPresentation; an
# earlier revision (the negative control) has the Objective-C bridge.
swift_bridge = revision is None or subprocess.run(['git', '-C', str(root), 'cat-file', '-e',
                                                   revision + ':Horos/Sources/DCMView+PlanarSnapshot.swift'],
                                                  capture_output=True).returncode == 0
if not swift_bridge:
    print('FAIL: %s has the Objective-C planar bridge, which this test no longer reads' % revision)
    raise SystemExit(1)
bridge = read('Horos/Sources/DCMView+PlanarSnapshot.swift')
presentation = read('Modules/IsiXImaging/Sources/ViewDrawing/PlanarPresentation.swift')
view_source = read('Horos/Sources/DCMView.m')
snapshot = bridge[bridge.index('private func horosPlanarSnapshot(drawnIn host: DCMView)'):]
refusal = snapshot[snapshot.index('guard let pix = view.curDCM'):snapshot.index('let bounds = host.bounds')]
if 'blending' in refusal:
    failures.append('the planar snapshot still refuses a fused series')
if 'isRGB' in refusal:
    failures.append('the snapshot still refuses a colour fused series')
if 'return isRGB && !packed && (fused || colorTransfer || redFactor != 1.0' not in presentation \
        or 'table[i] = alpha.map { $0[i] } ?? 0xFF' not in presentation or 'alpha: fused ? alpha : nil' not in snapshot:
    failures.append('a colour fused series is not tabled with the fusion\'s alpha table, as loadTextureIn:blending:YES tables it')
renderer_source = read('Horos/Sources/PlanarMetalRenderer.swift')
if 'if(p.window.z > 1.5) return float4(sampled.gba,sampled.r);' not in renderer_source:
    failures.append('the colour layer does not carry its tabled alpha byte to the blend')
# The key view of a 2D viewer, and every orthogonal view, as the original
# renderer blended them.
attach = re.search(r'let hasFusedSeries = !fused && view\.blending != nil.*?'
                   r'if PlanarPresentation\.drawsFusion\(hasFusedSeries: hasFusedSeries, locationsInSync: locationsInSync,\s*'
                   r'isKeyView: view\.isKeyView, is2DViewer: view\.is2DViewer\(\)\),\s*'
                   r'let fusedView = view\.blending \{\s*let layer = fusedView\.horosPlanarSnapshot\(drawnIn: view\)', snapshot, re.S) \
    and 'let locationsInSync = !horos_syncOnLocationImpossible' in snapshot \
    and 'return hasFusedSeries && locationsInSync && (isKeyView || !is2DViewer)' in presentation
if not attach:
    failures.append('the fused series is not attached where drawRect: draws it: key view or orthogonal view, locations in sync')
if not re.search(r'if PlanarPresentation\.whitensImageUnderFusion\(hasFusedSeries: hasFusedSeries, locationsInSync: locationsInSync,\s*'
                 r'whiteBackground: view\.whiteBackground\) \{\s*clut = \[UInt8\]\(repeating: 255, count: clut\.count\)', snapshot) \
        or 'return hasFusedSeries && locationsInSync && whiteBackground' not in presentation:
    failures.append('the image is not drawn white under a fusion with a white clear colour')
table = re.search(r'host\.blendingColorTables\(&unused1, &r, &g, &b\)\s*view\.colorTables\(&alpha, &unused1, &unused2, &unused3\)'
                  r'.*?PlanarPresentation\.scalarTable\(red: r, green: g, blue: b, alpha: alpha,', snapshot, re.S) and \
    re.search(r'for i in 0\.\.<256 \{\s*'
              r'table\[4 \* i\] = UInt8\(fminf\(255, fmaxf\(0, Float\(red\[i\]\) \* redFactor\)\)\)\s*'
              r'table\[4 \* i \+ 1\] = UInt8\(fminf\(255, fmaxf\(0, Float\(green\[i\]\) \* greenFactor\)\)\)\s*'
              r'table\[4 \* i \+ 2\] = UInt8\(fminf\(255, fmaxf\(0, Float\(blue\[i\]\) \* blueFactor\)\)\)\s*'
              r'table\[4 \* i \+ 3\] = alpha\.map \{ \$0\[i\] \} \?\? 255', presentation)
host_table = re.search(r'rgba\[4\*i\] = fminf\(255, fmaxf\(0, rT\[i\] \* redFactor\)\);\s*'
                       r'rgba\[4\*i\+1\] = fminf\(255, fmaxf\(0, gT\[i\] \* greenFactor\)\);\s*'
                       r'rgba\[4\*i\+2\] = fminf\(255, fmaxf\(0, bT\[i\] \* blueFactor\)\);\s*'
                       r'rgba\[4\*i\+3\] = currentAlphaTable\[i\];', view_source)
if not table or not host_table:
    failures.append('the fused table is not the one loadTextureIn:blending:YES builds')
for key, value in [('screenToPixel', 'view.horosPixel(at: NSPoint(x: bounds.minX, y: bounds.maxY), drawnIn: host)'),
                   ('viewSize', 'let bounds = host.bounds')]:
    if value not in snapshot:
        failures.append('the fused series\' %s is not taken in the image\'s view' % key)
draw = view_source[view_source.index('if( blendingView != nil && syncOnLocationImpossible == NO && noBlending == NO )'):]
draw = draw[:draw.index('glDisable( GL_BLEND);')]
if not re.search(r'if\( planarDrawn == NO\)\s*\{\s*if\( blendingTextureName\)\s*\[blendingView drawRectIn:', draw):
    failures.append('DCMView draws the fused series again over the Metal frame')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

def matched(text, at):
    """The text from `at` to the brace closing the first block after it."""
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    raise ValueError('unbalanced braces')


# The mirror, as DCMView+PlanarSnapshot.swift writes it over IsiXImaging's
# PlanarPresentation, and the view's conversions and its degree constant, as
# the Swift class writes them.
mirror = '    @objc(horosPixelAt:drawnIn:)\n' + \
    matched(bridge, bridge.index('    func horosPixel(at point: NSPoint, drawnIn host: DCMView) -> NSPoint {'))
coordinates = read('Horos/Sources/DCMView+WindowLevel+Coordinates.swift')
conversions = [matched(coordinates, coordinates.index('    @objc(%s)' % name)) for name in ('ConvertFromNSView2GL:', 'ConvertFromUpLeftView2GL:')]
settings = read('Horos/Sources/DCMViewSettings.swift')
degrees = settings[settings.index('    @objc static var horos_static_deg2rad'):]
degrees = degrees[:degrees.index('\n') + 1]

# The state the mirror and the conversions read, under the view's names.
BRIDGE = r"""
#import <AppKit/AppKit.h>

@interface DCMPix : NSObject
@property long pwidth, pheight;
@property double pixelRatio;
@end

@interface DCMView : NSView
@property NSRect horos_drawingFrameRect;
@property float horos_scaleValue, horos_rotation;
@property NSPoint horos_origin;
@property BOOL horos_xFlipped, horos_yFlipped;
@property NSRect drawingFrameRect;
@property(strong) DCMPix *curDCM;
@end
"""

EXTENSION = 'import AppKit\n\nextension DCMView {\n' + degrees + '\n' + '\n\n'.join(conversions) + '\n\n' + mirror + '\n}\n'

PROBE = r"""
#import "bridge.h"
#import "Horos-Swift.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@implementation DCMPix
@end

@implementation DCMView
- (NSRect) drawingFrameRect { return self.horos_drawingFrameRect; }
- (void) setDrawingFrameRect:(NSRect) rect { self.horos_drawingFrameRect = rect; }
@end

@interface ProbeView : DCMView
{ @public CGFloat probeBacking; }
@end
@implementation ProbeView
- (NSPoint) convertPointToBacking:(NSPoint) a { return NSMakePoint( a.x * probeBacking, a.y * probeBacking); }
- (void) probeFrame:(NSRect) frame scale:(float) s rotation:(float) r origin:(NSPoint) o flipX:(BOOL) fx flipY:(BOOL) fy
{
    self.horos_drawingFrameRect = frame; self.horos_scaleValue = s; self.horos_rotation = r; self.horos_origin = o;
    self.horos_xFlipped = fx; self.horos_yFlipped = fy;
}
@end

static double uniform( double lo, double hi) { return lo + ( hi - lo) * ( rand() / (double) RAND_MAX); }

int main( int argc, char **argv) { @autoreleasepool {
    unsigned seed = (unsigned) strtoul( argv[ 1], NULL, 10);
    srand( seed);
    long compared = 0, differing = 0, identity = 0;
    for( int trial = 0; trial < 4000; trial++) { @autoreleasepool {
        ProbeView *host = [[ProbeView alloc] initWithFrame: NSZeroRect], *fused = [[ProbeView alloc] initWithFrame: NSZeroRect];
        host->probeBacking = fused->probeBacking = trial % 2 ? 2.0 : 1.0;
        NSRect frame = NSMakeRect( 0, 0, floor( uniform( 64, 2400)), floor( uniform( 64, 1600)));
        host.curDCM = [[DCMPix alloc] init];
        host.curDCM.pwidth = 512; host.curDCM.pheight = 512; host.curDCM.pixelRatio = 1;
        [host probeFrame: frame scale: uniform( 0.2, 6) rotation: uniform( 0, 360) origin: NSMakePoint( uniform( -300, 300), uniform( -300, 300))
                   flipX: rand() % 2 flipY: rand() % 2];
        fused.curDCM = [[DCMPix alloc] init];
        fused.curDCM.pwidth = (long) uniform( 16, 700); fused.curDCM.pheight = (long) uniform( 16, 700);
        fused.curDCM.pixelRatio = trial % 3 ? 1.0 : uniform( 0.5, 2.5);
        // The fused view's own frame is another window's; drawRectIn: ignores it, and so must the mirror.
        [fused probeFrame: NSMakeRect( 0, 0, floor( uniform( 64, 2400)), floor( uniform( 64, 1600)))
                    scale: uniform( 0.2, 12) rotation: trial % 4 ? uniform( 0, 360) : 0
                   origin: NSMakePoint( uniform( -500, 500), uniform( -500, 500)) flipX: rand() % 2 flipY: rand() % 2];
        CGFloat b = host->probeBacking;
        NSPoint points[ 3] = { NSMakePoint( 0, frame.size.height / b), NSMakePoint( frame.size.width / b, frame.size.height / b), NSMakePoint( 0, 0) };
        for( int k = 0; k < 4; k++)
        {
            NSPoint p = k < 3 ? points[ k] : NSMakePoint( uniform( 0, frame.size.width / b), uniform( 0, frame.size.height / b));
            NSPoint mirror = [fused horosPixelAt: p drawnIn: host];
            // The host's conversion on the fused view, in the image's frame.
            NSRect own = fused.drawingFrameRect;
            fused.drawingFrameRect = frame;
            NSPoint upLeft = NSMakePoint( p.x * b, frame.size.height - p.y * b);
            NSPoint reference = [fused ConvertFromUpLeftView2GL: upLeft];
            fused.drawingFrameRect = own;
            compared++;
            if( memcmp( &mirror, &reference, sizeof mirror))
            {
                if( differing++ < 5) printf( "differs: trial %d point (%g, %g): mirror (%.17g, %.17g), host (%.17g, %.17g)\n",
                                             trial, p.x, p.y, mirror.x, mirror.y, reference.x, reference.y);
            }
            NSPoint own_image = [host horosPixelAt: p drawnIn: host], converted = [host ConvertFromNSView2GL: p];
            if( memcmp( &own_image, &converted, sizeof own_image) == 0) identity++;
        }
    }}
    printf( "compared %ld differing %ld identity %ld\n", compared, differing, identity);
    return differing ? 1 : 0;
}}
"""


DRIVER = r'''
import Foundation
import Metal

func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { print("FAIL: " + reason()); exit(1) } }

let w = 41, h = 37, fw = 23, fh = 19, dx = 9, dy = 7
// Values inside CLUT bins, away from the rounding boundary: bin k plus 0.2 or 0.8.
func sample(_ k: Int, _ f: Float, level: Float, width: Float) -> Float { level - width / 2 + width * (Float(k) + f) / 255 }
func index(_ k: Int, _ f: Float) -> Int { f < 0.5 ? k : k + 1 }
let primaryBins = (0..<(w * h)).map { i in ((i % w) * 7 + (i / w) * 13) % 255 }
let primaryFractions = (0..<(w * h)).map { i in Float(i % 3 == 0 ? 0.8 : 0.2) }
let fusedBins = (0..<(fw * fh)).map { i in ((i % fw) * 11 + (i / fw) * 5 + 3) % 255 }
let fusedFractions = (0..<(fw * fh)).map { i in Float(i % 2 == 0 ? 0.2 : 0.8) }
let primaryValues = (0..<(w * h)).map { sample(primaryBins[$0], primaryFractions[$0], level: 300, width: 1400) }
let fusedValues = (0..<(fw * fh)).map { sample(fusedBins[$0], fusedFractions[$0], level: 1000, width: 2000) }
func makePrimaryCLUT() -> [UInt8] {
    var table = [UInt8]()
    for i in 0..<256 {
        let entry: [UInt8] = [UInt8(i), UInt8((i * 3) % 256), UInt8(255 - i), 255]
        table += entry
    }
    return table
}
func makeFusedColours() -> [UInt8] {
    var colours = [UInt8]()
    for i in 0..<256 {
        let entry: [UInt8] = [UInt8((i * 5) % 256), UInt8(i), UInt8((i * 11) % 256)]
        colours += entry
    }
    return colours
}
let primaryCLUT = makePrimaryCLUT()
let fusedColours = makeFusedColours()
func fusedCLUT(_ alpha: (Int) -> UInt8) -> Data {
    var table = [UInt8]()
    for i in 0..<256 {
        let entry: [UInt8] = [fusedColours[3 * i], fusedColours[3 * i + 1], fusedColours[3 * i + 2], alpha(i)]
        table += entry
    }
    return Data(table)
}
// Every alpha once: 37 is prime to 256.
let spread: (Int) -> UInt8 = { UInt8(($0 * 37 + 11) % 256) }

func floats(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }

func fused(clut: Data, flipped: Bool = false, table: Data? = nil) -> NSDictionary {
    // Texel centres of the fused image under the target's pixel centres, at (dx, dy), mirrored when flipped.
    let left = flipped ? Double(fw + dx) : Double(-dx), right = flipped ? Double(fw + dx - w) : Double(w - dx)
    let layer: NSMutableDictionary = ["width": fw, "height": fh, "pixels": floats(fusedValues), "clut": clut,
        "frameIdentity": "fused", "level": 1000.0, "widthWindow": 2000.0, "isColor": false,
        "screenToPixel": [left, Double(-dy), right, Double(-dy), left, Double(h - dy)], "viewSize": [w, h], "softwareScale": 1]
    if let table {
        layer["transferFunction"] = table; layer["transferLevel"] = 1000.0; layer["transferWidth"] = 2000.0
    }
    return layer
}
func frame(fusion: NSDictionary?, level: Double = 300) throws -> PlanarFrame {
    let value: NSMutableDictionary = ["width": w, "height": h, "pixels": floats(primaryValues), "clut": Data(primaryCLUT),
        "frameIdentity": "image", "level": level, "widthWindow": 1400.0, "isColor": false,
        "screenToPixel": [0.0, 0.0, Double(w), 0.0, 0.0, Double(h)], "viewSize": [w, h], "softwareScale": 1]
    if let fusion { value["fusion"] = fusion }
    return try PlanarFrame(value)
}

@main struct Check {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("skipped: no Metal device"); exit(2) }
        let metal = try PlanarMetalRenderer(device: device)
        let pilot = PlanarMetal4Renderer.isSupported(device) ? try PlanarMetal4Renderer(device: device) : nil
        var composed = 0, blended = 0, exact = 0, largest = 0

        // The opacity table's bytes for the fused values, as the host computes them.
        let curve = (0..<4096).map { Float(($0 * 2654435761) % 4096) / 4095 }
        let from = Float(Double(1000) - Double(2000) / 2), ratio = Float(4096 / Double(2000))
        let tableBytes = fusedValues.map { value -> Int in
            let scaled = ratio * (value - from)
            return Int((255 * Double(curve[min(4095, max(0, Int(scaled)))])).rounded(.towardZero))
        }

        func check(_ label: String, _ frame: PlanarFrame, alpha: (Int) -> UInt8, flipped: Bool = false, table: Bool = false) throws {
            try metal.update(frame)
            let picture = [UInt8](try metal.renderBGRA(width: w, height: h))
            if let pilot {
                try pilot.update(frame)
                expect([UInt8](try pilot.renderBGRA(width: w, height: h)) == picture, "\(label): the Metal 4 pilot composes differently")
            }
            for y in 0..<h { for x in 0..<w {
                let o = (y * w + x) * 4, i = y * w + x
                let p = index(primaryBins[i], primaryFractions[i])
                let under = (Double(primaryCLUT[4 * p]), Double(primaryCLUT[4 * p + 1]), Double(primaryCLUT[4 * p + 2]))
                var expected = [under.0, under.1, under.2, 255.0]
                let sx = x - dx, sy = y - dy
                if sx >= 0, sx < fw, sy >= 0, sy < fh {
                    let j = sy * fw + (flipped ? fw - 1 - sx : sx)
                    let s = table ? tableBytes[j] : index(fusedBins[j], fusedFractions[j])
                    let a = Double(alpha(s)) / 255
                    expected = [Double(fusedColours[3 * s]) * a + under.0 * (1 - a), Double(fusedColours[3 * s + 1]) * a + under.1 * (1 - a),
                                Double(fusedColours[3 * s + 2]) * a + under.2 * (1 - a), (a * a + (1 - a)) * 255]
                    blended += 1
                } else {
                    let got = [picture[o + 2], picture[o + 1], picture[o], picture[o + 3]]
                    expect(got == [primaryCLUT[4 * p], primaryCLUT[4 * p + 1], primaryCLUT[4 * p + 2], 255],
                           "\(label): (\(x), \(y)), outside the fused image, draws \(got), not the image's CLUT colour")
                }
                let got = [Double(picture[o + 2]), Double(picture[o + 1]), Double(picture[o]), Double(picture[o + 3])]
                let difference = zip(got, expected).map { abs($0 - $1.rounded()) }.max()!
                expect(difference <= 1, "\(label): (\(x), \(y)) draws \(got), the blend is \(expected)")
                if difference == 0 { exact += 1 }
                largest = max(largest, Int(difference)); composed += 1
            } }
        }

        try check("float", try frame(fusion: fused(clut: fusedCLUT(spread))), alpha: spread)
        try check("flipped", try frame(fusion: fused(clut: fusedCLUT(spread), flipped: true)), alpha: spread, flipped: true)
        let curveData = curve.withUnsafeBufferPointer { Data(buffer: $0) }
        let tabled = try frame(fusion: fused(clut: fusedCLUT(spread), table: curveData))
        expect(tabled.fusion.first?.transfer != nil, "the fused series' opacity table was not taken")
        try check("opacity table", tabled, alpha: spread, table: true)
        try check("alpha 0", try frame(fusion: fused(clut: fusedCLUT { _ in 0 })), alpha: { _ in 0 })
        try check("alpha 255", try frame(fusion: fused(clut: fusedCLUT { _ in 255 })), alpha: { _ in 255 })

        // The fusion factor changes the alpha column only: the image's textures stay.
        let first = try PlanarTextures(try frame(fusion: fused(clut: fusedCLUT(spread))), reusing: nil, device: device)
        let moved = try PlanarTextures(try frame(fusion: fused(clut: fusedCLUT { UInt8(($0 * 3) % 256) })), reusing: first, device: device)
        expect(moved.image === first.image && moved.clut === first.clut, "moving the fusion factor uploaded the image again")
        expect(moved.fused!.clut !== first.fused!.clut, "moving the fusion factor did not upload the fused table")
        expect(moved.fused!.image === first.fused!.image, "moving the fusion factor reuploaded unchanged fused pixels")
        let windowed = try PlanarTextures(try frame(fusion: fused(clut: fusedCLUT { UInt8(($0 * 3) % 256) }), level: 250), reusing: moved, device: device)
        expect(windowed.fused!.image === moved.fused!.image && windowed.fused!.clut === moved.fused!.clut,
               "changing the image's window uploaded the fused series again")
        let alone = try PlanarTextures(try frame(fusion: nil), reusing: windowed, device: device)
        expect(alone.fused == nil, "the textures kept a fused series the frame no longer has")

        // A colour fused series: its ARGB bytes tabled as loadTextureIn:blending:YES
        // tables them, the alpha column the fusion's, and blended with that alpha.
        var argb = [UInt8](repeating: 0, count: fw * fh * 4)
        for j in 0..<(fw * fh) {
            argb[4 * j] = UInt8((j * 29 + 7) % 256); argb[4 * j + 1] = UInt8((j * 13) % 256)
            argb[4 * j + 2] = UInt8((j * 7 + 90) % 256); argb[4 * j + 3] = UInt8((j * 3 + 200) % 256)
        }
        var tables = [UInt8](repeating: 0, count: 1024)
        for i in 0..<256 {
            tables[i] = spread(i); tables[256 + i] = UInt8((i * 5 + 1) % 256)
            tables[512 + i] = UInt8(255 - i); tables[768 + i] = UInt8((i * 9) % 256)
        }
        let colour = fused(clut: fusedCLUT(spread)).mutableCopy() as! NSMutableDictionary
        colour["isColor"] = true
        colour["pixels"] = Data(argb); colour["hostBytes"] = Data(argb); colour["colourTable"] = Data(tables)
        let colourFrame = try frame(fusion: colour)
        expect(colourFrame.fusion.first?.window.z == 2, "a colour fused series is not drawn from its bytes")
        try metal.update(colourFrame)
        let colourPicture = [UInt8](try metal.renderBGRA(width: w, height: h))
        if let pilot {
            try pilot.update(colourFrame)
            expect([UInt8](try pilot.renderBGRA(width: w, height: h)) == colourPicture, "colour fused series: the Metal 4 pilot composes differently")
        }
        var colourBlended = 0
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4, i = y * w + x
            let p = index(primaryBins[i], primaryFractions[i])
            let under = [Double(primaryCLUT[4 * p]), Double(primaryCLUT[4 * p + 1]), Double(primaryCLUT[4 * p + 2])]
            var expected = under
            let sx = x - dx, sy = y - dy
            if sx >= 0, sx < fw, sy >= 0, sy < fh {
                let j = sy * fw + sx
                let a = Double(tables[Int(argb[4 * j])]) / 255
                let rgb = [Double(tables[256 + Int(argb[4 * j + 1])]), Double(tables[512 + Int(argb[4 * j + 2])]),
                           Double(tables[768 + Int(argb[4 * j + 3])])]
                expected = (0..<3).map { rgb[$0] * a + under[$0] * (1 - a) }
                colourBlended += 1
            }
            let got = [Double(colourPicture[o + 2]), Double(colourPicture[o + 1]), Double(colourPicture[o])]
            let difference = zip(got, expected).map { abs($0 - $1.rounded()) }.max()!
            expect(difference <= 1, "colour fused series: (\(x), \(y)) draws \(got), the blend is \(expected)")
            largest = max(largest, Int(difference)); composed += 1
        } }
        expect(colourBlended == fw * fh, "the colour fused series did not cover its image")
        // Not drawn here: a colour fused series without its table, or one fused over again.
        let untabled = colour.mutableCopy() as! NSMutableDictionary
        untabled.removeObject(forKey: "colourTable")
        expect((try? frame(fusion: untabled)) == nil, "a colour fused series without the fusion's alpha table was accepted")
        let nested = fused(clut: fusedCLUT(spread)).mutableCopy() as! NSMutableDictionary
        nested["fusion"] = fused(clut: fusedCLUT(spread))
        expect((try? frame(fusion: nested)) == nil, "a fused series with a fusion of its own was accepted")

        print("PASS: \(composed) composed pixels (\(blended) under the fused series) at texel centres of both layers, float, flipped and opacity-table fused series and alpha 0 and 255, within one level of the source-alpha blend (\(exact) exact, largest \(largest))\(pilot == nil ? "" : ", the Metal 4 pilot identical"); the fusion factor uploads only its CLUT and window changes preserve image uploads; a colour fused series tabled and blended with its alpha byte (\(colourBlended) pixels); untabled colour and nested fused series refused")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-planar-fusion-') as name:
    directory = Path(name)
    (directory / 'bridge.h').write_text(BRIDGE)
    (directory / 'conversions.swift').write_text(EXTENSION)
    (directory / 'probe.m').write_text(PROBE)
    for command in (['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'Horos', '-wmo',
                     '-import-objc-header', str(directory / 'bridge.h'),
                     '-emit-objc-header', '-emit-objc-header-path', str(directory / 'Horos-Swift.h'),
                     '-c', str(directory / 'conversions.swift'), str(root / 'Modules/IsiXImaging/Sources/ViewDrawing/PlanarPresentation.swift'),
                     '-o', str(directory / 'conversions.o')],
                    ['xcrun', 'clang', '-fobjc-arc', '-w', '-c', str(directory / 'probe.m'), '-o', str(directory / 'probe.o'),
                     '-I', str(directory)],
                    ['xcrun', 'swiftc', str(directory / 'conversions.o'), str(directory / 'probe.o'), '-o', str(directory / 'probe'),
                     '-framework', 'AppKit']):
        built = subprocess.run(command, capture_output=True, text=True)
        if built.returncode:
            sys.stderr.write(built.stderr[-4000:])
            print('FAIL: the mapping probe does not build')
            raise SystemExit(1)
    try:
        run = subprocess.run([str(directory / 'probe'), str(random.randrange(1 << 30))],
                             capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        print('FAIL: the mapping probe did not finish in 120 s')
        raise SystemExit(1)
    sys.stdout.write(run.stdout)
    sys.stdout.flush()
    if run.returncode:
        sys.stderr.write(run.stderr[-4000:])
        print('FAIL: the fused series\' mapping is not the host\'s conversion in the image\'s frame (exit %d)' % run.returncode)
        raise SystemExit(1)
    counts = re.search(r'compared (\d+) differing 0 identity (\d+)', run.stdout)
    if not counts or counts.group(1) != counts.group(2):
        print('FAIL: the image\'s own mapping is not ConvertFromNSView2GL:')
        raise SystemExit(1)

    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'MPRMetalReslicer.swift', 'MetalPerformanceTrace.swift',
               'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift', 'PlanarMetalRenderer.swift',
               'PlanarMetal4Renderer.swift']
    for source in sources:
        (directory / source).write_text(read('Horos/Sources/' + source))
    (directory / 'Check.swift').write_text(DRIVER)
    build_result = subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-suppress-warnings',
                                   *[str(directory / source) for source in sources], str(directory / 'Check.swift'),
                                   '-o', str(directory / 'check')])
    if build_result.returncode:
        print('FAIL: the planar renderer does not build with the fusion driver')
        raise SystemExit(1)
    result = subprocess.run([str(directory / 'check')], timeout=300)
    if result.returncode == 0:
        print('PASS: %s mapped points of a fused view equal to the host\'s ConvertFromUpLeftView2GL: in the image\'s frame, bit for bit' % counts.group(1))
    raise SystemExit(result.returncode)
