#!/usr/bin/env python3
"""An empty frame says why it is empty, on the image and not only in the log."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text, class_text

root = Path(__file__).resolve().parents[1]
main = r'''import Foundation

// Both sentences are short: they are drawn over the image, on one line, beside
// "Vertically Flipped" and "VOI LUT Applied".
let absent = MissingPixelsReason.reasonForAbsentPixelData()
assert(!absent.isEmpty && absent.count < 60, absent)
assert(absent.lowercased().contains("no image data"), absent)

// Frames are numbered from zero inside and from one on screen, where the viewer
// already shows them that way as "Im: 3/8".
assert(MissingPixelsReason.reasonForEmptyFrame(0).contains("1"))
assert(MissingPixelsReason.reasonForEmptyFrame(7).contains("8"))
assert(!MissingPixelsReason.reasonForEmptyFrame(0).contains("Frame 0"))
for frame in 0..<20 {
    let sentence = MissingPixelsReason.reasonForEmptyFrame(frame)
    assert(!sentence.isEmpty && sentence.count < 60, sentence)
}
assert(MissingPixelsReason.reasonForEmptyFrame(0) != absent)

// A non-image object names its SOP class, so a person can look it up.
let spectroscopy = MissingPixelsReason.reasonForNonImageStorage("1.2.840.10008.5.1.4.1.1.4.2")
assert(spectroscopy.contains("1.2.840.10008.5.1.4.1.1.4.2"), spectroscopy)
assert(spectroscopy.lowercased().contains("not an image"), spectroscopy)
assert(MissingPixelsReason.reasonForNonImageStorage(nil) == "This object is not an image")
assert(MissingPixelsReason.reasonForNonImageStorage("  ") == "This object is not an image")
assert(MissingPixelsReason.reasonForNonImageStorage(" 1.2.3 ").contains("(1.2.3)"))

let unreadable = MissingPixelsReason.reasonForUnreadableFrame()
assert(!unreadable.isEmpty && unreadable.count < 60, unreadable)

// A whole video in the Pixel Data element that could not be turned into
// pictures names the transfer syntax, which is what says why.
let undecodable = MissingPixelsReason.reasonForUndecodableVideoStream("1.2.840.10008.1.2.4.107")
assert(undecodable.contains("1.2.840.10008.1.2.4.107"), undecodable)
assert(undecodable.lowercased().contains("could not be decoded"), undecodable)
assert(MissingPixelsReason.reasonForUndecodableVideoStream(nil)
       == "This video stream could not be decoded")
assert(MissingPixelsReason.reasonForUndecodableVideoStream("   ")
       == "This video stream could not be decoded")

// A stream that decodes to a size the header does not describe names both.
let mismatch = MissingPixelsReason.reasonForVideoSizeMismatch(320, by: 240,
                                                              expectedWidth: 256, by: 256)
assert(mismatch.contains("320") && mismatch.contains("240"), mismatch)
assert(mismatch.contains("256"), mismatch)
assert(mismatch.count < 60, mismatch)

// A frame that is there and shorter than the picture says how much of it came.
let short = MissingPixelsReason.reasonForShortFrame(4, of: 8192)
assert(short.contains("4") && short.contains("8192"), short)
assert(short.count < 60, short)

assert(Set([absent, unreadable, spectroscopy, undecodable, mismatch, short,
            MissingPixelsReason.reasonForEmptyFrame(0)]).count == 7,
       "the seven reasons have to be distinguishable")

print("PASS: seven distinct sentences, short, the SOP class and transfer syntax named, frames from one")
'''

pix = class_text('DCMPix')
header = (root / 'Horos/Sources/DCMPix.h').read_bytes().decode('latin1')
# -drawOrientation: is Swift; it reads DCMPix properties through
# selectors declared at the top of the file.
view = source_text('DCMView+WindowLevel+Coordinates')

assert '@property(copy) NSString *missingPixelsReason;' in header, (
    'DCMPix has nowhere to record why a frame is empty')
assert 'var missingPixelsReason: String! {' in pix and 'horos_missingPixelsReason = newValue.map { NSString(string: $0) }' in pix, (
    'the reason is not kept as the copy the header promises')

# The frame loading is the IsiXImaging module's (IsiXFrameLoad); DCMPix keeps
# the sentences. The pixels of the empty, short and absent frames are checked
# by tests/test-dcmpix-frame-loading.py.
frames = (root / 'Modules/IsiXImaging/Sources/FrameLoad.swift').read_text()

# A frame that is there and shorter than the picture it has to fill: the
# module reports it, and DCMPix names it.
assert pix.count('reportShortFrame(load.') == 1 and 'load.shortFrameNeeded' in pix, (
    'a frame shorter than the image is not named where the module reports it')
assert 'reasonForShortFrame' in pix

# A frame that decoded to nothing.
empty = pix[pix.index('final func decodedFrame('):]
empty = empty[:empty.index('\n    }\n')]
assert 'reasonForEmptyFrame' in empty, 'a frame that decoded to nothing is not named'

# An object with no Pixel Data element at all never entered that branch, so
# nothing filled fImage: the view kept drawing the previous object's texture
# under this one's annotations.
absent = pix[pix.index('final func loadAbsentPixelData()'):]
absent = absent[:absent.index('\n    }\n')]
assert 'reasonForAbsentPixelData' in absent, 'an object with no pixel data is not named'
assert 'FrameLoad.emptyImage(width:' in absent and 'calloc(' in frames, (
    'an object with no pixel data does not get an empty frame')
assert 'horos_fImage == nil' in absent, (
    'the empty frame would overwrite one that something else already filled')

# A SOP class that is not an image class, and a frame that could not be read,
# were each painted as a 128 x 128 picture - stripes and a gradient. Both are
# failures that look like diagnostic images.
# The non-image object is read in DCMPix+EncapsulatedDocuments.swift.
documents = (root / 'Horos/Sources/DCMPix+EncapsulatedDocuments.swift').read_text()
assert 'if DICOMSOPClass.isNonImageStorage(sopClassUID) {\n            loadEmptyFrame(dcmObject)' in documents
invented = documents[documents.index('    private func loadEmptyFrame('):]
invented = invented[:invented.index('\n    }\n')]
assert 'i % 2' not in invented and 'i%2' not in invented, (
    'a non-image object is still painted as stripes')
assert 'MissingPixelsReason.reasonForNonImageStorage(sopClassUID)' in invented, 'a non-image object is not named'
assert 'memset(pixels, 0, side * side * 4)' in invented, (
    'the frame is not cleared, so it may show whatever memory held')
assert 'public static let emptyFrameSide = 128' in (
    root / 'Modules/IsiXImaging/Sources/Annotations/EncapsulatedDocument.swift').read_text()

unreadable = pix[pix.index('NSLog("not able to load the image : %@"'):]
unreadable = unreadable[:unreadable.index('if horos_isRGB, let image')]
assert 'image[i] = Float(i)' not in unreadable and 'memset(image, 0,' in unreadable, (
    'a frame that could not be read is still painted as a gradient')
assert 'reasonForUnreadableFrame' in unreadable, 'an unreadable frame is not named'

# And the viewer draws it, in the stack that already carries the other things
# worth saying about what is on screen.
drawn = view[view.index('VOI LUT Applied'):]
drawn = drawn[:drawn.index('//Bottom')]
assert 'private let kMissingPixelsReasonGetter = #selector(getter: DCMPix.missingPixelsReason)' in view
assert 'self.drawNSStringGL(objcProperty(self.curDCM, kMissingPixelsReasonGetter)' in drawn, (
    'the reason is recorded but never drawn')
assert 'DCMViewTextAlignCenter' in drawn

with tempfile.TemporaryDirectory(prefix='horos-missing-pixels-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(main)
    subprocess.run(['swiftc', str(root / 'Horos/Sources/MissingPixelsReason.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
