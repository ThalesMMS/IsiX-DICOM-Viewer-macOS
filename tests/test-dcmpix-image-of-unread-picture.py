#!/usr/bin/env python3
"""The image of a picture that was never read from its file.

-[DCMPix image] asked the picture for its size before anything had read it from
its file: 0 by 0, of which no bitmap can be made, so the answer was nil. A
picture a viewer shows was read long before; the picture DicomImage makes to
answer -image was not, and inserting into a report the images selected in the
database window answered that none was selected.

The production -image and what it draws with (DCMPix+Display.swift) run here
against a stand-in DCMPix that is read only when something asks for it, as the
real one is: its size and pixels are there after `checkLoad`, and
`compute8bitRepresentation` leaves at once when there are no 8-bit bytes to
fill, as the real one does. A picture read from its file gives its image at its
size, grey and colour; one whose file cannot be read gives none, and no bitmap
of 0 by 0 is asked for; one already read gives the same image as before.
"""
import isix_modules
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
display = (root / 'Horos/Sources/DCMPix+Display.swift').read_text(encoding='utf-8')
start = display.index('    @objc(image)\n    public dynamic func image() -> NSImage! {')
end = display.index('    private func bitmapImage() -> NSImage? {', start)
end = display.index('\n    }\n', end) + 7
methods = display[start:end]

program = r'''
import AppKit
import IsiXImaging

final class DCMPix: NSObject {
    var horos_width = 0, horos_height = 0
    var horos_baseAddr: UnsafeMutablePointer<CChar>?
    var horos_isRGB = false
    var isRGB: Bool { horos_isRGB }
    /// What the file holds; nil for one that cannot be read.
    var file: (width: Int, height: Int, colour: Bool)?
    var loads = 0, computed = 0

    func checkLoad() {
        guard loads == 0 else { return }
        loads = 1
        guard let file else { return }
        horos_width = file.width; horos_height = file.height; horos_isRGB = file.colour
    }
    var baseAddr: UnsafeMutablePointer<CChar>! {
        checkLoad()
        if horos_baseAddr == nil { allocate8bitRepresentation() }
        return horos_baseAddr
    }
    func allocate8bitRepresentation() {
        checkLoad()
        let pixels = (horos_width + 4) * (horos_height + 4)
        horos_baseAddr = calloc(horos_isRGB ? pixels * 4 : pixels, 1)?.assumingMemoryBound(to: CChar.self)
        compute8bitRepresentation()
    }
    /// As the real one: nothing to fill, nothing done - and the file not read.
    func compute8bitRepresentation() {
        guard let base = horos_baseAddr else { return }
        checkLoad()
        computed += 1
        let bytes = UnsafeMutableRawPointer(base).assumingMemoryBound(to: UInt8.self)
        if horos_isRGB {
            // ARGB: red is the column, green the row, blue 7.
            for y in 0..<horos_height { for x in 0..<horos_width {
                let p = bytes + (y * horos_width + x) * 4
                p[0] = 255; p[1] = UInt8(x); p[2] = UInt8(y); p[3] = 7
            } }
        } else {
            for y in 0..<horos_height { for x in 0..<horos_width { bytes[y * horos_width + x] = UInt8((x + 2 * y) & 255) } }
        }
    }
METHODS
}

func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL: \(message)"); exit(1) } }
func rep(_ image: NSImage) -> NSBitmapImageRep { image.representations[0] as! NSBitmapImageRep }

// Grey, never read: the image is the picture, at its size.
var pix = DCMPix()
pix.file = (48, 32, false)
var image = pix.image()
check(image != nil, "the image of a picture not read yet is nil")
check(pix.loads == 1 && rep(image!).pixelsWide == 48 && rep(image!).pixelsHigh == 32 && rep(image!).samplesPerPixel == 1,
      "the image of a grey picture is \(rep(image!))")
check(rep(image!).bitmapData![0] == 0 && rep(image!).bitmapData![31 * 48 + 47] == UInt8((47 + 62) & 255), "the grey image does not hold the picture's bytes")

// Colour, never read: three samples a pixel, without the alpha.
pix = DCMPix()
pix.file = (20, 10, true)
image = pix.image()
check(image != nil && rep(image!).pixelsWide == 20 && rep(image!).pixelsHigh == 10 && rep(image!).samplesPerPixel == 3,
      "the image of a colour picture not read yet is \(String(describing: image))")
let last = rep(image!).bitmapData! + (9 * 20 + 19) * 3
check(last[0] == 19 && last[1] == 9 && last[2] == 7, "the colour image does not hold the picture's bytes: \(last[0]) \(last[1]) \(last[2])")

// A file that cannot be read: no image, and nothing of 0 by 0 asked of AppKit.
pix = DCMPix()
check(pix.image() == nil && pix.loads == 1, "a picture that cannot be read gave an image")

// Already read and drawn: the same image, made through the current window again.
pix = DCMPix()
pix.file = (16, 16, false)
_ = pix.baseAddr
let before = pix.computed
image = pix.image()
check(image != nil && rep(image!).pixelsWide == 16 && pix.computed == before + 1, "a picture already read was drawn \(pix.computed - before) times")
print("PASS: the image of a picture is made from its file when nothing had read it, grey and colour, and is none when the file cannot be read")
'''.replace('METHODS', methods)

with tempfile.TemporaryDirectory(prefix='horos-dcmpix-image-') as folder:
    work = Path(folder)
    (work / 'main.swift').write_text(program)
    built = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'modules'), '-suppress-warnings',
                            *isix_modules.module_flags('IsiXImaging', work / 'IsiXImaging'), str(work / 'main.swift'),
                            '-o', str(work / 'image')], capture_output=True, text=True)
    if built.returncode:
        print('FAIL: the production -image did not compile against the stand-in:\n%s' % (built.stderr or built.stdout)[-3000:])
        sys.exit(1)
    ran = subprocess.run([str(work / 'image')], capture_output=True, text=True)
    sys.stdout.write(ran.stdout)
    if ran.returncode:
        sys.stdout.write(ran.stderr[-2000:])
        sys.exit(1)
