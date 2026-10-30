#!/usr/bin/env python3
"""Execute the exporter's real DICOMDIR scheduling against existing index paths.

The DICOM export is Swift (BrowserController+DICOMExport.swift): its DICOMDIR
stage runs here as it is, through the browser's horos_createDicomDir(atDir:)
(BrowserController+StateAccess.swift) and HorosBrowserCreateDicomDir of
BrowserController+CAPI.m, against a recording DicomDir.
"""
from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
a=s.index('        if addDICOMDIR && !exportAborted {');b=s.index('\n        #endif',a)
c=s.index('    nonisolated static func reportedError(')
reported=s[c:s.index('\n    }\n',c)+len('\n    }\n')]
m=(root/'Horos/Sources/BrowserController+CAPI.m').read_bytes().decode('latin1')
d=m.index('BOOL HorosBrowserCreateDicomDir(');wrapper=m[d:m.index('\n}\n',d)+3]
access=(root/'Horos/Sources/BrowserController+StateAccess.swift').read_text()
f=access.index('    nonisolated static func horos_createDicomDir(');g=access.index('    nonisolated private static var unexplainedFailure')
swift_wrapper=access[f:access.index('\n    }\n',f)+len('\n    }\n')]+access[g:access.index('\n    }\n',g)+len('\n    }\n')]
bridge=r'''
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface NSThread(Status)
@property(copy, nullable) NSString *status;
@end
@interface DicomDir:NSObject
+ (BOOL)createDicomDirAtDir:(NSString*)path error:(NSError**)error;
@end
@interface BrowserController:NSObject
@end
BOOL HorosBrowserCreateDicomDir(NSString* _Nullable path, NSError* _Nullable * _Nullable error);
extern int attempts, fail;
NS_ASSUME_NONNULL_END
'''
native=r'''
#import "Bridge.h"
int attempts,fail;
@implementation NSThread(Status)
- (void)setStatus:(NSString*)status{}
- (NSString*)status{return @"";}
@end
@implementation DicomDir
+ (BOOL)createDicomDirAtDir:(NSString*)path error:(NSError**)error {attempts++;if(fail)*error=[NSError errorWithDomain:@"test" code:1 userInfo:nil];return !fail;}
@end
@implementation BrowserController
@end
WRAPPER
'''.replace('WRAPPER',wrapper)
code=r'''
import Foundation
var alerts = 0
extension BrowserController {
REPORTED
WRAPPER
 @objc(showDICOMExportError:) func showDICOMExportError(_ error: NSError!) { alerts += 1 }
 func run(_ path: String, enabled addDICOMDIR: Bool) -> Bool {
  var exportAborted = false
  // The folders the export gave its patients, each once however many images it has.
  let patientFolders = NSMutableArray(array: [(path as NSString).appendingPathComponent("A"), (path as NSString).appendingPathComponent("B")])
  #if !OSIRIX_LIGHT
BODY
  #endif
  return exportAborted
 }
}
let root = CommandLine.arguments[1]
for name in ["A", "B"] {
 let folder = (root as NSString).appendingPathComponent(name)
 try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
 try! "existing index".write(toFile: (folder as NSString).appendingPathComponent("DICOMDIR"), atomically: true, encoding: .utf8)
}
for scenario in 0..<3 {
 attempts = 0; fail = scenario == 1 ? 1 : 0; alerts = 0
 let aborted = BrowserController().run(root, enabled: scenario != 2)
 let expected = scenario == 0 ? 2 : (scenario == 1 ? 1 : 0)
 if attempts != expected || aborted != (scenario == 1) || alerts != (scenario == 1 ? 1 : 0) {
  FileHandle.standardError.write("FAIL scenario \(scenario) attempts \(attempts) expected \(expected) aborted \(aborted)\n".data(using: .utf8)!); exit(1)
 }
}
print("PASS: existing DICOMDIR rebuilt once per patient; failure stops; disabled option skips indexing")
'''.replace('BODY',s[a:b]).replace('REPORTED',reported).replace('WRAPPER',swift_wrapper)
with tempfile.TemporaryDirectory(prefix='horos-dicomdir-refresh-') as folder:
 p=Path(folder);(p/'main.swift').write_text(code);(p/'Bridge.h').write_text(bridge);(p/'native.m').write_text(native)
 subprocess.run(['xcrun','clang','-c','-fno-objc-arc','-I',str(p),str(p/'native.m'),'-o',str(p/'native.o')],check=True)
 subprocess.run(['xcrun','swiftc','-import-objc-header',str(p/'Bridge.h'),str(p/'main.swift'),str(p/'native.o'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'files')],check=True)
