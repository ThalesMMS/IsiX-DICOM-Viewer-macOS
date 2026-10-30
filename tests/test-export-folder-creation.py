#!/usr/bin/env python3
"""Run each production export folder creation guard with a non-directory parent.

The DICOM export is Swift (BrowserController+DICOMExport.swift): its patient,
study and series folder creations run here as they are.
"""
from pathlib import Path
import re
import subprocess
import tempfile
root=Path(__file__).resolve().parent.parent
source=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
start=source.index('    nonisolated private func exportDICOMFiles(')
blocks=re.findall(r'do \{\n\s+try files\.createDirectory\(atPath: tempPath, withIntermediateDirectories: true, attributes: nil\)\n'
                  r'\s+\} catch let failure \{\n\s+exportError = failure as NSError\n\s+exportAborted = true\n\s+break\n\s+\}',source[start:])
assert len(blocks)==3, 'Patient, study and series creation must propagate failure'
with tempfile.TemporaryDirectory(prefix='horos-export-folder-') as directory:
 p=Path(directory)
 functions=[]
 for index,block in enumerate(blocks):
  functions.append('func guard%d(_ tempPath: String) -> Bool { let files = FileManager.default; var exportError: NSError?; var exportAborted = false; var continued = 0; for _ in 0..<1 { %s\n continued += 1 }; return exportAborted && exportError != nil && continued == 0 }'%(index,block))
 program='import Foundation\n'+'\n'.join(functions)+r'''
let path = CommandLine.arguments[1]
try! "preserved".write(toFile: path, atomically: true, encoding: .utf8)
let child = (path as NSString).appendingPathComponent("child")
guard guard0(child) && guard1(child) && guard2(child) else { print("FAIL: All hierarchy levels must stop on original mkdir failure"); exit(1) }
guard (try? String(contentsOfFile: path, encoding: .utf8)) == "preserved" else { print("FAIL: Preserve existing file"); exit(1) }
print("PASS: patient/study/series folder errors stop export and preserve existing data")
'''
 (p/'main.swift').write_text(program)
 subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'parent-file')],check=True)
