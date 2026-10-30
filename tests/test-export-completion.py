#!/usr/bin/env python3
"""Exercise actual completion count/gate against a temporary filesystem.

The DICOM export is Swift (BrowserController+DICOMExport.swift): its count of
the surviving files and the gate of the completion message run here as they
are, on a stand-in browser that records the message.
"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];s=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
a=s.index('        for case let exportedPath as String in exportedPaths where files.fileExists(atPath: exportedPath) {');b=s.index('\n        }\n',a)+len('\n        }\n');count=s[a:b]
a=s.index('        if !exportAborted && !Thread.current.isCancelled');b=s.index('\n        }\n',a)+len('\n        }\n');gate=s[a:b]
program=r'''
import Foundation
final class BrowserController: NSObject {
 @objc(showDICOMExportCompletion:) func showDICOMExportCompletion(_ result: NSDictionary!) {
  result.write(toFile: ((result["location"] as! String) as NSString).appendingPathComponent("result.plist"), atomically: true)
 }
 func run(_ location: String, scenario: Int) -> Bool {
  let exportAborted = scenario == 1
  let parameters: NSDictionary = ["showCompletion": NSNumber(value: scenario != 3)]
  let files = FileManager.default
  let existing = (location as NSString).appendingPathComponent("image.dcm"), missing = (location as NSString).appendingPathComponent("removed.dcm")
  let exportedPaths = NSMutableSet(object: missing)
  if scenario != 4 { try! "bytes".write(toFile: existing, atomically: true, encoding: .utf8); exportedPaths.add(existing); exportedPaths.add(existing) }
  var exportedCount = 0
COUNT
GATE
  let result = NSDictionary(contentsOfFile: (location as NSString).appendingPathComponent("result.plist"))
  return scenario == 0 ? ((result?["count"] as? NSNumber)?.intValue == 1 && (result?["location"] as? String) == location) : result == nil
 }
}
let probe = BrowserController()
for i in [0, 1, 3, 4, 2] {
 let p = (CommandLine.arguments[1] as NSString).appendingPathComponent(String(i))
 try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
 var passed = false
 if i == 2 {
  // A cancelled export thread.
  let done = DispatchSemaphore(value: 0)
  let thread = Thread { Thread.current.cancel(); passed = probe.run(p, scenario: i); done.signal() }
  thread.start(); done.wait()
 } else {
  passed = probe.run(p, scenario: i)
 }
 if !passed { print("FAIL: scenario \(i)"); exit(1) }
}
print("PASS: surviving files counted once; abort, cancel, internal caller and empty result suppress completion")
'''.replace('COUNT',count).replace('GATE',gate)
with tempfile.TemporaryDirectory(prefix='horos-completion-') as folder:
 p=Path(folder);(p/'main.swift').write_text(program)
 subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'files')],check=True)
