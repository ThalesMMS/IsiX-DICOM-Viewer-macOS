#!/usr/bin/env python3
"""IsiXVolumeRendering's ThickSlabComposer composes what ThickSlabVR.mm composed.

-[DCMPix computeThickSlab] hands a 2D viewer's volume-rendering slab (modes 4
and 5) to ThickSlabVR: the slices windowed to bytes, reversed unless the stack
is flipped, then front to back each pixel adds the opacity table's value of its
byte, clipped to what is left of 1, and that opacity times the colour tables'
values; a fused series adds its own colours under the same opacity. ThickSlabVR
is Swift now and the composite is ThickSlabComposer, in the module.

The reference is ThickSlabVR.mm from the last revision that has it, read from
git: the methods that compose (setImageData, setImageSource,
setImageBlendingSource, setWLWW, setBlendingWLWW, setCLUT, setBlendingCLUT,
compositeTables, subRender, renderSlab) cut out into a class with its instance
variables, against the module's sources. Both get the same generated series,
colour and opacity tables, and run the same cases (slabs of every thickness up
to the series, at its start, middle and end, flipped or not, windowed narrow,
wide and inverted, grey or coloured, fused or not, on 4 and on 7 workers, a
size that is not a multiple of four); the composite's bytes and the tables must
be the same, in Debug (-O0 / -Onone, under AddressSanitizer) and Release (-Os
/ -O). The opacity table comes from VTK in the app: that part is the VTK
adapter's test. Exits 2 when the history does not reach a revision with
ThickSlabVR.mm.

    python3 tests/test-thick-slab-equivalence.py
"""
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SLAB = 'Horos/Sources/ThickSlabVR.mm'
MODULE = ROOT / 'Modules/IsiXVolumeRendering/Sources'

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    raise SystemExit(2)
reference = history_reference.before_removal(SLAB)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', f'HEAD:{SLAB}'],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: no revision of this history has ' + SLAB, file=sys.stderr)
    raise SystemExit(2)
old = history_reference.show(reference, SLAB).decode('latin1')


def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for position in range(opening, len(source)):
        depth += {'{': 1, '}': -1}.get(source[position], 0)
        if depth == 0:
            return source[start:position + 1]
    raise ValueError(signature)


SIGNATURES = ['-(void) setImageBlendingSource: (float*) i', '-(void) setImageSource: (float*) i :(long) c',
              '-(void) setImageData:(long) w', '-(void) setWLWW: (float) l', '-(void) setBlendingWLWW: (float) l',
              '-(void) setBlendingCLUT:( unsigned char*) r', '-(void) setCLUT:( unsigned char*) r',
              '-(NSData*) compositeTables', '-(void) subRender:(NSDictionary*) dict', '-(unsigned char*) renderSlab']
methods = '\n'.join(method(old, s) for s in SIGNATURES).replace('[[NSProcessInfo processInfo] processorCount]', 'kThreads')

# --- the series, the tables and the cases ----------------------------------------------
rng = random.Random(1491)
W, H, N = 37, 23, 24          # 851 pixels a slice: not a multiple of four
volume = [rng.choice([-1000.0, 0.0, 40.0, 300.0, 1200.0]) + rng.uniform(-30, 30) for _ in range(W * H * N)]
fused = [rng.uniform(0, 5000) for _ in range(W * H * N)]
ramp = lambda f: bytes(max(0, min(255, int(f(i)))) for i in range(256))
clut = ramp(lambda i: i * 1.3), ramp(lambda i: 255 - i), ramp(lambda i: (i * 7) % 256)
fused_clut = ramp(lambda i: 255 if i > 128 else 0), ramp(lambda i: i), ramp(lambda i: 64)
opacity = [0.0] * 40 + [min(1.0, (i - 40) / 120.0) ** 1.5 for i in range(40, 256)]
opacity[200:210] = [1.0] * 10      # saturates: a pixel stops early

cases = []
for threads in (4, 7):
    for start, count in ((0, 1), (0, 2), (0, 5), (3, 8), (10, 14), (20, 4), (0, N)):
        for flip in (0, 1):
            for level, width in ((40.0, 400.0), (300.0, 50.0), (0.0, 3000.0), (200.0, -600.0)):
                for coloured in (0, 1):
                    cases.append((threads, start, count, flip, coloured, 0, level, width, 0.0, 0.0))
    for start, count in ((0, 3), (5, 12)):
        for flip in (0, 1):
            cases.append((threads, start, count, flip, 1, 1, 40.0, 400.0, 2500.0, 5000.0))
            cases.append((threads, start, count, flip, 0, 1, 300.0, -200.0, 1000.0, 300.0))

HOST = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static long kThreads = 4;

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

int main(int argc, char **argv) {
    @autoreleasepool {
        FILE *in = fopen(argv[1], "rb"), *cases = fopen(argv[2], "rb"), *out = fopen(argv[3], "wb");
        int header[3]; fread(header, 4, 3, in);
        long w = header[0], h = header[1], n = header[2];
        float *volume = malloc(w * h * n * 4), *fused = malloc(w * h * n * 4);
        fread(volume, 4, w * h * n, in); fread(fused, 4, w * h * n, in);
        unsigned char luts[6][256]; fread(luts, 1, sizeof luts, in);
        float opacity[256]; fread(opacity, 4, 256, in);
        ThickSlabVR *shared = nil;
        int c[6]; float f[4];
        while (fread(c, 4, 6, cases) == 6 && fread(f, 4, 4, cases) == 4) {
            // threads, start, count, flip, coloured, fused; level, width, fused level, fused width
            kThreads = c[0];
            ThickSlabVR *slab = c[5] ? [[ThickSlabVR alloc] init] : (shared ?: (shared = [[ThickSlabVR alloc] init]));
            [slab setImageData:w :h :100 :1 :1 :1 :c[3]];
            if (c[4]) [slab setCLUT:luts[0] :luts[1] :luts[2]]; else [slab setCLUT:nil :nil :nil];
            memcpy(slab->opacityTable, opacity, sizeof opacity);
            [slab setImageSource:volume + c[1] * w * h :c[2]];
            if (c[5]) {
                [slab setImageBlendingSource:fused + c[1] * w * h];
                [slab setBlendingCLUT:luts[3] :luts[4] :luts[5]];
            }
            [slab setWLWW:f[0] :f[1]];
            if (c[5]) [slab setBlendingWLWW:f[2] :f[3]];
            unsigned char *argb = [slab renderSlab];
            fwrite(argb, 1, w * h * 4, out);
            free(argb);
            NSData *tables = [slab compositeTables];
            fwrite(tables.bytes, 1, tables.length, out);
        }
        fclose(out);
    }
    return 0;
}
'''.replace('METHODS', methods)

DRIVER = r'''
import Foundation

let arguments = CommandLine.arguments
let input = try! Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let cases = try! Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let header = input.withUnsafeBytes { Array($0.bindMemory(to: Int32.self).prefix(3)) }
let (w, h, n) = (Int(header[0]), Int(header[1]), Int(header[2]))
let volume = UnsafeMutablePointer<Float>.allocate(capacity: w * h * n)
let fused = UnsafeMutablePointer<Float>.allocate(capacity: w * h * n)
let luts = UnsafeMutablePointer<UInt8>.allocate(capacity: 6 * 256)
var opacity = [Float](repeating: 0, count: 256)
input.withUnsafeBytes { raw in
    let base = raw.baseAddress! + 12
    memcpy(volume, base, w * h * n * 4)
    memcpy(fused, base + w * h * n * 4, w * h * n * 4)
    memcpy(luts, base + 2 * w * h * n * 4, 6 * 256)
    _ = opacity.withUnsafeMutableBytes { memcpy($0.baseAddress!, base + 2 * w * h * n * 4 + 6 * 256, 1024) }
}
var output = Data()
var shared: ThickSlabComposer?
var at = 0
while at + 40 <= cases.count {
    let c = cases.subdata(in: at..<(at + 24)).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    let f = cases.subdata(in: (at + 24)..<(at + 40)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    at += 40
    let slab: ThickSlabComposer
    if c[5] != 0 { slab = ThickSlabComposer() } else { if shared == nil { shared = ThickSlabComposer() }; slab = shared! }
    slab.threadCount = Int(c[0])
    slab.setImageData(w, h, 100, 1, 1, 1, c[3] != 0)
    if c[4] != 0 { slab.setCLUT(luts, luts + 256, luts + 512) } else { slab.setCLUT(nil, nil, nil) }
    slab.setOpacityTable(opacity)
    slab.setImageSource(volume + Int(c[1]) * w * h, Int(c[2]))
    if c[5] != 0 {
        slab.setImageBlendingSource(fused + Int(c[1]) * w * h)
        slab.setBlendingCLUT(luts + 768, luts + 1024, luts + 1280)
    }
    slab.setWLWW(f[0], f[1])
    if c[5] != 0 { slab.setBlendingWLWW(f[2], f[3]) }
    let argb = slab.renderSlab()!
    output.append(argb, count: w * h * 4)
    free(argb)
    output.append(slab.compositeTables)
}
try! output.write(to: URL(fileURLWithPath: arguments[3]))
'''


def run(command, **kw):
    return subprocess.run(command, capture_output=True, text=True, timeout=600, **kw)


failures = []
with tempfile.TemporaryDirectory(prefix='isix-thick-slab-') as folder:
    tmp = Path(folder)
    data = struct.pack('<3i', W, H, N) + struct.pack('<%df' % len(volume), *volume) + \
        struct.pack('<%df' % len(fused), *fused) + b''.join(clut) + b''.join(fused_clut) + struct.pack('<256f', *opacity)
    (tmp / 'input.bin').write_bytes(data)
    (tmp / 'cases.bin').write_bytes(b''.join(struct.pack('<6i4f', *case) for case in cases))
    (tmp / 'host.m').write_text(HOST)
    (tmp / 'main.swift').write_text(DRIVER)
    outputs = {}
    for optimization in ('debug', 'release'):
        debug = optimization == 'debug'
        host, composer = tmp / f'host-{optimization}', tmp / f'composer-{optimization}'
        built = run(['xcrun', 'clang', '-fno-objc-arc', '-w', '-O0' if debug else '-Os', *(['-fsanitize=address'] if debug else []),
                     '-framework', 'Foundation', '-framework', 'Accelerate', str(tmp / 'host.m'), '-o', str(host)])
        if built.returncode:
            print('FAIL: the reference does not build:\n' + built.stderr[-3000:])
            raise SystemExit(1)
        # The modules it depends on (IsiXLogging, which its log goes through).
        below = [flag for name in isix_modules.dependencies('IsiXVolumeRendering')
                 for flag in isix_modules.module_flags(name, tmp / 'modules')]
        built = run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'ThickSlabDriver', *below,
                     *(['-Onone', '-sanitize=address'] if debug else ['-O']),
                     *sorted(str(p) for p in MODULE.glob('*.swift')), str(tmp / 'main.swift'), '-o', str(composer)])
        if built.returncode:
            print('FAIL: the module does not build with the driver:\n' + built.stderr[-3000:])
            raise SystemExit(1)
        env = {**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'}
        for side, binary in (('reference', host), ('module', composer)):
            out = tmp / f'{side}-{optimization}.bin'
            ran = run([str(binary), str(tmp / 'input.bin'), str(tmp / 'cases.bin'), str(out)], env=env)
            if ran.returncode:
                print(f'FAIL: the {side} driver ({optimization}) exited with {ran.returncode}:\n' + ran.stderr[-2000:])
                raise SystemExit(1)
            outputs[side, optimization] = out.read_bytes()
        a, b = outputs['reference', optimization], outputs['module', optimization]
        per_case = W * H * 4 + 4096
        if a != b:
            first = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
            failures.append(f'{optimization}: case {first // per_case} differs at byte {first % per_case} '
                            f'(outputs of {len(a)} and {len(b)} bytes)')
        else:
            print(f'ok: {optimization}: {len(cases)} composites and their tables the same, '
                  f'{sum(c[5] for c in cases)} of them fused')

for failure in failures:
    print('FAIL:', failure)
if failures:
    raise SystemExit(1)
print('PASS: ThickSlabComposer composes, bit for bit, what ThickSlabVR.mm composed (reference ' + reference[:12] +
      '), plain and fused, in Debug and Release')
