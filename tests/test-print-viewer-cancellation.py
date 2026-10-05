#!/usr/bin/env python3
"""#384 A executes the legacy viewer's real post-preparation dispatch block.

Image capture and the print panel are doubles. The production decision that
submits a prepared prefix, discards its spool, and restores windows is compiled
unchanged, for a cancelled preparation and for a failed one: a page that could
not be written must not reach a printer as a blank cell. --source permits
proving the regression against an earlier source.

-endPrint: is Swift since #832, in ViewerController+Export+PrintMovie.swift:
the dispatch is taken from there as it stands and compiled with swiftc inside a
method of a Swift double of the viewer; printView, NSPrintInfo and
NSPrintOperation are module-local doubles that count what the block asks of
them. --source takes a Swift source of that method.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from sources import source_path

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=source_path('ViewerController+Export+PrintMovie'))
args = parser.parse_args()
source = args.source.read_text(encoding='utf-8')
method = source[source.index('    @objc(endPrint:)'):source.index('    @objc(printSlider:)')]
start = method.rindex('            self.adjustSlider()') + len('            self.adjustSlider()')
end = method.rindex('        } else {\n            self.restoreWindowsAfterPrint()')
dispatch = method[start:end]

code = r'''
import Foundation
var operations = 0, submittedFiles = 0, restored = 0, discarded = 0, reported = 0
var spoolToDiscard: String?, submittedTitle: String?
final class ProbeWait: NSObject {
    var cancelled = false
    func aborted() -> Bool { cancelled }
    func close() {}
}
final class NSPrintInfo: NSObject {
    static var shared: NSPrintInfo? { nil }
}
final class printView: NSObject {
    init(viewer: Any!, settings: Any!, files: NSArray!, printInfo info: NSPrintInfo!) {
        submittedFiles = files.count
        super.init()
    }
}
final class NSPrintOperation: NSObject {
    init(view: printView) { operations += 1; super.init() }
    var canSpawnSeparateThread = false
    var jobTitle: String? { didSet { submittedTitle = jobTitle } }
    func runModal(for window: NSObject, delegate: Any?, didRun selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {}
}
final class Viewer: NSObject {
    var window: NSObject? { nil }
    func restoreWindowsAfterPrint() { restored += 1 }
    func discardPrintSpoolDirectory() { try? FileManager.default.removeItem(atPath: spoolToDiscard!); discarded += 1 }
    func presentPrintPreparationFailure() { reported += 1 }
    @objc func printOperationDidRun(_ printOperation: NSPrintOperation!, success: Bool, contextInfo info: UnsafeMutableRawPointer!) {}
    func finish(_ splash: ProbeWait, files: NSMutableArray, folder tmpFolder: String, failed preparationFailed: Bool) {
        let settings = NSMutableDictionary()
        spoolToDiscard = tmpFolder
''' + dispatch + r'''
    }
}
autoreleasepool {
    let viewer = Viewer()
    for failed in [false, true] {
        for cancel in [true, false] {
            for scenario in 0...3 {
                let count = (scenario + 1) % 4
                let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
                let fm = FileManager.default
                precondition((try? fm.createDirectory(atPath: folder, withIntermediateDirectories: false)) != nil, "fixture directory")
                let files = NSMutableArray()
                for i in 0..<count {
                    let path = (folder as NSString).appendingPathComponent("\(i)")
                    precondition(fm.createFile(atPath: path, contents: "synthetic prepared image".data(using: .utf8)), "prepared fixture")
                    files.add(path)
                }
                let wait = ProbeWait() // production tail autoreleases it
                wait.cancelled = cancel
                operations = 0; submittedFiles = 0; restored = 0; discarded = 0; reported = 0
                submittedTitle = nil
                viewer.finish(wait, files: files, folder: folder, failed: failed)
                let dispatchExpected = !cancel && !failed && count > 0
                let passed = operations == (dispatchExpected ? 1 : 0) && submittedFiles == (dispatchExpected ? count : 0)
                    && restored == (dispatchExpected ? 0 : 1) && discarded == (dispatchExpected ? 0 : 1)
                    && fm.fileExists(atPath: folder) == dispatchExpected
                    && reported == (!dispatchExpected && failed ? 1 : 0)
                    && (!dispatchExpected || submittedTitle == "IsiX DICOM Viewer")
                try? fm.removeItem(atPath: folder)
                if !passed {
                    FileHandle.standardError.write(("FAIL: cancel=\(cancel) failed=\(failed) prepared=\(count) operations=\(operations) " +
                        "submitted=\(submittedFiles) restored=\(restored) discarded=\(discarded) reported=\(reported) title=\(submittedTitle ?? "nil")\n").data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }
}
print("PASS: real viewer dispatch refuses cancelled and failed prefixes (0..3 images), discards the spool, "
      + "reports a failure and restores windows; a complete job submits under a job title that is not the window's")
'''
with tempfile.TemporaryDirectory(prefix='horos-print-viewer-cancel-') as temporary:
    folder = Path(temporary)
    (folder/'main.swift').write_text(code, encoding='utf-8')
    subprocess.run(['xcrun', 'swiftc', str(folder/'main.swift'), '-o', str(folder/'check')], check=True, timeout=120)
    subprocess.run([str(folder/'check')], check=True, timeout=10)
