#!/usr/bin/env python3
"""Execute production media preparation with a failed anonymization result.
No media writer runs: the test verifies the boundary before content preparation.

BurnerWindowController is Swift since #717: its -performBurn: is taken from the
Swift source (tests/sources.py) and compiled into a Swift harness class, with the
real HorosObjCException, over the same four anonymization outcomes.
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
s = source_text('BurnerWindowController')
method = s[s.index('    @objc(performBurn:)'):s.index('    @IBAction @objc(setAnonymizedCheck:)')]
harness = r'''
import AppKit
var prepared = 0, alerts = 0
let mode = CommandLine.arguments[1]
func check(_ ok: Bool, _ line: Int = #line) { if !ok { print("FAIL line \(line) in mode \(mode)"); exit(1) } }
struct burnerDestination { var rawValue: UInt32 }
let CDDVD = burnerDestination(rawValue: 0), USBKey = burnerDestination(rawValue: 1), DMGFile = burnerDestination(rawValue: 2)
// -[NSFileManager tmpDirPath], a Nitrogen category: the user's temporary folder (#802).
extension FileManager { func tmpDirPath() -> String { return NSTemporaryDirectory() } }
final class DicomDatabase: NSObject {
    func independentDatabase() -> Any! { return self }
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
    var files: NSMutableArray?, dbObjectsID: NSMutableArray?, originalDbObjectsID: NSMutableArray?, anonymizedFiles: NSMutableArray?
    var anonymizationTags: NSArray?
    var isSettingUpBurn = false, runBurnAnimation = false, burning = false, cancelled = false, failed = false
    var writeDMGPath: String?, burnFailure: String?, writeVolumePath: String?
    @objc dynamic var buttonsDisabled = false
    var window: NSWindow? { return nil }
    func prepareCDContent(_ a: NSMutableArray!, _ b: NSMutableArray!) { prepared += 1 }
    func createDMG(_ image: String!, withSource folder: String!) -> Bool { return true }
    func saveOnVolume() -> Bool { return true }
    @objc func burnCD(_ object: Any?) {}
    func folderToBurn() -> String! { return "/nonexistent-horos-test-media-folder" }
    private static func logged(_ error: Error) -> NSObject { return error as NSError }
METHOD
    func run() {
        files = ["source"]; dbObjectsID = [1]; originalDbObjectsID = [1]; anonymizationTags = [1]
        buttonsDisabled = true; runBurnAnimation = true; burning = true; cancelled = true
        performBurn(nil)
        for _ in 0..<10 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        check(prepared == (mode == "success" ? 1 : 0))
        check(alerts == (mode == "success" || mode == "cancel" ? 0 : 1))
        check(!buttonsDisabled && !isSettingUpBurn && !runBurnAnimation && !burning)
    }
}
BurnerWindowController().run()
NSLog("PASS %@: preparation gate and UI reset", mode)
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-burn-anonymization-') as tmp:
    p = Path(tmp)
    (p / 'test.swift').write_text(harness)
    (p / 'bridging.h').write_text('#import <Cocoa/Cocoa.h>\n#import "HorosObjCException.h"\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / 'HorosObjCException.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(p / 'bridging.h'),
                    '-Xcc', '-I' + str(root / 'Horos/Sources'), str(p / 'test.swift'), str(p / 'HorosObjCException.o'),
                    '-o', str(p / 'test')], check=True)
    for mode in ['failure', 'nil-error', 'cancel', 'success']:
        subprocess.run([str(p / 'test'), mode], check=True)
