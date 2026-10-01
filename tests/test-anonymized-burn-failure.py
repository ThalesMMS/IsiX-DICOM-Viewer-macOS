#!/usr/bin/env python3
"""Execute production media preparation with a failed anonymization result.
No media writer runs: the test verifies the boundary before content preparation.

BurnerWindowController is Swift since #717: its -performBurn: is taken from the
Swift source (tests/sources.py) and compiled into a Swift harness class, with the
real HorosObjCException, over the same four anonymization outcomes.

Since #966 the burn reads its images on a private-queue context: the stand-in
database answers privateQueueIndependentDatabase() with itself, and
N2ManagedObjectContextPerformAndWait runs the block (#1030). The main-actor
callbacks are the real ones (MainActorCallbacks.swift).

Since #1029 the thread reads a BurnJob taken on the main thread and publishes
the window's state through the main queue: the harness takes the whole "Burn
thread" section (the job and -performBurn:) and stands in for the window's
-burnJob, the content preparation and the destinations. -performBurn: without a
job takes one from the window, as here. Each outcome runs twice: called on the
main thread, and on a thread of its own as -burn: starts it, where every write
of the window's state must reach the main thread and the preparation must not.
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
s = source_text('BurnerWindowController')
method = s[s.index('    // MARK: - Burn thread (#1029)'):s.index('    @IBAction @objc(setAnonymizedCheck:)')]
harness = r'''
import AppKit
import CoreData
var prepared = 0, alerts = 0
let mode = CommandLine.arguments[1], caller = CommandLine.arguments[2]
func check(_ ok: Bool, _ line: Int = #line) { if !ok { print("FAIL line \(line) in mode \(mode), called on the \(caller) thread"); exit(1) } }
struct burnerDestination { var rawValue: UInt32 }
let CDDVD = burnerDestination(rawValue: 0), USBKey = burnerDestination(rawValue: 1), DMGFile = burnerDestination(rawValue: 2)
// -[NSFileManager tmpDirPath], a Nitrogen category: the user's temporary folder (#802).
extension FileManager { func tmpDirPath() -> String { return NSTemporaryDirectory() } }
// Nitrogen's N2ManagedObjectContextPerformAndWait: here the block runs where it is.
func N2ManagedObjectContextPerformAndWait(_ context: NSManagedObjectContext?, _ block: () -> Void) { block() }
final class DicomDatabase: NSObject {
    func independentDatabase() -> Any! { return self }
    func privateQueueIndependentDatabase() -> Any! { return self }
    var managedObjectContext: NSManagedObjectContext? { return nil }
    func objects(withIDs ids: [Any]!) -> [Any]! { return ids }
}
final class BrowserController: NSObject {
    static let browser = BrowserController()
    class func currentBrowser() -> BrowserController! { return browser }
    var database: DicomDatabase! = DicomDatabase()
}
final class Anonymization: NSObject {
    class func anonymizeFiles(_ files: NSArray?, dicomImages: NSArray?, toPath dirPath: String?, withTags intags: NSArray?,
                              error outError: NSErrorPointer) -> NSDictionary? {
        if mode == "success" { return ["source": "anonymous"] }
        if mode != "nil-error" {
            outError?.pointee = NSError(domain: NSCocoaErrorDomain, code: mode == "cancel" ? NSUserCancelledError : NSFileWriteNoPermissionError, userInfo: nil)
        }
        return nil
    }
}
final class AnonymizationErrorPresenter: NSObject {
    static func present(error supplied: NSError?) { alerts += 1 }
}
final class BurnerWindowController: NSObject {
    var files: NSMutableArray?, dbObjectsID: NSMutableArray?, originalDbObjectsID: NSMutableArray?
    var anonymizationTags: NSArray?, cancelled = false
    var writeDMGPath: String?, writeVolumePath: String?
    // What the window's bindings observe: written on the main thread only.
    var anonymizedFiles: NSMutableArray? { didSet { check(Thread.isMainThread) } }
    var isSettingUpBurn = false { didSet { check(Thread.isMainThread) } }
    var runBurnAnimation = false { didSet { check(Thread.isMainThread) } }
    var burning = false { didSet { check(Thread.isMainThread) } }
    var failed = false { didSet { check(Thread.isMainThread) } }
    var burnFailure: String? { didSet { check(Thread.isMainThread) } }
    @objc dynamic var buttonsDisabled = false { didSet { check(Thread.isMainThread) } }
    var window: NSWindow? { return nil }
    private func burnJob() -> BurnJob {
        check(Thread.isMainThread)
        return BurnJob(files: files ?? [], dbObjectsID: dbObjectsID, originalDbObjectsID: originalDbObjectsID,
                       anonymizationTags: anonymizationTags, folder: "/nonexistent-horos-test-media-folder", name: "TEST",
                       destination: Int(DMGFile.rawValue), writeDMGPath: writeDMGPath, writeVolumePath: writeVolumePath,
                       compressionMode: 0, password: nil)
    }
    private func prepareContent(_ job: BurnJob, files: NSArray, dbObjects: NSMutableArray?, originalDbObjects: NSMutableArray?) {
        check(files == (mode == "success" ? ["anonymous"] : ["source"]) as NSArray)
        check(Thread.isMainThread == (caller == "main"))
        prepared += 1
    }
    private static func makeDiskImage(_ image: String?, from folder: String?) -> (written: Bool, failure: String?) { return (true, nil) }
    private static func copyToVolume(_ volume: String?, from folder: String, name: String?) -> (written: Bool, failure: String?) { return (true, nil) }
    @objc func burnCD(_ object: Any?) {}
    private static func logged(_ error: Error) -> NSObject { return error as NSError }
METHOD
    func run() {
        files = ["source"]; dbObjectsID = [1]; originalDbObjectsID = [1]; anonymizationTags = [1]
        buttonsDisabled = true; runBurnAnimation = true; burning = true; cancelled = true
        if caller == "main" {
            performBurn(nil)
        } else {
            let thread = Thread { self.performBurn(nil) }
            thread.start()
            let deadline = Date(timeIntervalSinceNow: 10)
            while !thread.isFinished && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
            check(thread.isFinished)
        }
        for _ in 0..<10 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        check(prepared == (mode == "success" ? 1 : 0))
        check(alerts == (mode == "success" || mode == "cancel" ? 0 : 1))
        check(!buttonsDisabled && !isSettingUpBurn && !runBurnAnimation && !burning)
        // The window's copy of the anonymized files, published on the main thread.
        check((anonymizedFiles?.count ?? 0) == (mode == "success" ? 1 : 0))
    }
}
BurnerWindowController().run()
NSLog("PASS %@ on the %@ thread: preparation gate and UI reset", mode, caller)
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-burn-anonymization-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(harness)
    (p / 'bridging.h').write_text('#import <Cocoa/Cocoa.h>\n#import "HorosObjCException.h"\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / 'HorosObjCException.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(p / 'bridging.h'),
                    '-Xcc', '-I' + str(root / 'Horos/Sources'), str(p / 'main.swift'), str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                    str(p / 'HorosObjCException.o'),
                    '-o', str(p / 'test')], check=True)
    for mode in ['failure', 'nil-error', 'cancel', 'success']:
        for caller in ['main', 'burn']:
            subprocess.run([str(p / 'test'), mode, caller], check=True)
