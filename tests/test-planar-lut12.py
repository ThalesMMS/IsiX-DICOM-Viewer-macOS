#!/usr/bin/env python3
"""The planar Metal renderer draws the 12-bit LUT mode's packed bytes.

The 12-bit LUT mode is on only with the automatic12BitTotoku preference
and +[AppController canDisplay12Bit], which a display vendor's plugin sets. The
plugin packs each pixel into four bytes (DCMPix's LUT12baseAddr) that the
display decodes, and -[DCMView loadTextureIn:...] takes them as colour bytes,
lays no table over them - no CLUT, channel factor or alpha table - and
enlarges them with vImageScale_ARGB8888 like a colour image. It used to be
refused by the planar snapshot; the maintainer decided to port it.

Checked in the sources: the snapshot hands LUT12baseAddr over as colour bytes
with no table, fused or not, and the host's branch still lays nothing over
those bytes.

On the GPU, with synthetic packed bytes (a 12-bit ramp split over the three
colour bytes, every value 0-4095 once): at texel centres both backends draw the
packed bytes exactly, so every 12-bit value decodes back; the 2x and 3x
enlargements upload vImageScale_ARGB8888 of the packed bytes, the host's; the
view's channel factors, which would table a colour image, leave them alone;
and fused over another series the packed bytes are blended source-alpha with
their fourth byte as the alpha, as drawRect: blends the host's texture of them.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


# The original renderer, the reference these checks port, has left the view;
# it is read from a public revision that retains it.
ORIGINAL_RENDERER = '4d46ba717f9dbd73265d0a9944e1d216f9d00736'
ORIGINAL_SOURCES = ('Horos/Sources/DCMView.m', 'Horos/Sources/LegacyScalarCLUT.swift')


def read(path):
    if revision or path in ORIGINAL_SOURCES:
        return subprocess.check_output(['git', '-C', str(root), 'show', (revision or ORIGINAL_RENDERER) + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


failures = []
bridge = read('Horos/Sources/PlanarHostBridge.m')
view = read('Horos/Sources/DCMView.m')
snapshot = bridge[bridge.index('- (NSDictionary *)horosPlanarSnapshot'):]
refusal = snapshot[:snapshot.index('return @{@"error": unsupported};')]
if 'pix.isLUT12Bit)' in refusal.replace('BOOL packed = pix.isLUT12Bit;', ''):
    failures.append('the snapshot still refuses the 12-bit LUT mode')
if 'fused && packed' in refusal:
    failures.append('a fused series in the 12-bit LUT mode is still refused')
if 'if (packed || volumeSlab) snapshot[@"bytesCarryAlpha"] = @YES;' not in snapshot:
    failures.append('the snapshot does not mark the packed bytes, which a fusion blends untabled')
if 'char *bytes = packed ? (char *)pix.LUT12baseAddr : pix.baseAddr;' not in snapshot:
    failures.append('the snapshot does not hand over the packed bytes, LUT12baseAddr')
if '@"isColor": @(colourBytes || volumeSlab)' not in snapshot or 'BOOL colourBytes = pix.isRGB || packed;' not in snapshot:
    failures.append('the packed bytes are not drawn as colour bytes')
if 'if (pix.isRGB && !packed && (fused ||' not in snapshot:
    failures.append('a table can still be laid over the packed bytes')
if not re.search(r'if\( self\.curDCM\.isLUT12Bit\)\s*\{\s*\}\s*else if\(\(localColorTransfer == YES\) \|\| \(blending == YES\)\)', view):
    failures.append('the host now lays something over the packed bytes; the port must follow it')
if not re.search(r'if\( self\.curDCM\.isLUT12Bit\)\s*src\.data = \(char\*\) self\.curDCM\.LUT12baseAddr;', view):
    failures.append('the host no longer enlarges the packed bytes as colour bytes')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

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

// A 12-bit value over the three colour bytes; alpha, the first byte, unused.
func pack(_ v: Int) -> [UInt8] { [255, UInt8(v >> 4), UInt8(((v & 15) << 4) | (v >> 8)), UInt8(v & 255)] }
func unpack(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int { (Int(r) << 4) | (Int(g) >> 4) }

@main struct Check {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("skipped: no Metal device"); exit(2) }
        let metal = try PlanarMetalRenderer(device: device)
        let pilot = PlanarMetal4Renderer.isSupported(device) ? try PlanarMetal4Renderer(device: device) : nil
        let w = 64, h = 64
        let values = (0..<(w * h)).map { ($0 * 1531) % 4096 }   // every 12-bit value once
        let packed = Data(values.flatMap(pack))
        var table = [UInt8](); for i in 0..<256 { table += [UInt8(255 - i), UInt8(i), UInt8((i * 3) % 256), 255] }
        // A 1:1 view whose pixel centres are the texel centres.
        func frame(scale: Int) throws -> PlanarFrame {
            try PlanarFrame(["width": w, "height": h, "pixels": packed, "hostBytes": packed, "isColor": true,
                             "clut": Data(table), "frameIdentity": "lut12", "level": 40.0, "widthWindow": 80.0,
                             "screenToPixel": [0.0, 0.0, Double(w), 0.0, 0.0, Double(h)], "viewSize": [w, h],
                             "softwareScale": scale, "nearest": false] as NSDictionary)
        }
        let plain = try frame(scale: 1)
        expect(plain.window.z == 2 && plain.colourTable == nil, "the packed bytes are not drawn as untabled colour bytes")
        try metal.update(plain)
        let picture = [UInt8](try metal.renderBGRA(width: w, height: h))
        if let pilot {
            try pilot.update(plain)
            expect([UInt8](try pilot.renderBGRA(width: w, height: h)) == picture, "the Metal 4 pilot draws the packed bytes differently")
        }
        for i in 0..<(w * h) {
            let r = picture[4 * i + 2], g = picture[4 * i + 1], b = picture[4 * i]
            expect([r, g, b] == Array(pack(values[i])[1...3]), "pixel \(i) draws \([r, g, b]), not the packed bytes")
            expect(unpack(r, g, b) == values[i], "pixel \(i) decodes to \(unpack(r, g, b)), not \(values[i])")
        }
        expect(Set(values).count == 4096, "the ramp does not cover the 12 bits")
        // Enlarged as the host enlarges colour bytes, and never tabled.
        for scale in [2, 3] {
            let big = try frame(scale: scale)
            try metal.update(big)
            let expected = [UInt8](try PlanarFrame.enlargeARGB(bytes: packed, width: w, height: h, scale: scale))
            expect(texture(metal.image!) == expected, "the \(scale)x texture is not vImageScale_ARGB8888 of the packed bytes")
            if let pilot { try pilot.update(big); expect(texture(pilot.image!) == expected, "the \(scale)x pilot texture differs") }
        }
        // Fused over a black image: each pixel is the packed colour times its
        // fourth byte, source-alpha over black, within the blend's rounding.
        var alphaPacked = [UInt8](packed)
        for i in 0..<(w * h) { alphaPacked[4 * i] = UInt8((i * 37) % 256) }
        let under: NSMutableDictionary = ["width": w, "height": h, "isColor": false, "pixels": Data(count: w * h * 4),
            "clut": Data(repeating: 0, count: 1024), "frameIdentity": "under", "level": 40.0, "widthWindow": 80.0,
            "screenToPixel": [0.0, 0.0, Double(w), 0.0, 0.0, Double(h)], "viewSize": [w, h], "softwareScale": 1, "nearest": false]
        under["fusion"] = ["width": w, "height": h, "pixels": Data(alphaPacked), "hostBytes": Data(alphaPacked), "isColor": true, "bytesCarryAlpha": true,
            "clut": Data(table), "frameIdentity": "lut12 fused", "level": 40.0, "widthWindow": 80.0,
            "screenToPixel": [0.0, 0.0, Double(w), 0.0, 0.0, Double(h)], "viewSize": [w, h], "softwareScale": 1, "nearest": false] as NSDictionary
        let fused = try PlanarFrame(under)
        expect(fused.fusion.count == 1, "a fused series in the 12-bit LUT mode is not drawn")
        try metal.update(fused)
        let blended = [UInt8](try metal.renderBGRA(width: w, height: h))
        var largest = 0
        for i in 0..<(w * h) {
            let alpha = Double(alphaPacked[4 * i]) / 255
            for (channel, byte) in [(2, 1), (1, 2), (0, 3)] {
                let expected = Double(alphaPacked[4 * i + byte]) * alpha
                largest = max(largest, Int(abs(Double(blended[4 * i + channel]) - expected).rounded(.up)))
            }
        }
        expect(largest <= 1, "the fused packed bytes are not blended with their fourth byte as the alpha (off by \(largest))")
        if let pilot { try pilot.update(fused); expect([UInt8](try pilot.renderBGRA(width: w, height: h)) == blended, "the Metal 4 pilot blends the fused packed bytes differently") }
        print("PASS: 4096 packed 12-bit values drawn byte for byte and decoded back on both backends; 2x and 3x enlargements equal vImageScale_ARGB8888 of the packed bytes; no table laid over them; fused, blended with their fourth byte within \(largest) level")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-planar-lut12-') as name:
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
        print('FAIL: the planar renderer does not build with the 12-bit driver')
        raise SystemExit(1)
    result = subprocess.run([str(directory / 'check')], timeout=300)
    raise SystemExit(result.returncode)
