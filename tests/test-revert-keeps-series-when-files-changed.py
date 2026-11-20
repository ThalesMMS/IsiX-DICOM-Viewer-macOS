#!/usr/bin/env python3
"""Revert Series does not read a series again from files removed or changed since it was read.

Revert Series of the 2D viewer releases every slice and reads it again from
its file. A file removed since gives an empty slice and one rewritten gives
other pixels, and what was released is gone: the undo and filter copies of the
3D windows went with the revert. So before anything is released, every decoded
slice is asked whether its file is still the one it was decoded from
(DCMPix.loadedFileMatchesDisk); when one is not:

* Revert Series says so in an alert and reads nothing: no slice is released,
  the loading thread is not started again, no change of volume is told;
* -executeRevert, which plugins and the 3D position panel call, reads nothing
  either, without an alert;
* a series made by post processing is refused as before, with its own alert;
* the 3D position panel's Reset says so and does not move the series again;
* a volume rendering window whose 2D viewer shows its slices says so before
  it chooses where the volume comes back from, and keeps its volume, its copy
  before the first filter and its undo copy.

With every file as it was read, the revert does what it did.

ViewerLoadingWait is compiled as it is in ViewerController+StudyNavigation.swift,
with stand-ins of the viewer, its slices and what the wait shows. The 3D
position panel's and the volume rendering window's parts are read from their
sources.

    python3 tests/test-revert-keeps-series-when-files-changed.py [<git revision>]

A revision reads the files from it instead of the tree: the negative control.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the compiler

ROOT = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'], capture_output=True)
        if shown.returncode:
            sys.exit(f'FAIL: {revision} has no {path}')
        return shown.stdout.decode('utf-8')
    return (ROOT / path).read_text(encoding='utf-8')


STUBS = r'''
import AppKit

enum Harness {
    static var log: [String] = []
}

extension Notification.Name {
    static let OsirixUpdateVolumeData = Notification.Name("OsirixUpdateVolumeDataNotification")
}
func postViewerNotification(_ name: Notification.Name, _ object: Any?, _ userInfo: [AnyHashable: Any]? = nil) {
    Harness.log.append("told " + name.rawValue + (userInfo?[VRController.horosReadFromFilesKey] as? Bool == false ? " read from files" : ""))
}

enum VRController {
    static let horosReadFromFilesKey = "HorosVolumeReadFromFiles"
}

/// A 3D window opened from a 2D viewer.
class Window3DController: NSWindowController {
    var opener: ViewerController?
    func viewer() -> ViewerController? { opener }
}

enum HorosAlertPanel {
    @discardableResult
    static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        Harness.log.append("alert " + title + ": " + message); return 1
    }
}

final class Wait {
    init?(string: String) {}
    func showWindow(_ sender: Any?) {}
    func increment(by amount: Double) {}
    func close() {}
}

enum GantryTiltPolicy {
    static var corrected: [ObjectIdentifier: NSNumber] = [:]
    static func correctedDegrees(of viewer: ViewerController?) -> NSNumber? { viewer.flatMap { corrected[ObjectIdentifier($0)] } }
    static func clearCorrection(of viewer: ViewerController) {
        corrected[ObjectIdentifier(viewer)] = nil
        Harness.log.append("tilt cleared")
    }
}

final class DCMPix: NSObject {
    /// Decoded, and whether its file is still the one it was decoded from.
    var decoded = true, fileAsRead = true
    func isLoaded() -> Bool { decoded }
    func loadedFileMatchesDisk() -> Bool { decoded ? fileAsRead : true }
    func revert() { Harness.log.append("slice released"); decoded = false }
}

/// The lock of the parsed files, which the wait hands back when the main
/// thread was left holding it; nothing here holds it.
enum DCMPixParsedFileCache {
    static func leaveWhatTheMainThreadLeftHeld() {}
}

/// The change of plane, which reverts a series it made of the files' slices.
@MainActor struct ViewerPlaneChange {
    static var revertsToFiles = false
    let viewer: ViewerController
    func revertToFiles() -> Bool {
        if ViewerPlaneChange.revertsToFiles { Harness.log.append("plane reverted") }
        return ViewerPlaneChange.revertsToFiles
    }
}

final class ImageView {
    func updatePresentationStateFromSeries() { Harness.log.append("presentation state") }
}

final class ViewerController: NSObject {
    var frames: [[DCMPix]]
    var horos_postprocessed = false
    var horos_loadingThread: Thread?
    var horos_checkEverythingLoadedFlag = false
    var horos_requestLoadingCancel = false
    var horos_windowWillClose = false
    var horos_blending: ViewerController?
    var horos_curMovieIndex: Int16 = 0
    var horos_imageView: ImageView? = ImageView()
    var window: NSWindow? { nil }

    init(frames: [[DCMPix]]) { self.frames = frames }

    var horos_movieCount: Int { frames.count }
    func horos_pixArray(_ x: Int) -> [DCMPix] { frames[x] }
    func horos_pixList(at x: Int) -> NSMutableArray? { NSMutableArray(array: frames[x]) }
    func setWindowTitle(_ sender: Any?) {}
    @discardableResult func computeInterval() -> Double { Harness.log.append("interval"); return 0 }
    static func correctGangtryTilt(_ viewer: ViewerController) {
        GantryTiltPolicy.corrected[ObjectIdentifier(viewer)] = 12
        Harness.log.append("tilt corrected")
    }
    func startLoadImageThread() {
        Harness.log.append("load started")
        for frame in frames { for pix in frame { pix.decoded = true } }
    }

    // The viewer's selectors, as ViewerController+StudyNavigation.swift makes them.
    @MainActor func checkEverythingLoaded() { ViewerLoadingWait(viewer: self).waitUntilLoaded() }
    @MainActor func executeRevert() { ViewerLoadingWait(viewer: self).revert() }
    @MainActor func revertSeries(_ sender: Any!) { ViewerLoadingWait(viewer: self).revertUnlessPostprocessed() }
}
'''

DRIVER = r'''
import AppKit

var failures: [String] = []
func check(_ condition: Bool, _ what: String) { if !condition { failures.append(what) } }

func viewer(times: Int = 1, slices: Int = 3) -> ViewerController {
    ViewerController(frames: (0..<times).map { _ in (0..<slices).map { _ in DCMPix() } })
}
func ran(_ body: () -> Void) -> [String] { Harness.log = []; body(); return Harness.log }
func count(_ log: [String], _ prefix: String) -> Int { log.filter { $0.hasPrefix(prefix) }.count }

@MainActor func run() {
    // Every file as it was read: the revert does what it did.
    do {
        let v = viewer(times: 2)
        let log = ran { v.revertSeries(v) }
        check(count(log, "slice released") == 6 && count(log, "load started") == 1 && count(log, "told ") == 2
              && log.filter({ $0.hasSuffix(" read from files") }).count == 2 && !log.contains("tilt corrected")
              && count(log, "alert") == 0 && log.contains("tilt cleared") && log.contains("presentation state"),
              "with its files as they were read, Revert Series releases every slice of every time point and reads them again: \(log)")
    }
    // A file removed or changed since, in the last time point.
    do {
        let v = viewer(times: 2)
        v.frames[1][2].fileAsRead = false
        let log = ran { v.revertSeries(v) }
        check(count(log, "slice released") == 0 && count(log, "load started") == 0 && count(log, "told ") == 0
              && !log.contains("tilt cleared"),
              "Revert Series reads a series again although a file of it was removed or changed since it was read: \(log)")
        check(count(log, "alert Revert: ") == 1 && log.contains { $0.contains("removed or changed since it was read") },
              "Revert Series refused for a removed or changed file does not say so once: \(log)")
        check(v.frames.allSatisfy { $0.allSatisfy(\.decoded) }, "a refused Revert Series released slices")
    }
    // -executeRevert, called by plugins and the 3D position panel: the same, without an alert.
    do {
        let v = viewer()
        v.frames[0][0].fileAsRead = false
        let log = ran { v.executeRevert() }
        check(count(log, "slice released") == 0 && count(log, "load started") == 0 && count(log, "told ") == 0
              && count(log, "alert") == 0,
              "-executeRevert reads the series again although a file of it was removed or changed, or shows an alert: \(log)")
    }
    // A slice not decoded yet has nothing stale: it does not hold the revert.
    do {
        let v = viewer()
        v.frames[0][1].decoded = false
        v.frames[0][1].fileAsRead = false
        let log = ran { v.executeRevert() }
        check(count(log, "load started") == 1, "a slice that was not decoded holds the revert: \(log)")
    }
    // A series corrected for a gantry tilt: the files give it tilted. With a 3D
    // window open on it, it is corrected again before the windows are told;
    // without one it stays as the files give it.
    do {
        let v = viewer()
        GantryTiltPolicy.corrected[ObjectIdentifier(v)] = 12
        var log = ran { v.revertSeries(v) }
        check(!log.contains("tilt corrected") && GantryTiltPolicy.correctedDegrees(of: v) == nil,
              "a corrected series with no 3D window is corrected again by its revert: \(log)")

        GantryTiltPolicy.corrected[ObjectIdentifier(v)] = 12
        let other = viewer()
        let window3D = Window3DController(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [],
                                                           backing: .buffered, defer: true))
        window3D.window?.windowController = window3D
        window3D.opener = other
        log = ran { v.revertSeries(v) }
        check(!log.contains("tilt corrected"), "the 3D window of another viewer makes a revert correct the tilt again: \(log)")

        GantryTiltPolicy.corrected[ObjectIdentifier(v)] = 12
        window3D.opener = v
        log = ran { v.revertSeries(v) }
        let order = ["tilt cleared", "load started", "tilt corrected", "interval"].map { log.lastIndex(of: $0) ?? -1 }
        let told = log.firstIndex { $0.hasPrefix("told ") } ?? -1
        check(order == order.sorted() && !order.contains(-1) && told > order[3] && GantryTiltPolicy.correctedDegrees(of: v) != nil,
              "with a 3D window open on it, a corrected series is not corrected again after its revert, before the windows are told: \(log)")

        // Never corrected: nothing to correct, 3D window or not.
        GantryTiltPolicy.corrected = [:]
        log = ran { v.revertSeries(v) }
        check(!log.contains("tilt corrected"), "a series that was not corrected is corrected by its revert: \(log)")
        window3D.window?.windowController = nil
    }
    // A post-processed series: refused as before, whatever its files.
    do {
        let v = viewer()
        v.horos_postprocessed = true
        let log = ran { v.revertSeries(v) }
        check(count(log, "slice released") == 0 && count(log, "alert Revert: ") == 1
              && log.contains { $0.contains("has been post processed") },
              "a post-processed series is not refused with its own alert: \(log)")
        // ...unless it is a change of plane of the files' slices, which reads
        // the files and changes the plane again: no alert, and nothing of the
        // revert of slices shown as their files give them.
        ViewerPlaneChange.revertsToFiles = true
        let reverted = ran { v.revertSeries(v) }
        ViewerPlaneChange.revertsToFiles = false
        check(reverted == ["plane reverted"], "a change of plane of the files' slices is not reverted by reading the files again: \(reverted)")
    }
}
MainActor.assumeIsolated { run() }
for failure in failures { print("FAIL: " + failure) }
if failures.isEmpty { print("PASS: the wait") }
exit(failures.isEmpty ? 0 : 1)
'''

navigation = read('Horos/Sources/ViewerController+StudyNavigation.swift')
start = navigation.find('@MainActor struct ViewerLoadingWait {')
if start < 0:
    sys.exit('FAIL: ViewerLoadingWait is not in ViewerController+StudyNavigation.swift')
wait = navigation[start:]
wait = wait[:wait.index('\n}\n') + 3]

failures = []
with tempfile.TemporaryDirectory(prefix='horos-revert-files-') as directory:
    p = Path(directory)
    (p / 'Stubs.swift').write_text(STUBS)
    (p / 'ViewerLoadingWait.swift').write_text('import AppKit\n\n' + wait)
    (p / 'main.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', str(p / 'Stubs.swift'),
                            str(p / 'ViewerLoadingWait.swift'), str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        sys.exit('FAIL: ViewerLoadingWait does not compile with the stand-ins')
    ran = subprocess.run([str(p / 'test')], capture_output=True, text=True)
    failures += [line[6:] for line in ran.stdout.splitlines() if line.startswith('FAIL: ')]
    if ran.returncode != 0 and not failures:
        failures.append('the harness ended with ' + str(ran.returncode) + ': ' + ran.stderr.strip()[-400:])

# The 3D position panel's Reset: nothing moves again when the files cannot give the series back.
position = read('Horos/Sources/ThreeDPositionController.swift')
reset = position[position.index('    @IBAction public func reset(_ sender: Any?) {'):]
reset = reset[:reset.index('\n    }\n')]
if not re.search(r'guard ViewerLoadingWait\(viewer: viewerController\)\.slicesMatchTheirFiles\(\) else \{\s*'
                 r'HorosAlertPanel\.run\(.*?removed or changed since it was read.*?return\s*\}\s*'
                 r'viewerController\.executeRevert\(\)\s*self\.movePositionPosition\(nil\)', reset, re.S):
    failures.append('the 3D position panel\'s Reset moves the series again although its files cannot give it back')

# The volume rendering window: refused before it chooses a source, and so before it drops a copy.
editing = read('Horos/Sources/VRController+Editing.swift')
revert = editing[editing.index('    public final func revertSeries(_ sender: Any!) {'):]
revert = revert[:revert.index('\n    }\n')]
if not re.search(r'func revertSeries\(_ sender: Any!\) \{\s*if horosRevertRefusedForChangedFiles\(\) \{ return \}\s*let source = ', revert):
    failures.append('the volume rendering window\'s Revert Series chooses its source, and drops its copies, before asking '
                    'whether the 2D viewer can read the files')
refused = editing.find('    final func horosRevertRefusedForChangedFiles() -> Bool {')
body = editing[refused:editing.index('\n    }\n', refused)] if refused >= 0 else ''
if not re.search(r'guard let viewer = viewer2DStorage, horosViewerShowsSeries\(\), !viewer\.postprocessed\(\) else \{ return false \}\s*'
                 r'viewer\.checkEverythingLoaded\(\)\s*'
                 r'guard !ViewerLoadingWait\(viewer: viewer\)\.slicesMatchTheirFiles\(\) else \{ return false \}\s*'
                 r'HorosAlertPanel\.run\(.*?removed or changed since it was read.*?\)\s*return true', body, re.S):
    failures.append('the volume rendering window refuses only when its 2D viewer shows its slices unprocessed and a file '
                    'changed, and says so')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: Revert Series, -executeRevert, the 3D position panel\'s Reset and the volume rendering window\'s Revert '
      'Series keep the series when a file of it was removed or changed since it was read, and say so; with the files '
      'as they were read the series is read again')
