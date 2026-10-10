#!/usr/bin/env python3
"""A capture reads back what the GPU drew, on every GPU, and never writes a black file.

An image exported from the 2D viewer on an Intel Mac came out black, while the
viewer showed it. A capture draws the frame into a texture off screen and
reads it back. The texture was shared, one memory for the CPU and the GPU,
which is what an Apple GPU has. The Intel and AMD GPUs of an x86_64 Mac draw
into their own memory: read back without being synchronized, the texture gives
the zeros it was made with.

- The readback texture is managed in an x86_64 build and shared otherwise, and
  PlanarMetalRenderer.bringToCPU synchronizes a managed one before it is read.
  Its source is compiled here as it is for x86_64, and run on this Mac twice:
  as it is, and with the x86_64 branches taken, so that a managed texture is
  cleared to a colour by the GPU, synchronized and read back as that colour.
  (This Mac's GPU shares its memory either way; that an unsynchronized read
  is black is seen only on Intel hardware. Managed storage is deprecated from
  macOS 27, which no Intel Mac runs: it is compiled for x86_64 alone.)
- Each place that reads a texture back asks for that storage and brings the
  texture to the CPU first.
- A view with an image that gives a capture no picture records why; the image
  and DICOM exports and the copy read it and write nothing.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


renderer = source_text('PlanarMetalRenderer')
start = renderer.index('    /// The storage of a texture the GPU draws into')
end = renderer.index('\n    }\n', renderer.index('static func bringToCPU', start)) + len('\n    }\n')
helpers = renderer[start:end]
check('#if arch(x86_64)' in helpers and re.search(r'#if arch\(x86_64\)\s+return \.managed\s+#else\s+return \.shared', helpers),
      'the readback texture is not managed for x86_64 and shared otherwise')
check(helpers.count('#if arch(x86_64)') == 2 and 'synchronize(resource: texture)' in helpers and 'waitUntilCompleted()' in helpers,
      'a managed texture is not synchronized, and waited for, before it is read')

for name, reads in (('PlanarMetalRenderer', 'func renderTexture('), ('PlanarMetal4Renderer', 'func renderTexture('),
                    ('PlanarHostRenderer', 'public func render(snapshot:')):
    source = source_text(name)
    body = source[source.index(reads):]
    body = body[:body.index('\n    }\n') + 1]
    check('readbackStorageMode' in body and 'storageMode = .shared' not in body, f'{name}: the readback texture is still shared everywhere')
    brought = body.find('bringToCPU(')
    check(brought > 0, f'{name}: the texture is not brought to the CPU')
    read = body.find('getBytes(')
    check(read < 0 or brought < read, f'{name}: the texture is read before it is brought to the CPU')

bridge = (root / 'Horos/Sources/PlanarHostBridge.m').read_text()
pixels = bridge[bridge.index('- (NSData *)horosPlanarPixelsWidth:'):bridge.index('+ (void)horosResetCaptureFailure')]
check('if (!pixels && self.curDCM)' in pixels and 'captureFailure = [reason copy]' in pixels,
      'a view with an image and no picture does not record why')
export = source_text('ViewerController+Export')
image_export = export[export.index('func endExportImage('):]
loop = image_export[image_export.index('DCMView.horosResetCaptureFailure()'):]
check(loop.find('if DCMView.horosCaptureFailure() != nil { break }') < loop.find('representationOfImageReps'),
      'the image export encodes a capture before asking whether it failed')
check('if let reason = DCMView.horosCaptureFailure()' in image_export, 'the image export does not say that a capture failed')
dicom = export[export.index('func exportDICOMFileInt(_ screenCapture: Int32, withName name: String!, allViewers: Bool)'):]
dicom = dicom[:dicom.index('func findPlayStopButton')]
check(dicom.find('DCMView.horosResetCaptureFailure()') < dicom.find('getRawPixelsWidth('), 'the DICOM export does not start from no failure')
failed = dicom.find('let reason = DCMView.horosCaptureFailure()')
check(0 < failed < dicom.find('writeDCMFile(') and 'free(failed)' in dicom, 'the DICOM export writes the file of a failed capture')
check(export.count('reportDICOMExportCaptureFailure()') == 3, 'the DICOM exports do not say, once, that a capture failed')
view = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('latin1')
copy = view[view.index('-(IBAction) copy:(id) sender'):]
copy = copy[:copy.index('[pb setData:')]
check('[DCMView horosResetCaptureFailure]' in copy and 'if( [DCMView horosCaptureFailure])' in copy and 'return;' in copy,
      'the copy puts the picture of a failed capture on the pasteboard')

program = '''import Metal
import Foundation
enum PlanarMetalRenderer {
    static func failure() -> NSError { NSError(domain: "test", code: 2) }
''' + helpers + '''}
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { print("no Metal device"); exit(2) }
check(PlanarMetalRenderer.readbackStorageMode.rawValue == EXPECTED, "the readback storage is \\(PlanarMetalRenderer.readbackStorageMode.rawValue), not EXPECTED")
for mode in [PlanarMetalRenderer.readbackStorageMode] {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 48, mipmapped: false)
    descriptor.storageMode = mode; descriptor.usage = [.renderTarget, .shaderRead]
    guard let target = device.makeTexture(descriptor: descriptor) else { check(false, "no texture of storage \\(mode.rawValue)"); continue }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0.5, 0.25, 1)
    let command = queue.makeCommandBuffer()!
    command.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
    command.commit(); command.waitUntilCompleted()
    do { try PlanarMetalRenderer.bringToCPU(target, queue: queue) } catch { check(false, "bringToCPU threw for storage \\(mode.rawValue)") }
    do { try PlanarMetalRenderer.bringToCPU(target, queue: nil) } catch { check(false, "bringToCPU without a queue threw") }
    var bytes = [UInt8](repeating: 0, count: 64 * 48 * 4)
    target.getBytes(&bytes, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 48), mipmapLevel: 0)
    for pixel in [0, 64 * 24 + 32, 64 * 48 - 1] {
        let bgra = Array(bytes[pixel * 4 ..< pixel * 4 + 4])
        check(bgra[0] == 64 && (bgra[1] == 127 || bgra[1] == 128) && bgra[2] == 255 && bgra[3] == 255,
              "storage \\(mode.rawValue) read back \\(bgra) at pixel \\(pixel)")
    }
}
print("ok")
'''
with tempfile.TemporaryDirectory(prefix='horos-readback-') as folder:
    # MTLStorageMode: shared 0, managed 1.
    source = Path(folder) / 'main.swift'
    source.write_text(program.replace('EXPECTED', '1'))
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-warnings-as-errors', '-target', 'x86_64-apple-macos26.0',
                            '-typecheck', str(source)], capture_output=True, text=True)
    check(built.returncode == 0, 'the readback helpers do not compile for x86_64:\n' + built.stderr[-1500:])
    for name, text in (('shared', program.replace('EXPECTED', '0')),
                       ('managed', program.replace('EXPECTED', '1').replace('#if arch(x86_64)', '#if true'))):
        source = Path(folder) / name / 'main.swift'
        source.parent.mkdir()
        source.write_text(text)
        binary = source.parent / 'readback'
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-target', 'arm64-apple-macos26.0', str(source), '-o', str(binary)],
                               capture_output=True, text=True)
        check(built.returncode == 0, f'{name}: the readback helpers do not compile:\n' + built.stderr[-1500:])
        if built.returncode != 0:
            continue
        ran = subprocess.run([str(binary)], capture_output=True, text=True)
        if ran.returncode == 2:
            print(f'{name}: skipped the readback itself: ' + ran.stdout.strip())
        else:
            check(ran.returncode == 0 and ran.stdout.strip().endswith('ok'), f'{name} readback: ' + (ran.stdout + ran.stderr).strip()[-800:])

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print('ok: captures read back on every GPU, and a failed one writes nothing')
