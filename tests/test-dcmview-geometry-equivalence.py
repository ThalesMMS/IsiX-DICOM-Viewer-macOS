#!/usr/bin/env python3
"""The viewer's geometry arithmetic gives, bit for bit, what DCMView.m gave.

The geometry block of DCMView (intersections of planes and segments, the
rotation around an axis, the 2D segment tests, the orientation of the image as
shown, the scale that fits it, the pan given in the image's axes, the fusion's
alpha ramp) moved from DCMView.m to Swift, with its arithmetic in IsiXImaging
(ViewGeometry). Clang contracted the Objective-C's a * b + c into fused
multiply-adds and Swift never does, so the module writes those out: this
checks that it did so everywhere, on thousands of inputs, edge cases included.

The reference is that Objective-C, read from DCMView.m in the last revision
that has it (history_reference) or from the tree while it is still there,
compiled with clang as Xcode compiles it, over a stand-in of the view and of
its DCMPix; the other side is the IsiXImaging sources of the tree, compiled
with swiftc. Every result, as its bits, must be the same.

    python3 tests/test-dcmview-geometry-equivalence.py [--reference REV]
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
VIEW = 'Horos/Sources/DCMView.m'
MARK = '#define SMALL_NUM  0.00000001'
MODULE = ROOT / 'Modules/IsiXImaging/Sources/ViewGeometry'

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--reference', default=None, help='the revision whose DCMView.m is the reference')
args = parser.parse_args()


def read(revision, path):
    if revision is None:
        # DCMView.m is gone from the tree once the class is Swift.
        return (ROOT / path).read_bytes() if (ROOT / path).exists() else b''
    shown = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (revision, path)], capture_output=True)
    return shown.stdout if shown.returncode == 0 else None


tree = read(None, VIEW).decode('latin1')
reference = args.reference
if reference is None and MARK not in tree:
    # Removed in the working tree but not yet committed: HEAD still has it.
    if MARK in (read('HEAD', VIEW) or b'').decode('latin1'):
        reference = 'HEAD'
    else:
        reference = history_reference.before_text_removed(VIEW, MARK)
    if reference is None:
        print('skipped: needs the history that has the Objective-C geometry of DCMView.m (a shallow clone does not)')
        sys.exit(2)
text = tree if reference is None else (read(reference, VIEW) or b'').decode('latin1')
if MARK not in text:
    sys.exit('FAIL: %s has no Objective-C geometry in %s' % (reference, VIEW))
if not MODULE.is_dir():
    print('skipped: the tree has no IsiXImaging ViewGeometry yet')
    sys.exit(2)


def between(start, end):
    a = text.index(start)
    return text[a:text.index(end, a)]


def method(signature):
    a = text.index(signature)
    return text[a:text.index('\n}\n', a) + 3]


# The C functions, as they were; the parallel-plane test, which asks DCMView
# and the preferences, is answered by the harness.
functions = between('#define SMALL_NUM', 'NSInteger studyCompare')
parallel = ('[DCMView angleBetweenVector: Pn1 andVector:Pn2] < [[NSUserDefaults standardUserDefaults] '
            'floatForKey: @"PARALLELPLANETOLERANCE"]')
if parallel not in functions:
    sys.exit('FAIL: the parallel-plane test of intersect3D_2Planes is not the one this harness answers')
functions = functions.replace(parallel, 'RefPlanesParallel')

classes = between('+ (BOOL) intersectionBetweenTwoLinesA1:', '+ (NSString*) findWLWWPreset:').replace('DCMView', 'RefView')
orientation = method('- (void) orientationCorrectedToView:(float*) correctedOrientation')
orientation = orientation.replace('[self.curDCM orientation: o];', 'memcpy(o, pixOrientation, sizeof o);')
fit = method('- (float) scaleToFitForDCMPix: (DCMPix*) d').replace('DCMPix*', 'RefPix*')
rotated = method('-(void) setOriginWithRotationX:(float) x Y:(float) y')
alpha = method('-(void) setAlpha:(float) a')

HEADER = r'''
#import <Cocoa/Cocoa.h>
typedef struct { double x,y,z; } XYZ;
extern BOOL RefPlanesParallel;
int intersect3D_SegmentPlane(float *P0, float *P1, float *Pnormal, float *Ppoint, float *resultPt);
short intersect3D_2Planes(float *Pn1, float *Pv1, float *Pn2, float *Pv2, float *u, float *iP);
XYZ ArbitraryRotate(XYZ p, double theta, XYZ r);
BOOL lineIntersectsRect(NSPoint lineStarts, NSPoint lineEnds, NSRect rect);

@interface RefPix : NSObject
@property long pwidth, pheight;
@property BOOL shutterEnabled;
@property NSRect shutterRect;
@property double pixelRatio;
@end

@interface RefView : NSObject
{
@public
    float rotation, scaleValue;
    BOOL xFlipped, yFlipped;
    long blendingMode;
    unsigned char alphaTable[256];
    float pixOrientation[9];
    NSSize backing;
    float originX, originY;
}
+ (BOOL) intersectionBetweenTwoLinesA1:(NSPoint) a1 A2:(NSPoint) a2 B1:(NSPoint) b1 B2:(NSPoint) b2 result:(NSPoint*) r NS_SWIFT_NAME(intersection(a1:a2:b1:b2:result:));
+ (float) Magnitude:( NSPoint) Point1 :(NSPoint) Point2 NS_SWIFT_NAME(magnitude(_:_:));
+ (int) DistancePointLine: (NSPoint) Point :(NSPoint) startPoint :(NSPoint) endPoint :(float*) Distance NS_SWIFT_NAME(distancePointLine(_:_:_:_:));
- (float) rotation;
- (float) scaleValue;
- (void) setOriginX:(float) x Y:(float) y;
- (NSRect) bounds;
- (NSRect) convertRectToBacking:(NSRect) r;
- (float) scaleToFitForDCMPix: (RefPix*) d NS_SWIFT_NAME(scaleToFit(for:));
- (void) orientationCorrectedToView:(float*) correctedOrientation NS_SWIFT_NAME(orientationCorrected(toView:));
- (void) setOriginWithRotationX:(float) x Y:(float) y NS_SWIFT_NAME(setOriginWithRotation(x:y:));
- (void) setAlpha:(float) a NS_SWIFT_NAME(setAlpha(_:));
- (unsigned char *) alphaTablePointer NS_SWIFT_NAME(alphaTablePointer());
@end
'''

REFERENCE = r'''
#import "Ref.h"
static double deg2rad = M_PI / 180.0;
BOOL RefPlanesParallel = NO;

''' + functions + r'''

@implementation RefPix
@end

@implementation RefView
- (float) rotation { return rotation; }
- (float) scaleValue { return scaleValue; }
- (void) setOriginX:(float) x Y:(float) y { originX = x; originY = y; }
- (NSRect) bounds { return NSMakeRect(0, 0, backing.width, backing.height); }
- (NSRect) convertRectToBacking:(NSRect) r { return r; }
- (unsigned char *) alphaTablePointer { return alphaTable; }
''' + classes + fit + orientation + rotated + alpha + '\n@end\n'

MAIN = r'''
import Foundation

var state: UInt64 = 0x2545F4914F6CDD1D
func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 }
func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * Double(next() % 1_000_000) / 1_000_000 }
/// Values with edge cases among them: zero, integers, negatives, tiny and large ones.
func value(_ scale: Double = 100) -> Double {
    switch next() % 10 {
    case 0: return 0
    case 1: return Double(Int(next() % 21) - 10)
    case 2: return uniform(-1e-6, 1e-6)
    case 3: return uniform(-1e5, 1e5)
    default: return uniform(-scale, scale)
    }
}
func f(_ x: Float) -> String { String(x.bitPattern, radix: 16) }
func d(_ x: Double) -> String { String(x.bitPattern, radix: 16) }

var compared = 0, failures = 0
func same(_ what: String, _ a: String, _ b: String) {
    compared += 1
    if a != b {
        failures += 1
        if failures <= 20 { print("DIFFERENT \(what): reference \(a), module \(b)") }
    }
}

for i in 0..<20000 {
    // A segment and a plane.
    var p0 = (0..<3).map { _ in Float(value()) }, p1 = (0..<3).map { _ in Float(value()) }
    if i % 7 == 0 { p1 = p0 }
    var n = (0..<3).map { _ in Float(value(1)) }, pt = (0..<3).map { _ in Float(value()) }
    if i % 11 == 0 { n = [0, 0, 1]; p1[2] = p0[2] }
    var r1: [Float] = [7, 7, 7], r2: [Float] = [7, 7, 7]
    let v1 = intersect3D_SegmentPlane(&p0, &p1, &n, &pt, &r1)
    let v2 = PlaneGeometry.segmentPlane(p0, p1, normal: n, point: pt, result: &r2)
    same("segmentPlane \(i)", "\(v1) " + r1.map(f).joined(separator: " "), "\(v2) " + r2.map(f).joined(separator: " "))

    // Two planes.
    var n1 = (0..<3).map { _ in Float(value(1)) }, n2 = (0..<3).map { _ in Float(value(1)) }
    var q1 = (0..<3).map { _ in Float(value()) }, q2 = (0..<3).map { _ in Float(value()) }
    if i % 13 == 0 { n2 = n1.map { $0 * 2 } }
    var u1: [Float] = [0, 0, 0], u2: [Float] = [0, 0, 0], ip1: [Float] = [0, 0, 0], ip2: [Float] = [0, 0, 0]
    RefPlanesParallel = false
    _ = intersect3D_2Planes(&n1, &q1, &n2, &q2, &u1, &ip1)
    PlaneGeometry.twoPlanesLine(n1: n1, p1: q1, n2: n2, p2: q2, u: &u2, point: &ip2)
    same("twoPlanes \(i)", (u1 + ip1).map(f).joined(separator: " "), (u2 + ip2).map(f).joined(separator: " "))

    // A rotation around an axis.
    let p = XYZ(x: value(), y: value(), z: value()), axis = XYZ(x: value(1), y: value(1), z: value(1))
    let theta = value(7)
    let a = ArbitraryRotate(p, theta, axis)
    let b = PlaneGeometry.arbitraryRotate(SIMD3(p.x, p.y, p.z), theta: theta, axis: SIMD3(axis.x, axis.y, axis.z))
    same("arbitraryRotate \(i)", [a.x, a.y, a.z].map(d).joined(separator: " "), [b.x, b.y, b.z].map(d).joined(separator: " "))

    // 2D segments, in view coordinates: the halving of lineIntersectsRect
    // never ends (and overflows the stack, in both) on far or tiny ones.
    func screen() -> Double { i % 19 == 0 ? Double(Int(next() % 801) - 400) : uniform(-400, 400) }
    let s = CGPoint(x: screen(), y: screen()), e = i % 5 == 0 ? CGPoint(x: s.x, y: screen()) : CGPoint(x: screen(), y: screen())
    let rect = CGRect(x: screen(), y: screen(), width: abs(screen()), height: i % 17 == 0 ? 0 : abs(screen()))
    same("lineIntersectsRect \(i)", "\(lineIntersectsRect(s, e, rect))",
         "\(LineGeometry.segment(from: s, to: e, intersects: rect))")
    let c1 = CGPoint(x: value(), y: value()), c2 = CGPoint(x: value(), y: value())
    let cross: (CGPoint, CGPoint) = i % 3 == 0 ? (CGPoint(x: (s.x + e.x) / 2, y: value()), CGPoint(x: (s.x + e.x) / 2 + 1, y: value())) : (c1, c2)
    var hit = CGPoint(x: -1, y: -1)
    let yes = RefView.intersection(a1: s, a2: e, b1: cross.0, b2: cross.1, result: &hit)
    let mine = LineGeometry.intersection(a1: s, a2: e, b1: cross.0, b2: cross.1)
    same("intersection \(i)", yes ? "\(d(hit.x)) \(d(hit.y))" : "none", mine.map { "\(d($0.x)) \(d($0.y))" } ?? "none")
    same("magnitude \(i)", f(RefView.magnitude(s, e)), f(LineGeometry.magnitude(s, e)))
    var distance: Float = -1
    _ = RefView.distancePointLine(c1, s, e, &distance)
    same("distance \(i)", f(distance), f(LineGeometry.distance(from: c1, toLineFrom: s, to: e)))

    // The view: fit, orientation, rotated pan, alpha.
    let view = RefView()
    view.setRotation(Float(i % 9 == 0 ? Double(90 * (i % 4)) : value(400)))
    view.setScaleValue(Float(i % 23 == 0 ? 0 : abs(value(10))))
    view.setFlips(i % 2 == 0, i % 3 == 0)
    let pix = RefPix()
    pix.pwidth = Int(next() % 2048); pix.pheight = Int(next() % 2048)
    pix.shutterEnabled = i % 4 == 0
    pix.shutterRect = CGRect(x: value(), y: value(), width: abs(value(500)), height: abs(value(500)))
    pix.pixelRatio = i % 6 == 0 ? 1 : uniform(0.2, 3)
    let backing = CGSize(width: i % 29 == 0 ? 0 : abs(value(3000)), height: abs(value(3000)))
    view.setBacking(backing)
    let width = pix.shutterEnabled ? Double(pix.shutterRect.size.width) : Double(pix.pwidth)
    let height = pix.shutterEnabled ? Double(pix.shutterRect.size.height) : Double(pix.pheight)
    let fallback = view.scaleValue() > 0 ? view.scaleValue() : 1
    same("fitScale \(i)", f(view.scaleToFit(for: pix)),
         f(ViewTransform.fitScale(viewSize: backing, width: width, height: height, pixelRatio: pix.pixelRatio,
                                  rotation: view.rotation(), fallback: fallback)))

    var o9 = (0..<9).map { _ in Float(value(1)) }
    view.setPixOrientation(&o9)
    var corrected = [Float](repeating: 0, count: 9)
    view.orientationCorrected(toView: &corrected)
    same("orientation \(i)", corrected.map(f).joined(separator: " "),
         ViewTransform.correctedOrientation(o9, rotation: view.rotation(), xFlipped: i % 2 == 0, yFlipped: i % 3 == 0,
                                            deg2rad: Double.pi / 180.0).map(f).joined(separator: " "))

    let ox = Float(value()), oy = Float(value())
    view.setOriginWithRotation(x: ox, y: oy)
    let turned = ViewTransform.rotatedOrigin(x: ox, y: oy, rotation: view.rotation(), deg2rad: Double.pi / 180.0)
    same("rotatedOrigin \(i)", "\(f(view.originXValue())) \(f(view.originYValue()))", "\(f(turned.x)) \(f(turned.y))")

    if i < 600 {
        let mode = i % 6
        let alphaValue: Float = [-256, -100, 0, 0.5, 100, 255.5, 256, Float(value(256))][i % 8]
        view.setBlendingModeValue(mode)
        view.setAlpha(alphaValue)
        let table = Array(UnsafeBufferPointer(start: view.alphaTablePointer(), count: 256))
        same("alpha \(mode) \(alphaValue)", table.map(String.init).joined(separator: " "),
             ViewTransform.alphaTable(mode: mode, alpha: alphaValue).map(String.init).joined(separator: " "))
    }
}
print("compared \(compared), different \(failures)")
exit(failures == 0 ? 0 : 1)
'''

# What Swift needs of the stand-in beyond its former methods.
EXTRA_HEADER = r'''
@interface RefView (Harness)
- (void) setRotation:(float) r NS_SWIFT_NAME(setRotation(_:));
- (void) setScaleValue:(float) s NS_SWIFT_NAME(setScaleValue(_:));
- (void) setFlips:(BOOL) x :(BOOL) y NS_SWIFT_NAME(setFlips(_:_:));
- (void) setBacking:(NSSize) size NS_SWIFT_NAME(setBacking(_:));
- (void) setPixOrientation:(float *) o NS_SWIFT_NAME(setPixOrientation(_:));
- (void) setBlendingModeValue:(long) mode NS_SWIFT_NAME(setBlendingModeValue(_:));
- (float) originXValue;
- (float) originYValue;
@end
'''
EXTRA = r'''
@implementation RefView (Harness)
- (void) setRotation:(float) r { rotation = r; }
- (void) setScaleValue:(float) s { scaleValue = s; }
- (void) setFlips:(BOOL) x :(BOOL) y { xFlipped = x; yFlipped = y; }
- (void) setBacking:(NSSize) size { backing = size; }
- (void) setPixOrientation:(float *) o { memcpy(pixOrientation, o, sizeof pixOrientation); }
- (void) setBlendingModeValue:(long) mode { blendingMode = mode; }
- (float) originXValue { return originX; }
- (float) originYValue { return originY; }
@end
'''

with tempfile.TemporaryDirectory() as temporary:
    folder = Path(os.environ.get('GEOMETRY_HARNESS_DIR') or temporary)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'Ref.h').write_text(HEADER + EXTRA_HEADER)
    (folder / 'Ref.m').write_text(REFERENCE + EXTRA)
    built = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-w', '-I', str(folder), str(folder / 'Ref.m'),
                            '-o', str(folder / 'Ref.o')], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the reference does not compile:\n' + built.stderr[-3000:])
    (folder / 'main.swift').write_text(MAIN)
    sources = sorted(str(p) for p in MODULE.glob('*.swift'))
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-Onone', '-import-objc-header', str(folder / 'Ref.h'),
                            str(folder / 'main.swift'), *sources, str(folder / 'Ref.o'), '-framework', 'Cocoa',
                            '-o', str(folder / 'harness')], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the harness does not compile:\n' + built.stderr[-3000:])
    run = subprocess.run([str(folder / 'harness')], capture_output=True, text=True, timeout=600)
    print(run.stdout.strip())
    if run.stderr.strip():
        print(run.stderr.strip()[-2000:])
    if run.returncode:
        sys.exit('FAIL: the module differs from the Objective-C of %s (exit %d)' % (reference or 'the tree', run.returncode))
print('PASS: the geometry of IsiXImaging gives the bits of DCMView.m (%s)' % (reference or 'the tree'))
