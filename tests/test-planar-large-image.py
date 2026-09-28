#!/usr/bin/env python3
"""The planar Metal renderer draws images larger than any texture (#723).

A 2D viewer of an image wider or taller than 16384 pixels, or whose samples
passed 512 MB, was refused by the planar snapshot and drew with «Original
renderer (Metal paused)». Apple GPUs make no 2D texture larger than 16384, and
the original renderer tiles such an image into several textures. The Metal
path now keeps a layer that large in a buffer, and a fragment reads its texels
with the arithmetic it uses on a texture.

The reference is the texture path itself: the same pixels cropped to a width
the texture path takes, with the same mapping, must draw the same picture -
bit for bit for float samples, for one-byte samples (the opacity table's
bytes) and with nearest sampling, where the arithmetic is the same; within one
level for colour bytes, which the texture's sampler interpolates with quantized
weights and the buffer path in float. Wide and tall images, a fused layer read
from a buffer, and the Metal 4 pilot, identical to Metal 3, are covered.

Also checked in the sources: the snapshot's new ceiling (65535 pixels a side,
the DICOM limit, and 2 GiB of samples, which it copies on every draw).

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
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


failures = []
bridge = read('Horos/Sources/PlanarHostBridge.m')
renderer = read('Horos/Sources/PlanarMetalRenderer.swift')
pilot = read('Horos/Sources/PlanarMetal4Renderer.swift')
snapshot = bridge[bridge.index('- (NSDictionary *)horosPlanarSnapshot'):]
if 'width > 65535 || height > 65535 || count > 2048UL*1024*1024' not in snapshot:
    failures.append('the snapshot still refuses an image past 16384 pixels or 512 MB')
if 'static let maximumTextureSide = 16384' not in renderer or 'planarBufferFragment' not in renderer:
    failures.append('the renderer has no buffer path for a layer larger than any texture')
if 'planarBufferFragment' not in pilot or 'textures.resources' not in pilot:
    failures.append('the Metal 4 pilot does not draw or keep resident a layer held in a buffer')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

DRIVER = r'''
import Foundation
import Metal

func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { print("FAIL: " + reason()); exit(1) } }

// A power-of-two view, and offsets and a step that are binary fractions: every
// pixel coordinate is then exact in float near 16384 as near zero, so the large
// layer and its crop are sampled at the same fractions. (Otherwise float's
// spacing near 16384 - 1/512 - would move the weights, not the renderer.)
let tw = 128, th = 4
func clut() -> Data {
    var table = [UInt8]()
    for i in 0..<256 { table += [UInt8(i), UInt8((i * 7) % 256), UInt8(255 - i), 255] }
    return Data(table)
}
// A view of tw x th pixels over pixels starting at (x0 + 0.375, y0 + 0.25), 0.9375 of a pixel apart:
// off-centre samples, so the interpolation is exercised.
func mapping(_ x0: Double, _ y0: Double) -> [Double] {
    [x0 + 0.375, y0 + 0.25, x0 + 0.375 + Double(tw) * 0.9375, y0 + 0.25, x0 + 0.375, y0 + 0.25 + Double(th) * 0.9375]
}
func layer(width: Int, height: Int, pixels: Data, colour: Bool, x0: Double, y0: Double, nearest: Bool = false,
           table: Data? = nil) -> NSMutableDictionary {
    let value: NSMutableDictionary = ["width": width, "height": height, "pixels": pixels, "clut": clut(),
        "frameIdentity": "large", "level": 300.0, "widthWindow": 1400.0, "isColor": colour,
        "screenToPixel": mapping(x0, y0), "viewSize": [tw, th], "softwareScale": 1, "nearest": nearest]
    if colour { value["hostBytes"] = pixels }
    if let table { value["transferFunction"] = table; value["transferLevel"] = 300.0; value["transferWidth"] = 1400.0 }
    return value
}

@main struct Check {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("skipped: no Metal device"); exit(2) }
        let metal = try PlanarMetalRenderer(device: device)
        let pilot = PlanarMetal4Renderer.isSupported(device) ? try PlanarMetal4Renderer(device: device) : nil
        var compared = 0, largest = 0

        func draw(_ value: NSDictionary) throws -> [UInt8] {
            let frame = try PlanarFrame(value)
            try metal.update(frame)
            let picture = [UInt8](try metal.renderBGRA(width: tw, height: th))
            if let pilot {
                try pilot.update(frame)
                expect([UInt8](try pilot.renderBGRA(width: tw, height: th)) == picture, "the Metal 4 pilot draws a large layer differently")
            }
            return picture
        }

        // (long side, wide?) - just past the limit, and further.
        for (side, wide) in [(16385, true), (20011, true), (16390, false)] {
            let w = wide ? side : 4, h = wide ? 4 : side
            // Where the view looks: near the far end, past any texture's reach.
            let x0 = wide ? Double(side - 200) : 0.0, y0 = wide ? 0.0 : Double(side - 20)
            let cx = wide ? side - 210 : 0, cy = wide ? 0 : side - 30
            let cw = wide ? 210 : w, ch = wide ? h : 30
            func crop<T>(_ values: [T], _ per: Int) -> [T] {
                var out = [T](); out.reserveCapacity(cw * ch * per)
                for y in cy..<(cy + ch) { let row = (y * w + cx) * per; out += values[row..<(row + cw * per)] }
                return out
            }
            let floats = (0..<(w * h)).map { i -> Float in Float((i * 2654435761) % 1400) - 400 + Float(i % 7) * 0.13 }
            let bytes = (0..<(w * h * 4)).map { UInt8(($0 * 97 + 13) % 256) }
            let curve = (0..<4096).map { Float(($0 * 40503) % 4096) / 4095 }
            let curveData = curve.withUnsafeBufferPointer { Data(buffer: $0) }
            func floatData(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

            let cases: [(String, Bool, Bool, Data?)] = [("float", false, false, nil), ("nearest", false, true, nil),
                                                        ("opacity table", false, false, curveData), ("colour", true, false, nil)]
            for (label, colour, nearest, table) in cases {
                let largeData = colour ? Data(bytes) : floatData(floats)
                let smallData = colour ? Data(crop(bytes, 4)) : floatData(crop(floats, 1))
                let big = try draw(layer(width: w, height: h, pixels: largeData, colour: colour, x0: x0, y0: y0,
                                         nearest: nearest, table: table))
                expect(metal.image?.width == 1, "\(label) \(w) x \(h): the layer was not put in a buffer")
                let small = try draw(layer(width: cw, height: ch, pixels: smallData, colour: colour,
                                           x0: x0 - Double(cx), y0: y0 - Double(cy), nearest: nearest, table: table))
                expect(metal.image?.width == cw, "\(label): the crop was not drawn from a texture")
                let difference = zip(big, small).map { abs(Int($0) - Int($1)) }.max()!
                if colour {
                    expect(difference <= 1, "\(label) \(w) x \(h): the buffer path differs from the texture path by \(difference)")
                } else {
                    expect(difference == 0, "\(label) \(w) x \(h): the buffer path differs from the texture path by \(difference)")
                }
                largest = max(largest, difference); compared += tw * th
            }
            // A fused layer read from a buffer, over a small image.
            let image: NSMutableDictionary = layer(width: 8, height: 8, pixels: floatData((0..<64).map { Float($0 * 20) }),
                                                   colour: false, x0: 0.0, y0: 0.0)
            var alpha = [UInt8](clut()); for i in 0..<256 { alpha[4 * i + 3] = UInt8((i * 37 + 11) % 256) }
            let fusedLarge = layer(width: w, height: h, pixels: floatData(floats), colour: false, x0: x0, y0: y0)
            fusedLarge["clut"] = Data(alpha)
            image["fusion"] = fusedLarge
            let withLarge = try draw(image)
            let fusedSmall = layer(width: cw, height: ch, pixels: floatData(crop(floats, 1)), colour: false,
                                   x0: x0 - Double(cx), y0: y0 - Double(cy))
            fusedSmall["clut"] = Data(alpha)
            image["fusion"] = fusedSmall
            expect(try draw(image) == withLarge, "a fused layer read from a buffer blends differently from a texture")
            compared += tw * th
        }
        print("PASS: \(compared) pixels of wide and tall layers past 16384 read from a buffer, equal to the texture path: float, nearest and opacity-table bytes bit for bit, colour within \(largest) level, a fused buffer layer identical\(pilot == nil ? "" : ", the Metal 4 pilot identical")")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-planar-large-') as name:
    directory = Path(name)
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
        print('FAIL: the planar renderer does not build with the large-image driver')
        raise SystemExit(1)
    result = subprocess.run([str(directory / 'check')], timeout=600)
    raise SystemExit(result.returncode)
