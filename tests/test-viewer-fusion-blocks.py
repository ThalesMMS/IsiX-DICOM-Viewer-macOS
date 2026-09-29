#!/usr/bin/env python3
"""The 2D viewer's fusion: -ActivateBlending: and the RGB composition (#865).

Defects of the "blending" block of ViewerController, kept by the Swift
translation (#832) and fixed in #865:

* the reentry guard of -ActivateBlending: also turned away the method's own
  calls: the one that undoes this viewer's previous fusion before a new one,
  and the one that undoes the other viewer's fusion with this one ("NO cross
  blending"). Two viewers could end up fused with each other. The guard must
  still turn away a call the body causes indirectly;
* the RGB composition (-blendWithViewer:blendingType: 4, 5 and 6) with a
  black-and-white source leaked its 8-bit buffer for each image;
* the same composition raised NSRangeException when the other series had
  fewer images than this one.

And fixed in #881: the composition walked this image's buffer with the other
image's width and height, so a larger image wrote past its end, from a
black-and-white source and from a colour one. Each stand-in image is followed
by a guard of sentinel bytes, which must come out untouched; an image of
another size must be left as the RGB conversion made it.

-ActivateBlending: (with the body it runs under the guard) and the cases 4 to 6
of -blendWithViewer:blendingType: are copied out of
ViewerController+Blending.swift, with the file's own helpers, into Swift
extensions of stand-in viewers and compiled with xcrun swiftc; malloc and free
are the harness's own, which count the buffers.

`<git revision>` as an optional argument reads the source from that revision,
the negative control.
"""
from pathlib import Path
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/ViewerController+Blending.swift'


def read(path):
    if len(sys.argv) > 1:
        shown = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path], capture_output=True)
        return shown.stdout.decode('utf-8') if shown.returncode == 0 else None
    return (root / path).read_text(encoding='utf-8') if (root / path).is_file() else None


source = read(PATH)
if source is None:
    sys.exit('FAIL: %s is missing' % PATH)


def helpers(*names):
    found = ''
    for name in names:
        match = re.search(r'\nfileprivate var %s\b[^\n]*\n' % name, source) or \
            re.search(r'\nfileprivate func %s\(.*?\n}\n' % name, source, re.S)
        if match is None:
            sys.exit('FAIL: the helper %s is not in %s' % (name, PATH))
        found += match.group(0) + '\n'
    return found


start = source.index('    @objc(ActivateBlending:)')
activate = source[start:source.index('    // -blendedWindow, the getter', start)]
start = source.index('        case 4,')
composition = source[start:source.index('        case 7:', start)]

COMMON = r'''
import Foundation
import Accelerate

func check(_ c: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !c() { fputs("FAIL: \(message) (line \(line))\n", stderr); exit(1) }
}
let HorosObjCExceptionKey = "HorosObjCException"
enum HorosObjCException { static func perform(_ body: () -> Void) throws { body() } }
func _N2LogExceptionImpl(_ e: NSException, _ b: Bool, _ where: String) {}
'''

ACTIVATE = COMMON + r'''
let NSAlertDefaultReturn = 1, NSAlertAlternateReturn = 0, NSAlertOtherReturn = -1
enum HorosAlertPanel {
    @discardableResult static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { return 1 }
    @discardableResult static func runCritical(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { return 1 }
}
final class UserDefaults {
    static let standard = UserDefaults()
    func float(forKey key: String) -> Float { return 0.01 }
    func integer(forKey key: String) -> Int { return 0 }
    func bool(forKey key: String) -> Bool { return false }
    func string(forKey key: String) -> String? { return nil }
    func set(_ value: Bool, forKey key: String) {}
}
final class DCMView { static func angleBetweenVector(_ a: UnsafeMutablePointer<Float>, andVector b: UnsafeMutablePointer<Float>) -> Float { return 0 } }
final class Geometry { func orientation(_ out: UnsafeMutablePointer<Float>) { for i in 0..<9 { out[i] = 0 }; out[8] = 1 } }
final class ImageView {
    var blending: ImageView? = nil
    var blendingMode = 0
    var curDCM: Geometry? = Geometry()
    func sendSyncMessage(_ v: Int) {}
    func setBlendingFactor(_ f: Float) {}
    func display() {}
}
final class DCMPix: NSObject { var isRGB = false }
final class Slider { var isEnabled = false; var floatValue: Float = 0 }
final class TextField { var isEnabled = true; var stringValue = "" }
final class Popup { func selectItem(withTag t: Int) {} }
final class SeriesView { func setBlendingMode(_ m: Int32) {}; func activateBlending(_ v: ViewerController?, blendingFactor: Float) {} }
final class ViewerController: NSObject {
    let name: String
    var horos_blending: ViewerController? = nil
    var horos_imageView: ImageView? = ImageView()
    var horos_blendingSlider: Slider? = Slider()
    var horos_blendingPercentage: TextField? = TextField()
    var horos_blendingPopupMenu: Popup? = Popup()
    var horos_seriesView: SeriesView? = SeriesView()
    var horos_backCurCLUTMenu: String? = nil
    var horos_curCLUTMenu: String? = "No CLUT"
    var previews = 0
    var duringCLUT: (() -> Void)? = nil
    init(_ name: String) { self.name = name }
    func horos_assignBlendingController(_ v: ViewerController?) { horos_blending = v }
    func blending() -> ViewerController? { return horos_blending }
    func fourDFusionRefusalReason(forOverlay v: ViewerController) -> String? { return nil }
    func fileList() -> NSMutableArray? { return nil }
    func pixList() -> NSMutableArray? { return nil }
    func imageView() -> ImageView? { return horos_imageView }
    func resampleSeries(_ v: ViewerController?, rescale: Bool) -> ViewerController? { return v }
    func displayWarningIfGantryTitled() {}
    func curCLUTMenu() -> String? { return horos_curCLUTMenu }
    func modality() -> String? { return "CT" }
    func applyCLUTString(_ s: String?) { duringCLUT?() }
    func buildMatrixPreview(_ b: Bool) { previews += 1 }
    func refreshMenus() {}
}
HELPERS
extension ViewerController {
ACTIVATE
}

// Cross fusion: B shows A; fusing B into A undoes B's fusion with A.
let a = ViewerController("A"), b = ViewerController("B"), c = ViewerController("C")
b.activateBlending(a)
check(b.horos_blending === a, "B is not fused with A")
a.activateBlending(b)
check(a.horos_blending === b, "A is not fused with B")
check(b.horos_blending == nil, "A and B are fused with each other")

// A new fusion first undoes the previous one: A's teardown runs, then the new fusion.
a.previews = 0
a.activateBlending(c)
check(a.horos_blending === c, "A is not fused with C")
check(a.previews == 2, "A's previous fusion was not undone (\(a.previews) matrix previews, not 2)")

// A call the body causes indirectly is still turned away.
let d = ViewerController("D"), e = ViewerController("E")
a.duringCLUT = { d.activateBlending(e) }
a.activateBlending(nil)
a.duringCLUT = nil
check(a.horos_blending == nil, "A is still fused")
check(d.horos_blending == nil, "a fusion started from inside -ActivateBlending: went through")

// The guard is released.
d.activateBlending(e)
check(d.horos_blending === e, "the guard stays taken")
print("ok")
'''.replace('HELPERS', helpers('noActivateBlendingReentry', 'objcTry', 'objcIsEqualToString', 'normalsAngle', 'blendingPercentageString')) \
   .replace('ACTIVATE', activate)

COMPOSE = COMMON + r'''
var live = 0
func malloc(_ size: Int) -> UnsafeMutableRawPointer? { live += 1; return UnsafeMutableRawPointer.allocate(byteCount: Swift.max(size, 1), alignment: 16) }
func free(_ p: UnsafeMutableRawPointer?) { if let p { live -= 1; p.deallocate() } }
// Past each image's pwidth * pheight floats, a guard of sentinel bytes, larger
// than any image of the harness: a write past the image lands there.
let guardFloats = 1024, sentinel: UInt8 = 0xA5
final class DCMPix: NSObject {
    let pwidth: Int, pheight: Int
    var isRGB = false
    var wl: Float = 100, ww: Float = 200
    var fImage: UnsafeMutablePointer<Float>!
    init(value: Float, width: Int = 6, height: Int = 5, rgb: Bool = false) {
        pwidth = width; pheight = height
        fImage = UnsafeMutablePointer<Float>.allocate(capacity: width * height + guardFloats)
        fImage.initialize(repeating: value, count: width * height)
        memset(fImage + width * height, Int32(sentinel), guardFloats * 4)
        if rgb { isRGB = true; memset(fImage, 120, width * height * 4) }
    }
    // Same byte count: pwidth * pheight floats are pwidth * pheight ARGB pixels.
    func convert(toRGB mode: Int, _ cwl: Int, _ cww: Int) { isRGB = true; memset(fImage, 0, pwidth * pheight * 4) }
    func changeWLWW(_ wl: Float, _ ww: Float) {}
    func byte(_ i: Int) -> UInt8 { return UnsafeMutableRawPointer(fImage).load(fromByteOffset: i, as: UInt8.self) }
    var guardIntact: Bool { return (0 ..< guardFloats * 4).allSatisfy { byte(pwidth * pheight * 4 + $0) == sentinel } }
    var untouched: Bool { return (0 ..< pwidth * pheight * 4).allSatisfy { byte($0) == 0 } }
}
final class ImageView: NSObject {
    var needsDisplay = false
    func getWLWW(_ wl: UnsafeMutablePointer<Float>, _ ww: UnsafeMutablePointer<Float>) { wl.pointee = 100; ww.pointee = 200 }
    func loadTextures() {}
}
final class ViewerController: NSObject {
    var list: NSMutableArray
    var horos_curMovieIndex: Int16 = 0
    var horos_imageView: ImageView? = ImageView()
    init(images: Int, value: Float, width: Int = 6, height: Int = 5, rgb: Bool = false) {
        list = NSMutableArray(array: (0..<images).map { _ in DCMPix(value: value, width: width, height: height, rgb: rgb) })
    }
    func horos_pixList(at i: Int) -> NSMutableArray? { return list }
    func pixList() -> NSMutableArray? { return list }
}
HELPERS
extension ViewerController {
    func compose(withViewer bc: ViewerController!, blendingType: Int32) {
        var i = 0
        switch blendingType {
COMPOSITION
        default:
            break
        }
        _ = i
    }
}

// A black-and-white source: its 8-bit buffers are freed.
let host = ViewerController(images: 4, value: 0), source = ViewerController(images: 4, value: 150)
host.compose(withViewer: source, blendingType: 4)
check(live == 0, "\(live) 8-bit buffers of the black-and-white source are never freed")
for case let p as DCMPix in host.list { check(p.isRGB && p.byte(1) > 0 && p.byte(2) == 0, "the green channel is not composed") }

// A source with fewer images: the images past its end are converted and left alone.
let longer = ViewerController(images: 5, value: 0), shorter = ViewerController(images: 2, value: 150)
longer.compose(withViewer: shorter, blendingType: 5)
check(live == 0, "\(live) 8-bit buffers are never freed")
for (i, p) in (longer.list as! [DCMPix]).enumerated() {
    check(p.isRGB, "image \(i) is not converted to RGB")
    check((p.byte(2) > 0) == (i < 2), "image \(i): blue channel \(p.byte(2))")
}

// A larger source, black-and-white and colour, in each channel: nothing is
// written past this image's buffer, and the image is left as converted (#881).
for rgb in [false, true] {
    for type: Int32 in [4, 5, 6] {
        let small = ViewerController(images: 2, value: 0), large = ViewerController(images: 2, value: 150, width: 12, height: 10, rgb: rgb)
        small.compose(withViewer: large, blendingType: type)
        check(live == 0, "\(live) 8-bit buffers are never freed")
        for (i, p) in (small.list as! [DCMPix]).enumerated() {
            check(p.guardIntact, "type \(type), \(rgb ? "colour" : "black-and-white") source of 12 x 10 on 6 x 5: image \(i) written past its buffer")
            check(p.isRGB && p.untouched, "type \(type): image \(i) is composed with an image of another size")
        }
    }
}

// A smaller source is not composed either: its pixels would land on the wrong rows.
let wide = ViewerController(images: 1, value: 0, width: 12, height: 10), narrow = ViewerController(images: 1, value: 150)
wide.compose(withViewer: narrow, blendingType: 4)
check(live == 0, "\(live) 8-bit buffers are never freed")
for case let p as DCMPix in wide.list { check(p.guardIntact && p.isRGB && p.untouched, "a 12 x 10 image is composed with a 6 x 5 one") }

// Images of the same size, from a colour source, still compose (and stay inside).
let plain = ViewerController(images: 2, value: 0), colour = ViewerController(images: 2, value: 0, rgb: true)
plain.compose(withViewer: colour, blendingType: 4)
for case let p as DCMPix in plain.list { check(p.guardIntact && p.byte(0) == 120 && p.byte(3) == 120, "the colour source is not composed") }
print("ok")
'''.replace('HELPERS', helpers('cLong')).replace('COMPOSITION', composition)

failures = []
with tempfile.TemporaryDirectory() as work:
    for name, program in (('activate', ACTIVATE), ('compose', COMPOSE)):
        path = Path(work) / (name + '.swift')
        path.write_text(program)
        binary = Path(work) / name
        built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(path), '-o', str(binary)], capture_output=True, text=True)
        if built.returncode:
            sys.exit('FAIL: the %s harness does not build:\n%s' % (name, built.stderr[-4000:]))
        ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
        if ran.returncode:
            reason = next((line for line in ran.stderr.splitlines() if 'FAIL' in line or 'NSRangeException' in line),
                          'exited with %d' % ran.returncode)
            failures.append('%s: %s' % (name, reason.replace('FAIL: ', '')))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('ok: -ActivateBlending: undoes both fusions it replaces and the RGB composition frees its buffers, stops at the source\'s end (#865) '
      'and never writes past this image\'s buffer (#881)')
