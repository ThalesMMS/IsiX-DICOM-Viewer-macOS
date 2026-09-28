#!/usr/bin/env python3
"""The Metal ray cast takes the host's 16-bit CLUT (#725).

The 3D view's 16-bit CLUT is a colour function and an opacity function over the
whole value range, not over the window, which VTK evaluates into its own
tables. It used to be refused ("The 16-bit CLUT keeps the original renderer.").
The snapshot now samples the same functions (`GetTable`) at 4096 points over
the volume's range and hands the renderer tables of that size; the kernel reads
entry round(w * (entries - 1)) instead of round(w * 255), and a projection is
painted from the tables.

Checked here:
- in the sources, the snapshot no longer refuses the 16-bit CLUT and samples
  VTK's functions over the value range; the kernel indexes by the table's last
  entry; the facade and the projection painting take tables;
- on the GPU, a constant transfer function draws the same bytes with 256 and
  4096 entries, in composite and in MIP;
- a narrow opaque band in the middle of a 4096-entry table colours a volume
  whose value falls in the band, and not one whose value falls just outside,
  which only the table's own last entry reproduces;
- the projection painting from tables agrees with the 256-entry painting of the
  same ramp to within one 8-bit level.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('utf-8')
    return (root / path).read_text()


failures = []
bridge = read('Horos/Sources/VRHostBridge.mm')
renderer = read('Horos/Sources/VolumeMetalRenderer.swift')
if 'The 16-bit CLUT keeps the original renderer.' in bridge:
    failures.append('the 16-bit CLUT is still refused')
if 'colorTransferFunction->GetTable(from, to, entries, colours.data());' not in bridge or \
        'double from = (OFFSET16 + lowest) * valueFactor, to = (OFFSET16 + highest) * valueFactor;' not in bridge:
    failures.append('the 16-bit CLUT is not VTK\'s own functions over the value range')
if 'opacityTable:snapshot[@"opacityTable"]' not in bridge or 'projection[@"projectionOpacityTable"]' not in bridge:
    failures.append('the tables do not reach the render and the projection painting')
if 'float lastEntry = float(p.clipping.z);' not in renderer or '* 255.0 + 0.5);' in renderer.replace('rgb.b * 255.0 + 0.5', '').replace('rgb.g * 255.0 + 0.5', '').replace('rgb.r * 255.0 + 0.5', ''):
    failures.append('the kernel does not index the table by its own last entry')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

DRIVER = r'''
import Foundation
import Metal
import simd

func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { print("FAIL: " + reason()); exit(1) } }

@main struct Check {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("skipped: no Metal device"); exit(2) }
        let engine = try VolumeMetalRenderer(device: device)
        let w = 12, h = 10, d = 8
        func volume(_ value: (Int, Int, Int) -> Float) throws -> ResliceVolume {
            var voxels = [Float](); for k in 0..<d { for j in 0..<h { for i in 0..<w { voxels.append(value(i, j, k)) } } }
            return try ResliceVolume(width: w, height: h, depth: d, voxels: voxels.withUnsafeBufferPointer { Data(buffer: $0) },
                                     voxelToWorld: matrix_identity_float4x4)
        }
        let camera = try VolumeCamera(position: SIMD3(5.5, 4.5, -30), focalPoint: SIMD3(5.5, 4.5, 3.5), viewUp: SIMD3(0, -1, 0),
                                      parallel: true, parallelScale: 7, viewAngle: 30, clippingRange: nil)
        func render(_ transfer: VolumeTransferFunction, _ mode: VolumeRenderingMode) throws -> Data {
            let request = try VolumeRenderRequest(camera: camera, transfer: transfer, mode: mode, shading: VolumeShading(enabled: false),
                                                  crop: nil, width: 16, height: 14, sampleStep: 0.5)
            return try engine.render(request).bgra
        }
        func table(_ n: Int, colour: (Int) -> [UInt8], opacity: (Int) -> Float) throws -> VolumeTransferFunction {
            var bytes = [UInt8](); for i in 0..<n { bytes += colour(i) + [255] }
            return try VolumeTransferFunction(level: 500, width: 1000, colour: Data(bytes), opacity: (0..<n).map(opacity))
        }
        // 1. A constant function: the same bytes with 256 and 4096 entries.
        try engine.upload(try volume { i, j, k in Float(i * 70 + j * 11 + k * 5) })
        for mode in [VolumeRenderingMode.composite, .maximum] {
            let small = try render(try table(256, colour: { _ in [200, 120, 40] }, opacity: { _ in 0.08 }), mode)
            let wide = try render(try table(4096, colour: { _ in [200, 120, 40] }, opacity: { _ in 0.08 }), mode)
            expect(small == wide, "mode \(mode): a constant function draws differently with 4096 entries")
        }
        // 2. An opaque band of entries 2000...2100 of 4096 over [0, 1000]:
        // values 490...513. A volume at 500 is in it; one at 530 is not; with
        // 255 as the last entry both would read the table's first entries.
        let band = try table(4096, colour: { $0 >= 2000 && $0 <= 2100 ? [255, 0, 0] : [0, 0, 255] },
                             opacity: { $0 >= 2000 && $0 <= 2100 ? 1 : 0 })
        try engine.upload(try volume { _, _, _ in 500 })
        let inside = [UInt8](try render(band, .composite))
        expect(inside[4 * (7 * 16 + 8) + 2] > 200 && inside[4 * (7 * 16 + 8)] < 30, "a value in the band is not drawn with the band's colour")
        try engine.upload(try volume { _, _, _ in 530 })
        let outside = [UInt8](try render(band, .composite))
        expect(outside[4 * (7 * 16 + 8) + 2] == 0 && outside[4 * (7 * 16 + 8)] == 0, "a value outside the band is drawn")
        // 3. The projection painting from tables and from 256 colours, one ramp.
        let values: [Float] = [-10, 0, 1.3, 250, 499.5, 500, 777.7, 999, 1000, 1200]
        let scalar = values.withUnsafeBufferPointer { NSData(bytes: $0.baseAddress!, length: $0.count * 4) }
        var clut = [UInt8](); for i in 0..<256 { clut += [UInt8(i), UInt8(255 - i), UInt8(i / 2), 255] }
        func shorts(_ data: Data) -> [UInt16] { data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) } }
        let small = shorts(MPRVolumeBridgeTestAccess.picture256(scalar: scalar, clut: Data(clut)))
        var wideColour = [UInt8](), wideOpacity = [Float]()
        for i in 0..<4096 {
            let x = Double(i) / 4095 * 254   // the 256 painting interpolates entries 0...254
            let lower = Int(x), upper = min(254, lower + 1), t = x - Double(lower)
            for c in 0..<3 { wideColour.append(UInt8((Double(clut[4 * lower + c]) * (1 - t) + Double(clut[4 * upper + c]) * t).rounded())) }
            wideColour.append(255)
            wideOpacity.append(Float(i) / 4095)
        }
        let wide = shorts(HorosVolumeRendererPictures.table(scalar: scalar, colour: Data(wideColour),
                                                            opacity: wideOpacity.withUnsafeBufferPointer { Data(buffer: $0) }))
        expect(small.count == values.count * 4 && wide.count == small.count, "a projection painting has the wrong size")
        let worst = zip(small, wide).map { abs(Int($0) - Int($1)) }.max() ?? 0
        expect(worst <= 128, "the projection painted from tables differs from the 256-entry painting by \(worst) in 15 bits")
        print("PASS: a constant function draws the same with 256 and 4096 entries; a narrow band of 4096 entries is read at its own index; projection tables paint within \(worst) of 32767 of the 256-entry painting")
    }
}

enum MPRVolumeBridgeTestAccess {
    static func picture256(scalar: NSData, clut: Data) -> Data {
        HorosVolumeRendererPictures.points(scalar: scalar, clut: clut)
    }
}
enum HorosVolumeRendererPictures {
    static func points(scalar: NSData, clut: Data) -> Data {
        VolumeRendererBridge.projectionPicture(scalar: scalar, level: 500, width: 1000, clut: clut as NSData,
                                               opacityPoints: [0, 0, 256, 1], background: -1e30) as Data
    }
    static func table(scalar: NSData, colour: Data, opacity: Data) -> Data {
        VolumeRendererBridge.projectionPicture(scalar: scalar, level: 500, width: 1000, colourTable: colour as NSData,
                                               opacityTable: opacity as NSData, background: -1e30) as Data
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-volume-wide-table-') as name:
    work = Path(name)
    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'MPRMetalReslicer.swift', 'VolumeMetalRenderer.swift',
               'MetalPerformanceTrace.swift', 'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift']
    for source in sources:
        (work / source).write_text(read('Horos/Sources/' + source))
    (work / 'Check.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-suppress-warnings',
                            *[str(work / s) for s in sources], str(work / 'Check.swift'), '-o', str(work / 'check')])
    if build.returncode:
        print('FAIL: the renderer does not build with the table driver')
        raise SystemExit(1)
    raise SystemExit(subprocess.run([str(work / 'check')], timeout=300).returncode)
