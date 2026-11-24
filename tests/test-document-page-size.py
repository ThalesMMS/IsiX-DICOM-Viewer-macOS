#!/usr/bin/env python3
"""A document page has one size: the import stores the size the viewer draws.

A PDF page has no pixels of its own. The viewer draws it at two pixels a point
(-[DCMPix getDataFromNSImage:]), into the place the series' volume lends, which
is of the size the image's row in the database says - the size the import
measured. The import measured the page at one pixel a point, so the first
opening of every encapsulated PDF, PDF file and rendered structured report
squeezed the page drawn at 1190 x 1684 into 595 x 842 and wrote the right size
to the row, and only the second opening was sharp.

Both sides now take the pixels from one rule, NSImage.displayedPixels().

Compiled and run, as they stand: that rule, the import's measure of a rendered
document (DicomFile+DICOMReading.swift) and the viewer's drawing with its
reconciling of the stored size (DCMPix+NonDICOM.swift), in stand-ins of
DicomFile and DCMPix. Read: the import of a PDF file, which is too long to
stand alone.
"""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        print('FAIL:', message)


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8')


def member(text, start, end='\n    }\n'):
    """The member of `text` that starts at `start`, through its closing brace."""
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


non_dicom = read('DCMPix+NonDICOM.swift')
reading = read('DicomFile+DICOMReading.swift')
readers = read('DicomFile+NonDICOMReaders.swift')
get_data = member(non_dicom, '    @objc(getDataFromNSImage:)')
reconcile = member(non_dicom, '    private func reconcile(')
buffer = member(non_dicom, '    private func imageBuffer(')
adopt = member(reading, '    private final func adoptRenderedDocument(').replace('private final func', 'func')

# --- Read: one rule, and no other measure beside it ----------------------------

check('displayedPixels()' in get_data, 'the viewer no longer draws a page by the shared rule')
check('displayedPixels()' in adopt, 'the import of a rendered document no longer measures by the shared rule')
image_file = member(readers, '    func readImageFile() -> Bool {', '\n    }\n\n')
check('otherImage.displayedPixels()' in image_file,
      'the import of an image or PDF file no longer measures by the shared rule')
for name, text in (('DCMPix+NonDICOM.swift', get_data), ('DicomFile+DICOMReading.swift', adopt),
                   ('DicomFile+NonDICOMReaders.swift', image_file)):
    for other in ('cgImage(forProposedRect', 'tiffRepresentation', '.ctm'):
        check(other not in text, '%s measures or draws an image by a rule of its own again (%s)' % (name, other))

# --- Compiled and run ----------------------------------------------------------

HARNESS = r'''
import AppKit

let OsirixDicomImageSizeUnknown = Int32.max

enum HorosObjCException {
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool { body(); return true }
}

/// Stands for ARGBImages of IsiXImaging: the drawing, without the paper.
enum ARGBImages {
    static func draw(_ image: CGImage, width: Int, height: Int, into argb: UnsafeMutableRawPointer, paper: CGColor? = nil) -> Bool {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: argb, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(paper ?? .white)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return true
    }
}

/// The import's reading of a file, as far as a rendered document goes.
final class DicomFile: NSObject {
    var horos_numberOfFrames = 1
    var horos_width = 1
    var horos_height = 1
    var horos_filePath: String? = "document.dcm"

ADOPT
}

/// DCMPix's state the drawing reads and writes, under the names DCMPix.swift stores it by.
final class DCMPix: NSObject {
    var horos_fImage: UnsafeMutablePointer<Float>!
    var horos_fExternalOwnedImage: UnsafeMutablePointer<Float>!
    var horos_width = 0
    var horos_height = 0
    var horos_isRGB = false
    var horos_isDocumentPage = false
    var horos_savedHeightInDB: Int32 = 0
    var horos_savedWidthInDB: Int32 = 0
    /// What the drawing asked to be written to the image's row.
    var stored: [String: Int] = [:]

    private func storeSizes(_ sizes: NSMutableDictionary) {
        for (key, value) in sizes { stored[key as! String] = (value as! NSNumber).intValue }
    }

RECONCILE
BUFFER
GET_DATA
}
'''.replace('ADOPT', adopt).replace('RECONCILE', reconcile).replace('BUFFER', buffer).replace('GET_DATA', get_data)

MAIN = r'''
import AppKit

var results: [String: Any] = [:]

/// `pages` pages of `width` x `height` points, white, with a black bar half a
/// point wide, 100 points from the left edge: one whole pixel at two pixels a
/// point, and grey when the page is squeezed to one.
func pdfData(width: CGFloat, height: CGFloat, pages: Int) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: width, height: height)
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 100, y: 0, width: 0.5, height: height))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// What the import stores of the document.
func imported(_ document: Data) -> DicomFile {
    let file = DicomFile()
    file.adoptRenderedDocument(NSPDFImageRep(data: document), elements: NSMutableDictionary())
    return file
}

/// The page as a viewer shows it: in a place of the volume of the size stored.
func shown(_ document: Data, storedWidth: Int, storedHeight: Int) -> [String: Any] {
    let pix = DCMPix()
    let place = UnsafeMutablePointer<Float>.allocate(capacity: storedWidth * storedHeight)
    defer { place.deallocate() }
    pix.horos_fExternalOwnedImage = place
    pix.horos_savedWidthInDB = Int32(storedWidth)
    pix.horos_savedHeightInDB = Int32(storedHeight)
    let image = NSImage()
    image.addRepresentation(NSPDFImageRep(data: document)!)
    pix.getData(from: image)
    // The darkest green byte of the middle row: 0 where the bar is one whole pixel.
    var darkest = 255
    if pix.horos_fImage != nil {
        let bytes = UnsafeRawPointer(pix.horos_fImage).assumingMemoryBound(to: UInt8.self)
        let row = (pix.horos_height / 2) * pix.horos_width * 4
        for x in 0..<pix.horos_width { darkest = min(darkest, Int(bytes[row + x * 4 + 2])) }
    }
    return ["width": pix.horos_width, "height": pix.horos_height, "stored": pix.stored, "darkest": darkest]
}

for (name, width, height) in [("A4", 595.0, 842.0), ("A4 in fractions", 595.28, 841.89), ("letter", 612.0, 792.0)] {
    let document = pdfData(width: width, height: height, pages: 2)
    let file = imported(document)
    results[name] = ["frames": file.horos_numberOfFrames, "width": file.horos_width, "height": file.horos_height,
                     "first opening": shown(document, storedWidth: file.horos_width, storedHeight: file.horos_height)]
}
// A row written before: the page at one pixel a point.
results["row at one pixel a point"] = shown(pdfData(width: 595, height: 842, pages: 1), storedWidth: 595, storedHeight: 842)
// A document that renders to nothing keeps the placeholder.
let nothing = imported(Data())
results["nothing"] = ["frames": nothing.horos_numberOfFrames, "width": nothing.horos_width, "height": nothing.horos_height]

print(String(data: try JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
'''


def run():
    if shutil.which('xcrun') is None:
        print('skipped: needs xcrun (swiftc)', file=sys.stderr)
        sys.exit(2)
    with tempfile.TemporaryDirectory() as folder:
        work = Path(folder)
        (work / 'Harness.swift').write_text(HARNESS)
        (work / 'main.swift').write_text(MAIN)
        binary = work / 'pages'
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings',
                                '-module-cache-path', str(work / 'modules'),
                                str(SOURCES / 'NSImage+DisplayedPixels.swift'),
                                str(work / 'Harness.swift'), str(work / 'main.swift'), '-o', str(binary)],
                               capture_output=True, text=True)
        if built.returncode != 0:
            print(built.stderr[-3000:])
            check(False, 'the measure and the drawing do not compile in the stand-ins')
            return None
        ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        if ran.returncode != 0:
            print(ran.stderr[-3000:])
            check(False, 'the stand-ins did not run')
            return None
        return json.loads(ran.stdout.strip().splitlines()[-1])


results = run()
if results is not None:
    a4 = results['A4']
    check((a4['frames'], a4['width'], a4['height']) == (2, 1190, 1684),
          'an A4 document of two pages is imported as %s frames of %s x %s, not 2 of 1190 x 1684'
          % (a4['frames'], a4['width'], a4['height']))
    for name in ('A4', 'A4 in fractions', 'letter'):
        page, first = results[name], results[name]['first opening']
        check((first['width'], first['height']) == (page['width'], page['height']),
              '%s: imported as %s x %s and drawn as %s x %s at the first opening'
              % (name, page['width'], page['height'], first['width'], first['height']))
        check(first['stored'] == {}, '%s: the first opening still corrects the size of the row: %s' % (name, first['stored']))
        # A page of whole points only: the other is drawn a fraction of a pixel wider.
        check(name == 'A4 in fractions' or first['darkest'] == 0,
              '%s: a bar of one pixel is not black at the first opening (%s): the page was squeezed' % (name, first['darkest']))
    before = results['row at one pixel a point']
    check((before['width'], before['height']) == (595, 842),
          'a page whose row says 595 x 842 is drawn past the place the volume lends it: %s x %s'
          % (before['width'], before['height']))
    check(before['darkest'] > 0, 'the bar does not tell a squeezed page from a whole one')
    check(before['stored'] == {'width': 1190, 'height': 1684},
          'a row written at one pixel a point is no longer corrected at its first opening: %s' % before['stored'])
    nothing = results['nothing']
    check((nothing['frames'], nothing['width'], nothing['height']) == (1, 1, 1),
          'a document that renders to nothing lost its placeholder: %s' % nothing)

if failures:
    sys.exit(1)
print('ok: a document page is imported at the size the viewer draws it, two pixels a point, so its first '
      'opening is neither squeezed nor corrected; a row written at one pixel a point is still corrected then')
