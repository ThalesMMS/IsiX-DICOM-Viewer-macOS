#!/usr/bin/env python3
"""Remembered MPR geometry survives disk round trips without replacing another series."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
mpr = (root / 'Horos/Sources/MPRController.swift').read_text()


def body(signature):
    start = mpr.index('{', mpr.index(signature))
    depth = 0
    for index in range(start, len(mpr)):
        depth += (mpr[index] == '{') - (mpr[index] == '}')
        if depth == 0:
            return mpr[start:index + 1]
    raise AssertionError('unclosed function ' + signature)


show_window = body('override dynamic func showWindow(')
assert 'guard isInitializing else' in show_window
assert 'super.showWindow(sender)' in show_window
assert 'resetMPRPlanes(sender)' in show_window
opening = body('private dynamic func resetMPRPlanes(')
assert 'if self.isInitializing {\n            self.restoreRememberedPlanes()' in opening
assert opening.index('self.applyViewsPosition()') < opening.index('self.restoreRememberedPlanes()')
assert opening.index('self.restoreRememberedPlanes()') < opening.index('self.isInitializing = false')
closing = body('override dynamic func windowWillClose(')
assert closing.index('self.saveRememberedPlanes()') < closing.index('hiddenVRController?.close()')
location = body('private func planeStateLocation()')
assert 'bool(forKey: "RememberMPRPlaneAngles")' in location
assert 'return rememberedPlaneStateLocation' in location
assert 'BrowserController' not in location and 'viewer2D' not in location
capture = body('private func capturePlaneStateLocation()')
assert 'studyInstanceUID' in capture and 'seriesInstanceUID' in capture
assert 'statesDirPath()' in capture and '!viewer.postprocessed()' in capture
initializer = body('public convenience init?(dcmPixList')
assert initializer.index('self.viewer2D = viewer') < initializer.index('self.capturePlaneStateLocation()')
assert initializer.index('self.capturePlaneStateLocation()') < initializer.index('self.initialize(')
restore = body('private func restoreRememberedPlanes()')
for field in ('position', 'focalPoint', 'viewUp', 'rollAngle', 'forceUpdate'):
    assert f'view.camera.{field} =' in restore
for field in ('parallelScale', 'wl', 'ww', 'clippingRangeThickness'):
    assert f'.{field} =' not in restore
assert 'view.angleMPR =' in restore and 'moveCross(to:' in restore
assert 'view.updateViewMPR(false)' in restore
assert 'toolbarItem?.action = #selector(resetMPRPlanes(_:))' in mpr

# Replay the number of show requests made by the actual 2D opening action,
# including its deferred AppKit layout refreshes, against the production
# showWindow body. The reset/render work is a test double; dispatch policy is not.
viewer = (root / 'Horos/Sources/ViewerController+ThreeDViewers.swift').read_text(errors='replace')
start = viewer.index('    func mprViewer(_ sender: Any!) {')
viewer_opening = viewer[start:viewer.index('/// The CPR open on these slices', start)]
show_requests = len(re.findall(r'viewer\?\.showWindow\(self\)', viewer_opening))
assert show_requests >= 1

code = r'''
import Foundation

final class Study { var studyInstanceUID: String? = "owned-study" }
final class Series {
    var study: Study? = Study()
    var seriesInstanceUID: String? = "owned-series"
}
final class Viewer {
    var series: Series? = Series()
    func currentSeries() -> Series? { series }
    func postprocessed() -> Bool { false }
}
final class Database {
    let path: String
    init(_ path: String) { self.path = path }
    func statesDirPath() -> String? { path }
}
final class BrowserController {
    static var browser: BrowserController? = BrowserController()
    var database: Database?
    static func currentBrowser() -> BrowserController? { browser }
}
final class Owner {
    var viewer2D: Viewer? = Viewer()
    var rememberedPlaneStateLocation: (directory: URL, studyUID: String, seriesUID: String)?
    func capturePlaneStateLocation() CAPTURE
    func planeStateLocation() -> (directory: URL, studyUID: String, seriesUID: String)? LOCATION
}

class WindowBase {
    var presentations = 0
    func showWindow(_ sender: Any?) { presentations += 1 }
}
final class OpeningLifecycle: WindowBase {
    var isInitializing = true
    var resets = 0
    var pose = 0
    override func showWindow(_ sender: Any?) SHOW_WINDOW
    func resetMPRPlanes(_ sender: Any?) {
        resets += 1
        pose = 0
        if isInitializing && UserDefaults.standard.bool(forKey: "RememberMPRPlaneAngles") { pose = 37 }
        super.showWindow(sender)
        isInitializing = false
    }
}

@main struct Test {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let pose = MPRPlaneState.Pose(position: [12.5, -3, 5], focalPoint: [13, -2, 7],
                                      viewUp: [0, 1, 0], rollAngle: 37.5, angleMPR: -18.25)
        let original = MPRPlaneState(poses: [pose, pose, pose], crossCenter: [7.5, -22.3, 41.25])
        if CommandLine.arguments.count > 2 {
            // A fresh process must read the persisted geometry without any in-memory cache.
            precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-a", seriesUID: "series-a") == original)
            print("PASS: geometry restored by a new process")
            return
        }
        precondition(original.isValid)

        // Exercise the production capture/lookup methods through database teardown.
        let ownedDirectory = directory.appendingPathComponent("original-database", isDirectory: true)
        let otherDirectory = directory.appendingPathComponent("new-database", isDirectory: true)
        let defaults = UserDefaults.standard
        let savedPreference = defaults.object(forKey: "RememberMPRPlaneAngles")
        defer { defaults.set(savedPreference, forKey: "RememberMPRPlaneAngles") }
        for enabled in [false, true] {
            defaults.set(enabled, forKey: "RememberMPRPlaneAngles")
            let lifecycle = OpeningLifecycle()
            for _ in 0..<SHOW_REQUESTS { lifecycle.showWindow(nil) }
            precondition(lifecycle.presentations == SHOW_REQUESTS && lifecycle.resets == 1)
            precondition(lifecycle.pose == (enabled ? 37 : 0))
            lifecycle.resetMPRPlanes(nil)
            precondition(lifecycle.pose == 0 && lifecycle.resets == 2)
            lifecycle.showWindow(nil)
            precondition(lifecycle.pose == 0 && lifecycle.resets == 2)
        }
        defaults.set(false, forKey: "RememberMPRPlaneAngles")
        BrowserController.browser?.database = Database(ownedDirectory.path)
        let owner = Owner()
        owner.capturePlaneStateLocation()
        precondition(owner.planeStateLocation() == nil)
        defaults.set(true, forKey: "RememberMPRPlaneAngles")
        BrowserController.browser?.database = nil
        owner.viewer2D = nil
        let retained = owner.planeStateLocation()!
        precondition(retained.directory == ownedDirectory && retained.studyUID == "owned-study" && retained.seriesUID == "owned-series")
        try MPRPlaneStateStore.save(original, in: retained.directory, studyUID: retained.studyUID, seriesUID: retained.seriesUID)
        BrowserController.browser?.database = Database(otherDirectory.path)
        let afterSwitch = owner.planeStateLocation()!
        precondition(afterSwitch.directory == ownedDirectory)
        precondition(MPRPlaneStateStore.load(in: afterSwitch.directory, studyUID: retained.studyUID, seriesUID: retained.seriesUID) == original)
        precondition(MPRPlaneStateStore.load(in: otherDirectory, studyUID: retained.studyUID, seriesUID: retained.seriesUID) == nil)

        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-a", seriesUID: "series-a") == nil)
        try MPRPlaneStateStore.save(original, in: directory, studyUID: "study-a", seriesUID: "series-a")
        var second = original
        second.poses[1].angleMPR = 67
        second.crossCenter = [9, 4, -13]
        try MPRPlaneStateStore.save(second, in: directory, studyUID: "study-a", seriesUID: "series-b")
        try MPRPlaneStateStore.save(second, in: directory, studyUID: "study-b", seriesUID: "series-a")
        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-a", seriesUID: "series-a") == original)
        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-a", seriesUID: "series-b") == second)
        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-b", seriesUID: "series-a") == second)
        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-a", seriesUID: "unknown") == nil)

        var invalid = original
        invalid.poses.removeLast()
        precondition(!invalid.isValid)
        invalid = original
        invalid.poses[0].position = [1, 2]
        precondition(!invalid.isValid)
        invalid = original
        invalid.poses[0].viewUp = [0, 0, 0]
        precondition(!invalid.isValid)
        invalid = original
        invalid.poses[0].focalPoint = invalid.poses[0].position
        precondition(!invalid.isValid)
        invalid = original
        invalid.crossCenter[0] = .nan
        precondition(!invalid.isValid)
        do {
            try MPRPlaneStateStore.save(invalid, in: directory, studyUID: "study-a", seriesUID: "series-a")
            preconditionFailure("invalid geometry was saved")
        } catch {}
        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-a", seriesUID: "series-a") == original)

        let url = MPRPlaneStateStore.fileURL(in: directory, studyUID: "study-b")
        let validData = try Data(contentsOf: url)
        var plist = try PropertyListSerialization.propertyList(from: validData, format: nil) as! [String: Any]
        plist["version"] = 99
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-b", seriesUID: "series-a") == nil)
        plist["version"] = 1
        plist["studyUID"] = "wrong-study"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-b", seriesUID: "series-a") == nil)
        try Data("not a plist".utf8).write(to: url)
        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-b", seriesUID: "series-a") == nil)

        // Invalid dimensions on disk are refused as well as before writing.
        plist = try PropertyListSerialization.propertyList(from: validData, format: nil) as! [String: Any]
        var series = plist["series"] as! [String: Any]
        var state = series["series-a"] as! [String: Any]
        state["crossCenter"] = [1, 2]
        series["series-a"] = state
        plist["series"] = series
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        precondition(MPRPlaneStateStore.load(in: directory, studyUID: "study-b", seriesUID: "series-a") == nil)
        // An arbitrary UID never becomes a relative path or a directory.
        let safe = MPRPlaneStateStore.fileURL(in: directory, studyUID: "../../study/with/slashes")
        precondition(safe.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        print("PASS: exact plane round trip, independent series/studies, malformed geometry and versions")
    }
}
'''.replace('CAPTURE', capture).replace('LOCATION', location).replace('SHOW_WINDOW', show_window).replace('SHOW_REQUESTS', str(show_requests))

with tempfile.TemporaryDirectory(prefix='horos-mpr-plane-state-') as folder:
    temp = Path(folder)
    (temp / 'main.swift').write_text(code)
    executable = temp / 'test'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(root / 'Horos/Sources/MPRPlaneState.swift'), str(temp / 'main.swift'),
                    '-o', str(executable)], check=True)
    directory = temp / 'states'
    subprocess.run([str(executable), str(directory)], check=True)
    subprocess.run([str(executable), str(directory), 'read'], check=True)

print('PASS: MPR opening/closing integration, default-off gate, reset and view-setting preservation')
