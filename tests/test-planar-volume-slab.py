#!/usr/bin/env python3
"""The planar Metal renderer composes the volume-rendering thick slab.

A 2D viewer's thick slab in modes 4 and 5 was refused by the planar snapshot
and drew with «Original renderer (Metal paused)». -[DCMPix computeThickSlab]
hands the slab's slices to -[ThickSlabVR renderSlab], which no longer calls VTK:
it windows every slice to bytes with vImageConvert_PlanarFtoPlanar8, and each
pixel adds, front to back, the opacity table's value of its byte, clipped to
what is left of 1, and that opacity times the colour tables' values. The sums
become bytes by the same vImage call, under an opaque alpha. Mode 4 composes the
slices in memory order, mode 5 reversed. Metal now runs that composite:
PlanarVolumeSlabPass, with vImage for the two conversions, which have no closed
form, and the kernel for the loop. The snapshot asks for it through
HorosPlanarThickSlab and keeps it with the image, as the host keeps its
composite, until the slices, the window or the tables change; it is drawn as
colour bytes whose alpha is their own.

The reference is the host's own code: the ThickSlabVR methods setImageData,
setImageSource, setWLWW, subRender and renderSlab, and computeThickSlab's
case 4 and 5, are cut out of ThickSlabVR.mm and DCMPix.m, compiled into a small
class with the same instance variables, in Debug (-O0, under AddressSanitizer)
and with Release's -ffast-math -O3, the thread count fixed so that the result
does not depend on the machine. A 64 x 48 series runs on 4 threads; a 37 x 23
one, 851 pixels, on 7: the host composes four pixels a step, and its ranges,
not multiples of four, read and wrote past its buffers - the original renderer
crashed in the allocator - until they were aligned, with the remainder composed
a pixel at a time. Over slabs in both modes and directions, cut at
either end of the series, windowed, inverted, fixed and saturated, Metal's
bytes must equal the host's bit for bit, as must the Metal 4 pilot's, a 2x
enlargement must be vImageScale_ARGB8888 of the host's bytes, and fused over
another series the composite, whose alpha is opaque, must cover it.

Also checked in the sources: the snapshot no longer refuses modes 4 and 5,
composes the slices by PlanarThickSlab's rule with ThickSlabVR's tables, and
keys the composite it keeps on all of them.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


failures = []
# The snapshot is Swift (DCMView+PlanarSnapshot.swift); its decisions are
# IsiXImaging's PlanarPresentation.
bridge = read('Horos/Sources/DCMView+PlanarSnapshot.swift')
presentation = read('Modules/IsiXImaging/Sources/ViewDrawing/PlanarPresentation.swift')
renderer = read('Horos/Sources/PlanarMetalRenderer.swift')
try:
    vr = read('Horos/Sources/ThickSlabVR.mm')
    swift_slab = None
except (OSError, subprocess.CalledProcessError):
    # ThickSlabVR is Swift, its composite IsiXVolumeRendering's ThickSlabComposer,
    # which tests/test-thick-slab-equivalence.py finds bit for bit ThickSlabVR.mm's:
    # the host's rule is cut from the last revision that has the Objective-C++.
    sys.path.insert(0, str(root / 'tests'))
    import history_reference
    host_revision = history_reference.before_removal('Horos/Sources/ThickSlabVR.mm')
    if host_revision is None and subprocess.run(['git', '-C', str(root), 'cat-file', '-e', 'HEAD:Horos/Sources/ThickSlabVR.mm'],
                                                capture_output=True).returncode == 0:
        host_revision = 'HEAD'
    if host_revision is None:
        print('skipped: no revision of this history has ThickSlabVR.mm', file=sys.stderr)
        raise SystemExit(2)
    vr = history_reference.show(host_revision, 'Horos/Sources/ThickSlabVR.mm').decode('latin1')
    swift_slab = read('Horos/Sources/ThickSlabVR.swift')
try:
    pix = read('Horos/Sources/DCMPix.m')
except (OSError, subprocess.CalledProcessError):
    pix = ''  # DCMPix is Swift
snapshot = bridge[bridge.index('private func horosPlanarSnapshot(drawnIn host: DCMView)'):]
refusal = snapshot[snapshot.index('guard let pix = view.curDCM'):snapshot.index('let bounds = host.bounds')]
if 'thickSlabVRActivated' in refusal or 'stackMode > 3' in refusal or 'mode <= 3' in presentation:
    failures.append('the snapshot still refuses the volume-rendering slab')
if 'volumeSlab = !colour && (stackMode == 4 || stackMode == 5) && stack >= 1 && seriesCount > 1' not in presentation \
        or 'PlanarThickSlab.volumeSliceIndices(position: pix.pixPos' not in snapshot \
        or 'let thickSlab = pix.horosPlanarThickSlab()' not in snapshot or 'thickSlab?.compositeTables' not in snapshot \
        or 'memoryOrder: thickSlab?.composesInMemoryOrder ?? false' not in snapshot \
        or 'PlanarThickSlab.volumeComposite(slices: stacked' not in snapshot:
    failures.append('the snapshot does not compose the slab\'s slices, in the host\'s order, with ThickSlabVR\'s tables')
kept = re.search(r'var key = String\(format: "%ld/%ld/%ld/%ld/%a/%a", session\?\.sessionID \?\? 0, session\?\.identity\.generation \?\? 0,\s*'
                 r'width, height, Double\(window\.level\), Double\(window\.width\)\).*?'
                 r'key \+= Self\.address\(slice, samples\).*?kept\.key == key, kept\.tables == tables', snapshot, re.S)
if not kept:
    failures.append('the composite kept with the image is not keyed on its slices, window and tables')
if 'final class PlanarVolumeSlabPass' not in renderer or 'func volumeComposite(' not in renderer:
    failures.append('the renderer does not compose the volume-rendering slab')
if (swift_slab is None and '-(NSData*) compositeTables' not in vr) or \
        (swift_slab is not None and '@objc public func compositeTables() -> Data' not in swift_slab):
    failures.append('ThickSlabVR does not give its tables')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)


def method(source, signature):
    """The body of the Objective-C method whose declaration starts `signature`."""
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for position in range(opening, len(source)):
        depth += {'{': 1, '}': -1}.get(source[position], 0)
        if depth == 0:
            return source[start:position + 1]
    raise ValueError(signature)


methods = [method(vr, sig) for sig in ('-(void) setImageData:(long) w', '-(void) setImageSource: (float*) i',
                                       '-(void) setWLWW: (float) l', '-(void) subRender:(NSDictionary*) dict',
                                       '-(unsigned char*) renderSlab')]
methods = [m.replace('[[NSProcessInfo processInfo] processorCount]', 'kThreads') for m in methods]
case = re.search(r'case 4:\s*// Volume Rendering\s*case 5:\s*// Volume Rendering\s*(if\( thickSlab\).*?)\s*break;', pix, re.S)
if case:
    case = case.group(1)
elif '- (float*) computeThickSlab' not in pix:
    # The case is DCMPix+DisplaySource.swift's, which hands the slab to the
    # controller through HorosDCMPixRenderThickSlab (DCMPix+CAPI.m), or through
    # -horos_renderThickSlabFrom:count:level:width: (DCMPix+SwiftIvars.m) while
    # the class was Objective-C. As long as both say what the Objective-C did,
    # the same steps run here in Objective-C.
    source = read('Horos/Sources/DCMPix+DisplaySource.swift')
    swift_class = '- (void) horos_renderThickSlab' not in source and 'HorosDCMPixRenderThickSlab(' in source
    helper = read('Horos/Sources/DCMPix+CAPI.m' if swift_class else 'Horos/Sources/DCMPix+SwiftIvars.m')
    swift_case = source[source.index('case 4, 5:'):source.index('case 1, 2, 3:')]
    expected = ['stackSize = position - stack < 0 ? position + 1 : stack + 1',
                'stackSize = position + stack < count ? stack : count - position',
                'stackDirection != 0 ? horos_fImage.map { $0 - (stackSize - 1) * height * width } : horos_fImage',
                'HorosDCMPixRenderThickSlab(horos_thickSlab, source, stackSize, iwl, displayInverted ? -iww : iww)' if swift_class else
                'horos_renderThickSlab(from: source, count: stackSize, level: iwl, width: displayInverted ? -iww : iww)',
                'horos_thickSlabVRActivated = true', 'baseAddr = rgba']
    slab = 'slab' if swift_class else 'thickSlab'
    steps = ['[%s setImageSource: source :count];' % slab, '[%s setWLWW: level :width];' % slab, 'return [%s renderSlab];' % slab]
    if any(e not in swift_case for e in expected) or any(s not in helper for s in steps):
        print('FAIL: computeThickSlab no longer has the volume-rendering case this test cuts out')
        raise SystemExit(1)
    case = '''if( thickSlab)
            {
                if( stackDirection)
                    stacksize = pixPos-stack < 0 ? pixPos+1 : stack+1;
                else
                    stacksize = pixPos+stack < (long) [pixArray count] ? stack : [pixArray count] - pixPos;
                float *source = stackDirection ? fImage - (stacksize-1)*height * width : fImage;
                [thickSlab setImageSource: source :stacksize];
                [thickSlab setWLWW: iwl: self.displayInverted ? -iww : iww];
                rgbaImage = [thickSlab renderSlab];
                thickSlabVRActivated = YES;
                [self setBaseAddr: (char*) rgbaImage];
            }'''
else:
    print('FAIL: computeThickSlab no longer has the volume-rendering case this test cuts out')
    raise SystemExit(1)

HOST = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const long kThreads = THREADS;

@interface ThickSlabVR : NSObject {
@public
    float *imageBlendingPtr, *imagePtr;
    long width, height, count;
    float spaceX, spaceY, thickness, ww, wl;
    BOOL flipData, lowQuality;
    float tableFloatR[256], tableFloatG[256], tableFloatB[256];
    float tableBlendingFloatR[256], tableBlendingFloatG[256], tableBlendingFloatB[256];
    float opacityTable[256];
    void *flipReader;
    vImage_Buffer srcf, dst8, srcfBlending, dst8Blending;
    float *dstFloatR, *dstFloatG, *dstFloatB;
    long ifrom, ito, isize;
    BOOL isRGB;
    NSLock *processorsLock;
    volatile int numberOfThreadsForCompute;
}
@end
@implementation ThickSlabVR
METHODS
@end

@interface Pix : NSObject {
@public
    long stackMode, stack, stackDirection, pixPos, height, width;
    NSArray *pixArray;
    float *fImage;
    ThickSlabVR *thickSlab;
    BOOL thickSlabVRActivated, inverted;
    unsigned char *base;
}
@end
@implementation Pix
- (BOOL)displayInverted { return inverted; }
- (void)setBaseAddr:(char *)p { base = (unsigned char *)p; }
- (void)composeWithLevel:(float)iwl width:(float)iww {
    long stacksize;
    unsigned char *rgbaImage;
    CASE
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        FILE *in = fopen(argv[1], "rb"), *cases = fopen(argv[2], "rb"), *out = fopen(argv[3], "wb");
        int header[3]; fread(header, 4, 3, in);
        long w = header[0], h = header[1], n = header[2];
        float *volume = malloc(w * h * n * 4); fread(volume, 4, w * h * n, in);
        float tables[1024]; fread(tables, 4, 1024, in);
        ThickSlabVR *slab = [[ThickSlabVR alloc] init];
        memcpy(slab->opacityTable, tables, 1024); memcpy(slab->tableFloatR, tables + 256, 1024);
        memcpy(slab->tableFloatG, tables + 512, 1024); memcpy(slab->tableFloatB, tables + 768, 1024);
        [slab setImageData:w :h :100 :1 :1 :1 :YES];
        NSMutableArray *series = [NSMutableArray array];
        for (long i = 0; i < n; i++) [series addObject:[NSNull null]];
        int c[5]; float window[2];
        while (fread(c, 4, 5, cases) == 5 && fread(window, 4, 2, cases) == 2) {
            // mode, position, stack, direction, inverted; level, width
            slab->flipData = c[0] == 4;
            Pix *pix = [[Pix alloc] init];
            pix->stackMode = c[0]; pix->pixPos = c[1]; pix->stack = c[2]; pix->stackDirection = c[3]; pix->inverted = c[4];
            pix->width = w; pix->height = h; pix->pixArray = series; pix->fImage = volume + c[1] * w * h; pix->thickSlab = slab;
            [pix composeWithLevel:window[0] width:window[1]];
            fwrite(pix->base, 1, w * h * 4, out);
            free(pix->base);
        }
        fclose(out);
    }
    return 0;
}
'''.replace('METHODS', '\n'.join(methods)).replace('CASE', case)

DRIVER = r'''
import Foundation
import Metal
import Accelerate

func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { print("FAIL: " + reason()); exit(1) } }
func texture(_ image: MTLTexture) -> [UInt8] {
    var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
    image.getBytes(&values, bytesPerRow: image.width * 4, from: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0)
    return values
}

@main struct Check {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("skipped: no Metal device"); exit(2) }
        let arguments = CommandLine.arguments
        let input = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let cases = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let metal = try PlanarMetalRenderer(device: device)
        let pilot = PlanarMetal4Renderer.isSupported(device) ? try PlanarMetal4Renderer(device: device) : nil
        let ints = input.withUnsafeBytes { Array($0.bindMemory(to: Int32.self).prefix(3)) }
        let w = Int(ints[0]), h = Int(ints[1]), n = Int(ints[2]), slice = w * h * 4
        let volume = input.subdata(in: 12..<(12 + n * slice)), tables = input.subdata(in: (12 + n * slice)..<(12 + n * slice + 4096))
        var table = [UInt8](); for i in 0..<256 { table += [UInt8(i), UInt8(i), UInt8(i), 255] }
        var hosts = [[UInt8]]()
        for name in arguments[3...] { hosts.append([UInt8](try Data(contentsOf: URL(fileURLWithPath: name)))) }
        let count = cases.count / 28
        var compared = 0
        for index in 0..<count {
            let fields = cases.subdata(in: (index * 28)..<(index * 28 + 28))
            let c = fields.withUnsafeBytes { Array($0.bindMemory(to: Int32.self).prefix(5)) }
            let window = fields.withUnsafeBytes { Array($0.bindMemory(to: Float.self).suffix(2)) }
            let mode = Int(c[0]), position = Int(c[1]), stack = Int(c[2]), direction = Int(c[3]), inverted = c[4] != 0
            let indices = PlanarThickSlab.volumeSliceIndices(position: position, stack: stack, direction: direction,
                                                            count: n, memoryOrder: mode == 4).map { $0.intValue }
            var slices = Data()
            for i in indices { slices.append(volume.subdata(in: (i * slice)..<((i + 1) * slice))) }
            guard let composite = PlanarThickSlab.volumeComposite(slices: slices, count: indices.count, width: w, height: h,
                level: window[0], windowWidth: inverted ? -window[1] : window[1], tables: tables) else {
                print("FAIL: case \(index): the slab was not composed"); exit(1)
            }
            // As the snapshot hands it over.
            func layer(scale: Int) -> NSDictionary {
                ["width": w, "height": h, "isColor": true, "pixels": composite, "hostBytes": composite, "bytesCarryAlpha": true,
                    "clut": Data(table), "frameIdentity": "slab \(index)", "level": 40.0, "widthWindow": 400.0,
                    "screenToPixel": [0.0, 0.0, Double(w), 0.0, 0.0, Double(h)], "viewSize": [w, h], "softwareScale": scale,
                    "nearest": false] as NSDictionary
            }
            func frame(scale: Int) throws -> PlanarFrame { try PlanarFrame(layer(scale: scale)) }
            let plain = try frame(scale: 1)
            expect(plain.window.z == 2 && plain.colourTable == nil, "case \(index): the composite is not drawn as untabled colour bytes")
            try metal.update(plain)
            let drawn = texture(metal.image!)
            for (build, host) in hosts.enumerated() {
                let expected = Array(host[(index * slice)..<((index + 1) * slice)])
                let differing = zip(drawn, expected).filter { $0 != $1 }.count
                expect(differing == 0, "case \(index) (mode \(mode), position \(position), stack \(stack), direction \(direction)): \(differing) bytes differ from the host's composite, build \(build)")
            }
            if let pilot { try pilot.update(plain); expect(texture(pilot.image!) == drawn, "case \(index): the Metal 4 pilot differs") }
            // Fused over another series, the composite's opaque alpha covers it,
            // as loadTextureIn: lays no table over it and drawRect: blends it
            // source-alpha over the image.
            let alone = [UInt8](try metal.renderBGRA(width: w, height: h))
            let under: NSMutableDictionary = ["width": w, "height": h, "isColor": false, "pixels": Data(count: slice),
                "clut": Data(table), "frameIdentity": "under", "level": 40.0, "widthWindow": 400.0,
                "screenToPixel": [0.0, 0.0, Double(w), 0.0, 0.0, Double(h)], "viewSize": [w, h], "softwareScale": 1, "nearest": false]
            under["fusion"] = layer(scale: 1)
            let fused = try PlanarFrame(under)
            expect(fused.fusion.first?.bytesCarryAlpha == true, "case \(index): a fused volume-rendering slab is not drawn")
            try metal.update(fused)
            expect([UInt8](try metal.renderBGRA(width: w, height: h)) == alone, "case \(index): the fused composite does not cover the image")
            try metal.update(plain)
            let big = try frame(scale: 2)
            try metal.update(big)
            let enlarged = [UInt8](try PlanarFrame.enlargeARGB(bytes: Data(hosts[0][(index * slice)..<((index + 1) * slice)]), width: w, height: h, scale: 2))
            expect(texture(metal.image!) == enlarged, "case \(index): the 2x texture is not vImageScale_ARGB8888 of the host's composite")
            compared += w * h
        }
        print("PASS: \(w) x \(h), \(count) volume-rendering slabs, \(compared) pixels, equal to ThickSlabVR's composite bit for bit in its Debug and Release builds\(pilot == nil ? "" : " and in the Metal 4 pilot"); 2x enlargements equal vImageScale_ARGB8888 of the host's bytes")
    }
}
'''

def dataset(w, h, n):
    volume = []
    for s in range(n):
        for i in range(w * h):
            value = ((i * 2654435761 + s * 40503) % 2600) - 700 + (i % 5) * 0.25
            if i % 97 == 0: value = -200.0          # the window's edges, exactly
            if i % 89 == 0: value = 600.0
            volume.append(float(value))
    return volume


opacity = []
for i in range(256):
    if i < 20: opacity.append(0.0)
    elif i % 50 == 0: opacity.append(1.0)       # saturates at once
    elif i % 31 == 0: opacity.append(0.5)       # halves, clipped exactly
    else: opacity.append((i / 255.0) ** 2 * 0.35)
tables = opacity + [float(i) for i in range(256)] + [float(255 - i) for i in range(256)] + [float((i * 7) % 256) for i in range(256)]
cases = [  # mode, position, stack, direction, inverted, level, width
    (4, 3, 5, 0, 0, 200.0, 800.0), (5, 3, 5, 0, 0, 200.0, 800.0),
    (4, 10, 4, 1, 0, 200.0, 800.0), (5, 10, 4, 1, 0, 200.0, 800.0),
    (4, 2, 6, 1, 0, 200.0, 800.0), (5, 14, 6, 0, 0, 200.0, 800.0),
    (4, 8, 7, 0, 1, 350.0, 1500.0), (5, 8, 7, 1, 1, 350.0, 1500.0),
    (4, 5, 9, 0, 0, 127.0, 256.0), (5, 12, 3, 1, 0, 100.0, 60.0),
    (4, 7, 1, 0, 0, 200.0, 800.0), (4, 7, 1, 1, 0, 200.0, 800.0),
]

with tempfile.TemporaryDirectory(prefix='horos-planar-volume-slab-') as name:
    directory = Path(name)
    (directory / 'cases.bin').write_bytes(b''.join(struct.pack('<5i2f', m, p, st, d, inv, lv, wd)
                                                   for m, p, st, d, inv, lv, wd in cases))
    (directory / 'host.m').write_text(HOST)
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
        print('FAIL: the planar renderer does not build with the volume-slab driver')
        raise SystemExit(1)
    for w, h, threads in ((64, 48, 4), (37, 23, 7)):
        n = 16
        volume = dataset(w, h, n)
        data = directory / ('input-%dx%d.bin' % (w, h))
        data.write_bytes(struct.pack('<3i', w, h, n) + struct.pack('<%df' % len(volume), *volume)
                         + struct.pack('<1024f', *tables))
        outputs = []
        for label, flags in (('debug', ['-O0', '-g', '-fsanitize=address']), ('release', ['-O3', '-ffast-math'])):
            binary = directory / ('host-%s-%d' % (label, threads))
            build = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-w', '-DTHREADS=%d' % threads, *flags,
                                    str(directory / 'host.m'), '-framework', 'Foundation', '-framework', 'Accelerate',
                                    '-o', str(binary)])
            if build.returncode:
                print('FAIL: ThickSlabVR\'s composite does not build out of its sources')
                raise SystemExit(1)
            output = directory / ('host-%s-%dx%d.bin' % (label, w, h))
            run = subprocess.run([str(binary), str(data), str(directory / 'cases.bin'), str(output)],
                                 capture_output=True, text=True, timeout=300)
            if run.returncode:
                print(run.stderr[-3000:])
                print('FAIL: ThickSlabVR\'s composite, %s, %d x %d on %d threads, stopped (%d)' % (label, w, h, threads, run.returncode))
                raise SystemExit(1)
            outputs.append(str(output))
        result = subprocess.run([str(directory / 'check'), str(data), str(directory / 'cases.bin'), *outputs], timeout=300)
        if result.returncode:
            raise SystemExit(result.returncode)
