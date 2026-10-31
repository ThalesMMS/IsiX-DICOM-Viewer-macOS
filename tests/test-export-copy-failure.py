#!/usr/bin/env python3
"""Run the actual export copy block against real success/failure filesystem paths.

The DICOM export is Swift (DICOMFolderExport.swift): its copy block runs
here as it is, through the browser's
+horos_copyFileForPublication:toPath:error:, which calls the real
HorosCopyFileForPublication. The destination is never nil in Swift (the file
name is always made), so that case of the former test is gone.
"""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/DICOMFolderExport.swift').read_text()
a=s.index('                do {\n                    try BrowserController.horos_copyFile(forPublication:',s.index('    private func export('))
b=s.index('                if compresses && (image.fileType()',a)
block=s[a:b]
c=s.index('func objcReportedError(')
reported=s[c:s.index('\n}\n',c)+len('\n}\n')]
bridge=r'''
#import <Foundation/Foundation.h>
@interface BrowserController : NSObject
+ (BOOL)horos_copyFileForPublication:(nullable NSString*)source toPath:(nullable NSString*)destination error:(NSError* _Nullable * _Nullable)error;
@end
'''
native=r'''
#import "Bridge.h"
#import "HorosFileCopy.h"
@implementation BrowserController
+ (BOOL)horos_copyFileForPublication:(NSString*)source toPath:(NSString*)destination error:(NSError**)error
{
    return HorosCopyFileForPublication(NSFileManager.defaultManager, source, destination, NO, error);
}
@end
'''
program=r'''
import Foundation
REPORTED
let root = CommandLine.arguments[1]
let files = FileManager.default
try! files.createDirectory(atPath: root, withIntermediateDirectories: true)
let source = (root as NSString).appendingPathComponent("source")
try! "original bytes".write(toFile: source, atomically: true, encoding: .utf8)
for scenario in [0, 1, 3, 4] {
 let paths = [(scenario == 1 || scenario == 4) ? (root as NSString).appendingPathComponent("missing") : source]
 var dest = (root as NSString).appendingPathComponent("output-\(scenario)")
 if scenario == 3 { dest = (source as NSString).appendingPathComponent("child") }
 var exportError: NSError?
 var exportAborted = false
 var completed = 0
 var exportedPaths = Set<String>()
 var renames: [(oldName: String, newName: String)] = []
 let attempt: Int32 = scenario == 4 ? 3 : 2
 let count32: Int32 = 1, imageNo: Int32 = 1
 let addDICOMDIR = false, tempPath = root, pathExtension = "dcm"
 for i in 0..<paths.count {
  let source = paths[i]
BODY
  completed += 1
 }
 if scenario == 0 {
  if exportAborted || exportError != nil || completed != 1 || FileManager.default.contents(atPath: source) != FileManager.default.contents(atPath: dest) { exit(1) }
 } else if !exportAborted || exportError == nil || (exportError?.localizedDescription ?? "").isEmpty || completed != 0 || !renames.isEmpty || !exportedPaths.isEmpty {
  FileHandle.standardError.write("FAIL scenario \(scenario): aborted \(exportAborted) error \(String(describing: exportError)) continued \(completed)\n".data(using: .utf8)!)
  exit(1)
 }
}
print("PASS: copy success preserved; missing source and invalid parent stop with actionable errors")
'''.replace('BODY',block).replace('REPORTED',reported)
with tempfile.TemporaryDirectory(prefix='horos-copy-failure-') as folder:
 p=Path(folder)
 (p/'Bridge.h').write_text(bridge);(p/'native.m').write_text(native);(p/'main.swift').write_text(program)
 subprocess.run(['xcrun','clang','-c','-fno-objc-arc','-I',str(p),'-I',str(root/'Horos/Sources'),str(p/'native.m'),'-o',str(p/'native.o')],check=True)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-import-objc-header',str(p/'Bridge.h'),str(root/'Modules/IsiXDatabase/Sources/ExportRules.swift'),
                 str(root/'Modules/IsiXDatabase/Sources/StudyListRules.swift'),str(p/'main.swift'),str(p/'native.o'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'files')],check=True)
