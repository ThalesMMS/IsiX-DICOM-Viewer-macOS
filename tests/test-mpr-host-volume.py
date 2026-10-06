#!/usr/bin/env python3
"""The MPR's typed volume at the Objective-C/Swift boundary.

`MPRHostBridge.m` converts the viewer's volume, the fused series' snapshot and
an RGB volume into one `HorosMPRVolume` per plane. This compiles that type with
the engine and checks, on the GPU:

- every refusal happens at the conversion, with its reason, before a byte is
  read: no owner, no extent, a buffer shorter than its slices, an extent whose
  byte count overflows, a transform missing, short, not finite or degenerate,
  a background or step not finite, and for the fused snapshot its `error`, a
  missing key, a key of the wrong type, a fractional extent and an RGB series;
- a buffer longer than its slices is accepted and cut without a copy: the view
  points at the owner's own bytes, for exactly the slices;
- the view keeps its owner alive, and so does an engine that holds the
  uploaded volume, until `releaseVolume`; then the owner goes;
- a scalar volume uploaded through the typed path reslices to the same floats,
  bit for bit, as the same bytes through the former number-array upload;
- an RGB volume's three channels are uploaded by the typed path and resliced
  back to their bytes;
- the upload key (`isSameVolumeAs:`) tells the same buffer and placement from
  another buffer with equal content and from another placement.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]

DRIVER = r'''
import Foundation
import Metal

var failures = [String]()
func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { failures.append(reason()) } }
func refused(_ reason: String, _ make: () throws -> MPRHostVolume) {
    do { _ = try make(); failures.append("accepted: " + reason) }
    catch { expect((error as NSError).localizedDescription.contains(reason), "refused with \((error as NSError).localizedDescription), not \(reason)") }
}

let W = 8, H = 6, D = 5
let identity: [NSNumber] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1].map { NSNumber(value: $0) }
func ramp(extra: Int = 0) -> NSData {
    var values = [Float](repeating: -7, count: W * H * D + extra)
    for k in 0..<D { for j in 0..<H { for i in 0..<W { values[(k * H + j) * W + i] = Float(i + 10 * j + 100 * k) } } }
    return values.withUnsafeBytes { NSData(bytes: $0.baseAddress!, length: $0.count) }
}
func scalar(_ owner: NSData?, w: Int = W, h: Int = H, d: Int = D, transform: [NSNumber]? = identity,
            background: Float = -1, step: Double = 1) throws -> MPRHostVolume {
    try MPRHostVolume.volume(owner: owner, width: w, height: h, depth: d, voxelToWorld: transform,
                             background: background, sampleStep: step, colour: false)
}

@main struct Check {
    static func main() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { exit(2) }

        // --- refusals at the conversion ------------------------------------
        refused("The reconstruction has no volume.") { try scalar(nil) }
        refused("has no extent") { try scalar(ramp(), d: 0) }
        refused("The volume bytes do not match the slice list.") { try scalar(ramp(), d: D + 1) }
        refused("The volume bytes do not match the slice list.") { try scalar(ramp(), w: Int.max / 2, h: 4) }
        refused("transform is unavailable") { try scalar(ramp(), transform: nil) }
        refused("transform is unavailable") { try scalar(ramp(), transform: Array(identity.prefix(15))) }
        var nan = identity; nan[12] = NSNumber(value: Double.nan)
        refused("transform is not finite") { try scalar(ramp(), transform: nan) }
        var flat = identity; flat[10] = 0
        refused("geometry is degenerate") { try scalar(ramp(), transform: flat) }
        refused("background is not finite") { try scalar(ramp(), background: .infinity) }
        refused("spacing is not usable") { try scalar(ramp(), step: 0) }
        refused("spacing is not usable") { try scalar(ramp(), step: .nan) }

        let good: [String: Any] = ["volume": ramp(), "width": W, "height": H, "depth": D, "transform": identity,
                                   "background": -1024, "sampleStep": 0.5, "colour": false]
        func fused(_ change: (inout [String: Any]) -> Void) throws -> MPRHostVolume {
            var snapshot = good; change(&snapshot); return try MPRHostVolume.fused(snapshot: snapshot as NSDictionary)
        }
        refused("The fused series has no volume yet.") { try MPRHostVolume.fused(snapshot: nil) }
        refused("The 3D view has no fused volume.") { try fused { $0 = ["error": "The 3D view has no fused volume."] } }
        refused("no valid volume") { try fused { $0["volume"] = nil } }
        refused("no valid volume") { try fused { $0["volume"] = "bytes" } }
        refused("no valid width") { try fused { $0["width"] = 1.5 } }
        refused("no valid height") { try fused { $0["height"] = "6" } }
        refused("no valid depth") { try fused { $0["depth"] = 0 } }
        refused("no valid transform") { try fused { $0["transform"] = ["1"] } }
        refused("no valid background") { try fused { $0["background"] = nil } }
        refused("no valid sampleStep") { try fused { $0["sampleStep"] = [0.5] } }
        refused("An RGB fused series keeps the original renderer.") { try fused { $0["colour"] = true } }
        refused("The fused volume bytes do not match its slices.") { try fused { $0["depth"] = D + 1 } }
        let fusedVolume = try fused { _ in }
        expect(fusedVolume.isFused && fusedVolume.background == -1024 && fusedVolume.sampleStep == 0.5, "fused fields")

        // --- a longer buffer, cut without a copy, owner kept ---------------
        weak var weakOwner: NSData?
        var volume: MPRHostVolume? = try autoreleasepool {
            let owner = ramp(extra: 13)
            weakOwner = owner
            return try scalar(owner)
        }
        expect(weakOwner != nil, "the volume does not keep its owner")
        autoreleasepool { if let volume {
            expect(volume.byteCount == W * H * D * 4 && volume.voxels.count == volume.byteCount && volume.slices.length == volume.byteCount,
                   "the view is not exactly the slices")
            expect(volume.voxels.withUnsafeBytes { $0.baseAddress } == volume.owner.bytes && volume.slices.bytes == volume.owner.bytes,
                   "the view is a copy of the owner's bytes")
            expect(volume.rowBytes == W * 4 && volume.sliceBytes == W * H * 4, "strides")
        } }

        // --- the engine keeps the owner of what it holds, until release ----
        let reslicer = try MPRReslicerBridge.make()
        try autoreleasepool { try reslicer.upload(volume!); volume = nil }
        expect(weakOwner != nil, "the engine holds bytes whose owner is gone")
        autoreleasepool { reslicer.releaseVolume() }
        expect(weakOwner == nil, "the owner outlives releaseVolume")

        // --- the same floats as the former upload --------------------------
        let bytes = ramp()
        let typed = try scalar(ramp(extra: 32))
        try reslicer.upload(typed)
        let legacy = try MPRReslicerBridge.make()
        try legacy.uploadVolume(bytes, width: W, height: H, depth: D, voxelToWorld: identity)
        for (origin, orientation) in [([0, 0, 2], [1, 0, 0, 0, 1, 0, 0, 0, 1]), ([0.5, 0.25, 0.3], [0.8, 0.6, 0, -0.6, 0.8, 0, 0, 0, 1]),
                                      ([3, 0, 0], [0, 1, 0, 0, 0, 1, 1, 0, 0])] as [([Double], [Double])] {
            let a = try reslicer.reslice(origin: origin.map { NSNumber(value: $0) }, orientation: orientation.map { NSNumber(value: $0) },
                                         spacing: 1, width: W, height: H, thickness: 2, sampleStep: typed.sampleStep, projection: 1, background: Double(typed.background))
            let b = try legacy.reslice(origin: origin.map { NSNumber(value: $0) }, orientation: orientation.map { NSNumber(value: $0) },
                                       spacing: 1, width: W, height: H, thickness: 2, sampleStep: 1, projection: 1, background: -1)
            expect(a == b, "the typed upload reslices other floats than the former one at \(origin)")
        }
        let centre = try reslicer.reslice(origin: [0, 0, 3], orientation: identity.prefix(3).map { $0 } + [0, 1, 0, 0, 0, 1].map { NSNumber(value: $0) },
                                          spacing: 1, width: W, height: H, thickness: 0, sampleStep: 1, projection: 1, background: -1)
        let values = (centre as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        expect(values[0] == 300 && values[W * H - 1] == Float(W - 1 + 10 * (H - 1) + 300), "the plane through slice 3 is not its voxels")

        // --- the upload key ------------------------------------------------
        let owner = ramp()
        let first = try scalar(owner), same = try scalar(owner), copy = try scalar(ramp())
        var moved = identity; moved[12] = 5
        let shifted = try scalar(owner, transform: moved)
        expect(first.isSameVolume(as: same) && !first.isSameVolume(as: copy) && !first.isSameVolume(as: shifted)
               && !first.isSameVolume(as: nil), "the upload key does not follow buffer and placement")

        // --- RGB channels --------------------------------------------------
        var argb = [UInt8](repeating: 0, count: W * H * D * 4 + 8)
        for voxel in 0..<(W * H * D) { argb[voxel * 4] = 255; argb[voxel * 4 + 1] = UInt8(voxel % 256); argb[voxel * 4 + 2] = UInt8((voxel * 3) % 256); argb[voxel * 4 + 3] = UInt8((voxel * 7) % 256) }
        let colour = try MPRHostVolume.volume(owner: NSData(bytes: argb, length: argb.count), width: W, height: H, depth: D,
                                              voxelToWorld: identity, background: -1, sampleStep: 1, colour: true)
        do { try reslicer.upload(colour); failures.append("a colour volume was uploaded as a scalar one") } catch {}
        let channels = try (0..<3).map { _ in try MPRReslicerBridge.make() }
        try MPRReslicerBridge.uploadColour(colour, into: channels)
        let planes = try MPRReslicerBridge.resliceChannels(channels, origin: [0, 0, 2], orientation: [1, 0, 0, 0, 1, 0, 0, 0, 1].map { NSNumber(value: $0) },
                                                          spacing: 1, width: W, height: H, thickness: 0, sampleStep: 1, projection: 1, background: -1)
        for (channel, plane) in planes.enumerated() {
            let floats = (plane as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let wanted = (0..<(W * H)).map { Float(argb[(2 * W * H + $0) * 4 + 1 + channel]) }
            expect(floats == wanted, "RGB channel \(channel) is not its bytes")
        }

        if failures.isEmpty { print("ok") } else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
'''


def main():
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / 'Check.swift').write_text(DRIVER)
        sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'MPRMetalReslicer.swift', 'MetalPerformanceTrace.swift',
                   'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift', 'MPRHostVolume.swift']
        subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-suppress-warnings',
                        *[str(root / 'Horos/Sources' / name) for name in sources], str(work / 'Check.swift'),
                        '-o', str(work / 'check')], check=True)
        result = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=180)
        if result.returncode == 2:
            print('skipped: no Metal device', file=sys.stderr)
            return 2
        if result.returncode or result.stdout.strip() != 'ok':
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr)
            return 1
    print('mpr host volume: refusals at the conversion with their reasons, a longer buffer cut without a copy, the owner kept '
          'by the view and the engine until release, the same floats as the former upload, RGB channels, upload key')
    return 0


if __name__ == '__main__':
    sys.exit(main())
