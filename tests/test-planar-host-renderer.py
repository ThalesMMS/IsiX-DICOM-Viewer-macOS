#!/usr/bin/env python3
"""The view's picture, drawn by Metal into its layer and read back, without a UI (#728).

Since #728 the DCMView is no NSOpenGLView: PlanarHostRenderer draws the planar
frame into the view's CAMetalLayer and presents it with the frame's Core
Animation transaction, and draws the same frame into a texture of its own for
a capture or the magnifying lens. Checked here, against the renderer the host
draws with, at several sizes:
- what a capture reads back is the renderer's own BGRA, byte for byte;
- the inverted frame is each colour byte's complement, as the host's
  (ONE_MINUS_DST_COLOR, ZERO) quad made it;
- a drawable is drawn and presented, and a frame with no picture is cleared;
- an unchanged frame is not uploaded again, a new one is;
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
        // A frame that did not change is not uploaded again; a new one is.
        let before = host.renderedFrameCount
        let layer = CAMetalLayer()
        layer.device = device; layer.pixelFormat = .bgra8Unorm; layer.drawableSize = CGSize(width: 64, height: 48)
        guard host.draw(snapshot:payload, session:session, layer:layer, inverted:false),
              host.draw(snapshot:payload, session:session, layer:layer, inverted:true) else {
            print("FAIL: the layer was not drawn"); exit(1)
        }
        guard host.renderedFrameCount == before + 2, host.encodedGPUCommand, !host.backendName.isEmpty else {
            print("FAIL: the drawn frames were not recorded"); exit(1)
        }
        host.clear(layer:layer, white:true, inverted:false)
        // Without a session, as the MPR and preview views draw.
        let free = PlanarHostRenderer()
        guard free.render(snapshot:payload, session:nil, width:8, height:5, inverted:false) != nil else {
            print("FAIL: a view without a volume session draws nothing"); exit(1)
        }
        // A volume closed or replaced meanwhile draws nothing.
        registry.invalidateVolume(session.identity)
        guard !host.draw(snapshot:payload, session:session, layer:layer, inverted:false) else {
            print("FAIL: a stale session still draws"); exit(1)
        }
        let next = session.identity
        registry.close(session)
        session = registry.open(identity:next, owner:"host")!
        host.invalidate(); registry.close(session)
        guard !host.draw(snapshot:payload, session:session, layer:layer, inverted:false) else {
            print("FAIL: a closed session still draws"); exit(1)
        }
        guard registry.openSessionCount == 0 else { print("FAIL: a session was left open"); exit(1) }
        print("PASS: \(checked) pixels read back exact, the inverted frame exact, layer drawing, clearing and sessions")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-planar-host-') as temporary:
    work = Path(temporary)
    (work/'Check.swift').write_text(driver)
    # PlanarMetal4Renderer is the backend the host may be asked for (#609);
    # it compiles here so the selection and its fallback are exercised, not stubbed.
    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'PlanarMetalRenderer.swift',
               'PlanarMetal4Renderer.swift', 'MetalPerformanceTrace.swift', 'MPRMetalReslicer.swift',
               'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift']
    command = ['xcrun', 'swiftc', '-Onone', '-parse-as-library', '-suppress-warnings',
               *[str(root/'Horos/Sources'/name) for name in sources], str(args.host_source),
               str(work/'Check.swift'), '-o', str(work/'check')]
    subprocess.run(command, check=True)
    result = subprocess.run([str(work/'check')], timeout=45)
    raise SystemExit(result.returncode)
