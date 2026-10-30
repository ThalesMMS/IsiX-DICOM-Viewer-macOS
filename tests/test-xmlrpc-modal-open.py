#!/usr/bin/env python3
"""Execute the production open method against a real run loop and fake UI/model.

No windows are created. A modal-loop marker lets us assert that an accepted
request does not close/activate/resolve/open anything until the operator leaves
the modal state, including a nested default loop. Optionally test an old ref
(one where the method is Swift, in XMLRPCInterface+Opening.swift).
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
relative = 'Horos/Sources/XMLRPCInterface+Opening.swift'
source = (subprocess.check_output(['git', 'show', sys.argv[1] + ':' + relative]).decode('utf-8')
          if len(sys.argv) > 1 else (root / relative).read_text(encoding='utf-8'))
start = source.index('    @objc(_onMainThreadOpenObjectsWithIDs:)')
method = source[start:source.index('    /// Selects the first of `objectIDs` in the browser', start)]
driver = r'''
import Foundation

func check(_ condition: Bool, _ what: String) {
    if !condition {
        FileHandle.standardError.write("failed: \(what)\n".data(using: .utf8)!)
        exit(1)
    }
}
typealias NSManagedObject = NSObject
var closes = 0, opens = 0, activations = 0, resolutions = 0, refusals = 0, modalReads = 0

final class AppProbe {
    var activeModal: AnyObject?
    var modalWindow: AnyObject? {
        check(Thread.isMainThread, "the modal state is read on the main thread")
        modalReads += 1
        return activeModal
    }
    func activate(ignoringOtherApps: Bool) { activations += 1 }
}
let NSApp = AppProbe()

final class DicomStudy: NSObject {
    var series: NSArray?
    func imageSeries() -> NSArray? { series }
}
final class ViewerController {
    static func closeAllWindows() { check(Thread.isMainThread, "viewers close on the main thread"); closes += 1 }
}
final class Database {
    var objects: [Int: Any] = [:]
    var lastIDs: NSArray?
    func objects(withIDs ids: [Any]?) -> [Any]? {
        check(Thread.isMainThread, "the objects are resolved on the main thread")
        resolutions += 1
        lastIDs = ids as NSArray?
        return (ids ?? []).compactMap { objects[($0 as! NSNumber).intValue] }
    }
}
final class BrowserController {
    static let shared = BrowserController()
    static func currentBrowser() -> BrowserController? { shared }
    var lastStudyNotOpenedReason: String?
    var lastObject: AnyObject?
    func display(_ study: DicomStudy?, object: NSManagedObject?, command: String) -> Bool {
        check(Thread.isMainThread && command == "Open", "a study opens on the main thread")
        opens += 1
        lastObject = object
        return true
    }
}
final class XMLRPCInterface: NSObject {
    var database: Database?
    func study(for object: NSManagedObject?) -> DicomStudy? { object as? DicomStudy }
    func reportStudyNotOpened(_ study: DicomStudy?) { refusals += 1 }
}
extension XMLRPCInterface {
METHOD
}

func runMode(_ mode: RunLoop.Mode, _ seconds: Double) {
    let keepAlive = Timer(timeInterval: 0.01, repeats: true) { _ in }
    RunLoop.current.add(keepAlive, forMode: mode)
    let until = Date(timeIntervalSinceNow: seconds)
    while until.timeIntervalSinceNow > 0 { RunLoop.current.run(mode: mode, before: until) }
    keepAlive.invalidate()
}

UserDefaults.standard.setVolatileDomain(["CloseAllWindowsBeforeXMLRPCOpen": true,
                                         "bringOsiriXToFrontAfterReceivingMessage": true],
                                        forName: UserDefaults.argumentDomain)
let modalMode = RunLoop.Mode("NSModalPanelRunLoopMode")
CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(modalMode.rawValue as CFString))
let first = DicomStudy(), second = DicomStudy()
first.series = [1]; second.series = [2]
let rpc = XMLRPCInterface()
rpc.database = Database()
rpc.database!.objects = [1: first, 2: second]

// The driver runs on the main thread, where the app performs the method.
MainActor.assumeIsolated { rpc.openObjects(withIDs: [1]) }
check(closes == 1 && opens == 1 && activations == 1 && resolutions == 1 && refusals == 0, "an open without a modal")
check(BrowserController.shared.lastObject === first, "the first study opens")

NSApp.activeModal = NSObject()
autoreleasepool { MainActor.assumeIsolated { rpc.openObjects(withIDs: NSArray(object: 2)) } }
check(closes == 1 && opens == 1 && activations == 1 && resolutions == 1 && refusals == 0, "nothing happens under a modal")
let beforeModalLoop = modalReads
runMode(modalMode, 0.25)
check(modalReads == beforeModalLoop, "no timer work in the modal/common mode")
check(opens == 1 && closes == 1, "nothing opens in the modal loop")

// A nested default loop must recheck instead of assuming the modal ended.
runMode(.default, 0.25)
check(modalReads > beforeModalLoop && opens == 1 && closes == 1 && activations == 1, "a nested default loop rechecks")
NSApp.activeModal = nil
runMode(.default, 0.3)
check(closes == 2 && opens == 2 && activations == 2 && resolutions == 2 && refusals == 0, "the open after dismissal")
check((rpc.database!.lastIDs ?? []).isEqual(to: [2]) && BrowserController.shared.lastObject === second, "the retained IDs")
runMode(.default, 0.2)
check(opens == 2 && closes == 2, "delivered exactly once")

MainActor.assumeIsolated { rpc.openObjects(withIDs: [99]) }
check(opens == 2 && refusals == 1, "existing missing-study reporting survives")
print("PASS: modal/default loops, no hidden UI side effects, retained IDs, one delivery after dismissal and missing-study reporting")
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-xmlrpc-modal-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(folder / 'main.swift'), '-o', str(folder / 'test')],
                   check=True)
    subprocess.run([str(folder / 'test')], check=True, timeout=60)
