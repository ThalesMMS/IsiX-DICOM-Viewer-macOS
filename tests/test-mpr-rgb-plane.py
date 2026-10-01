#!/usr/bin/env python3
"""An RGB volume's MPR plane is resliced by channel in Metal (#724).

The MPR refused an RGB volume in Metal. VTK's ray caster holds the viewer's
ARGB bytes as four independent components - alpha, weighted 0, and red, green
and blue, each with its colour function and the view's opacity function - and
combines them in 15 bits (`VTKKWRCHelper_LookupAndCombineIndependentColorsMax`).
The Metal path reslices each channel as a scalar volume and combines the three
through the mapper's own tables with that arithmetic.

Checked here:
- in the sources, the bridge reslices an RGB volume by channel, with the view's
  own mode (the reference is the geometry; the CPU ray cast that draws a
  refused plane is checked in `test-mpr-rgb-cpu-slab.py`, #786), and the
  view takes the plane as colour bytes; the 3D view no longer refuses RGB;
- `HorosMPRColourPlane.channels(fromARGB:)` separates the bytes exactly;
- `HorosMPRColourPlane.combine` equals VTK's macro, cut out of the VTK header
  and compiled as C++, for every index of three random tables and weights;
- on the GPU, the three channels of a small ARGB volume, resliced on voxel
  centres in MIP, MinIP and mean, combine to what the macro gives for each
  channel's maximum, minimum and mean;
- the three channels go to the GPU in one submission (#787): the bridge makes
  one `resliceChannels` call, not one reslice per channel, and on Metal 3 and
  Metal 4 its planes equal, bit for bit, the three channels resliced one at a
  time, on oblique planes off the voxel grid, thin and thick, in MIP, MinIP
  and mean.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import random
import re
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
from sources import dependency_source
vtk_source = dependency_source('VTK')
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path], stderr=subprocess.DEVNULL).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


failures = []
bridge = read('Horos/Sources/MPRHostBridge.m')
# MPRDCMView is Swift since #823; an earlier revision has the Objective-C.
try:
    view = read('Horos/Sources/MPRDCMView.swift')
    copied_is_rgb = 'isRGB = ObjCBool(host.horosMPRCopiedImageIsRGB())'
except (FileNotFoundError, subprocess.CalledProcessError):
    view = read('Horos/Sources/MPRDCMView.m')
    copied_is_rgb = 'isRGB = [self horosMPRCopiedImageIsRGB];'
vr = read('Horos/Sources/VRHostBridge.mm')
reslicer = read('Horos/Sources/MPRMetalReslicer.swift')
if '@objc(HorosMPRColourPlane)' not in reslicer:
    failures.append('there is no colour plane to combine the channels')
if 'if (volume.isColour) return [self horosMPRCopyColourImageWidth:width height:height volume:volume];' not in bridge:
    failures.append('the MPR does not reslice an RGB volume by channel')
elif 'NSInteger projection = controller.clippingRangeMode;' not in bridge[bridge.index('- (float *)horosMPRCopyColourImageWidth'):]:
    failures.append('the colour plane does not follow the view\'s own mode')
if copied_is_rgb not in view:
    failures.append('the view does not take the Metal plane as colour bytes')
if 'if (firstObject.isRGB) return @"RGB planes keep the original renderer.";' in vr:
    failures.append('the 3D view still refuses an RGB plane')
if '[vrView horosMPRColourTables]' not in bridge or 'GetTableSize(c)' not in vr:
    failures.append('the colour plane is not combined through the mapper\'s own tables')
if '[HorosMPRReslicer resliceChannels:reslicers' not in bridge or 'for (HorosMPRReslicer *channel in reslicers)' in bridge:
    failures.append('the colour plane is not resliced in one GPU submission')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

header = (vtk_source / 'Rendering/Volume/vtkFixedPointVolumeRayCastHelper.h').read_text()
# The macro runs to its first line without a continuation backslash.
macro = re.search(r'#define VTKKWRCHelper_LookupAndCombineIndependentColorsMax\((?:[^\n]*\\\n)*[^\n]*\n', header)
if not macro:
    print('FAIL: VTK\'s combination macro is no longer where this test cuts it out')
    raise SystemExit(1)

random.seed(724)
tables = []
for component in (1, 2, 3):
    size = random.choice([256, 249, 253])
    opacity = [random.randrange(0, 32768) for _ in range(size)]
    colour = [random.randrange(0, 32768) for _ in range(3 * size)]
    tables.append((component, random.choice([1.0, 0.75, 0.3333]), size, opacity, colour))
count = 256
# Per pixel and channel, an index each table has (and some past its end, which both clamp).
indices = [[random.randrange(0, 260) for _ in range(count)] for _ in range(3)]

REFERENCE = r'''
#include <stdio.h>
#include <stdlib.h>
#define VTKKW_FP_SHIFT 15
MACRO
int main(int argc, char **argv) {
    FILE *in = fopen(argv[1], "rb"), *out = fopen(argv[2], "wb");
    int count, sizes[3]; float weights[3];
    fread(&count, 4, 1, in); fread(sizes, 4, 3, in); fread(weights, 4, 3, in);
    unsigned short *opacity[3], *colour[3];
    for (int c = 0; c < 3; ++c) {
        opacity[c] = (unsigned short *)malloc(sizes[c] * 2); colour[c] = (unsigned short *)malloc(sizes[c] * 6);
        fread(opacity[c], 2, sizes[c], in); fread(colour[c], 2, 3 * sizes[c], in);
    }
    int *index[3];
    for (int c = 0; c < 3; ++c) { index[c] = (int *)malloc(count * 4); fread(index[c], 4, count, in); }
    for (int i = 0; i < count; ++i) {
        unsigned short idx[3], colourOut[4];
        for (int c = 0; c < 3; ++c) { int k = index[c][i]; idx[c] = (unsigned short)(k < sizes[c] ? k : sizes[c] - 1); }
        VTKKWRCHelper_LookupAndCombineIndependentColorsMax(colour, opacity, idx, weights, 3, colourOut);
        unsigned char argb[4] = {255, (unsigned char)(colourOut[0] >> 7), (unsigned char)(colourOut[1] >> 7),
                                 (unsigned char)(colourOut[2] >> 7)};
        fwrite(argb, 1, 4, out);
    }
    fclose(out);
    return 0;
}
'''.replace('MACRO', macro.group(0))

DRIVER = r'''
import Foundation
import Metal

func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { print("FAIL: " + reason()); exit(1) } }

@main struct Check {
    static func main() throws {
        let arguments = CommandLine.arguments
        let input = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let expected = [UInt8](try Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        var cursor = 0
        func ints(_ n: Int) -> [Int32] { defer { cursor += 4 * n }; return input.subdata(in: cursor..<(cursor + 4 * n)).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) } }
        func floats(_ n: Int) -> [Float] { defer { cursor += 4 * n }; return input.subdata(in: cursor..<(cursor + 4 * n)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        func shorts(_ n: Int) -> Data { defer { cursor += 2 * n }; return input.subdata(in: cursor..<(cursor + 2 * n)) }
        let count = Int(ints(1)[0]), sizes = ints(3).map(Int.init), weights = floats(3)
        var tables = [NSDictionary]()
        for c in 0..<3 {
            let opacity = shorts(sizes[c]), colour = shorts(3 * sizes[c])
            tables.append(["component": c + 1, "weight": weights[c], "shift": 0.0, "scale": 1.0, "size": sizes[c],
                           "opacity": opacity, "colour": colour] as NSDictionary)
        }
        let channels = (0..<3).map { _ in ints(count).map { Float($0) } }
        func data(_ values: [Float]) -> NSData { values.withUnsafeBufferPointer { NSData(bytes: $0.baseAddress!, length: $0.count * 4) } }
        guard let combined = MPRColourPlane.combine(red: data(channels[0]), green: data(channels[1]), blue: data(channels[2]),
                                                    count: count, tables: tables) else { print("FAIL: nothing combined"); exit(1) }
        let got = [UInt8](combined as Data)
        let differing = zip(got, expected).filter { $0 != $1 }.count
        expect(got.count == expected.count && differing == 0, "the combination differs from VTK's macro in \(differing) bytes")

        // The channels of ARGB bytes, exactly.
        let w = 5, h = 4, d = 3, n = w * h * d
        var argb = [UInt8](); for i in 0..<n { argb += [UInt8(255 - i % 7), UInt8((i * 37) % 256), UInt8((i * 91 + 3) % 256), UInt8((i * 13 + 200) % 256)] }
        guard let split = MPRColourPlane.channels(fromARGB: NSData(bytes: argb, length: argb.count), width: w, rows: h * d),
              split.count == 3 else { print("FAIL: the channels were not separated"); exit(1) }
        for c in 0..<3 {
            let values = (split[c] as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            expect(values == (0..<n).map { Float(argb[4 * $0 + c + 1]) }, "channel \(c + 1) is not the bytes as floats")
        }

        // On the GPU: a plane through voxel centres (the stack's own axial
        // plane), a slab over all three slices, each channel resliced in MIP,
        // MinIP and mean, then combined through the tables.
        guard MTLCreateSystemDefaultDevice() != nil else { print("skipped: no Metal device"); exit(2) }
        var transform = [NSNumber](repeating: 0, count: 16)
        transform[0] = 1; transform[5] = 1; transform[10] = 1; transform[15] = 1
        let reslicers = try (0..<3).map { _ in try MPRReslicerBridge.make() }
        for c in 0..<3 { try reslicers[c].uploadVolume(split[c], width: w, height: h, depth: d, voxelToWorld: transform) }
        for projection in 1...3 {
            // As the bridge asks for it: the three channels in one submission.
            let planes = try MPRReslicerBridge.resliceChannels(reslicers, origin: [0, 0, 1], orientation: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                                                               spacing: 1, width: w, height: h, thickness: 2, sampleStep: 1,
                                                               projection: projection, background: -1)
            expect(planes.count == 3, "the colour reslice gave \(planes.count) planes")
            guard let plane = MPRColourPlane.combine(red: planes[0], green: planes[1], blue: planes[2], count: w * h, tables: tables)
            else { print("FAIL: no colour plane"); exit(1) }
            let bytes = [UInt8](plane as Data)
            for p in 0..<(w * h) {
                var reduced = [Float]()
                for c in 0..<3 {
                    let column = (0..<d).map { Float(argb[4 * ($0 * w * h + p) + c + 1]) }
                    reduced.append(projection == 1 ? column.max()! : projection == 2 ? column.min()! : column.reduce(0, +) / Float(d))
                }
                guard let one = MPRColourPlane.combine(red: data([reduced[0]]), green: data([reduced[1]]), blue: data([reduced[2]]),
                                                       count: 1, tables: tables) else { print("FAIL"); exit(1) }
                expect(Array(bytes[(4 * p)..<(4 * p + 4)]) == [UInt8](one as Data),
                       "projection \(projection), pixel \(p): \(Array(bytes[(4 * p)..<(4 * p + 4)])) is not the combination of the channels' \(reduced)")
            }
        }

        // One submission against three (#787): on each backend, the planes of
        // `resliceChannels` equal, bit for bit, each channel resliced on its
        // own, on oblique planes off the voxel grid of an anisotropic volume.
        let device = MTLCreateSystemDefaultDevice()!
        var seed: UInt64 = 787
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        let (vw, vh, vd) = (37, 29, 23)
        let channelVolumes = (0..<3).map { _ in (0..<(vw * vh * vd)).map { _ in Float(Int(next() * 256)) } }
        let voxelToWorld: [NSNumber] = [0.8, 0, 0, 0, 0, 0.65, 0, 0, 0, 0, 1.7, 0, -12.5, 4.25, 30, 1]
        var backends: [MetalComputeBackend] = [.metal3]
        if Metal4ComputeSubmitter.isSupported(device) { backends.append(.metal4) }
        var compared = 0
        for backend in backends {
            let engines = try (0..<3).map { _ in try MPRReslicerBridge.make(device: device, backend: backend) }
            for c in 0..<3 { try engines[c].uploadVolume(data(channelVolumes[c]), width: vw, height: vh, depth: vd, voxelToWorld: voxelToWorld) }
            for trial in 0..<12 {
                // A random rotation (unit quaternion) of the volume's axes, a centre inside it.
                var q = (0..<4).map { _ in next() * 2 - 1 }; let n = sqrt(q.reduce(0) { $0 + $1 * $1 }); q = q.map { $0 / n }
                let (a, b, cq, dq) = (q[0], q[1], q[2], q[3])
                let row = [a*a + b*b - cq*cq - dq*dq, 2*(b*cq + a*dq), 2*(b*dq - a*cq)]
                let column = [2*(b*cq - a*dq), a*a - b*b + cq*cq - dq*dq, 2*(cq*dq + a*b)]
                let normal = [row[1]*column[2] - row[2]*column[1], row[2]*column[0] - row[0]*column[2], row[0]*column[1] - row[1]*column[0]]
                let (pw, ph) = (41 + trial, 33 + 2 * trial)
                let spacing = 0.45 + 0.1 * Double(trial % 4)
                let centre = [-12.5 + 0.8 * 18.3, 4.25 + 0.65 * 13.7, 30 + 1.7 * 10.9]
                let origin = (0..<3).map { centre[$0] - row[$0] * spacing * Double(pw) / 2 - column[$0] * spacing * Double(ph) / 2 + (next() - 0.5) }
                let thickness = [0.0, 2.3, 6.0, 11.5][trial % 4]
                for projection in 1...3 {
                    let args = (origin: origin.map { NSNumber(value: $0) }, orientation: (row + column + normal).map { NSNumber(value: $0) })
                    let together = try MPRReslicerBridge.resliceChannels(engines, origin: args.origin, orientation: args.orientation,
                                                                         spacing: spacing, width: pw, height: ph, thickness: thickness,
                                                                         sampleStep: 0.65, projection: projection, background: -1)
                    expect(together.count == 3, "\(backend.name): \(together.count) planes")
                    for c in 0..<3 {
                        let alone = try engines[c].reslice(origin: args.origin, orientation: args.orientation, spacing: spacing,
                                                           width: pw, height: ph, thickness: thickness, sampleStep: 0.65,
                                                           projection: projection, background: -1)
                        let x = (together[c] as Data).withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
                        let y = (alone as Data).withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
                        let differing = zip(x, y).filter { $0 != $1 }.count
                        let inside = y.filter { Float(bitPattern: $0) != -1 }.count
                        expect(x.count == pw * ph && y.count == x.count && differing == 0,
                               "\(backend.name), plane \(trial), projection \(projection), channel \(c): \(differing) of \(y.count) pixels differ from the channel resliced alone")
                        expect(inside > y.count / 4, "\(backend.name), plane \(trial): only \(inside) pixels fall inside the volume")
                        compared += x.count
                    }
                }
            }
        }
        print("PASS: \(count) pixels combined byte for byte as VTK's macro does; ARGB split exactly; MIP, MinIP and mean of three channels resliced on the GPU and combined; " +
              "\(compared) channel pixels of one submission equal to three (\(backends.map { $0.name }.joined(separator: ", ")))")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-mpr-rgb-') as name:
    work = Path(name)
    payload = struct.pack('<i', count) + struct.pack('<3i', *[t[2] for t in tables]) + struct.pack('<3f', *[t[1] for t in tables])
    for _, _, size, opacity, colour in tables:
        payload += struct.pack('<%dH' % size, *opacity) + struct.pack('<%dH' % (3 * size), *colour)
    for channel in indices:
        payload += struct.pack('<%di' % count, *channel)
    (work / 'input.bin').write_bytes(payload)
    (work / 'reference.cpp').write_text(REFERENCE)
    if subprocess.run(['xcrun', 'clang++', '-O0', '-w', str(work / 'reference.cpp'), '-o', str(work / 'reference')]).returncode:
        print('FAIL: VTK\'s macro does not build')
        raise SystemExit(1)
    subprocess.run([str(work / 'reference'), str(work / 'input.bin'), str(work / 'expected.bin')], check=True)
    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'MPRMetalReslicer.swift', 'MetalPerformanceTrace.swift',
               'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift']
    for source in sources:
        (work / source).write_text(read('Horos/Sources/' + source))
    (work / 'Check.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-suppress-warnings',
                            *[str(work / s) for s in sources], str(work / 'Check.swift'), '-o', str(work / 'check')])
    if build.returncode:
        print('FAIL: the reslicer does not build with the colour driver')
        raise SystemExit(1)
    raise SystemExit(subprocess.run([str(work / 'check'), str(work / 'input.bin'), str(work / 'expected.bin')], timeout=300).returncode)
