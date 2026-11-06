#!/usr/bin/env python3
"""Executes the legacy viewer's real post-preparation dispatch block.

Image capture and the print panel are doubles. The production decision that
submits a prepared prefix, discards its spool, and restores windows is compiled
unchanged, for a cancelled preparation and for a failed one: a page that could
not be written must not reach a printer as a blank cell. --source permits
proving the regression against an earlier source.

The print of the 2D viewer is ViewerPrintJob (ViewerPrintJob.swift), which
-endPrint: of the viewer makes: its finish(pages:settings:cancelled:failed:)
is taken from there as it stands and compiled with swiftc inside a Swift
double of the job; printView, NSPrintInfo, NSPrintOperation and the settings
are module-local doubles that count what the method asks of them. --source
takes a Swift source of that type.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from sources import source_path

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=source_path('ViewerPrintJob'))
args = parser.parse_args()
source = args.source.read_text(encoding='utf-8')
dispatch = source[source.index('    func finish(pages:'):source.index('    /// The end of the print operation')]

code = r'''
import Foundation
var operations = 0, submittedFiles = 0, restored = 0, discarded = 0, reported = 0
var spoolToDiscard: String?, submittedTitle: String?
struct PropertyListValue { var object: Any }
struct ViewerPrintSettings {
    var propertyList: [String: PropertyListValue] { ["format": PropertyListValue(object: 0)] }
}
final class NSPrintInfo: NSObject {
    static var shared: NSPrintInfo? { nil }
}
final class printView: NSObject {
    init(viewer: Any!, settings: NSDictionary!, files: NSArray!, printInfo info: NSPrintInfo!) {
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
final class ViewerController: NSObject {
    var window: NSObject? { nil }
    @objc func printOperationDidRun(_ printOperation: NSPrintOperation!, success: Bool, contextInfo info: UnsafeMutableRawPointer!) {}
}
final class ViewerPrintJob {
    let viewer = ViewerController()
    func restoreWindows() { restored += 1 }
    func discardSpoolDirectory() { try? FileManager.default.removeItem(atPath: spoolToDiscard!); discarded += 1 }
    func presentPreparationFailure() { reported += 1 }
''' + dispatch + r'''
}
autoreleasepool {
    let job = ViewerPrintJob()
    for failed in [false, true] {
        for cancel in [true, false] {
            for scenario in 0...3 {
                let count = (scenario + 1) % 4
                let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
                let fm = FileManager.default
                precondition((try? fm.createDirectory(atPath: folder, withIntermediateDirectories: false)) != nil, "fixture directory")
                var files: [String] = []
                for i in 0..<count {
                    let path = (folder as NSString).appendingPathComponent("\(i)")
                    precondition(fm.createFile(atPath: path, contents: "synthetic prepared image".data(using: .utf8)), "prepared fixture")
                    files.append(path)
                }
                spoolToDiscard = folder
                operations = 0; submittedFiles = 0; restored = 0; discarded = 0; reported = 0
                submittedTitle = nil
                job.finish(pages: files, settings: ViewerPrintSettings(), cancelled: cancel, failed: failed)
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
