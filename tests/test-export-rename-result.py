#!/usr/bin/env python3
"""Run actual export rename stage with real filesystem collisions.

The DICOM export is Swift (BrowserController+DICOMExport.swift): its rename
stage runs here as it is.
"""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
a=s.index('        DicomStudy.dbModifyLock()?.unlock()',s.index('    nonisolated private func exportDICOMFiles('))
a=s.index('\n',a)+1;b=s.index('        // Close the progress window.',a)
support=(root/'Horos/Sources/BrowserController+DatabaseSupport.swift').read_text()
c=support.index('    static func literallyEqual(')
literally=support[c:support.index('\n    }\n',c)+len('\n    }\n')]
program=r'''
import Foundation
enum BrowserObjC {
LITERALLY
}
let root = CommandLine.arguments[1]
let files = FileManager.default
for scenario in 0..<5 {
 let folder = (root as NSString).appendingPathComponent(String(scenario))
 try! files.createDirectory(atPath: folder, withIntermediateDirectories: true)
 let oldName = (folder as NSString).appendingPathComponent("old.dcm"), newName = (folder as NSString).appendingPathComponent("new.dcm")
 if scenario != 3 { try! "source bytes".write(toFile: oldName, atomically: true, encoding: .utf8) }
 if scenario == 2 || scenario == 4 { try! "existing bytes".write(toFile: newName, atomically: true, encoding: .utf8) }
 let rename: NSDictionary = ["oldName": oldName, "newName": newName]
 let exportedPaths = NSMutableSet()
 let renameArray = NSMutableArray(array: scenario == 1 ? [rename, rename, rename] : [rename])
 let files2Compress = NSMutableArray(array: [oldName, "another file"])
 let originalError: NSError? = scenario == 4 ? NSError(domain: "prior", code: 1) : nil
 var exportError: NSError? = originalError
 var exportAborted = false
BODY
 func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
 if scenario < 2 {
  if exportAborted || exportError != nil || (files2Compress[0] as! String) != newName || files.fileExists(atPath: oldName) { exit(1) }
  if text(newName) != "source bytes" { exit(2) }
 } else {
  if !exportAborted || exportError == nil || (files2Compress[0] as! String) != oldName { exit(3) }
  if scenario == 4 && exportError !== originalError { exit(4) }
  if scenario != 3 && text(newName) != "existing bytes" { exit(6) }
  if scenario != 3 && text(oldName) != "source bytes" { exit(5) }
 }
}
print("PASS: rename updates codec paths, handles duplicate requests and reports failures preserving sources")
'''.replace('BODY',s[a:b]).replace('LITERALLY',literally)
with tempfile.TemporaryDirectory(prefix='horos-export-rename-') as folder:
 p=Path(folder);(p/'main.swift').write_text(program)
 subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'files')],check=True)
