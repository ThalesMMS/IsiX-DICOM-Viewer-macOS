#!/usr/bin/env python3
"""The planar Metal renderer draws subtraction and DICOM shutters from the host's bytes.

An image with a subtraction mask (`pix.subtractedfImage`) or a DICOM shutter
(`pix.shutterEnabled`) used to be refused by the planar snapshot, so it drew with
«Original renderer (Metal paused)». For both the host prepares 8-bit bytes the
original renderer draws: the subtraction through vImage's half-precision gamma
curve (`gamma = 2 ww/256`, `zero = 1.6 - 0.8 wl/128`, WL/WW clamped to 2...512),
the window through vImage's float-to-byte conversion, the polarity, and the
shutter's rectangle, circle and polygon masked over them with the CLUT's black
index (zero for colour, which has the rectangle only). Neither vImage rule has a
closed form (the gamma is reproducible only through a table of its own
thresholds, the conversion through none of five candidate formulas), so the
snapshot hands Metal the host's own bytes, from the `baseAddr` accessor that
brings them up to date, and Metal draws them as it draws the opacity table's.

The reference is the host's own code, the application's `DCMPix.o` linked as
`tests/test-planar-thick-slab.py` links it: subtraction at three WL/WW (one
clamped) and two percentages, shutter rectangles (rounded, clamped at the image
edge, with a black index and inverted polarity), circle and polygon, a
subtraction under a shutter, and a colour image under a rectangle. For each:

* the frame takes those bytes and nothing else: a table, a slab or a filter in
  the same snapshot is already in them and is not applied again;
* the upload and both backends' textures are the bytes; a 2x enlargement is
  `vImageScale_Planar8` of them, as the host enlarges its buffer;
* the render at every texel centre is the CLUT entry of the byte, through the
  level 0.5, width 1 read; a colour image's bytes are drawn as they are.

Also checked in the sources: the snapshot no longer refuses either mode and
hands over `pix.baseAddr`, one byte per pixel or four for colour.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import argparse
import contextlib
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('revision', nargs='?')
parser.add_argument('--case', choices=('all','snapshot'), default='all')
parser.add_argument('--benchmark', action='store_true')
parser.add_argument('--optimization', choices=('debug','release'), default='release')
parser.add_argument('--keep', type=Path)
args = parser.parse_args()
revision = args.revision


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


failures = []
# The snapshot is Swift (DCMView+PlanarSnapshot.swift); its decisions are
# IsiXImaging's PlanarPresentation, and its state DCMView+PlanarHost.swift's.
bridge = read('Horos/Sources/DCMView+PlanarSnapshot.swift')
host = read('Horos/Sources/DCMView+PlanarHost.swift')
presentation = read('Modules/IsiXImaging/Sources/ViewDrawing/PlanarPresentation.swift')
snapshot = bridge[bridge.index('private func horosPlanarSnapshot(drawnIn host: DCMView)'):]
refusal = snapshot[snapshot.index('guard let pix = view.curDCM'):snapshot.index('let bounds = host.bounds')]
for mode, key in (('a subtraction', 'subtractedfImage'), ('a DICOM shutter', 'shutterEnabled')):
    if key in refusal:
        failures.append('the planar snapshot still refuses %s' % mode)
if 'pix.baseAddr' not in snapshot or 'snapshot["hostBytes"]' not in snapshot:
    failures.append('the snapshot does not hand over the host\'s bytes')
elif '(source.colourBytes ? 4 : 1)' not in snapshot or 'let colour = isRGB || packed' not in presentation:
    failures.append('the host\'s bytes are not one byte per pixel, four for colour')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)


# Compile the host's actual snapshot acquisition function with Foundation. The
# receiver substitutes only the view shell; source bytes stay mutable/owned.
SWIFT_DRIVER = r"""
import Foundation
final class State { var scalarSnapshot: NSData? }
final class Shell {
    let planarHostState = State()
METHOD
}
func byte(_ data: NSData, _ at: Int) -> UInt8 { data.bytes.load(fromByteOffset: at, as: UInt8.self) }
let n = 2048 * 2048 * 4
let storage = NSMutableData(length: n)!
memset(storage.mutableBytes, 73, n)
let view = Shell(), other = Shell()
let first = view.planarScalarSnapshot(storage.bytes, count: n)
let again = view.planarScalarSnapshot(storage.bytes, count: n)
precondition(first.isEqual(to: again as Data) && first === again)
storage.mutableBytes.storeBytes(of: 91, toByteOffset: n - 1, as: UInt8.self)
let changed = view.planarScalarSnapshot(storage.bytes, count: n)
precondition(byte(first, n - 1) == 73 && byte(changed, n - 1) == 91)
let otherSnapshot = other.planarScalarSnapshot(storage.bytes, count: n)
precondition(changed.isEqual(to: storage as Data) && otherSnapshot.isEqual(to: storage as Data))
storage.mutableBytes.storeBytes(of: 19, toByteOffset: 0, as: UInt8.self)
let otherChanged = other.planarScalarSnapshot(storage.bytes, count: n)
precondition(byte(otherChanged, 0) == 19 && byte(changed, 0) == 73)
precondition(otherChanged !== otherSnapshot && view.planarHostState.scalarSnapshot === changed)
storage.mutableBytes.storeBytes(of: 73, toByteOffset: 0, as: UInt8.self)
precondition(view.planarScalarSnapshot(storage.bytes, count: n / 2).length == n / 2)
view.planarHostState.scalarSnapshot = nil
let fresh = view.planarScalarSnapshot(storage.bytes, count: n)
precondition(fresh.isEqual(to: changed as Data) && fresh !== changed)
var report: [String: [Double]] = [:]
for cold in [false, true] {
    var samples: [Double] = []
    for i in 0..<45 {
        autoreleasepool {
            if cold { view.planarHostState.scalarSnapshot = nil }
            let start = ProcessInfo.processInfo.systemUptime
            let pixels = view.planarScalarSnapshot(storage.bytes, count: n)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            precondition(pixels.length == n && byte(pixels, n - 1) == 91)
            if i >= 5 { samples.append(ms) }
        }
    }
    report[cold ? "cold_ms" : "unchanged_ms"] = samples
}
print(String(data: try! JSONSerialization.data(withJSONObject: report), encoding: .utf8)!)
"""

# The Swift snapshot (DCMView+PlanarSnapshot.swift): its scalar copy, compiled
# as it is over a stand-in of the view's planar state.
if args.case == 'snapshot' and 'private func planarScalarSnapshot(' in bridge:
    begin = bridge.index('    private func planarScalarSnapshot(')
    method = bridge[begin:bridge.index('\n    }\n', begin) + 6].replace('    private func', '    func', 1)
    assert 'samples = planarScalarSnapshot(pixels, count: count)' in snapshot
    for selector in ('horosInvalidatePlanar', 'horosPlanarForgetSlab'):
        begin = host.index('func ' + selector + '() {')
        assert 'state.scalarSnapshot = nil' in host[begin:host.index('\n    }', begin)], selector
    if args.keep: args.keep.mkdir(parents=True, exist_ok=True)
    with (contextlib.nullcontext(str(args.keep)) if args.keep else tempfile.TemporaryDirectory(prefix='horos-snapshot-')) as tmp:
        folder = Path(tmp)
        (folder / 'check.swift').write_text(SWIFT_DRIVER.replace('METHOD', method))
        subprocess.run(['xcrun', 'swiftc', '-Onone' if args.optimization == 'debug' else '-O',
                        *([] if args.benchmark else ['-sanitize=address']),
                        str(folder / 'check.swift'), '-o', str(folder / 'check')], check=True)
        for _ in range(2 if args.benchmark else 1): subprocess.run([str(folder / 'check')], check=True)
    raise SystemExit(0)

if args.case == 'snapshot':
    marker = 'static NSData *HorosPlanarScalarSnapshot('
    cached = marker in bridge
    assert cached or revision, 'the current host must provide scalar snapshot reuse'
    if cached:
        begin = bridge.index(marker)
        function = bridge[begin:bridge.index('\n}\n', begin)+3]
        assert 'HorosPlanarScalarSnapshot(view, pixels, count)' in snapshot
        for selector in ('horosInvalidatePlanar', 'horosPlanarForgetSlab'):
            begin = bridge.index('- (void)' + selector + ' {')
            method = bridge[begin:bridge.index('\n}', begin)]
            assert 'objc_setAssociatedObject(self, &scalarSnapshotKey, nil,' in method, selector
    else:
        assert '[NSData dataWithBytes:pixels length:count]' in snapshot
        function = 'static NSData *HorosPlanarScalarSnapshot(id view, const void *pixels, NSUInteger count) { return [NSData dataWithBytes:pixels length:count]; }'
    driver = r"""
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <assert.h>
static char scalarSnapshotKey;
FUNCTION
int main(void) { @autoreleasepool {
 const NSUInteger n=2048*2048*4;
 NSMutableData *storage=[NSMutableData dataWithLength:n];
 memset(storage.mutableBytes,73,n);
 NSObject *view=[NSObject new], *other=[NSObject new];
 NSData *first=[HorosPlanarScalarSnapshot(view,storage.bytes,n) retain];
 NSData *again=HorosPlanarScalarSnapshot(view,storage.bytes,n);
 assert([first isEqualToData:again]);
 if(CACHED) assert(first==again);
 ((char*)storage.mutableBytes)[n-1]=91;
 NSData *changed=[HorosPlanarScalarSnapshot(view,storage.bytes,n) retain];
 assert(((const char*)first.bytes)[n-1]==73 && ((const char*)changed.bytes)[n-1]==91);
 NSData *otherSnapshot=[HorosPlanarScalarSnapshot(other,storage.bytes,n) retain];
 assert([changed isEqualToData:storage] && [otherSnapshot isEqualToData:storage]);
 ((char*)storage.mutableBytes)[0]=19;
 NSData *otherChanged=HorosPlanarScalarSnapshot(other,storage.bytes,n);
 assert(((const char*)otherChanged.bytes)[0]==19 && ((const char*)changed.bytes)[0]==73);
 if(CACHED) assert(otherChanged!=otherSnapshot && objc_getAssociatedObject(view,&scalarSnapshotKey)==changed);
 ((char*)storage.mutableBytes)[0]=73;
 assert(HorosPlanarScalarSnapshot(view,storage.bytes,n/2).length==n/2);
 objc_setAssociatedObject(view,&scalarSnapshotKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 NSData *fresh=HorosPlanarScalarSnapshot(view,storage.bytes,n);
 assert([fresh isEqualToData:changed]);
 if(CACHED) assert(fresh!=changed);
 NSMutableDictionary *report=[NSMutableDictionary dictionary];
 for(int cold=0;cold<2;cold++) {
  NSMutableArray *samples=[NSMutableArray array];
  for(int i=0;i<45;i++) { @autoreleasepool {
   if(cold) objc_setAssociatedObject(view,&scalarSnapshotKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
   double start=NSProcessInfo.processInfo.systemUptime;
   NSData *pixels=HorosPlanarScalarSnapshot(view,storage.bytes,n);
   double ms=(NSProcessInfo.processInfo.systemUptime-start)*1000;
   assert(pixels.length==n && ((const char*)pixels.bytes)[n-1]==91);
   if(i>=5) [samples addObject:@(ms)];
  }}
  report[cold?@"cold_ms":@"unchanged_ms"]=samples;
 }
 puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);
 [first release];[changed release];[otherSnapshot release];[view release];[other release];
}}
""".replace('FUNCTION',function).replace('CACHED','1' if cached else '0')
    if args.keep: args.keep.mkdir(parents=True, exist_ok=True)
    with (contextlib.nullcontext(str(args.keep)) if args.keep else tempfile.TemporaryDirectory(prefix='horos-snapshot-')) as tmp:
        folder=Path(tmp)
        (folder/'check.m').write_text(driver)
        subprocess.run(['xcrun','clang','-O0' if args.optimization=='debug' else '-O2',
                        *([] if args.benchmark else ['-fsanitize=address,undefined']),
                        '-framework','Foundation',str(folder/'check.m'),'-o',str(folder/'check')],check=True)
        for _ in range(2 if args.benchmark else 1): subprocess.run([str(folder/'check')],check=True)
    raise SystemExit(0)

sys.path.insert(0, str(root / 'tests'))
import app_object_probe  # noqa: E402
import roi_harness  # noqa: E402

obj = app_object_probe.built_object('DCMPix')
if obj is None:
    print('needs a built DCMPix.o: build Debug or Release once', file=sys.stderr)
    raise SystemExit(2)

PROBE = r'''
#import <Foundation/Foundation.h>
#import "DCMPix.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
// PIX_IVARS

static const int kWidth = 41, kHeight = 37;

@interface ProbePix : DCMPix
- (void) prepare:(BOOL) colour;
- (void) window:(float) level :(float) width;
- (void) circle:(int) x :(int) y :(int) radius;
- (void) polygon:(const int*) points :(int) count;
@end
@implementation ProbePix
- (void) CheckLoad {}
- (float) minValueOfSeries { return -500; }
- (void) prepare:(BOOL) colour
{
    PIX_IVAR( self, long, width) = kWidth; PIX_IVAR( self, long, height) = kHeight; PIX_IVAR( self, BOOL, isRGB) = colour;
    PIX_IVAR( self, BOOL, thickSlabVRActivated) = NO; PIX_IVAR( self, short, stackMode) = 0; PIX_IVAR( self, short, stack) = 0;
    float *fImage = PIX_IVAR( self, float*, fImage) = (float*) calloc( kWidth * kHeight, sizeof( float));
    if( colour)
    {
        unsigned char *bytes = (unsigned char*) fImage;
        for( int i = 0; i < kWidth * kHeight * 4; i++) bytes[ i] = (unsigned char)(( i * 53 + ( i / 4) % 17 * 31) & 255);
    }
    else
        for( int y = 0; y < kHeight; y++)
            for( int x = 0; x < kWidth; x++)
                fImage[ y * kWidth + x] = sinf( x * 0.31f + y * 0.47f) * 900.f + (float)(( x * 5 + y * 7) % 13) * 7.3f + 250.f;
}
- (void) window:(float) level :(float) width_
{
    PIX_IVAR( self, float, wl) = level; PIX_IVAR( self, float, ww) = width_;
    PIX_IVAR( self, BOOL, needToCompute8bitRepresentation) = YES;
}
- (void) circle:(int) x :(int) y :(int) radius
{
    PIX_IVAR( self, NSPoint, shutterCircular) = NSMakePoint( x, y); PIX_IVAR( self, long, shutterCircular_radius) = radius;
    PIX_IVAR( self, BOOL, needToCompute8bitRepresentation) = YES;
}
- (void) polygon:(const int*) points :(int) count
{
    NSPoint *&shutterPolygonal = PIX_IVAR( self, NSPoint*, shutterPolygonal);
    if( shutterPolygonal) free( shutterPolygonal);
    shutterPolygonal = (NSPoint*) malloc( count * sizeof( NSPoint));
    for( int i = 0; i < count; i++) shutterPolygonal[ i] = NSMakePoint( points[ 2 * i], points[ 2 * i + 1]);
    PIX_IVAR( self, long, shutterPolygonalSize) = count;
    PIX_IVAR( self, BOOL, needToCompute8bitRepresentation) = YES;
}
@end

static FILE *out;
static void emit( const char *label, ProbePix *pix)
{
    [pix setNeedToCompute8bitRepresentation: YES];
    char *bytes = [pix baseAddr];
    int header[ 3] = { (int) strlen( label), [pix isRGB] ? 1 : 0, 0 };
    fwrite( header, sizeof header, 1, out);
    fwrite( label, 1, strlen( label), out);
    fwrite( bytes, 1, (size_t) kWidth * kHeight * ([pix isRGB] ? 4 : 1), out);
}

int main( int argc, char **argv) { @autoreleasepool {
    out = fopen( argv[ 1], "wb");
    if( !out) return 3;
    // Subtraction: the mask, its series-wide range, and the host's gamma of the difference.
    float *mask = (float*) calloc( kWidth * kHeight, sizeof( float));
    for( int y = 0; y < kHeight; y++)
        for( int x = 0; x < kWidth; x++)
            mask[ y * kWidth + x] = cosf( x * 0.23f - y * 0.19f) * 700.f + 180.f;
    ProbePix *sub = [[ProbePix alloc] init];
    [sub prepare: NO];
    NSPoint range = [sub subMinMax: [sub fImage] : mask];
    [sub setSubtractedfImage: mask : range];
    [sub setSubSlidersPercent: 1.0];
    [sub window: 128 : 256]; emit( "subtraction 128/256", sub);
    // WW clamped by the host to 512: gamma 4, zero 0.35.
    [sub window: 200 : 700]; emit( "subtraction 200/700, clamped", sub);
    [sub setSubSlidersPercent: 0.6];
    [sub window: 100 : 400]; emit( "subtraction 100/400 at 60 %", sub);
    // A subtraction under a shutter.
    [sub setSubSlidersPercent: 1.0];
    [sub setShutterRect: NSMakeRect( 6, 5, 27, 24)];
    [sub setShutterEnabled: YES];
    [sub window: 128 : 256]; emit( "subtraction under a shutter", sub);

    ProbePix *pix = [[ProbePix alloc] init];
    [pix prepare: NO];
    [pix window: 400 : 1200];
    [pix setShutterRect: NSMakeRect( 5.3, 4.6, 25.2, 22.7)];
    [pix setShutterEnabled: YES];
    emit( "rectangle, rounded", pix);
    [pix setShutterRect: NSMakeRect( -6, -3, 30, 50)];
    emit( "rectangle clamped at the edge", pix);
    [pix setShutterRect: NSMakeRect( 3, 2, 30, 30)];
    [pix setBlackIndex: 17];
    [pix setDisplayInverted: YES];
    emit( "rectangle, black index 17, inverted", pix);
    [pix setDisplayInverted: NO];
    [pix setBlackIndex: 0];
    [pix setShutterRect: NSMakeRect( 0, 0, kWidth, kHeight)];
    [pix circle: 20 : 18 : 13];
    emit( "circle", pix);
    [pix circle: 0 : 0 : 0];
    const int pentagon[ 10] = { 20, 2, 38, 14, 31, 34, 9, 34, 2, 14 };
    [pix polygon: pentagon : 5];
    emit( "polygon", pix);

    ProbePix *colour = [[ProbePix alloc] init];
    [colour prepare: YES];
    [colour window: 128 : 256];
    [colour setShutterRect: NSMakeRect( 7, 3, 22, 26)];
    [colour setShutterEnabled: YES];
    emit( "colour rectangle", colour);
    fclose( out);
    return 0;
}}
'''

DRIVER = r'''
import Foundation
import Metal
import Accelerate

func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { print("FAIL: " + reason()); exit(1) } }

func texture(_ image: MTLTexture, bytesPerPixel: Int) -> Data {
    var values = Data(count: image.width * image.height * bytesPerPixel)
    values.withUnsafeMutableBytes { bytes in
        image.getBytes(bytes.baseAddress!, bytesPerRow: image.width * bytesPerPixel,
                       from: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0)
    }
    return values
}

@main struct Check {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("skipped: no Metal device"); exit(2) }
        let file = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let w = 41, h = 37
        let metal = try PlanarMetalRenderer(device: device)
        let pilot = PlanarMetal4Renderer.isSupported(device) ? try PlanarMetal4Renderer(device: device) : nil
        // A CLUT whose three columns differ, so a wrong channel or index shows.
        var clut = [UInt8]()
        for i in 0..<256 { clut += [UInt8(i), UInt8(255 - i), UInt8((i * 7) % 256), 255] }
        let floats = Data(count: w * h * 4)
        let curve = (0..<4096).map { Float($0) / 4095 }.withUnsafeBytes { Data($0) }
        var cases = 0, scalarPixels = 0, colourPixels = 0
        var subtractions = [Data]()
        var offset = 0
        while offset < file.count {
            let header = file.subdata(in: offset..<offset + 12).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
            offset += 12
            let label = String(decoding: file.subdata(in: offset..<offset + Int(header[0])), as: UTF8.self)
            offset += Int(header[0])
            let colour = header[1] != 0
            let bytesPerPixel = colour ? 4 : 1
            let host = file.subdata(in: offset..<offset + w * h * bytesPerPixel); offset += w * h * bytesPerPixel
            func snapshot(scale: Int = 1) -> NSMutableDictionary {
                // Bytes the host already tabled, reduced and filtered: those keys must not apply again.
                var kernel = [Float](repeating: 1, count: 25)
                let value: NSMutableDictionary = ["width": w, "height": h, "pixels": floats, "clut": Data(clut),
                    "frameIdentity": label, "level": 400.0, "widthWindow": 1200.0, "isColor": colour,
                    "screenToPixel": [0.0, 0.0, Double(w), 0.0, 0.0, Double(h)], "viewSize": [w * scale, h * scale],
                    "softwareScale": scale, "hostBytes": host,
                    "transferFunction": curve, "transferLevel": 400.0, "transferWidth": 1200.0,
                    "convolutionSize": 3, "convolutionKernel": Data(bytes: &kernel, count: 100), "convolutionNormalization": 9.0]
                return value
            }
            let frame = try PlanarFrame(snapshot())
            expect(frame.hostBytes == host, "\(label): the frame did not take the host's bytes")
            expect(frame.transfer == nil && frame.slab == nil && frame.convolution == nil,
                   "\(label): a table, slab or filter would apply again to bytes that already carry it")
            let (uploaded, format, size) = try frame.uploadPixels(device: device)
            expect(uploaded == host && format == (colour ? .rgba8Unorm : .r8Unorm) && size == bytesPerPixel,
                   "\(label): the upload is not the host's bytes")
            try metal.update(frame)
            expect(texture(metal.image!, bytesPerPixel: bytesPerPixel) == host, "\(label): the Metal 3 texture is not the host's bytes")
            if let pilot {
                try pilot.update(frame)
                expect(texture(pilot.image!, bytesPerPixel: bytesPerPixel) == host, "\(label): the Metal 4 pilot's texture is not the host's bytes")
            }
            // Every texel centre: the CLUT entry of the byte (BGRA out).
            let picture = [UInt8](try metal.renderBGRA(width: w, height: h))
            let bytes = [UInt8](host)
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    let expected: (UInt8, UInt8, UInt8)
                    if colour {
                        // ARGB: the three channels are bytes 1...3, drawn as they are;
                        // a colour CLUT reaches them through the host's colour table.
                        let p = (y * w + x) * 4
                        expected = (bytes[p + 1], bytes[p + 2], bytes[p + 3])
                    } else {
                        let b = Int(bytes[y * w + x])
                        expected = (clut[b * 4], clut[b * 4 + 1], clut[b * 4 + 2])
                    }
                    let got = (picture[o + 2], picture[o + 1], picture[o])
                    expect(got == expected, "\(label): pixel (\(x), \(y)) draws \(got), the CLUT of the host's byte is \(expected)")
                }
            }
            // The bytes are the presentation, not a blank: the shutters against their
            // analytic shapes (the rectangle rounded and clamped as applyShutter does),
            // and the subtraction against its other windows.
            func masked(_ inside: (Int, Int) -> Bool, black: UInt8) {
                var kept = 0
                for y in 0..<h { for x in 0..<w {
                    if inside(x, y) { kept += 1; continue }
                    if colour {
                        let q = (y * w + x) * 4
                        expect(bytes[q..<q + 4].allSatisfy { $0 == 0 }, "\(label): pixel (\(x), \(y)) outside the shutter is not black")
                    } else {
                        expect(bytes[y * w + x] == black, "\(label): pixel (\(x), \(y)) outside the shutter is \(bytes[y * w + x]), not \(black)")
                    }
                } }
                expect(kept > 0 && Set(bytes).count > 8, "\(label): nothing of the image is left inside the shutter")
            }
            let rectangle = { (x0: Int, y0: Int, x1: Int, y1: Int) in { (x: Int, y: Int) in x >= x0 && x < x1 && y >= y0 && y < y1 } }
            switch label {
            case "rectangle, rounded": masked(rectangle(5, 5, 30, 28), black: 0)
            case "rectangle clamped at the edge": masked(rectangle(0, 0, 24, 37), black: 0)
            case "rectangle, black index 17, inverted": masked(rectangle(3, 2, 33, 32), black: 17)
            case "subtraction under a shutter": masked(rectangle(6, 5, 33, 29), black: 0)
            case "colour rectangle": masked(rectangle(7, 3, 29, 29), black: 0)
            case "circle": masked({ x, y in (x - 20) * (x - 20) + (y - 18) * (y - 18) <= 13 * 13 + 13 }, black: 0)
            case "polygon":
                expect(bytes[18 * w + 20] != 0 && bytes[0] == 0 && bytes[36 * w + 40] == 0 && bytes[36 * w + 0] == 0,
                       "\(label): the pentagon did not keep its centre and black the corners")
            default:
                expect(Set(bytes).count > 32, "\(label): the subtraction is nearly constant")
                subtractions.append(host)
            }
            if colour { colourPixels += w * h } else { scalarPixels += w * h }
            if !colour {
                let bigger = try PlanarFrame(snapshot(scale: 2)).uploadPixels(device: device).pixels
                var input = host, reference = Data(count: w * h * 4)
                let status = reference.withUnsafeMutableBytes { destination in
                    input.withUnsafeMutableBytes { source in
                        var from = vImage_Buffer(data: source.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                        var to = vImage_Buffer(data: destination.baseAddress!, height: vImagePixelCount(h * 2), width: vImagePixelCount(w * 2), rowBytes: w * 2)
                        return vImageScale_Planar8(&from, &to, nil, vImage_Flags(kvImageNoFlags))
                    }
                }
                expect(status == kvImageNoError && bigger == reference, "\(label): the 2x enlargement is not vImageScale_Planar8 of the host's bytes")
            }
            cases += 1
        }
        expect(cases == 10, "only \(cases) cases were read")
        expect(subtractions.count == 3 && Set(subtractions).count == 3, "the three subtraction windows gave the same bytes")
        print("PASS: \(cases) host presentations (subtraction at three windows and two percentages, rectangle, circle and polygon shutters, black index and polarity, colour) through the frame, the upload, the Metal 3 texture\(pilot == nil ? "" : " and the Metal 4 pilot's"), the 2x enlargement and every texel centre of the render: \(scalarPixels) scalar and \(colourPixels) colour pixels the CLUT of the host's bytes")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-planar-host-presentation-') as name:
    directory = Path(name)
    (directory / 'probe.mm').write_text(PROBE.replace('// PIX_IVARS\n', roi_harness.PIX_IVARS))
    try:
        run = app_object_probe.link_and_run(directory, [directory / 'probe.mm'], [obj], [directory / 'presentations.bin'],
                                            always_stub=('ROI',))
    except subprocess.TimeoutExpired:
        print('FAIL: the host probe did not finish in 120 s')
        raise SystemExit(1)
    if run.returncode:
        sys.stderr.write(run.stderr)
        print('FAIL: the host probe did not produce the presentations (exit %d)' % run.returncode)
        raise SystemExit(1)

    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'MPRMetalReslicer.swift', 'MetalPerformanceTrace.swift',
               'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift', 'PlanarMetalRenderer.swift',
               'PlanarMetal4Renderer.swift']
    for source in sources:
        (directory / source).write_text(read('Horos/Sources/' + source))
    (directory / 'Check.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-suppress-warnings',
                            *[str(directory / source) for source in sources], str(directory / 'Check.swift'),
                            '-o', str(directory / 'check')])
    if build.returncode:
        print('FAIL: the planar renderer does not build with the host-presentation driver')
        raise SystemExit(1)
    result = subprocess.run([str(directory / 'check'), str(directory / 'presentations.bin')], timeout=300)
    raise SystemExit(result.returncode)
