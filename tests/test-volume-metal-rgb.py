#!/usr/bin/env python3
"""An RGB volume draws with the Metal ray cast of the 3D view.

VTK's ray caster holds an RGB series' ARGB bytes as four independent
components: alpha, weighted 0, and red, green and blue, each with its colour
function and one opacity function over the byte. In composite it combines a
sample's components as `VTKKWRCHelper_LookupAndCombineIndependentColorsUS`
does - the colour the sum of each component's colour times its opacity, the
opacity the sum of the squared opacities over their sum - and in a projection
it keeps each component's own extreme. The Metal renderer used to refuse the
volume ("RGB volumes keep the original renderer."); it now uploads the bytes
as an RGBA texture and runs the same arithmetic, and the host paints a
projection's three values with the mapper's own tables.

Checked here:
- in the sources, the snapshot no longer refuses an RGB volume, takes VTK's
  component colour functions and opacity function over 0...255, and the hook
  paints a projection with the mapper's tables;
- on the GPU, a volume whose only non-zero component is red draws, in
  composite, what the scalar renderer draws of that channel with the same
  table, within two levels (the two textures filter in their own precision);
- rays down a column of voxels give, for each component, the maximum,
  minimum and mean of the column's samples.

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
snapshot = bridge[bridge.index('- (NSDictionary *)horosVolumeSnapshot {'):]
snapshot = snapshot[:snapshot.index('\n}\n')]
if 'RGB volumes keep the original renderer.' in snapshot:
    failures.append('the snapshot still refuses an RGB volume')
if 'property->GetRGBTransferFunction(component)->GetTable(0, 255, 256, colours);' not in bridge or \
        'property->GetScalarOpacity(1)->GetTable(0, 255, 256, alphas);' not in bridge or \
        'HorosColourTables(volumeProperty, samplesPerMillimetre, &clut, &opacityTable, &projectionOpacityTable)' not in bridge:
    failures.append('the RGB tables are not VTK\'s own component functions over the byte')
if 'pictureWithComponents:scalar count:(NSInteger)(bgra.length / 4) tables:projection[@"componentTables"]' not in bridge or \
        'snapshot[@"componentTables"] = [self horosColourTablesFused:NO refresh:NO][@"tables"]' not in bridge:
    failures.append('an RGB projection is not painted with the mapper\'s tables')
if 'uploadColourVolume:slices' not in bridge or 'func uploadColourVolume(' not in renderer:
    failures.append('the ARGB bytes are not uploaded as a colour volume')
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
        let colourEngine = try VolumeMetalRenderer(device: device), scalarEngine = try VolumeMetalRenderer(device: device)
        let w = 12, h = 10, d = 8
        func red(_ i: Int, _ j: Int, _ k: Int) -> Int { (i * 19 + j * 7 + k * 23) % 256 }
        var argb = [UInt8](), floats = [Float]()
        for k in 0..<d { for j in 0..<h { for i in 0..<w { argb += [255, UInt8(red(i, j, k)), 0, 0]; floats.append(Float(red(i, j, k))) } } }
        try colourEngine.upload(try ResliceVolume(width: w, height: h, depth: d, voxels: Data(argb), voxelToWorld: matrix_identity_float4x4), colour: true)
        try scalarEngine.upload(try ResliceVolume(width: w, height: h, depth: d, voxels: floats.withUnsafeBufferPointer { Data(buffer: $0) },
                                                  voxelToWorld: matrix_identity_float4x4))
        let opacity: [Float] = (0..<256).map { $0 == 0 ? 0 : Float($0) / 255 * 0.3 }
        var ramp = [UInt8](); for i in 0..<256 { ramp += [UInt8(i), UInt8(i / 2), UInt8(255 - i), 255] }
        let three = Data(ramp + [UInt8](repeating: 0, count: 2048))    // green and blue tables: black, and never lit
        let camera = try VolumeCamera(position: SIMD3(5.5, 4.5, -30), focalPoint: SIMD3(5.5, 4.5, 3.5), viewUp: SIMD3(0, -1, 0),
                                      parallel: true, parallelScale: 6, viewAngle: 30, clippingRange: nil)
        func request(_ transfer: VolumeTransferFunction, _ mode: VolumeRenderingMode, width: Int = 16, height: Int = 14, step: Float = 0.5) throws -> VolumeRenderRequest {
            try VolumeRenderRequest(camera: camera, transfer: transfer, mode: mode, shading: VolumeShading(enabled: false), crop: nil,
                                    width: width, height: height, sampleStep: step)
        }
        let colourTransfer = try VolumeTransferFunction(level: 127.5, width: 255, colour: three, opacity: opacity)
        let scalarTransfer = try VolumeTransferFunction(level: 127.5, width: 255, colour: Data(ramp), opacity: opacity)
        let colour = [UInt8](try colourEngine.render(try request(colourTransfer, .composite)).bgra)
        let scalar = [UInt8](try scalarEngine.render(try request(scalarTransfer, .composite)).bgra)
        let worst = zip(colour, scalar).map { abs(Int($0) - Int($1)) }.max()!
        expect(worst <= 2, "one red component composes \(worst) levels from the scalar composite of that channel")
        expect(colour.contains { $0 > 20 }, "the composite drew nothing")

        // Through voxel centres: a parallel view down z whose pixel (x, y) is voxel column (x, y).
        let axial = try VolumeCamera(position: SIMD3(5.5, 4.5, -30), focalPoint: SIMD3(5.5, 4.5, 3.5), viewUp: SIMD3(0, -1, 0),
                                     parallel: true, parallelScale: 5, viewAngle: 30, clippingRange: nil)
        var mixed = [UInt8]()
        for k in 0..<d { for j in 0..<h { for i in 0..<w { mixed += [255, UInt8(red(i, j, k)), UInt8((i * 5 + k * 31) % 256), UInt8((j * 13 + k * 3) % 256)] } } }
        try colourEngine.upload(try ResliceVolume(width: w, height: h, depth: d, voxels: Data(mixed), voxelToWorld: matrix_identity_float4x4), colour: true)
        for mode in [VolumeRenderingMode.maximum, .minimum, .mean] {
            let result = try colourEngine.render(try VolumeRenderRequest(camera: axial, transfer: colourTransfer, mode: mode,
                shading: VolumeShading(enabled: false), crop: nil, width: 12, height: 10, sampleStep: 1, scalarBackground: -1))
            let values = result.scalar.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            expect(values.count == 3 * 12 * 10, "a colour projection does not hand back three values a pixel")
            for y in 1..<9 { for x in 1..<11 {
                for c in 0..<3 {
                    // The ray enters at z = -0.5 and samples every voxel: at
                    // -0.5, 0.5, ... d - 0.5, each the mean of the two
                    // neighbouring voxels, the first and the last the edge ones.
                    let column = (0..<d).map { Float(mixed[4 * (($0 * h + y) * w + x) + c + 1]) }
                    let samples = [column[0]] + (0..<(d - 1)).map { (column[$0] + column[$0 + 1]) / 2 } + [column[d - 1]]
                    let expected = mode == .maximum ? samples.max()! : mode == .minimum ? samples.min()! : samples.reduce(0, +) / Float(samples.count)
                    let got = values[3 * (y * 12 + x) + c]
                    expect(abs(got - expected) <= 0.51,
                           "mode \(mode), column (\(x), \(y)), component \(c + 1): \(got), the column gives \(expected)")
                }
            } }
        }
        print("PASS: one red component composes within \(worst) levels of the scalar channel; MIP, MinIP and mean of three components down each column equal its samples'")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-volume-rgb-') as name:
    work = Path(name)
    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'MPRMetalReslicer.swift', 'VolumeMetalRenderer.swift',
               'MetalPerformanceTrace.swift', 'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift']
    for source in sources:
        (work / source).write_text(read('Horos/Sources/' + source))
    (work / 'Check.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-suppress-warnings',
                            *[str(work / s) for s in sources], str(work / 'Check.swift'), '-o', str(work / 'check')])
    if build.returncode:
        print('FAIL: the renderer does not build with the RGB driver')
        raise SystemExit(1)
    raise SystemExit(subprocess.run([str(work / 'check')], timeout=300).returncode)
