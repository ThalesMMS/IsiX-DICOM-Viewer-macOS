#!/usr/bin/env python3
"""A 3D frame that casts no rays shows the volume it showed before.

Under the scissors' outline, a measure, an angle or the oval, the 3D view asks
for frames in which the ray caster does not run: only the 2D marks change, and
the volume is drawn again as it was. A plain composite frame is shown from a
texture of the presenter, and VTK's image does not hold it: a frame without a
ray cast that drew VTK's image showed an empty view.

The presenter of the 3D views is compiled alone and drawn off screen:
- a frame shown from the presenter's texture shows that texture;
- the next frame, in which nothing announces a picture, shows it again;
- once a render says the frame is VTK's image, that image is drawn, in that
  frame and in the next.

`<git revision>` as an optional argument reads the presenter from that
revision, the negative control. Exit code 2: this Mac has no Metal device.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/VRPresenter.swift'

if revision:
    presenter = subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode()
else:
    presenter = (root / path).read_text()

DRIVER = r'''
import AppKit
import Metal
import QuartzCore

/// The device the presenter falls back on; the application's planar renderer keeps it.
enum PlanarHostRenderer {
    @MainActor static let device = MTLCreateSystemDefaultDevice()
}

@main
struct Main {
    static let side = 16

    @MainActor static func words(_ red: UInt16, _ green: UInt16, _ blue: UInt16, _ alpha: UInt16) -> [UInt16] {
        var all = [UInt16]()
        for _ in 0..<(side * side) { all += [red, green, blue, alpha] }
        return all
    }

    /// One frame with the volume's image drawn from `image`; the colour at its centre.
    @MainActor static func frame(_ presenter: VRPresenter, image: [UInt16], prepare: () -> Void = {}) -> [UInt8] {
        guard presenter.begin(width: side, height: side, red: 0, green: 0, blue: 0) else { return [] }
        prepare()
        image.withUnsafeBytes { bytes in
            presenter.drawImage(pixels: bytes.baseAddress!, memoryWidth: side, memoryHeight: side, usedWidth: side, usedHeight: side,
                                originX: 0, originY: 0, viewportWidth: side, viewportHeight: side, depth: 0.5, scale: 1)
        }
        presenter.finish()
        guard let pixels = presenter.readPixels(x: side / 2, y: side / 2, width: 1, height: 1, alpha: false) else { return [] }
        return [UInt8](pixels as Data)
    }

    @MainActor static func main() {
        guard let device = MTLCreateSystemDefaultDevice() else { exit(2) }
        let layer = CAMetalLayer()
        layer.device = device
        guard let presenter = VRPresenter(layer: layer) else {
            print("FAIL: the presenter could not be made")
            exit(1)
        }
        var failures = [String]()
        func expect(_ got: [UInt8], _ wanted: [UInt8], _ what: String) {
            if got != wanted { failures.append("\(what): \(got), expected \(wanted)") }
        }

        let empty = words(0, 0, 0, 0), green = words(0, 65535, 0, 65535)

        // The picture a Metal render leaves in the presenter's texture: red.
        guard let target = presenter.volumePictureTarget(width: side, height: side) else {
            print("FAIL: no texture for the volume's picture")
            exit(1)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: side, height: side, mipmapped: false)
        guard let staging = device.makeTexture(descriptor: descriptor), let queue = device.makeCommandQueue(),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { exit(2) }
        words(65535, 0, 0, 65535).withUnsafeBytes { bytes in
            staging.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: side * 8)
        }
        blit.copy(from: staging, to: target)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()

        expect(frame(presenter, image: empty) { presenter.showVolumePicture() }, [255, 0, 0],
               "the frame of a render shown from the texture")
        expect(frame(presenter, image: empty), [255, 0, 0], "the frame after it, without a ray cast")
        expect(frame(presenter, image: empty), [255, 0, 0], "a second frame without a ray cast")
        #if HAS_SHOW_VOLUME_IMAGE
        expect(frame(presenter, image: green) { presenter.showVolumeImage() }, [0, 255, 0],
               "the frame of a render that wrote VTK's image")
        expect(frame(presenter, image: green), [0, 255, 0], "the frame after it, without a ray cast")
        #endif

        if failures.isEmpty {
            print("PASS")
        } else {
            for failure in failures { print("FAIL: " + failure) }
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'VRPresenter.swift').write_text(presenter)
    (folder / 'Driver.swift').write_text(DRIVER)
    command = ['xcrun', 'swiftc', '-Onone', '-parse-as-library', '-suppress-warnings',
               str(folder / 'VRPresenter.swift'), str(folder / 'Driver.swift'), '-o', str(folder / 'driver')]
    if 'func showVolumeImage' in presenter:
        command[2:2] = ['-D', 'HAS_SHOW_VOLUME_IMAGE']
    built = subprocess.run(command, capture_output=True, text=True)
    if built.returncode != 0:
        print('FAIL: the presenter did not compile alone')
        print(built.stderr[-3000:])
        sys.exit(1)
    ran = subprocess.run([str(folder / 'driver')], capture_output=True, text=True)
    print(ran.stdout.strip() or ran.stderr.strip()[-2000:])
    if ran.returncode == 2:
        print('skipped: no Metal device')
    sys.exit(ran.returncode)
