#!/usr/bin/env python3
"""The 2D viewer's convolution filters: "apply on source" and saved filters.

Two defects of the "convolution" block of ViewerController, kept by the Swift
translation and fixed since:

* "Apply on source" of a 4D colour series hung on a Mac with more than one
  core: the pass across the slices set a worker condition to the number of
  cores for each time point, and a colour series, which has no such pass,
  took one off it and waited for 0 forever. The passes now go to
  SeriesConvolution, which has no condition to wait on; a colour series must
  still skip the pass across its slices;
* the read of a saved filter took its coefficients and normalization with
  longValue, so a filter saved with 0.5 ran with 0; the Option click that
  opens a filter in the editor read the normalization the same way.

The convolution part of ViewerColourTables.swift, with the members it reads,
is compiled with xcrun swiftc into a class over stand-ins of the viewer, its
slices and its controls, with the IsiXImaging and IsiXPreferences modules. The
question asked before a saved filter is deleted is formatted by that part from
its literal, with viewerFormatArgument, which is compiled as written from
ViewerController+ImagePipelineSupport.swift; the sheet that shows it is a
stand-in. The hang showed only on a Mac with more than one core, as ProcessInfo
reports them.
"""
from pathlib import Path
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags  # noqa: E402

root = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/ViewerColourTables.swift'
source = (root / PATH).read_text(encoding='utf-8')
SUPPORT_PATH = 'Horos/Sources/ViewerController+ImagePipelineSupport.swift'
support_source = (root / SUPPORT_PATH).read_text(encoding='utf-8')
if os.cpu_count() is None or os.cpu_count() < 2:
    print('skipped: the hang needs a Mac with more than one core')
    sys.exit(2)


def block(pattern, text=source, path=PATH):
    """The declaration `pattern` starts, through its closing brace at the same indentation."""
    found = re.search(r'\n( *)' + pattern + r'.*?\n\1}\n', text, re.S)
    if not found:
        sys.exit('FAIL: %s has no %s' % (path, pattern))
    return found.group(0)


try:
    # The convolution filters are the class's last part, up to its closing brace.
    section = source[source.index('    // MARK: - The convolution filters'):source.rindex('\n}\n')] + '\n'
except ValueError:
    sys.exit('FAIL: %s has no convolution section' % PATH)
members = block(r'private var convolutionFilters:') + block(r'private func stored<')
snapshot = block(r'private struct ConvolvedSlices')
# The `%@` argument of the question asked before a saved filter is deleted.
format_argument = block(r'func viewerFormatArgument\(', support_source, SUPPORT_PATH)

harness = r'''
import Foundation
import IsiXImaging
import IsiXPreferences

func check(_ c: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !c() { fputs("FAIL: \(message) (line \(line))\n", stderr); exit(1) }
}
extension Notification.Name {
    static let OsirixUpdateVolumeData = Notification.Name("OsirixUpdateVolumeData")
    static let OsirixUpdateConvolutionMenu = Notification.Name("OsirixUpdateConvolutionMenu")
}
func NSLocalizedString(_ key: String, comment: String) -> String { key }
func viewerIsEqualToString(_ a: String?, _ b: String?) -> Bool { a != nil && a == b }
FORMAT_ARGUMENT
nonisolated(unsafe) var alerts = 0
enum HorosAlertPanel {
    @discardableResult static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int { alerts += 1; return 1 }
}
enum ViewerSender {
    static func tag(_ sender: Any?) -> Int { (sender as? MenuItem)?.tag ?? 0 }
    static func string(_ sender: Any?, _ name: String) -> String? { (sender as? MenuItem)?.title }
    static func selectedCellTag(_ sender: Any?) -> Int { 0 }
}
struct ModifierFlags: OptionSet { let rawValue: UInt; static let shift = ModifierFlags(rawValue: 1); static let option = ModifierFlags(rawValue: 2) }
final class Event { var modifierFlags = ModifierFlags() }
@MainActor final class NSApplication {
    static let shared = NSApplication()
    var currentEvent: Event? = Event()
    struct ModalResponse { let rawValue: Int; init(rawValue: Int) { self.rawValue = rawValue } }
}
@MainActor final class NSWindow {
    var sheets = 0
    func beginSheet(_ sheet: NSWindow, completionHandler: ((Int) -> Void)?) { sheets += 1 }
    func orderOutAndEndSheet(returnCode: NSApplication.ModalResponse) {}
}
enum Alignment { case center }
final class Cell { var floatValue: Float = 0; var stringValue = ""; var isEnabled = true; var alignment = Alignment.center; var tag = 0 }
@MainActor final class Matrix {
    var cells = (0..<25).map { _ in Cell() }
    var selected = Cell()
    func cell(atRow r: Int, column c: Int) -> Cell? { cells[r * 5 + c] }
    func cell(withTag t: Int) -> Cell? { cells[t] }
    func selectCell(withTag t: Int) { selected.tag = t }
    func selectedCell() -> Cell? { selected }
}
@MainActor final class TextField { var floatValue: Float = 0; var stringValue = "" }
final class MenuItem { var title: String?; var tag = 0; init(_ t: String?) { title = t } }
@MainActor final class Menu { let first = MenuItem(nil); func item(at i: Int) -> MenuItem? { first } }
@MainActor final class Popup { var menu: Menu? = Menu() }
@MainActor final class ImageView { var curImage = 0; func setIndex(_ i: Int) {} }

/// A slice: its pixels point into the volume of its time point, as the
/// viewer's slices do.
final class DCMPix: @unchecked Sendable {
    let isRGB: Bool
    let pwidth = 4, pheight = 3
    let fImage: UnsafeMutablePointer<Float>
    let kernelStorage = UnsafeMutablePointer<Float>.allocate(capacity: 25)
    var size: Int16 = 3
    var norm: Float = 9
    private let lock = NSLock()
    private var filtered = 0
    init(rgb: Bool, pixels: UnsafeMutablePointer<Float>) {
        isRGB = rgb
        fImage = pixels
        kernelStorage.initialize(repeating: 1, count: 25)
    }
    func kernel() -> UnsafeMutablePointer<Float>! { kernelStorage }
    func normalization() -> Float { norm }
    func kernelsize() -> Int16 { size }
    func setConvolutionKernel(_ weights: UnsafeMutablePointer<Float>!, _ size: Int16, _ norm: Float) {}
    func applyConvolutionOnSourceImage() { lock.lock(); filtered += 1; lock.unlock() }
    var timesFiltered: Int { lock.lock(); defer { lock.unlock() }; return filtered }
}

@MainActor final class PresetMenuCache {
    func announce(_ menu: Notification.Name, current: String?, presetsChanged: Bool) {}
}

@MainActor final class Graph {
    unowned let viewer: ViewerController
    init(viewer: ViewerController) { self.viewer = viewer }
    var colourTables: ViewerColourTables { viewer.tables }
}

@MainActor final class ViewerController {
    var horos_curConvMenu: String? = "Blur"
    var horos_curMovieIndex: Int16 = 0
    let volumes: [NSMutableData]
    let frames: [[DCMPix]]
    var horos_imageView: ImageView? = ImageView()
    var horos_convPopup: Popup? = Popup()
    var horos_matrixName: TextField? = TextField()
    var horos_matrixNorm: TextField? = TextField()
    var horos_sizeMatrix: Matrix? = Matrix()
    var horos_convMatrix: Matrix? = Matrix()
    var horos_addConvWindow: NSWindow? = NSWindow()
    var window: NSWindow? = NSWindow()
    var conv: (size: Int16, norm: Float, matrix: [Float])? = nil
    var volumeDataPosts = 0
    lazy var tables = ViewerColourTables(preferences: preferences, menus: PresetMenuCache())
    var sessionGraph: Graph { Graph(viewer: self) }
    let preferences: MemoryPreferences

    init(rgb: Bool, preferences: MemoryPreferences) {
        self.preferences = preferences
        volumes = (0..<3).map { frame in
            let data = NSMutableData(length: 5 * 12 * MemoryLayout<Float>.size)!
            let floats = data.mutableBytes.assumingMemoryBound(to: Float.self)
            for i in 0..<60 { floats[i] = Float((i * 7 + frame) % 11) }
            return data
        }
        frames = volumes.map { data in
            let floats = data.mutableBytes.assumingMemoryBound(to: Float.self)
            return (0..<5).map { DCMPix(rgb: rgb, pixels: floats + $0 * 12) }
        }
    }
    var horos_movieCount: Int { frames.count }
    func horos_pixArray(_ i: Int) -> [DCMPix] { frames[i] }
    func horos_pixList(at i: Int) -> [DCMPix]? { frames[i] }
    func horos_volumeData(at i: Int) -> NSObject? { volumes[i] }
    func isDataVolumicIn4D(_ checkEverythingLoaded: Bool) -> Bool { true }
    func applyConvString(_ str: String!) { tables.applyFilter(str, in: self) }
    func setConv(_ m: UnsafeMutablePointer<Float>!, _ s: Int16, _ norm: Float) {
        conv = m == nil ? nil : (s, norm, (0..<Int(s) * Int(s)).map { m[$0] })
    }
    func convMatrixAction(_ sender: Any!) {}
    func getMatrix(_ size: Int16) -> NSMutableArray! { NSMutableArray() }
}

SNAPSHOT

@MainActor final class ViewerColourTables {
    private let preferences: any PreferenceStore
    private let menus: PresetMenuCache

    init(preferences: any PreferenceStore, menus: PresetMenuCache) {
        self.preferences = preferences
        self.menus = menus
    }
MEMBERS
SECTION
    private func askToDelete(title: String, message: String, name: String?, in viewer: ViewerController,
                             delete: @escaping @Sendable @MainActor (ViewerController, String) -> Void) {}
}

@MainActor func run() {
    let cores = ProcessInfo.processInfo.processorCount
    // A saved filter with fractional coefficients and normalization.
    let matrix: [Double] = [0.5, 1, 0.5, 1, 2.25, 1, 0.5, 1, 0.5]
    let preferences = MemoryPreferences(registered: ["Convolution": ["Half": ["Size": 3, "Normalization": 7.25, "Matrix": matrix]]])
    let viewer = ViewerController(rgb: false, preferences: preferences)
    viewer.applyConvString("Half")
    check(alerts == 0, "the saved filter was not found")
    check(viewer.conv?.size == 3, "the filter's size is \(String(describing: viewer.conv?.size))")
    check(viewer.conv?.matrix == matrix.map { Float($0) }, "the coefficients \(String(describing: viewer.conv?.matrix)) are not the saved ones \(matrix)")
    check(viewer.conv?.norm == 7.25, "the normalization \(String(describing: viewer.conv?.norm)) is not the saved 7.25")
    check(viewer.horos_curConvMenu == "Half", "the filter is not the current one")

    // Option click on the filter opens it in the editor with its normalization.
    NSApplication.shared.currentEvent?.modifierFlags = .option
    viewer.tables.filterChosen(MenuItem("Half"), in: viewer)
    NSApplication.shared.currentEvent?.modifierFlags = []
    check(viewer.horos_matrixNorm?.floatValue == 7.25, "the editor shows the normalization \(viewer.horos_matrixNorm?.floatValue ?? -1), not 7.25")
    check(viewer.window?.sheets == 1, "the editor did not open")

    // Apply on source, a 4D colour series: every slice filtered once, no pass
    // across the slices, and it returns.
    let colour = ViewerController(rgb: true, preferences: preferences)
    let before = colour.volumes.map { Data($0) }
    colour.tables.applyFilterToPixels(in: colour)
    check(colour.frames.allSatisfy { $0.allSatisfy { $0.timesFiltered == 1 } }, "a colour series' slices were not each filtered once")
    check(zip(colour.volumes, before).allSatisfy { Data($0.0) == $0.1 }, "a colour series went through the pass across its slices")
    check(colour.horos_curConvMenu == "No Filter", "the filter stays on after apply on source")

    // A 4D scalar series: every slice filtered once, each time point across its
    // slices, and the first row of each slice is the first pixel.
    let scalar = ViewerController(rgb: false, preferences: preferences)
    let original = scalar.volumes.map { Data($0) }
    let first = scalar.frames.map { $0[0].fImage.pointee }
    scalar.tables.applyFilterToPixels(in: scalar)
    check(scalar.frames.allSatisfy { $0.allSatisfy { $0.timesFiltered == 1 } }, "a scalar series' slices were not each filtered once")
    check(zip(scalar.volumes, original).allSatisfy { Data($0.0) != $0.1 }, "a time point was not filtered across its slices")
    for (frame, value) in zip(scalar.frames, first) {
        check(frame.allSatisfy { slice in (0..<slice.pwidth).allSatisfy { slice.fImage[$0] == value } }, "a first row is not the first pixel")
    }

    // Without a filter: said so, nothing filtered.
    let none = ViewerController(rgb: false, preferences: preferences)
    none.horos_curConvMenu = "No Filter"
    none.tables.applyFilterToPixels(in: none)
    check(alerts == 1 && none.frames.allSatisfy { $0.allSatisfy { $0.timesFiltered == 0 } }, "apply on source ran without a filter")
    print("ok on \(cores) cores")
}
MainActor.assumeIsolated { run() }
'''
harness = harness.replace('FORMAT_ARGUMENT', format_argument).replace('SNAPSHOT', snapshot).replace('MEMBERS', members).replace('SECTION', section)

with tempfile.TemporaryDirectory() as work:
    program = Path(work) / 'main.swift'
    program.write_text(harness)
    flags = module_flags('IsiXImaging', Path(work) / 'modules') + module_flags('IsiXPreferences', Path(work) / 'modules')
    binary = Path(work) / 'convolution'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-suppress-warnings', str(program), *flags, '-o', str(binary)],
                           capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the harness does not build:\n' + built.stderr[-4000:])
    try:
        ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        sys.exit('FAIL: apply on source never returns')
    if ran.returncode:
        sys.exit(ran.stderr.strip() or 'FAIL: the harness exited with %d' % ran.returncode)

print('ok: apply on source returns for a 4D colour series and saved filters keep their fractional coefficients')
