#!/usr/bin/env python3
"""Execute actual export selection guards with controlled outline/matrix selection.

The export command is Swift: the browser's -exportDICOMFile: hands the
thumbnails' or the list's selection to DICOMFolderExport.swift, whose
selection guards run here as they are, against a recording browser.
"""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
facade=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
assert 'DICOMFolderExport.chooseFolderAndExport(from: self, thumbnails: isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix)' in facade, \
 'the menu command no longer chooses the thumbnails when the menu or the focus is theirs'
s=(root/'Horos/Sources/DICOMFolderExport.swift').read_text()
a=s.index('    @MainActor static func chooseFolderAndExport(from browser: BrowserController, thumbnails: Bool) {\n')
a=s.index('\n',a)+1
prefix=s[a:s.index('        let preferences = PreferencesSource',a)]
end=s.index('        let request = DICOMFolderExportRequest(',a)
start=s.rfind('        guard !selection.paths.isEmpty, !selection.objects.isEmpty',a,end)
guard=s[start:end] if start!=-1 else ''
assert guard, 'the filtered selection is no longer checked before the export starts'
code=r'''
import Foundation
final class Selection: NSObject {
 var selected = false
 var selectedCells: [Any] { selected ? [1] : [] }
 var selectedRowIndexes: IndexSet { selected ? IndexSet(integer: 0) : IndexSet() }
}
final class Browser { var horos_oMatrix: Selection? = Selection(), horos_databaseOutline: Selection? = Selection() }
struct Files { var paths: [String]; var objects: [Any] }
final class Peer {
 var alerts = 0, proceeded = 0
 func presentEmptySelection() { alerts += 1 }
 func run(from browser: Browser, thumbnails: Bool) {
PREFIX
  proceeded += 1
 }
 func filtered(_ selection: Files) {
GUARD
  proceeded += 1
 }
}
for matrix in [false, true] { for selected in [false, true] {
 let p = Peer(), browser = Browser()
 browser.horos_oMatrix?.selected = matrix ? selected : !selected
 browser.horos_databaseOutline?.selected = matrix ? !selected : selected
 p.run(from: browser, thumbnails: matrix)
 if p.alerts != (selected ? 0 : 1) || p.proceeded != (selected ? 1 : 0) {
  FileHandle.standardError.write("FAIL matrix \(matrix) selected \(selected): alerts \(p.alerts) proceeded \(p.proceeded)\n".data(using: .utf8)!); exit(1)
 }
}}
for files in [[], ["a"]] as [[String]] { for objects in [false, true] {
 let p = Peer()
 p.filtered(Files(paths: files, objects: objects ? [1] : []))
 let valid = !files.isEmpty && objects
 if p.alerts != (valid ? 0 : 1) || p.proceeded != (valid ? 1 : 0) { FileHandle.standardError.write("FAIL filtered selection\n".data(using: .utf8)!); exit(1) }
}}
print("PASS: outline/matrix guards use the active selection; filtered empty batches stop before worker creation")
'''.replace('PREFIX',prefix).replace('GUARD',guard)
with tempfile.TemporaryDirectory(prefix='horos-empty-selection-') as folder:
 p=Path(folder);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
