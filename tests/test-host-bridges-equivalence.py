#!/usr/bin/env python3
"""The decisions the host bridges took in Objective-C, taken now by IsiXImaging.

The MPR, planar, registration and registered GIF bridges of the 2D and 3D
viewers moved from Objective-C (MPRHostBridge.m, PlanarHostBridge.m,
RegistrationHostBridge.m, RegisteredGIFHostBridge.m) to Swift extensions of
their classes, with their pure decisions in IsiXImaging: MPRPlaneRules,
PlanarPresentation and FusionComparison. This compiles those decisions as the
Objective-C wrote them, read from the last revision that has the bridges
(`--reference`), with clang as Xcode compiles them (its fused multiply-adds
included), and the module's Swift with swiftc, and runs both over the same
random and edge inputs. Everything they produce must be the same, bit for bit:

* the MPR: which projection modes are resliced, the slab's sample step from
  the slice interval, thickness and pixel spacings (or its refusal), the
  centre of pixel (0, 0) from VTK's corner, cosines and spacing, and when the
  cubic display plane is made;
* the planar snapshot: the stack modes and image sizes it refuses, when the
  host's 8-bit bytes are drawn, which source a frame is drawn from (own
  samples, display plane, host bytes, volume-rendering slab, scalar slab),
  whether its bytes carry their alpha or are tabled, the window and the
  software scale, when a fused series is drawn and the image whitened under
  it, the scalar CLUT table and the colour tables (channel factors stored
  into bytes unclamped), and the pixel of a fused view under a point of the
  view it is fused over;
* the fusion comparison: the blend of the Fusion panel's slider, the slider
  value of a blend stop, the manual offset, and the patient box of a volume.

    python3 tests/test-host-bridges-equivalence.py [--reference REV]
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BRIDGES = ['MPRHostBridge.m', 'PlanarHostBridge.m', 'RegistrationHostBridge.m', 'RegisteredGIFHostBridge.m']
MODULE = ['ViewerReconstruction/MPRPlaneRules.swift', 'ViewDrawing/PlanarPresentation.swift', 'ViewerFusion/FusionComparison.swift']

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference', help='the revision whose Objective-C bridges are the reference')
args = parser.parse_args()


def reference_revision():
    if args.reference:
        return args.reference
    found = history_reference.before_removal('Horos/Sources/PlanarHostBridge.m')
    if found:
        return found
    has = subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:Horos/Sources/PlanarHostBridge.m'], capture_output=True)
    return 'HEAD' if has.returncode == 0 else None


REFERENCE = reference_revision()
if REFERENCE is None:
    print('skipped: needs the history back to the Objective-C bridges; a shallow clone does not carry it', file=sys.stderr)
    sys.exit(2)
SOURCES = {name: subprocess.check_output(['git', '-C', str(ROOT), 'show', '%s:Horos/Sources/%s' % (REFERENCE, name)]).decode('latin1')
           for name in BRIDGES}


def take(name, pattern, flags=re.S):
    """The first match of `pattern` in the reference bridge `name`; a missing
    piece fails the test rather than testing something else."""
    found = re.search(pattern, SOURCES[name], flags)
    if not found:
        print('FAIL: %s no longer has %r at %s' % (name, pattern, REFERENCE))
        sys.exit(1)
    return found


def block(text, at):
    """`text` from `at` to the brace that closes the first block after it."""
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    raise ValueError('unbalanced braces')


mpr, planar, registration, gif = (SOURCES[name] for name in BRIDGES)

# --- the MPR ------------------------------------------------------------------
pixel_centre = block(mpr, take('MPRHostBridge.m', r'static NSArray \*HorosMPRPixelCentre\(').start())
maximum_slab = take('MPRHostBridge.m', r'static const float HorosMPRCubicDisplayMaximumSlab = [^;]+;').group(0)
cubic = take('MPRHostBridge.m', r'if \((controller\.horosMPRCubicDisplay && !fused && thickness <= HorosMPRCubicDisplayMaximumSlab)\)').group(1)
cubic = cubic.replace('controller.horosMPRCubicDisplay', 'preference').replace('!fused', '!isFused')
volume_route = take('MPRHostBridge.m', r'if \((controller\.clippingRangeMode < 1 \|\| controller\.clippingRangeMode > 3)\) \{\s*\[vrView horosSetMPRVolumeMetal:YES\];').group(1)
volume_route = volume_route.replace('controller.clippingRangeMode', 'mode')
spacing = take('MPRHostBridge.m', r'(double dz = fabs\(first\.sliceInterval\);.*?if \(dz <= 0 \|\| !isfinite\(dz\) \|\| !isfinite\(sx\) \|\| !isfinite\(sy\)\)) \{ \*reason = @"The volume spacing is not usable\."; return nil; \}').group(1)
step = take('MPRHostBridge.m', r'sampleStep:(MIN\(sx, MIN\(sy, dz\)\)) colour:').group(1)

# --- the planar snapshot ------------------------------------------------------
snapshot = planar[planar.index('- (NSDictionary *)horosPlanarSnapshotDrawnIn:(DCMView *)host'):]
mirror = block(planar, take('PlanarHostBridge.m', r'- \(NSPoint\)horosPixelAt:\(NSPoint\)point drawnIn:\(DCMView \*\)host \{').start())
scalar_loop = take('PlanarHostBridge.m', r'(for \(NSUInteger i = 0; i < 256; \+\+i\) \{\s*rgba\[4\*i\] = .*?rgba\[4\*i\+3\] = alpha \? alpha\[i\] : 255;\s*\})').group(1)
colour_loop = take('PlanarHostBridge.m', r'unsigned char table\[1024\];\s*(for \(NSUInteger i = 0; i < 256; \+\+i\) \{\s*table\[i\] = fused \? alpha\[i\] : opaqueTable\[i\];.*?\}\s*\})').group(1)


def condition(pattern):
    return take('PlanarHostBridge.m', pattern).group(1)


PLANAR_CONDITIONS = {
    'refusedMode': condition(r'if \(!pix \|\| (pix\.stackMode < 0 \|\| pix\.stackMode > 5)\)'),
    'refusedSize': condition(r'if \((width <= 0 \|\| height <= 0 \|\| width > 65535 \|\| height > 65535 \|\| count > 2048UL\*1024\*1024)\)'),
    'hostEightBit': condition(r'BOOL hostEightBit = ([^;]+);'),
    'colourBytes': condition(r'BOOL colourBytes = ([^;]+);'),
    'volumeSlab': condition(r'BOOL volumeSlab = ([^;]+);'),
    'hostBytesBranch': condition(r'\} else if \((colourBytes \|\| pix\.subtractedfImage \|\| pix\.shutterEnabled \|\| hostEightBit)\) \{'),
    'displayPlane': condition(r'if \((!colourBytes && !volumeSlab && displayPlane\.length == count && !\(pix\.stackMode >= 1 && pix\.stack > 1\))\)\s*samples = displayPlane;'),
    'ownSamples': condition(r'if \((!colourBytes && !volumeSlab && !samples && !hostBytes && !\(pix\.stackMode >= 1 && pix\.stack > 1\))\)\s*samples = HorosPlanarScalarSnapshot'),
    'carriesAlpha': condition(r'if \((packed \|\| volumeSlab)\) snapshot\[@"bytesCarryAlpha"\]'),
    'colourTable': condition(r'if \((pix\.isRGB && !packed && \(fused \|\| colorTransfer \|\| redFactor != 1\.0 \|\| greenFactor != 1\.0 \|\| blueFactor != 1\.0\))\) \{'),
    'scalarSlab': condition(r'if \((!colourBytes && !hostEightBit && pix\.stackMode >= 1 && pix\.stackMode <= 3 && pix\.stack > 1 && series\.count > 1)\) \{'),
    'white': condition(r'if \((!fused && view\.blendingView && !syncOnLocationImpossible && view\.whiteBackground)\) \{'),
    'drawsFusion': condition(r'if \((!fused && view\.blendingView && !syncOnLocationImpossible && \(view\.isKeyView \|\| !\[view is2DViewer\]\))\) \{'),
}
level = condition(r'@"level": @\(([^)]*\? 127 : view\.curWL)\)')
window_width = condition(r'@"widthWindow": @\((\(pix\.displayInverted \? -1 : 1\) \* \(noScale \|\| \[pix horosPlanarUsesFixedWindow\] \? 256 : view\.curWW\))\)')
software = condition(r'@"softwareScale": @\((\[view softwareInterpolation\] \? \(width <= 256 \? 3 : 2\) : 1)\)')


def objc_free(expression):
    """The snapshot's message sends, as the stand-in structures' fields."""
    for message, field in (('[pix horosPlanarUsesFixedWindow]', 'pix.fixedWindow'), ('[view is2DViewer]', 'view.is2DViewer'),
                           ('[view softwareInterpolation]', 'view.softwareInterpolation')):
        expression = expression.replace(message, field)
    return expression


# --- the fusion comparison ----------------------------------------------------
blend = take('RegistrationHostBridge.m', r'double blend = (hi > lo \? \(raw - lo\) / \(hi - lo\) : 0\.5);').group(1)
slider = take('RegisteredGIFHostBridge.m', r'\[slider setDoubleValue:(low \+ stop\.doubleValue \* \(high - low\))\];').group(1).replace('stop.doubleValue', 'stop')
offset = take('RegistrationHostBridge.m', r'double v = field\.doubleValue; \[offset addObject:@\((isfinite\(v\) \? v : 0)\)\];').group(1)
bounds = take('RegistrationHostBridge.m', r'(for \(int axis = 0; axis < 3; axis\+\+\) \{ lo\[axis\] = MIN\(lo\[axis\], d\[axis\]\); hi\[axis\] = MAX\(hi\[axis\], d\[axis\]\); \})').group(1)
bounds_start = take('RegistrationHostBridge.m', r'(double lo\[3\] = \{INFINITY, INFINITY, INFINITY\}, hi\[3\] = \{-INFINITY, -INFINITY, -INFINITY\};)').group(1)

HEADER = r'''
#import <Foundation/Foundation.h>
#include <stdbool.h>

void reference_pixel_centre(const float corner[3], const float cosines[9], double spacing, double out[3]);
double reference_sample_step(double interval, double thickness, double spacingX, double spacingY);
bool reference_cubic(bool preference, bool isFused, float thickness);
bool reference_volume_route(long mode);
unsigned reference_planar(long stackMode, long stack, long width, long height, unsigned long count, long seriesCount,
                          bool isRGB, bool packed, bool subtracted, bool shutter, bool displayPlaneMatches, bool fused,
                          bool colorTransfer, float redFactor, float greenFactor, float blueFactor, bool blending, bool sync,
                          bool white, bool keyView, bool is2DViewer);
void reference_window(bool noScale, bool fixedWindow, bool inverted, float curWL, float curWW, bool software, long width,
                      float *level, float *windowWidth, long *scale);
void reference_scalar_table(const unsigned char *r, const unsigned char *g, const unsigned char *b, const unsigned char *alpha,
                            float redFactor, float greenFactor, float blueFactor, unsigned char rgba[1024]);
void reference_colour_table(const unsigned char *r, const unsigned char *g, const unsigned char *b, const unsigned char *alpha,
                            bool fused, float redFactor, float greenFactor, float blueFactor, unsigned char table[1024]);
NSPoint reference_mirror(NSPoint point, double backing, NSSize frame, BOOL xFlipped, BOOL yFlipped, float scale, float rotation,
                         NSPoint origin, BOOL hasImage, long width, long height, double pixelRatio);
double reference_blend(double raw, double lo, double hi);
double reference_slider(double stop, double low, double high);
double reference_offset(double v);
void reference_bounds(const float *points, long count, double lo[3], double hi[3]);
'''

REFERENCE_M = r'''
#import <AppKit/AppKit.h>
#include <math.h>
#include <string.h>
#import "reference.h"

PIXEL_CENTRE

void reference_pixel_centre(const float corner[3], const float cosines[9], double spacing, double out[3]) {
    NSArray *centre = HorosMPRPixelCentre(corner, cosines, spacing);
    for (int i = 0; i < 3; i++) out[i] = [centre[i] doubleValue];
}

typedef struct { double sliceInterval, sliceThickness, pixelSpacingX, pixelSpacingY; } Slice;

double reference_sample_step(double interval, double thickness, double spacingX, double spacingY) {
    Slice first = { interval, thickness, spacingX, spacingY };
    SPACING return NAN;
    return STEP;
}

MAXIMUM_SLAB

bool reference_cubic(bool preference, bool isFused, float thickness) { return CUBIC; }

bool reference_volume_route(long mode) { return VOLUME_ROUTE; }

typedef struct { long stackMode, stack; BOOL isRGB, isLUT12Bit, shutterEnabled, fixedWindow, displayInverted; float *subtractedfImage; } Pix;
typedef struct { long count; } Series;
typedef struct { void *blendingView; BOOL whiteBackground, isKeyView, is2DViewer, softwareInterpolation; float curWL, curWW; } View;
typedef struct { unsigned long length; } Plane;

unsigned reference_planar(long stackMode, long stack, long width, long height, unsigned long count, long seriesCount,
                          bool isRGB, bool packed, bool subtracted, bool shutter, bool displayPlaneMatches, bool fused,
                          bool colorTransfer, float redFactor, float greenFactor, float blueFactor, bool blending, bool sync,
                          bool white, bool keyView, bool is2DViewer) {
    float subtraction = 0;
    Pix pix = { stackMode, stack, isRGB, packed, shutter, NO, NO, subtracted ? &subtraction : NULL };
    Series series = { seriesCount };
    View view = { blending ? (void *) &series : NULL, white, keyView, is2DViewer, NO, 0, 0 };
    Plane displayPlane = { displayPlaneMatches ? count : count + 1 };
    BOOL syncOnLocationImpossible = !sync;
    unsigned bits = 0;
    if (REFUSED_MODE) bits |= 1u << 0;
    if (REFUSED_SIZE) bits |= 1u << 1;
    BOOL hostEightBit = HOST_EIGHT_BIT;
    BOOL colourBytes = COLOUR_BYTES;
    BOOL volumeSlab = VOLUME_SLAB;
    BOOL hostBytesBranch = !volumeSlab && (HOST_BYTES_BRANCH);
    void *hostBytes = volumeSlab || hostBytesBranch ? (void *) &bits : NULL;
    void *samples = NULL;
    if (DISPLAY_PLANE) { samples = &displayPlane; bits |= 1u << 2; }
    if (OWN_SAMPLES) bits |= 1u << 3;
    if (hostEightBit) bits |= 1u << 4;
    if (colourBytes || volumeSlab) bits |= 1u << 5;
    if (volumeSlab) bits |= 1u << 6;
    if (hostBytes) bits |= 1u << 7;
    if (hostBytes && (CARRIES_ALPHA)) bits |= 1u << 8;
    if (hostBytes && (COLOUR_TABLE)) bits |= 1u << 9;
    if (SCALAR_SLAB) bits |= 1u << 10;
    if (WHITE) bits |= 1u << 11;
    if (DRAWS_FUSION) bits |= 1u << 12;
    return bits;
}

void reference_window(bool noScale, bool fixedWindow, bool inverted, float curWL, float curWW, bool software, long width,
                      float *level, float *windowWidth, long *scale) {
    Pix pix = { 0, 1, NO, NO, NO, fixedWindow, inverted, NULL };
    View view = { NULL, NO, NO, NO, software, curWL, curWW };
    NSNumber *l = @(LEVEL), *w = @(WINDOW_WIDTH), *s = @(SOFTWARE);
    *level = l.floatValue; *windowWidth = w.floatValue; *scale = s.longValue;
}

void reference_scalar_table(const unsigned char *r, const unsigned char *g, const unsigned char *b, const unsigned char *alpha,
                            float redFactor, float greenFactor, float blueFactor, unsigned char rgba[1024]) {
    SCALAR_LOOP
}

void reference_colour_table(const unsigned char *r, const unsigned char *g, const unsigned char *b, const unsigned char *alpha,
                            bool fused, float redFactor, float greenFactor, float blueFactor, unsigned char table[1024]) {
    unsigned char opaqueTable[256];
    memset(opaqueTable, 0xFF, sizeof opaqueTable);
    COLOUR_LOOP
}

@interface DCMPix : NSObject
@property long pwidth, pheight;
@property double pixelRatio;
@end
@implementation DCMPix
@end

@interface DCMView : NSView
{ @public CGFloat probeBacking; }
@property NSRect drawingFrameRect;
@property float horos_scaleValue, horos_rotation;
@property NSPoint horos_origin;
@property BOOL horos_xFlipped, horos_yFlipped;
@property(strong) DCMPix *curDCM;
@end
@implementation DCMView
- (NSPoint) convertPointToBacking:(NSPoint) a { return NSMakePoint(a.x * probeBacking, a.y * probeBacking); }
- (NSPoint) ConvertFromNSView2GL:(NSPoint) a { return a; }
MIRROR
@end

NSPoint reference_mirror(NSPoint point, double backing, NSSize frame, BOOL xFlipped, BOOL yFlipped, float scale, float rotation,
                         NSPoint origin, BOOL hasImage, long width, long height, double pixelRatio) {
    @autoreleasepool {
        DCMView *host = [[DCMView alloc] initWithFrame:NSZeroRect], *fused = [[DCMView alloc] initWithFrame:NSZeroRect];
        host->probeBacking = backing;
        host.drawingFrameRect = NSMakeRect(0, 0, frame.width, frame.height);
        fused.horos_scaleValue = scale; fused.horos_rotation = rotation; fused.horos_origin = origin;
        fused.horos_xFlipped = xFlipped; fused.horos_yFlipped = yFlipped;
        if (hasImage) {
            fused.curDCM = [[DCMPix alloc] init];
            fused.curDCM.pwidth = width; fused.curDCM.pheight = height; fused.curDCM.pixelRatio = pixelRatio;
        }
        return [fused horosPixelAt:point drawnIn:host];
    }
}

double reference_blend(double raw, double lo, double hi) { return BLEND; }
double reference_slider(double stop, double low, double high) { return SLIDER; }
double reference_offset(double v) { return OFFSET; }
void reference_bounds(const float *points, long count, double out_lo[3], double out_hi[3]) {
    BOUNDS_START
    for (long p = 0; p < count; p++) {
        const float *d = points + 3 * p;
        BOUNDS
    }
    for (int axis = 0; axis < 3; axis++) { out_lo[axis] = lo[axis]; out_hi[axis] = hi[axis]; }
}
'''

replacements = {
    'PIXEL_CENTRE': pixel_centre, 'SPACING': spacing, 'STEP': step, 'MAXIMUM_SLAB': maximum_slab, 'CUBIC': cubic,
    'VOLUME_ROUTE': volume_route,
    'REFUSED_MODE': PLANAR_CONDITIONS['refusedMode'], 'REFUSED_SIZE': PLANAR_CONDITIONS['refusedSize'],
    'HOST_EIGHT_BIT': PLANAR_CONDITIONS['hostEightBit'],
    'COLOUR_BYTES': PLANAR_CONDITIONS['colourBytes'].replace('pix.isRGB || packed', 'pix.isRGB || pix.isLUT12Bit'),
    'VOLUME_SLAB': PLANAR_CONDITIONS['volumeSlab'], 'HOST_BYTES_BRANCH': PLANAR_CONDITIONS['hostBytesBranch'],
    'DISPLAY_PLANE': PLANAR_CONDITIONS['displayPlane'], 'OWN_SAMPLES': PLANAR_CONDITIONS['ownSamples'],
    'CARRIES_ALPHA': PLANAR_CONDITIONS['carriesAlpha'].replace('packed', 'pix.isLUT12Bit'),
    'COLOUR_TABLE': PLANAR_CONDITIONS['colourTable'].replace('!packed', '!pix.isLUT12Bit'),
    'SCALAR_SLAB': PLANAR_CONDITIONS['scalarSlab'],
    'WHITE': PLANAR_CONDITIONS['white'], 'DRAWS_FUSION': objc_free(PLANAR_CONDITIONS['drawsFusion']),
    'LEVEL': objc_free(level), 'WINDOW_WIDTH': objc_free(window_width), 'SOFTWARE': objc_free(software),
    'SCALAR_LOOP': scalar_loop, 'COLOUR_LOOP': colour_loop, 'MIRROR': mirror,
    'BLEND': blend, 'SLIDER': slider, 'OFFSET': offset, 'BOUNDS_START': bounds_start, 'BOUNDS': bounds,
}
reference_source = REFERENCE_M
for key in sorted(replacements, key=len, reverse=True):
    reference_source = reference_source.replace(key, replacements[key])

DRIVER = r'''
import AppKit

var state: UInt64 = 0x9E3779B97F4A7C15
func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53) }
func coin() -> Bool { next() >> 63 == 1 }
func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
func same(_ a: Double, _ b: Double) -> Bool { a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN) }
func same(_ a: Float, _ b: Float) -> Bool { a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN) }

var compared: [String: Int] = [:]
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
    compared[label, default: 0] += 1
    if !ok { failures += 1; if failures <= 20 { print("differs: \(label): \(detail())") } }
}

state = UInt64(CommandLine.arguments[1])!
let odd: [Double] = [0, -0.0, 1, -1, 0.5, 2.5, 1e-9, 1e300, .infinity, -.infinity, .nan]

for _ in 0..<20000 {
    // The MPR.
    let corner = (0..<3).map { _ in Float(uniform(-500, 500)) }
    let cosines = (0..<9).map { _ in Float(uniform(-1, 1)) }
    let spacing = coin() ? uniform(0.01, 4) : pick(odd)
    var centre = [Double](repeating: 0, count: 3)
    reference_pixel_centre(corner, cosines, spacing, &centre)
    let module = MPRPlaneRules.pixelCentre(corner: corner, cosines: cosines, spacing: spacing)
    check("pixel centre", zip(centre, module).allSatisfy { same($0, $1) }, "\(centre) vs \(module)")

    let interval = coin() ? uniform(-5, 5) : pick(odd), thickness = coin() ? uniform(0, 5) : pick(odd)
    let sx = coin() ? uniform(-1, 3) : pick(odd), sy = coin() ? uniform(-1, 3) : pick(odd)
    let step = reference_sample_step(interval, thickness, sx, sy)
    let moduleStep = MPRPlaneRules.sampleStep(sliceInterval: interval, sliceThickness: thickness, pixelSpacingX: sx, pixelSpacingY: sy)
    check("sample step", step.isNaN ? moduleStep == nil : moduleStep.map { same($0, step) } ?? false, "\(step) vs \(String(describing: moduleStep))")

    let preference = coin(), isFused = coin()
    let slab = Float(pick([uniform(0, 3), 1.0, 1.001, 1.0009, 1.0011, Double(Float(1.0) + Float(1e-3))]))
    check("cubic plane", reference_cubic(preference, isFused, slab) == MPRPlaneRules.drawsCubicDisplayPlane(preference: preference, fused: isFused, thickness: slab), "\(preference) \(isFused) \(slab)")
    let mode = Int(next() % 7) - 1
    check("volume route", reference_volume_route(mode) == !MPRPlaneRules.reslices(projectionMode: mode), "\(mode)")

    // The planar snapshot's decisions.
    let stackMode = Int(next() % 8) - 1, stack = Int(next() % 5), seriesCount = Int(next() % 4)
    let width = pick([0, 1, 255, 256, 257, 16383, 16384, 65535, 65536, Int(uniform(1, 3000))])
    let height = pick([0, 1, 16384, 65536, Int(uniform(1, 3000))])
    let count = VolumeBytes.count(width: width, height: height)
    let isRGB = coin(), packed = coin(), subtracted = coin(), shutter = coin(), matches = coin(), fusedView = coin()
    let colorTransfer = coin()
    let factors = (0..<3).map { _ in Float(coin() ? 1 : uniform(-1, 3)) }
    let blending = coin(), sync = coin(), white = coin(), keyView = coin(), is2D = coin()
    let bits = reference_planar(stackMode, stack, width, height, UInt(count), seriesCount, isRGB, packed, subtracted, shutter,
                                matches, fusedView, colorTransfer, factors[0], factors[1], factors[2], blending, sync, white,
                                keyView, is2D)
    let eightBit = PlanarPresentation.drawsEightBitRepresentation(width: width, height: height)
    // Stack is 1 without a stack mode, as DCMPix answers it.
    let source = PlanarPresentation.Source(stackMode: stackMode, stack: stack, seriesCount: seriesCount, isRGB: isRGB, packed: packed,
                                           subtracted: subtracted, shutter: shutter, eightBit: eightBit)
    var expected: UInt32 = 0
    if !PlanarPresentation.drawsStackMode(stackMode) { expected |= 1 << 0 }
    if !PlanarPresentation.accepts(width: width, height: height, planeBytes: count) { expected |= 1 << 1 }
    if source.takesDisplayPlane && matches { expected |= 1 << 2 }
    if source.drawsOwnSamples && !(source.takesDisplayPlane && matches) { expected |= 1 << 3 }
    if eightBit { expected |= 1 << 4 }
    if source.isColour { expected |= 1 << 5 }
    if source.volumeSlab { expected |= 1 << 6 }
    let hostBytes = source.volumeSlab || source.hostBytes
    if hostBytes { expected |= 1 << 7 }
    if hostBytes && source.bytesCarryAlpha(packed: packed) { expected |= 1 << 8 }
    if hostBytes && PlanarPresentation.tablesColourBytes(isRGB: isRGB, packed: packed, fused: fusedView, colorTransfer: colorTransfer,
                                                         redFactor: factors[0], greenFactor: factors[1], blueFactor: factors[2]) { expected |= 1 << 9 }
    if source.scalarSlab { expected |= 1 << 10 }
    if PlanarPresentation.whitensImageUnderFusion(hasFusedSeries: !fusedView && blending, locationsInSync: sync, whiteBackground: white) { expected |= 1 << 11 }
    if PlanarPresentation.drawsFusion(hasFusedSeries: !fusedView && blending, locationsInSync: sync, isKeyView: keyView, is2DViewer: is2D) { expected |= 1 << 12 }
    check("planar decisions", bits == expected, "\(String(bits, radix: 2)) vs \(String(expected, radix: 2)) for mode \(stackMode) stack \(stack) series \(seriesCount) \(width)x\(height)")

    let noScale = coin(), fixed = coin(), inverted = coin(), software = coin()
    let wl = Float(uniform(-2000, 2000)), ww = Float(uniform(-10, 4000))
    var level: Float = 0, windowWidth: Float = 0, scale = 0
    reference_window(noScale, fixed, inverted, wl, ww, software, width, &level, &windowWidth, &scale)
    let window = PlanarPresentation.window(level: wl, width: ww, fixed: noScale || fixed, inverted: inverted)
    check("window", same(level, window.level) && same(windowWidth, window.width), "\(level) \(windowWidth) vs \(window)")
    check("software scale", scale == PlanarPresentation.softwareScale(interpolates: software, width: width), "\(scale)")

    // The tables.
    let r = (0..<256).map { _ in UInt8(truncatingIfNeeded: next()) }, g = (0..<256).map { _ in UInt8(truncatingIfNeeded: next()) }
    let b = (0..<256).map { _ in UInt8(truncatingIfNeeded: next()) }, a = (0..<256).map { _ in UInt8(truncatingIfNeeded: next()) }
    let tableFactors = (0..<3).map { _ in Float(pick([1, uniform(-2, 4), uniform(0, 1e10), -0.0, .nan, .infinity])) }
    let withAlpha = coin()
    var rgba = [UInt8](repeating: 0, count: 1024), table = [UInt8](repeating: 0, count: 1024)
    if withAlpha {
        reference_scalar_table(r, g, b, a, tableFactors[0], tableFactors[1], tableFactors[2], &rgba)
    } else {
        reference_scalar_table(r, g, b, nil, tableFactors[0], tableFactors[1], tableFactors[2], &rgba)
    }
    let scalar = r.withUnsafeBufferPointer { r in g.withUnsafeBufferPointer { g in b.withUnsafeBufferPointer { b in a.withUnsafeBufferPointer { a in
        PlanarPresentation.scalarTable(red: r.baseAddress!, green: g.baseAddress!, blue: b.baseAddress!, alpha: withAlpha ? a.baseAddress! : nil,
                                       redFactor: tableFactors[0], greenFactor: tableFactors[1], blueFactor: tableFactors[2]) } } } }
    check("scalar table", rgba == scalar, "factors \(tableFactors)")
    reference_colour_table(r, g, b, a, withAlpha, tableFactors[0], tableFactors[1], tableFactors[2], &table)
    let colour = r.withUnsafeBufferPointer { r in g.withUnsafeBufferPointer { g in b.withUnsafeBufferPointer { b in a.withUnsafeBufferPointer { a in
        PlanarPresentation.colourTable(red: r.baseAddress!, green: g.baseAddress!, blue: b.baseAddress!, alpha: withAlpha ? a.baseAddress! : nil,
                                       redFactor: tableFactors[0], greenFactor: tableFactors[1], blueFactor: tableFactors[2]) } } } }
    check("colour table", table == colour, "factors \(tableFactors)")

    // The fused view's pixel.
    let backing: Double = coin() ? 2 : 1
    let frame = NSSize(width: floor(uniform(64, 2400)), height: floor(uniform(64, 1600)))
    let point = NSPoint(x: uniform(-50, frame.width / backing + 50), y: uniform(-50, frame.height / backing + 50))
    let flipX = coin(), flipY = coin(), hasImage = !(next() % 8 == 0)
    let zoom = Float(uniform(0.2, 12)), rotation = Float(coin() ? uniform(0, 360) : pick([0, 90, 180, 270]))
    let origin = NSPoint(x: uniform(-500, 500), y: uniform(-500, 500))
    let iw = Int(uniform(16, 700)), ih = Int(uniform(16, 700)), ratio = coin() ? 1 : uniform(0.5, 2.5)
    let mirrored = reference_mirror(point, backing, frame, flipX, flipY, zoom, rotation, origin, hasImage, iw, ih, ratio)
    let mapped = PlanarPresentation.fusedImagePixel(backing: NSPoint(x: point.x * backing, y: point.y * backing), frame: frame,
                                                    xFlipped: flipX, yFlipped: flipY, scale: zoom, rotation: rotation, origin: origin,
                                                    image: hasImage ? (width: iw, height: ih, pixelRatio: ratio) : nil)
    check("fused pixel", same(mirrored.x, mapped.x) && same(mirrored.y, mapped.y), "\(mirrored) vs \(mapped)")

    // The fusion comparison.
    let lo = coin() ? -256 : uniform(-10, 10), hi = coin() ? 256 : uniform(-10, 10), raw = coin() ? uniform(-300, 300) : pick(odd)
    check("blend", same(reference_blend(raw, lo, hi), FusionComparison.blend(value: raw, minimum: lo, maximum: hi)), "\(raw) \(lo) \(hi)")
    let stop = coin() ? uniform(0, 1) : pick(odd)
    check("slider value", same(reference_slider(stop, lo, hi), FusionComparison.sliderValue(stop: stop, minimum: lo, maximum: hi)), "\(stop) \(lo) \(hi)")
    let typed = coin() ? uniform(-100, 100) : pick(odd)
    check("offset", same(reference_offset(typed), FusionComparison.offset([typed])[0]), "\(typed)")
    let points = (0..<Int(next() % 9)).map { _ in SIMD3<Float>(Float(uniform(-400, 400)), Float(uniform(-400, 400)), Float(coin() ? uniform(-400, 400) : pick(odd))) }
    var refLo = [Double](repeating: 0, count: 3), refHi = [Double](repeating: 0, count: 3)
    reference_bounds(points.flatMap { [$0.x, $0.y, $0.z] }, points.count, &refLo, &refHi)
    let box = FusionComparison.bounds(of: points)
    check("bounds", zip(refLo + refHi, box.minimum + box.maximum).allSatisfy { same($0, $1) }, "\(refLo) \(refHi) vs \(box)")
}

enum VolumeBytes {
    /// VolumeAllocation.byteCount for one float slice, saturating.
    static func count(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let (product, overflow) = (width * height).multipliedReportingOverflow(by: 4)
        return overflow ? Int.max : product
    }
}

print(compared.keys.sorted().map { "\($0) \(compared[$0]!)" }.joined(separator: ", "))
if failures > 0 { print("FAIL: \(failures) differences"); exit(1) }
'''


def run(command, **kwargs):
    built = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if built.returncode:
        sys.stderr.write(built.stdout[-4000:] + built.stderr[-4000:])
    return built


with tempfile.TemporaryDirectory(prefix='horos-host-bridges-') as name:
    folder = Path(name)
    (folder / 'reference.h').write_text(HEADER)
    (folder / 'reference.m').write_text(reference_source)
    (folder / 'main.swift').write_text(DRIVER)
    sources = [str(ROOT / 'Modules/IsiXImaging/Sources' / path) for path in MODULE]
    # As Xcode compiles the app: clang's default contraction into fused
    # multiply-adds, and Release's optimisation for the Swift.
    if run(['xcrun', 'clang', '-fobjc-arc', '-Os', '-w', '-c', str(folder / 'reference.m'), '-o', str(folder / 'reference.o')]).returncode:
        print('FAIL: the reference bridges do not compile')
        sys.exit(1)
    if run(['xcrun', 'swiftc', '-O', '-module-name', 'Check', '-import-objc-header', str(folder / 'reference.h'), *sources,
            str(folder / 'main.swift'), str(folder / 'reference.o'), '-framework', 'AppKit', '-o', str(folder / 'check')]).returncode:
        print('FAIL: the module does not compile with the driver')
        sys.exit(1)
    seed = str(0x5EED + sum(ord(c) for c in REFERENCE))
    try:
        result = subprocess.run([str(folder / 'check'), seed], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        print('FAIL: the comparison did not finish in 120 s')
        sys.exit(1)
    sys.stdout.write(result.stdout)
    if result.returncode:
        sys.stderr.write(result.stderr[-4000:])
        print('FAIL: the module does not decide as the Objective-C bridges did (reference %s)' % REFERENCE)
        sys.exit(1)
print('PASS: the MPR, planar and fusion decisions of the bridges at %s, bit for bit, in IsiXImaging' % REFERENCE)
