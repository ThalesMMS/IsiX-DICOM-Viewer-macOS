#!/usr/bin/env python3
"""Deleting in the ROI Manager removes only the selected rows' ROIs.

New ROIs are all "Unnamed" by default. The Manager used to delete by name,
which removed every ROI of the series sharing the selected one's name, on
every slice. It now hands the selected ROI objects to -[DCMView deleteROIs:],
which removes them as the Delete key removes selected ROIs: one undo step,
locked ROIs kept, a grouped ROI's group removed with it.

The production -deleteROIs: and -deleteROIGroupID: (DCMView+ROIEditing.swift)
run here against stand-ins for ROI and for the DCMView state they touch. The
Manager's action is checked to call it and no longer to delete by name.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
swift = (root / 'Horos/Sources/DCMView+ROIEditing.swift').read_text()


def method(start_text):
    start = swift.index(start_text)
    return swift[start:swift.index('\n    }\n', start) + 7]


methods = method('    @objc(deleteROIs:)\n') + method('    @objc(deleteROIGroupID:)\n') + \
    method('    /// Sends `selector` with `argument` to the window controller')

code = r"""
import Cocoa
let ROI_sleep = 0, ROI_selected = 2
extension NSNotification.Name {
    static let OsirixRemoveROI = NSNotification.Name("OsirixRemoveROINotification")
    static let OsirixROIRemovedFromArray = NSNotification.Name("OsirixROIRemovedFromArrayNotification")
}
func roiEditingTry(_ body: () -> Void) -> NSException? { body(); return nil }
func logROIEditingException(_ exception: NSException, _ function: StaticString, stack: Bool = true) { print(exception) }
final class ROI: NSObject {
    @objc dynamic var locked = false
    @objc dynamic var groupID: TimeInterval = 0
    var name = "Unnamed"
}
final class Window: NSObject {
    var undoSteps = 0
    @objc(addToUndoQueue:) func addToUndoQueue(_ what: String) { if what == "roi" { undoSteps += 1 } }
}
final class DCMView: NSObject {
    static var horos_static_drawLock: NSRecursiveLock? = NSRecursiveLock()
    var horos_curRoiList: NSMutableArray? = NSMutableArray()
    var window = Window()
    var stops = 0, successors = 0, needsDisplay = false
    func windowController() -> Any! { window }
    func stopROIEditingForce(_ force: Bool) { stops += 1 }
    func removeROI(fromSliceOrVolume roi: ROI!) { horos_curRoiList?.removeObject(identicalTo: roi as Any) }
    func selectSuccessorOfDeletedROIs() { successors += 1 }
METHODS
}
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { print("FAIL line \(line): " + what); exit(1) } }
func roi() -> ROI { ROI() }
func has(_ list: NSMutableArray?, _ r: ROI) -> Bool { (list?.indexOfObjectIdentical(to: r) ?? NSNotFound) != NSNotFound }

var removed: [AnyObject] = []
NotificationCenter.default.addObserver(forName: .OsirixRemoveROI, object: nil, queue: nil) { removed.append($0.object as AnyObject) }

// Three unnamed ROIs on this slice and one on another slice.
let a = roi(), b = roi(), c = roi(), elsewhere = roi()
let otherSlice = NSMutableArray(array: [elsewhere])
let v = DCMView()
v.horos_curRoiList = NSMutableArray(array: [a, b, c])

v.deleteROIs([b])
check(v.horos_curRoiList!.count == 2 && !has(v.horos_curRoiList, b), "b removed")
check(has(v.horos_curRoiList, a) && has(v.horos_curRoiList, c), "a and c kept")
check(otherSlice.count == 1 && removed.count == 1 && removed[0] === b, "b notified, other slice kept")
check(v.window.undoSteps == 1 && v.stops == 1 && v.successors == 1, "one undo step, editing stopped, successor")

// Several rows at once, in any order and repeated: each removed once, one undo step.
removed.removeAll()
v.deleteROIs([c, a, c])
check(v.horos_curRoiList!.count == 0 && removed.count == 2 && v.window.undoSteps == 2, "several rows")

// A locked ROI stays, and nothing to remove records no undo step.
let locked = roi(); locked.locked = true
v.horos_curRoiList = NSMutableArray(array: [locked])
removed.removeAll()
v.deleteROIs([locked])
v.deleteROIs([])
v.deleteROIs([elsewhere])
check(v.horos_curRoiList!.count == 1 && removed.count == 0 && v.window.undoSteps == 2 && otherSlice.count == 1, "locked kept")

// A grouped ROI takes its group with it, even when both rows are selected.
let g1 = roi(), g2 = roi(), single = roi()
g1.groupID = 42; g2.groupID = 42
v.horos_curRoiList = NSMutableArray(array: [g1, single, g2])
removed.removeAll()
v.deleteROIs([g1, g2])
check(v.horos_curRoiList!.count == 1 && v.horos_curRoiList![0] as AnyObject === single && removed.count == 2 && v.window.undoSteps == 3, "groups")
print("PASS: only the given ROIs, same-named ROIs kept, one undo step, locked kept, groups removed together")
""".replace('METHODS', methods)

with tempfile.TemporaryDirectory(prefix='horos-roi-manager-delete-') as folder:
    p = Path(folder)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(p / 'modules'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

manager = (root / 'Horos/Sources/ROIManagerController.swift').read_text()
action = manager[manager.index('public func deleteROI(_ sender: Any!)'):]
action = action[:action.index('\n    }\n')]
assert 'deleteROIs(selectedROIs)' in action, 'the Manager no longer deletes the selected ROI objects'
assert 'deleteSeriesROIwithName' not in action, 'the Manager deletes by name again'
# DCMView is Swift: the selector is the method's @objc name.
assert '@objc(deleteROIs:)\n    public dynamic func deleteROIs(' in swift, 'deleteROIs: is not exposed to Objective-C'
print('PASS: the ROI Manager deletes only the selected rows')
