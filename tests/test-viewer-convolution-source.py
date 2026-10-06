#!/usr/bin/env python3
"""The 2D viewer's convolution filters: "apply on source" and saved filters.

Two defects of the "convolution" block of ViewerController, kept by the Swift
translation and now fixed:

* "Apply on source" of a 4D colour series hung on a Mac with more than one
  core: the Z pass set the worker condition to the number of cores for each
  time point, and a colour series, which has no Z pass, took one off it and
  waited for 0 forever;
* -ApplyConvString: read the coefficients and the normalization of a saved
  filter with longValue, so a filter saved with 0.5 ran with 0; the Option
  click that opens a filter in the editor read the normalization the same way.

-applyConvolutionOnSource:, -ApplyConvString: and -ApplyConv: are copied out of
ViewerController+Convolution.swift, with the file's own objcSend helpers, into
a Swift extension of a stand-in viewer and compiled with xcrun swiftc. The
workers are stand-ins that only count themselves and release the condition as
the real ones do. The hang shows only on a Mac with more than one core, as
ProcessInfo reports them.

`<git revision>` as an optional argument reads the source from that revision,
the negative control.
"""
from pathlib import Path
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/ViewerController+Convolution.swift'


def read(path):
    if len(sys.argv) > 1:
        shown = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path], capture_output=True)
        return shown.stdout.decode('utf-8') if shown.returncode == 0 else None
    return (root / path).read_text(encoding='utf-8') if (root / path).is_file() else None


source = read(PATH)
if source is None:
    sys.exit('FAIL: %s is missing' % PATH)
if os.cpu_count() is None or os.cpu_count() < 2:
    print('skipped: the hang needs a Mac with more than one core')
    sys.exit(2)


def method(selector, following):
    start = source.index('    @objc(%s)' % selector)
    return source[start:source.index('    @objc(%s)' % following, start)]


helpers = ''.join(re.findall(r'\nfileprivate func (?:objcIsEqualToString|objcImplementation|objcSendInteger|objcSendFloat|objcSendObject|objcSendVoid)\(.*?\n}\n', source, re.S))
methods = method('applyConvolutionOnSource:', 'computeSum:') + method('ApplyConvString:', 'ApplyConv:') + method('ApplyConv:', 'getMatrix:')
# The dictionary the main thread hands the workers: the stand-in workers below
# only count themselves, so it carries nothing they read.
if 'workerDictionary(self)' in methods:
    helpers += '\nfunc workerDictionary(_ viewer: ViewerController) -> NSMutableDictionary { return NSMutableDictionary() }\n'

harness = r'''
import Foundation

func check(_ c: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !c() { fputs("FAIL: \(message) (line \(line))\n", stderr); exit(1) }
}
extension Notification.Name {
    static let OsirixUpdateVolumeData = Notification.Name("OsirixUpdateVolumeData")
    static let OsirixUpdateConvolutionMenu = Notification.Name("OsirixUpdateConvolutionMenu")
}
var alerts = 0
enum HorosAlertPanel {
    @discardableResult static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
struct ModifierFlags: OptionSet { let rawValue: UInt; static let shift = ModifierFlags(rawValue: 1); static let option = ModifierFlags(rawValue: 2) }
final class Event { var modifierFlags = ModifierFlags() }
final class NSApplication { static let shared = NSApplication(); var currentEvent: Event? = Event(); func beginSheet(_ a: Any, modalFor: Any, modalDelegate: Any?, didEnd: Selector?, contextInfo: UnsafeMutableRawPointer?) {} }
final class NSWindow: NSObject { func beginSheet(_ sheet: NSWindow, completionHandler: ((Int) -> Void)?) {} }
let NSApp = NSApplication.shared
enum Alignment { case center }
final class Cell { var floatValue: Float = 0; var stringValue = ""; var isEnabled = true; var alignment = Alignment.center }
final class Matrix { var cells = [Cell](); init() { for _ in 0..<25 { cells.append(Cell()) } }
    func cell(atRow r: Int, column c: Int) -> Cell? { return cells[r * 5 + c] }
    func selectCell(withTag t: Int) {} }
final class TextField: NSObject { var floatValue: Float = 0; @objc var stringValue = "" }
final class Menu { func item(at i: Int) -> NSObject? { return nil } }
final class Popup { var menu: Menu? = Menu() }
final class ImageView { var curImage: Int16 = 0; func setIndex(_ i: Int16) {} }
final class DCMPix: NSObject {
    var isRGB: Bool
    let pwidth = 4, pheight = 3
    var fImage: UnsafeMutablePointer<Float>!
    let kernelStorage = UnsafeMutablePointer<Float>.allocate(capacity: 25)
    init(rgb: Bool) {
        isRGB = rgb
        fImage = UnsafeMutablePointer<Float>.allocate(capacity: 12); fImage.initialize(repeating: 7, count: 12)
        kernelStorage.initialize(repeating: 1, count: 25)
    }
    func kernel() -> UnsafeMutablePointer<Float>! { return kernelStorage }
    func normalization() -> Float { return 9 }
    func applyConvolutionOnSourceImage() {}
}
final class ViewerController: NSObject {
    var horos_curConvMenu: String? = "Blur"
    var horos_convThread: NSConditionLock?
    var horos_maxMovieIndex: Int16 = 3
    var horos_curMovieIndex: Int16 = 0
    var lists = [NSMutableArray]()
    var horos_imageView: ImageView? = ImageView()
    var horos_convPopup: Popup? = Popup()
    var horos_matrixName: TextField? = TextField()
    var horos_matrixNorm: TextField? = TextField()
    var horos_sizeMatrix: Matrix? = Matrix()
    var horos_convMatrix: Matrix? = Matrix()
    var horos_addConvWindow: NSWindow? = nil
    var window: NSWindow? = nil
    var xyWorkers = 0, zWorkers = 0
    var conv: (size: Int16, norm: Float, matrix: [Float])? = nil
    init(rgb: Bool) {
        for _ in 0..<3 { lists.append(NSMutableArray(array: (0..<5).map { _ in DCMPix(rgb: rgb) })) }
    }
    func horos_pixList(at i: Int) -> NSMutableArray? { return lists[i] }
    func isDataVolumicIn4D(_ checkEverythingLoaded: Bool) -> Bool { return true }
    func horos_beginDeleteConvolutionSheetForSender(_ sender: Any!) {}
    func setConv(_ m: UnsafeMutablePointer<Float>!, _ s: Int16, _ norm: Float) {
        conv = m == nil ? nil : (s, norm, (0..<Int(s) * Int(s)).map { m[$0] })
    }
    private func done() {
        let c = horos_convThread
        c?.lock(); c?.unlock(withCondition: (c?.condition ?? 0) - 1)
    }
    @objc(applyConvolutionXYThread:) func applyConvolutionXYThread(_ dict: Any!) { objc_sync_enter(self); xyWorkers += 1; objc_sync_exit(self); done() }
    @objc(applyConvolutionZThread:) func applyConvolutionZThread(_ dict: Any!) { objc_sync_enter(self); zWorkers += 1; objc_sync_exit(self); done() }
}
final class MenuItem: NSObject { @objc var title: String; init(_ t: String) { title = t } }
HELPERS
extension ViewerController {
METHODS
}

let cores = ProcessInfo.processInfo.processorCount

// A saved filter with fractional coefficients and normalization.
let matrix: [Double] = [0.5, 1, 0.5, 1, 2.25, 1, 0.5, 1, 0.5]
UserDefaults.standard.register(defaults: ["Convolution": ["Half": ["Size": 3, "Normalization": 7.25, "Matrix": matrix]]])
let viewer = ViewerController(rgb: false)
viewer.applyConvString("Half")
check(alerts == 0, "the saved filter was not found")
check(viewer.conv?.size == 3, "the filter's size is \(String(describing: viewer.conv?.size))")
check(viewer.conv?.matrix == matrix.map { Float($0) }, "the coefficients \(String(describing: viewer.conv?.matrix)) are not the saved ones \(matrix)")
check(viewer.conv?.norm == 7.25, "the normalization \(String(describing: viewer.conv?.norm)) is not the saved 7.25")

// Option click on the filter opens it in the editor with its normalization.
NSApp.currentEvent?.modifierFlags = .option
viewer.applyConv(MenuItem("Half"))
check(viewer.horos_matrixNorm?.floatValue == 7.25, "the editor shows the normalization \(viewer.horos_matrixNorm?.floatValue ?? -1), not 7.25")

// Apply on source, a 4D colour series: no Z pass, and it returns.
let colour = ViewerController(rgb: true)
colour.applyConvolutionOnSource(nil)
check(colour.xyWorkers == cores && colour.zWorkers == 0, "a 4D colour series ran \(colour.xyWorkers) XY and \(colour.zWorkers) Z workers")
check(colour.horos_curConvMenu == "No Filter", "the filter stays on after apply on source")

// A 4D scalar series: one Z pass per time point, each on all cores.
let scalar = ViewerController(rgb: false)
scalar.applyConvolutionOnSource(nil)
check(scalar.xyWorkers == cores && scalar.zWorkers == 3 * cores, "a 4D scalar series ran \(scalar.zWorkers) Z workers, not \(3 * cores)")
print("ok")
'''.replace('HELPERS', helpers).replace('METHODS', methods)

with tempfile.TemporaryDirectory() as work:
    program = Path(work) / 'main.swift'
    program.write_text(harness)
    binary = Path(work) / 'convolution'
    built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(program), '-o', str(binary)], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the harness does not build:\n' + built.stderr[-4000:])
    try:
        ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        sys.exit('FAIL: apply on source of a 4D colour series never returns (the worker condition never reaches 0)')
    if ran.returncode:
        sys.exit(ran.stderr.strip() or 'FAIL: the harness exited with %d' % ran.returncode)

print('ok: apply on source returns for a 4D colour series and saved filters keep their fractional coefficients')
