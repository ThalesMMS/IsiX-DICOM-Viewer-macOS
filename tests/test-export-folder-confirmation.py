#!/usr/bin/env python3
"""Run actual patient-folder handling with real temporary folders and controlled answers.

The block is the exporter's own, over the real folder claims: a folder that was
there before the export is asked about once; a second patient that comes to the
same name gets a numbered sibling and no question about a folder the export
itself just made. A compressed export packs the folders into one archive, named
after the folder they were asked for, or «DICOM Export» when the names differ.

The export is Swift (BrowserController+DICOMExport.swift): the block and the
folder question run here as they are, with the real HorosAlertPanel answers.
"""
from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
a=s.index('                // Two patients of this export')
b=s.index('                let folderTreeSelectedTag = ',a)
c=s.index('    @objc(confirmDICOMExportFolder:)')
helper=s[c:s.index('    @objc(showDICOMExportCompletion:)',c)]
bridge=r'''
#import <Cocoa/Cocoa.h>
#import "HorosAlertPanel.h"
'''
code=r'''
import Cocoa
import CoreData
enum BrowserObjC {
 static func synchronized(_ token: Any, _ body: () -> Void) { objc_sync_enter(token); body(); objc_sync_exit(token) }
}
final class Peer: NSObject {
 var prompts = 0, answer = 0, completed = 0
 var exportAborted = false
 var exportError: NSError?
 var used: [String] = [], archive = ""
HELPER
 @objc(runInformationAlertPanel:) func runInformationAlertPanel(_ options: NSMutableDictionary!) { prompts += 1; options["result"] = NSNumber(value: answer) }
 func run(_ requests: [[String: String]]) {
  let reviewedPatientFolders = NSMutableSet()
  let patientFolders = NSMutableArray()
  let result = NSMutableArray()
  let parameters = NSMutableDictionary()
  let folderClaims = ExportFolderClaims()
  let files = FileManager.default
  let addDICOMDIR = false
  var exportAborted = false
  var exportError: NSError?
  var i = 0
  while i < requests.count {
   defer { i += 1 }
   let request = requests[i]
   var tempPath = request["path"]!
   let curImage: NSDictionary = ["series": ["study": ["patientUID": request["patient"]!]]]
BODY
   try! "image".write(toFile: (tempPath as NSString).appendingPathComponent("\(i).dcm"), atomically: true, encoding: .utf8)
   completed += 1
  }
  self.exportAborted = exportAborted; self.exportError = exportError
  used = patientFolders as! [String]
  archive = folderClaims.archivePath(forFolders: used)
  if !exportAborted && (result as! [String]) != requests.map({ ($0["expected"]! as NSString).lastPathComponent }) {
   FileHandle.standardError.write("FAIL folders \(result)\n".data(using: .utf8)!); exit(1)
  }
 }
}
func fail(_ message: String) -> Never { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); exit(1) }
@main struct Main {
 static func main() {
  let root = CommandLine.arguments[1]
  let fm = FileManager.default
  func count(_ path: String) -> Int { (try? fm.contentsOfDirectory(atPath: path))?.count ?? 0 }
  // 0: new folder; 1: there before, Merge; 2: there before, Cancel; 3: there before, Replace.
  for scenario in 0..<4 {
   let path = (root as NSString).appendingPathComponent("\(scenario)")
   let sibling = path + "_2"
   let peer = Peer()
   peer.answer = scenario == 2 ? HorosAlertPanel.alternateResponse : (scenario == 3 ? HorosAlertPanel.defaultResponse : HorosAlertPanel.otherResponse)
   let a = ["path": path, "patient": "A", "expected": path], b = ["path": path, "patient": "B", "expected": sibling]
   let sentinel = (path as NSString).appendingPathComponent("existing.txt")
   if scenario != 0 {
    try! fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    try! "preserve".write(toFile: sentinel, atomically: true, encoding: .utf8)
   }
   if scenario == 2 {
    // Cancel stops at the first image and leaves what was there.
    peer.run([a, a, b])
    if peer.prompts != 1 || !peer.exportAborted || peer.completed != 0 || !fm.fileExists(atPath: sentinel) { fail("FAIL cancel") }
    continue
   }
   peer.run([a, a, b, a, b])
   let expectedPrompts = scenario != 0 ? 1 : 0
   if peer.prompts != expectedPrompts || peer.completed != 5 || peer.exportAborted {
    fail("FAIL scenario \(scenario): prompts \(peer.prompts) expected \(expectedPrompts), completed \(peer.completed) aborted \(peer.exportAborted)")
   }
   if peer.used != [path, sibling] { fail("FAIL scenario \(scenario) folders handed on") }
   // One person's two folders, asked for under one name: one archive of that name.
   if peer.archive != path + ".zip" { fail("FAIL scenario \(scenario) archive \(peer.archive)") }
   // Both patients keep every file: three of A, two of B.
   let extra = scenario == 1 ? 1 : 0
   if count(path) != 3 + extra || count(sibling) != 2 { fail("FAIL scenario \(scenario) files") }
   if fm.fileExists(atPath: sentinel) != (scenario == 1) { fail("FAIL existing contents after merge/replace") }
  }
  // Folders asked for under different names share an archive of a neutral name,
  // which never replaces one already there.
  let claims = ExportFolderClaims()
  let mixed = (root as NSString).appendingPathComponent("mixed")
  let folders = [claims.folder(source: "A", proposed: (mixed as NSString).appendingPathComponent("SMITH"), componentLimit: 0),
                 claims.folder(source: "B", proposed: (mixed as NSString).appendingPathComponent("DOE"), componentLimit: 0)]
  try! fm.createDirectory(atPath: mixed, withIntermediateDirectories: true)
  if claims.archivePath(forFolders: folders) != (mixed as NSString).appendingPathComponent("DICOM Export.zip") { fail("FAIL neutral archive name") }
  try! "earlier export".write(toFile: (mixed as NSString).appendingPathComponent("DICOM Export.zip"), atomically: true, encoding: .utf8)
  if claims.archivePath(forFolders: folders) != (mixed as NSString).appendingPathComponent("DICOM Export 2.zip") { fail("FAIL archive already there") }
  if claims.archivePath(forFolders: [folders[1]]) != folders[1] + ".zip" { fail("FAIL single folder archive") }
  print("PASS: a folder there before the export is asked about once; a second patient under the same name gets a sibling, unasked; cancellation stops the batch; one archive per export")
 }
}
'''.replace('BODY',s[a:b]).replace('HELPER',helper)
with tempfile.TemporaryDirectory(prefix='horos-folder-confirm-') as folder:
 p=Path(folder);(p/'main.swift').write_text(code);(p/'Bridge.h').write_text(bridge)
 sources=root/'Horos/Sources'
 subprocess.run(['xcrun','clang','-c','-fno-objc-arc','-Wno-deprecated-declarations','-I',str(sources),str(sources/'HorosAlertPanel.m'),'-o',str(p/'alert.o')],check=True)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-import-objc-header',str(p/'Bridge.h'),'-Xcc','-I','-Xcc',str(sources),
                 str(p/'main.swift'),str(sources/'ExportFolderNaming.swift'),str(p/'alert.o'),'-framework','Cocoa','-framework','CoreData','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'exports')],check=True)
