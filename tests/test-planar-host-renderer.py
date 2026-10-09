#!/usr/bin/env python3
"""The view's picture, drawn by Metal into its layer and read back, without a UI.

The DCMView is no NSOpenGLView: PlanarHostRenderer draws the planar
frame into the view's CAMetalLayer and presents it with the frame's Core
Animation transaction, and draws the same frame into a texture of its own for
a capture or the magnifying lens. Checked here, against the renderer the host
draws with, at several sizes:
- what a capture reads back is the renderer's own BGRA, byte for byte;
- the inverted frame is each colour byte's complement, as the host's
  (ONE_MINUS_DST_COLOR, ZERO) quad made it;
- a drawable is drawn and presented, and a frame with no picture is cleared;
- an unchanged picture stays presented without another GPU command; changed
  pixels, inversion, viewport or layer redraw it, as do clearing/invalidation;
- offscreen captures leave the last picture's presentation intact;
- a closed or replaced volume session draws nothing, and a view without one
  (the MPR, orthogonal, endoscopy and preview views) still draws.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host-source', type=Path, default=root/'Horos/Sources/PlanarHostRenderer.swift')
args = parser.parse_args()

driver = r'''
import AppKit
import Metal
import QuartzCore

@main @MainActor struct Check {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { exit(2) }
        let registry = VolumeSessionRegistry.shared
        let id = VolumeIdentity(studyInstanceUID:"synthetic", seriesInstanceUID:"host")!
        var session = registry.open(identity:id, owner:"host")!
        let host = PlanarHostRenderer()
        guard host.uploadedTexture(layer:0) == nil else { fatalError("upload exists before a frame") }
        let control = try PlanarMetalRenderer(device:device)
        var table = [UInt8]()
        for i in 0..<256 { table += [UInt8(i), UInt8(255 - i), UInt8((i * 7) % 256), 255] }
        let clut = Data(table)
        let source = (0..<40).map { Float(($0*31)%256) }
        let payload: NSMutableDictionary = [
            "width":8, "height":5, "pixels":source.withUnsafeBytes { Data($0) }, "clut":clut,
            "frameIdentity":"frame/0", "level":128, "widthWindow":256,
            "viewSize":[8,5], "screenToPixel":[0,0,8,0,0,5], "nearest":false]
        var checked = 0
        for (w,h) in [(8,5),(512,320),(41,66),(8,5)] {
            let frame = try PlanarFrame(payload)
            try control.update(frame)
            let expected = try control.renderBGRA(width:w, height:h)
            guard let read = host.render(snapshot:payload, session:session, width:w, height:h, inverted:false) else {
                print("FAIL: no picture read back at \(w)x\(h)"); exit(1)
            }
            guard read == expected else { print("FAIL: the picture read back differs at \(w)x\(h)"); exit(1) }
            guard let inverted = host.render(snapshot:payload, session:session, width:w, height:h, inverted:true) else {
                print("FAIL: no inverted picture at \(w)x\(h)"); exit(1)
            }
            for i in stride(from: 0, to: read.count, by: 4) {
                for k in 0..<3 where inverted[i+k] != 255 - read[i+k] {
                    print("FAIL: the inverted picture is not the complement at \(w)x\(h), byte \(i+k)"); exit(1)
                }
            }
            checked += read.count / 4
        }
        // The collector reads the upload actually bound to Metal, not source fImage.
        guard let uploaded = host.uploadedTexture(layer: 0), uploaded.pixelFormat == .r32Float,
              uploaded.storageMode == .shared, uploaded.width == 8, uploaded.height == 5,
              host.uploadedTexture(layer: -1) == nil, host.uploadedTexture(layer: 2) == nil,
              host.uploadedTexture(layer: 1) == nil else { fatalError("invalid uploaded layer access") }
        var uploadedBytes = Data(count: 40 * 4)
        uploadedBytes.withUnsafeMutableBytes { buffer in
            uploaded.getBytes(buffer.baseAddress!, bytesPerRow: 8 * 4,
                              from: MTLRegionMake2D(0,0,8,5), mipmapLevel: 0)
        }
        guard uploadedBytes == source.withUnsafeBytes({ Data($0) }) else { fatalError("actual GPU upload differs") }
        let fusionHost = PlanarHostRenderer()
        let fusedPayload = payload.mutableCopy() as! NSMutableDictionary
        let secondaryValues = source.map { $0 + 100 }
        let secondary = payload.mutableCopy() as! NSMutableDictionary
        secondary["pixels"] = secondaryValues.withUnsafeBytes { Data($0) }
        secondary["frameIdentity"] = "secondary/0"
        fusedPayload["fusion"] = secondary
        guard fusionHost.render(snapshot:fusedPayload, session:nil, width:8, height:5, inverted:false) != nil,
              let fused = fusionHost.uploadedTexture(layer:1), fused.width == 8 else { fatalError("fused upload absent") }
        fusionHost.invalidate()
        guard fusionHost.uploadedTexture(layer:0) == nil, fusionHost.uploadedTexture(layer:1) == nil else {
            fatalError("invalidated upload exposed")
        }
        var retainedBytes = Data(count: 40 * 4)
        retainedBytes.withUnsafeMutableBytes { buffer in
            fused.getBytes(buffer.baseAddress!, bytesPerRow:8*4, from:MTLRegionMake2D(0,0,8,5), mipmapLevel:0)
        }
        guard retainedBytes == secondaryValues.withUnsafeBytes({ Data($0) }), retainedBytes != uploadedBytes else { fatalError("retained upload did not survive invalidation") }
        guard host.responds(to: NSSelectorFromString("uploadedTextureForLayer:")) else { fatalError("collector selector absent") }
        let byteHost = PlanarHostRenderer()
        let bytePayload = payload.mutableCopy() as! NSMutableDictionary
        let byteValues = Data((0..<40).map { UInt8($0) })
        bytePayload["hostBytes"] = byteValues
        guard byteHost.render(snapshot:bytePayload, session:nil, width:8, height:5, inverted:false) != nil,
              let byteTexture = byteHost.uploadedTexture(layer:0), byteTexture.pixelFormat == .r8Unorm else {
            fatalError("byte upload absent")
        }
        var byteRead = Data(count:40)
        byteRead.withUnsafeMutableBytes { buffer in
            byteTexture.getBytes(buffer.baseAddress!, bytesPerRow:8, from:MTLRegionMake2D(0,0,8,5), mipmapLevel:0)
        }
        guard byteRead == byteValues else { fatalError("byte upload differs") }
        // Overlay redraws keep the picture, while presentation changes draw it.
        let layer = CAMetalLayer()
        layer.device = device; layer.pixelFormat = .bgra8Unorm; layer.drawableSize = CGSize(width: 64, height: 48)
        func checkDraw(_ snapshot: NSDictionary, _ target: CAMetalLayer,
                       inverted: Bool = false, submitted: Bool = true) {
            let before = host.renderedFrameCount
            guard host.draw(snapshot:snapshot, session:session, layer:target, inverted:inverted),
                  host.renderedFrameCount == before + (submitted ? 1 : 0),
                  host.encodedGPUCommand == submitted, !host.backendName.isEmpty else {
                fatalError("picture presentation did not match expected submission: \(submitted)")
            }
        }
        checkDraw(payload, layer)
        checkDraw(payload, layer, submitted:false)
        checkDraw(payload, layer, inverted:true)
        checkDraw(payload, layer, inverted:true, submitted:false)

        // Pixel content changes even when the frame identity stays the same.
        let changed = payload.mutableCopy() as! NSMutableDictionary
        changed["pixels"] = source.map { $0 + 10 }.withUnsafeBytes { Data($0) }
        checkDraw(changed, layer, inverted:true)
        checkDraw(changed, layer, inverted:true, submitted:false)
        // A capture of another image does not replace the visible picture.
        guard host.render(snapshot:payload, session:session, width:8, height:5, inverted:false) != nil else {
            fatalError("offscreen capture failed")
        }
        checkDraw(changed, layer, inverted:true, submitted:false)
        checkDraw(payload, layer, inverted:true)

        layer.drawableSize = CGSize(width: 80, height: 60)
        checkDraw(payload, layer, inverted:true)
        checkDraw(payload, layer, inverted:true, submitted:false)
        let otherLayer = CAMetalLayer()
        otherLayer.device = device; otherLayer.pixelFormat = .bgra8Unorm; otherLayer.drawableSize = layer.drawableSize
        checkDraw(payload, otherLayer, inverted:true)
        checkDraw(payload, otherLayer, inverted:true, submitted:false)

        host.clear(layer:otherLayer, white:true, inverted:false)
        checkDraw(payload, otherLayer, inverted:true)
        host.invalidate()
        checkDraw(payload, otherLayer, inverted:true)
        checkDraw(payload, otherLayer, inverted:true, submitted:false)

        checkDraw(payload, layer)
        host.clear(layer:layer, white:true, inverted:false)
        // Without a session, as the MPR and preview views draw.
        let free = PlanarHostRenderer()
        guard free.render(snapshot:payload, session:nil, width:8, height:5, inverted:false) != nil else {
            print("FAIL: a view without a volume session draws nothing"); exit(1)
        }
        // A volume closed or replaced meanwhile draws nothing.
        checkDraw(payload, layer)
        checkDraw(payload, layer, submitted:false)
        registry.invalidateVolume(session.identity)
        guard !host.draw(snapshot:payload, session:session, layer:layer, inverted:false) else {
            print("FAIL: a stale session still draws"); exit(1)
        }
        let next = session.identity
        registry.close(session)
        session = registry.open(identity:next, owner:"host")!
        checkDraw(payload, layer)
        checkDraw(payload, layer, submitted:false)
        registry.close(session)
        guard !host.draw(snapshot:payload, session:session, layer:layer, inverted:false) else {
            print("FAIL: a closed session still draws"); exit(1)
        }
        guard registry.openSessionCount == 0 else { print("FAIL: a session was left open"); exit(1) }
        print("PASS: \(checked) pixels read back exact, presentation reuse, pixel/inversion/size/layer changes, capture isolation, clearing and sessions")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-planar-host-') as temporary:
    work = Path(temporary)
    (work/'Check.swift').write_text(driver)
    # PlanarMetal4Renderer is the backend the host may be asked for;
    # it compiles here so the selection and its fallback are exercised, not stubbed.
    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'PlanarMetalRenderer.swift',
               'PlanarMetal4Renderer.swift', 'MetalPerformanceTrace.swift', 'MPRMetalReslicer.swift',
               'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift']
    command = ['xcrun', 'swiftc', '-Onone', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'nonisolated', '-warnings-as-errors',
               *[str(root/'Horos/Sources'/name) for name in sources], str(args.host_source),
               str(work/'Check.swift'), '-o', str(work/'check')]
    subprocess.run(command, check=True)
    result = subprocess.run([str(work/'check')], timeout=45)
    raise SystemExit(result.returncode)
