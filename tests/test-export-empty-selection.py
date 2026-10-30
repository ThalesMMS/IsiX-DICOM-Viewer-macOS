#!/usr/bin/env python3
"""Execute actual export selection guards with controlled outline/matrix selection.

The export command is Swift (BrowserController+DICOMExport.swift): its
selection guards run here as they are, against a recording browser.
"""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
a=s.index('    func exportDICOMFile(_ sender: Any!) {\n')+len('    func exportDICOMFile(_ sender: Any!) {\n')
prefix=s[a:s.index('        let panel = NSOpenPanel()',a)]
end=s.index('        let parameters = NSMutableDictionary(',a)
start=s.rfind('        guard let filesToExport, filesToExport.count > 0',a,end)
guard=s[start:end] if start!=-1 else ''
code=r'''
import Foundation
final class Selection: NSObject {
 var selected = false
 var selectedCells: [Any] { selected ? [1] : [] }
 var selectedRowIndexes: IndexSet { selected ? IndexSet(integer: 0) : IndexSet() }
}
final class Window { var firstResponder: AnyObject? }
final class Peer {
 var horos_oMatrix: Selection? = Selection(), horos_databaseOutline: Selection? = Selection()
 var window: Window? = Window()
 var alerts = 0, proceeded = 0
 func showEmptyDICOMExportSelection() { alerts += 1 }
 // The run is sent from no menu: not the thumbnails' context menu.
 func isThumbnailMenuItem(_ sender: Any!) -> Bool { false }
 func run(_ sender: Any!) {
PREFIX
  proceeded += 1
 }
 func filtered(_ filesToExport: NSMutableArray?, objects dicomFiles2Export: NSMutableArray) {
GUARD
  _ = filesToExport
  proceeded += 1
 }
}
for matrix in [false, true] { for selected in [false, true] {
 let p = Peer()
 p.window?.firstResponder = matrix ? p.horos_oMatrix : p.horos_databaseOutline
 p.horos_oMatrix?.selected = matrix ? selected : !selected
 p.horos_databaseOutline?.selected = matrix ? !selected : selected
 p.run(nil)
 if p.alerts != (selected ? 0 : 1) || p.proceeded != (selected ? 1 : 0) {
  FileHandle.standardError.write("FAIL matrix \(matrix) selected \(selected): alerts \(p.alerts) proceeded \(p.proceeded)\n".data(using: .utf8)!); exit(1)
 }
}}
for files in [nil, [], [1]] as [[Any]?] { for objects in [false, true] {
 let p = Peer()
 p.filtered(files.map { NSMutableArray(array: $0) }, objects: NSMutableArray(array: objects ? [1] : []))
 let valid = (files?.count ?? 0) > 0 && objects
 if p.alerts != (valid ? 0 : 1) || p.proceeded != (valid ? 1 : 0) { FileHandle.standardError.write("FAIL filtered selection\n".data(using: .utf8)!); exit(1) }
}}
print("PASS: outline/matrix guards use the active selection; filtered empty batches stop before worker creation")
'''.replace('PREFIX',prefix).replace('GUARD',guard)
with tempfile.TemporaryDirectory(prefix='horos-empty-selection-') as folder:
 p=Path(folder);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
