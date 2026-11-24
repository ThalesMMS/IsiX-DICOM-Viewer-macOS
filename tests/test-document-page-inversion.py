#!/usr/bin/env python3
"""Document pages shown inverted in Dark Mode, on the screen only.

A PDF page (an encapsulated PDF, a PDF file in the database, a PDF dropped on a
viewer, which becomes an encapsulated PDF) and the rendering of a structured
report are drawn by -[DCMPix getDataFromNSImage:] on white paper and marked as
document pages there. A picture is not: a scan wrapped in a Secondary Capture,
a PNG. The 2D views and the database's preview show a document page inverted
while the application is in Dark Mode, unless the Viewers pane turned it off
(InvertsDocumentPagesInDarkMode, registered on). The inversion is a table laid over the colour bytes of the view's planar snapshot
as the screen draws it (DocumentPagePolarity, IsiXImaging): the image's pixels
stay the page's, and the snapshot a capture reads - what a copy, an export or
a print gets - carries no inverted table.

Compiled and run: getDataFromNSImage: of DCMPix+NonDICOM.swift, the PDF page
of DCMPix+EncapsulatedDocuments.swift and the decision of DCMPix+Display.swift,
as they stand, in a stand-in DCMPix with ARGBImages and DocumentPagePolarity of
IsiXImaging and the preferences of IsiXPreferences. Read: the view's planar
host (DCMView+PlanarHost.swift), the copy of an image, the preference change
and the Viewers pane, in every copy of its nib and every catalog.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import process_graph_stand_in  # noqa: E402

SOURCES = ROOT / 'Horos/Sources'
TITLE = 'Show PDFs and structured reports inverted in Dark Mode'
KEY = 'InvertsDocumentPagesInDarkMode'
TIP = ('In Dark Mode, PDF documents and structured reports are shown with inverted colors: light text on a '
       'dark page. Exporting, printing and copying give the original page.')
# The check that shares the row: in the copy's language too, so the row does not mix two.
PREVIEW = 'Open PDF with Preview application'
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


# --- The marking and the decision, compiled ------------------------------------

non_dicom = read('DCMPix+NonDICOM.swift')
documents = read('DCMPix+EncapsulatedDocuments.swift')
display = read('DCMPix+Display.swift')
get_data = member(non_dicom, '    @objc(getDataFromNSImage:)')
pdf_page = member(documents, '    private func loadPDFPage(').replace('private func', 'func')
decision = member(display, '    func showsDocumentPageInverted(in appearance: NSAppearance) -> Bool {')

HARNESS = r'''
import AppKit
import IsiXPreferences

enum HorosObjCException {
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool { body(); return true }
}

/// DCMPix's state the pieces read and write, under the names DCMPix.swift stores it by.
final class DCMPix: NSObject {
    var horos_fImage: UnsafeMutablePointer<Float>!
    var horos_fExternalOwnedImage: UnsafeMutablePointer<Float>!
    var horos_width = 0
    var horos_height = 0
    var horos_isRGB = false
    var horos_isDocumentPage = false
    var horos_frameNo = 0
    var horos_savedHeightInDB: Int32 = 0
    var horos_savedWidthInDB: Int32 = 0

    private func reconcile(_ value: Int, saved: Int32, key: String, sizes: NSMutableDictionary, clampAlways: Bool,
                           message: (Int32, Int) -> String) -> Int { value }
    private func storeSizes(_ sizes: NSMutableDictionary) {}
    private func imageBuffer(_ bytes: Int) -> UnsafeMutableRawPointer? { malloc(Swift.max(bytes, 0)) }

GET_DATA
PDF_PAGE
DECISION
}
'''.replace('GET_DATA', get_data).replace('PDF_PAGE', pdf_page).replace('DECISION', decision)

MAIN = r'''
import AppKit
import IsiXPreferences

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
var results: [String: Any] = [:]

/// A page of 48 x 36 points, white, its right half black ink.
func pdfData() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 48, height: 36)
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 24, y: 0, width: 24, height: 36))
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

/// A grey picture of 8 x 8 pixels, as a scan is.
func picture() -> CGImage {
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return context.makeImage()!
}

func bytes(_ pix: DCMPix) -> [UInt8] {
    guard let pixels = pix.horos_fImage else { return [] }
    return [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(pixels), count: pix.horos_width * pix.horos_height * 4))
}

func record(_ name: String, _ pix: DCMPix) {
    let argb = bytes(pix)
    results[name] = ["document": pix.horos_isDocumentPage, "rgb": pix.horos_isRGB,
                     "first": Array(argb.prefix(4)).map(Int.init), "last": Array(argb.suffix(4)).map(Int.init)]
}

let page = pdfData()
try page.write(to: folder.appendingPathComponent("page.pdf"))
try page.write(to: folder.appendingPathComponent("report.xml.pdf"))
let scan = picture()
try NSBitmapImageRep(cgImage: scan).representation(using: .png, properties: [:])!
    .write(to: folder.appendingPathComponent("scan.png"))

// An encapsulated PDF: its Encapsulated Document, a page of it.
let encapsulated = DCMPix()
encapsulated.loadPDFPage(NSPDFImageRep(data: page))
record("encapsulated PDF", encapsulated)

// A structured report: the PDF its rendering wrote, read back.
let report = DCMPix()
report.loadPDFPage((try? Data(contentsOf: folder.appendingPathComponent("report.xml.pdf"))).flatMap { NSPDFImageRep(data: $0) })
record("structured report", report)

// A PDF file of the database, opened as -loadNonDICOMImage opens it.
let loose = DCMPix()
let file = NSImage(contentsOfFile: folder.appendingPathComponent("page.pdf").path)
file?.backgroundColor = .white
loose.getData(from: file)
record("PDF file", loose)

// A Secondary Capture whose Pixel Data wraps a scan: the picture of its fragments.
let wrapped = DCMPix()
wrapped.getData(from: NSImage(cgImage: scan, size: NSSize(width: 8, height: 8)))
record("wrapped scan", wrapped)

// A PNG file.
let png = DCMPix()
png.getData(from: NSImage(contentsOfFile: folder.appendingPathComponent("scan.png").path))
record("PNG file", png)

// The same image read again as a picture is no longer a page.
let reread = DCMPix()
reread.loadPDFPage(NSPDFImageRep(data: page))
reread.getData(from: NSImage(cgImage: scan, size: NSSize(width: 8, height: 8)))
record("page read again as a picture", reread)

// The decision, in each appearance, with the preference as the application
// registers it and turned off. The registration and the argument domain are
// volatile: nothing is written to a preferences file.
let dark = NSAppearance(named: .darkAqua)!, light = NSAppearance(named: .aqua)!
let highContrastDark = NSAppearance(named: .accessibilityHighContrastDarkAqua)!
func decisions() -> [String: Bool] {
    ["page dark": encapsulated.showsDocumentPageInverted(in: dark),
     "page high contrast dark": encapsulated.showsDocumentPageInverted(in: highContrastDark),
     "page light": encapsulated.showsDocumentPageInverted(in: light),
     "report dark": report.showsDocumentPageInverted(in: dark),
     "picture dark": wrapped.showsDocumentPageInverted(in: dark)]
}
let preferences = UserDefaults.standard
let arguments = preferences.volatileDomain(forName: UserDefaults.argumentDomain)
preferences.removeVolatileDomain(forName: UserDefaults.argumentDomain)
let inverts = ViewerPreferences.invertsDocumentPagesInDarkMode
if let registered = inverts.registration?.value(in: .current(viewer: true, appStore: false)) {
    preferences.register(defaults: [inverts.name: registered])
}
results["registered"] = decisions()
preferences.setVolatileDomain(arguments.merging([inverts.name: false]) { $1 },
                              forName: UserDefaults.argumentDomain)
results["turned off"] = decisions()
preferences.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

// What the view draws (on screen) and what a capture reads, from the
// encapsulated page's own bytes.
let before = bytes(encapsulated)
let snapshot = ["width": encapsulated.horos_width, "height": encapsulated.horos_height, "isColor": true,
                "pixels": Data(before), "hostBytes": Data(before)] as NSDictionary
let onScreen = DocumentPagePolarity.shown(snapshot, inverted: encapsulated.showsDocumentPageInverted(in: dark))
let captured = DocumentPagePolarity.shown(snapshot, inverted: false)
let table = (onScreen["colourTable"] as? Data).map { [UInt8]($0) } ?? []
let shownFirst = table.isEmpty ? [] : (0..<4).map { Int(table[$0 * 256 + Int(before[$0])]) }
results["screen"] = ["table": table.count, "first": shownFirst,
                     "captureTable": captured["colourTable"] != nil, "captureIsSnapshot": captured === snapshot,
                     "pixelsKept": bytes(encapsulated) == before && (onScreen["hostBytes"] as? Data) == Data(before)]

let json = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
print(String(data: json, encoding: .utf8)!)
'''


def run_harness():
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
                                str(ROOT / 'Modules/IsiXImaging/Sources/NonDICOM/ARGBImages.swift'),
                                str(ROOT / 'Modules/IsiXImaging/Sources/ViewDrawing/DocumentPagePolarity.swift'),
                                str(SOURCES / 'NSImage+DisplayedPixels.swift'),
                                str(work / 'Harness.swift'), str(work / 'main.swift'),
                                *process_graph_stand_in.swift_flags(work / 'isix'), '-o', str(binary)],
                               capture_output=True, text=True)
        if built.returncode != 0:
            print(built.stderr[-3000:])
            check(False, 'the pieces of DCMPix do not compile in the stand-in')
            return None
        ran = subprocess.run([str(binary), str(work)], capture_output=True, text=True, timeout=120)
        if ran.returncode != 0:
            print(ran.stderr[-3000:])
            check(False, 'the stand-in did not run')
            return None
        return json.loads(ran.stdout.strip().splitlines()[-1])


results = run_harness()
if results is not None:
    for name in ('encapsulated PDF', 'structured report', 'PDF file'):
        page = results[name]
        check(page['document'] and page['rgb'], f'{name}: not marked as a document page')
        # The page is kept as it is: white paper at its top left, black ink at its bottom right.
        check(page['first'] == [255, 255, 255, 255], f'{name}: the page is not kept on white paper ({page["first"]})')
        check(page['last'] == [255, 0, 0, 0], f'{name}: the ink of the page is not kept black ({page["last"]})')
    for name in ('wrapped scan', 'PNG file', 'page read again as a picture'):
        check(not results[name]['document'] and results[name]['rgb'], f'{name}: marked as a document page')
    on, off = results['registered'], results['turned off']
    check(on['page dark'] and on['page high contrast dark'] and on['report dark'],
          'a document page is not inverted in Dark Mode by default')
    check(not on['page light'], 'a document page is inverted in Light Mode')
    check(not on['picture dark'], 'a picture is inverted in Dark Mode')
    check(not any(off.values()), f'{KEY} turned off does not turn the inversion off: {off}')
    screen = results['screen']
    check(screen['table'] == 1024 and screen['first'] == [255, 0, 0, 0],
          f'the screen does not show the page inverted (white paper shows as {screen["first"]})')
    check(not screen['captureTable'] and screen['captureIsSnapshot'], 'a capture reads an inverted table')
    check(screen['pixelsKept'], 'showing the page inverted changed its pixels')

# --- The view: the screen inverts, a capture does not ---------------------------

pix = read('DCMPix.swift')
check('    final var horos_isDocumentPage = false\n' in pix, 'DCMPix keeps no mark of a document page')
copy = member(pix, '    func copy(with zone: NSZone?) -> Any {')
check('copy.horos_isDocumentPage = horos_isDocumentPage' in copy, 'a copy of a document page loses its mark')

host = read('DCMView+PlanarHost.swift')
drawable = member(host, '    private func drawablePlanarSnapshot(onScreen: Bool) -> NSDictionary? {')
check('return DocumentPagePolarity.shown(snapshot, inverted: onScreen && '
      'curDCM?.showsDocumentPageInverted(in: effectiveAppearance) == true)' in drawable,
      'the drawable snapshot does not invert a document page on screen')
draw = member(host, '    func horosDrawPlanar(in layer: CAMetalLayer, inverted: Bool) -> Bool {')
check('drawablePlanarSnapshot(onScreen: true)' in draw, 'the view does not draw a document page inverted')
capture = member(host, '    func horosPlanarPixelsWidth(_ width: Int, height: Int, inverted: Bool) -> Data? {')
check('drawablePlanarSnapshot(onScreen: false)' in capture and 'DocumentPagePolarity' not in capture,
      'a capture (copy, export, print) reads an inverted page')
lens = member(host, '    func horosPlanarPixelsSide(_ side: Int, topLeft: NSPoint, topRight: NSPoint, bottomLeft: NSPoint, '
                    'inverted: Bool) -> Data? {')
check('DocumentPagePolarity.shown(horosPlanarSnapshot(), inverted: curDCM?.showsDocumentPageInverted(in: '
      'effectiveAppearance) == true)' in lens, 'the lens does not show the page as the view does')
captures = read('DCMView+Capture.swift')
check('self.horosPlanarPixelsWidth(frameWidth, height: frameHeight, inverted: inverted)' in captures,
      'the screen capture no longer reads the capture snapshot')
# Nothing else reads the mark: no white background, no other path changes what is captured.
readers = sorted(path.name for path in SOURCES.glob('*.swift')
                 if re.search(r'horos_isDocumentPage|showsDocumentPageInverted', path.read_text(encoding='utf-8')))
check(readers == ['DCMPix+Display.swift', 'DCMPix+NonDICOM.swift', 'DCMPix.swift', 'DCMView+PlanarHost.swift'],
      f'the mark is read elsewhere: {readers}')

# --- The preference -------------------------------------------------------------

import default_preferences  # noqa: E402
check(default_preferences.registered().get(KEY) == '1', f'{KEY} is not registered on')
change = (ROOT / 'Modules/IsiXPreferences/Sources/PreferenceChange.swift').read_text(encoding='utf-8')
redraw = change[change.index('viewerRedraw = compared'):change.index('lengthPresentation = compared')]
check('compared.switchChanged(ViewerPreferences.invertsDocumentPagesInDarkMode)' in redraw, 'turning the inversion off does not redraw')
responder = read('PreferenceChangeResponder.swift')
block = responder[responder.index('if change.viewerRedraw {'):]
block = block[:block.index('\n        if ')]
check('processGraph.currentBrowser?.horos_imageView?.needsDisplay = true' in block,
      'the database preview is not redrawn when the inversion is turned off or on')

nibs = sorted(ROOT.glob('Horos/Resources/*.lproj/OSIViewerPreferencePanePref.xib'))
nibs += sorted(ROOT.glob('Preference Panes/OSIViewerPreferencePane/*.lproj/OSIViewerPreferencePanePref.xib'))
check(len(nibs) == 10, f'{len(nibs)} copies of the Viewers pane')


def catalog(language):
    path = ROOT / 'Horos/Resources' / f'{language}.lproj/Localizable.strings'
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


for nib in nibs:
    language = nib.parent.stem
    root = ET.parse(nib).getroot()
    checks = [button for button in root.iter('button')
              if button.find(f'.//binding[@name="value"][@keyPath="values.{KEY}"]') is not None]
    check(len(checks) == 1, f'{language}: {len(checks)} checks bound to {KEY}')
    if len(checks) != 1:
        continue
    button = checks[0]
    # Checked is inverted: the key itself, through no value transformer.
    check(button.find(f'.//binding[@keyPath="values.{KEY}"]/dictionary') is None and 'NSNegateBoolean' not in ET.tostring(button, encoding='unicode'),
          f'{language}: the check is not bound to {KEY} directly')
    # Beside "Open PDF with Preview application", in the same row of the same group.
    group = next(view for view in root.iter('view')
                 if any(child is button for child in view.findall('subviews/button')))
    preview = group.find('subviews/button[@id="412"]')
    frame, beside = button.find('rect[@key="frame"]'), preview.find('rect[@key="frame"]') if preview is not None else None
    check(beside is not None and frame.get('y') == beside.get('y')
          and float(beside.get('x')) + float(beside.get('width')) <= float(frame.get('x')),
          f'{language}: the check is not beside "Open PDF with Preview application"')
    texts = {'Base': None, 'ja-JP': 'ja-JP'}.get(language, language)
    strings = catalog(texts or 'en')
    cell = button.find('buttonCell')
    check(cell.get('title') == strings[TITLE], f'{language}: the title is not the catalog\'s')
    check(button.get('toolTip') == strings[TIP], f'{language}: the tooltip is not the catalog\'s')
    preview_cell = preview.find('buttonCell') if preview is not None else None
    check(preview_cell is not None and preview_cell.get('title') == strings.get(PREVIEW),
          f'{language}: "Open PDF with Preview application" is not the catalog\'s, beside a translated check')

english = catalog('en')
for path in sorted((ROOT / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    language = path.parent.stem
    strings = catalog(language)
    for key in (TITLE, TIP, PREVIEW):
        check(key in strings, f'{language} lacks {key[:40]!r}')
        if language != 'en' and key in strings:
            check(strings[key] != english.get(key), f'{language} leaves {key[:40]!r} in English')

# Spanish and Italian have no copy of the nib: the pane, loading it through instantiatePaneNib, reads its titles
# and tooltips from the catalog.
pane = (ROOT / 'Preference Panes/OSIViewerPreferencePane/OSIViewerPreferencePanePref.swift').read_text(encoding='utf-8')
helper = (ROOT / 'Preference Panes/PaneCatalogTranslation.swift').read_text(encoding='utf-8')
translate = member(helper, '    private static func translate(view: NSView, with catalog: (String) -> String) {')
check('instantiatePaneNib(named: "OSIViewerPreferencePanePref"' in pane, 'the Viewers pane does not read its texts from the catalog')
check('view.toolTip = text(tip, catalog)' in translate, 'Spanish and Italian show the tooltips in English')

if failures:
    sys.exit(1)
print('PASS: PDF pages and structured reports are marked and inverted on screen in Dark Mode only, '
      'captures keep the page, and the Viewers pane turns it off in every language')
