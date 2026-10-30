#!/usr/bin/env python3
"""Exercise the actual conversion queue with real operations.

DicomDatabase is Swift: -processFilesAtPaths:intoDirAtPath:mode:error: and the
chunk it runs on each operation are compiled here as they are, from
DicomDatabase+Compression.swift, in an @implementation of a DicomDatabase whose
codec raises or fails on request, with the chunk rules of IsiXDatabase and the
@try of DicomDatabaseObjC.attempt (HorosObjCException.m).

The export's call is Swift (BrowserController+DICOMExport.swift): it runs here
as it is, through the browser's horos_processFiles(atPaths:in:mode:)
(BrowserController+StateAccess.swift) and HorosBrowserProcessFiles of
BrowserController+CAPI.m, on the database's real queue.
"""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402


def member(text, opening, closing='\n    }\n'):
 at=text.index(opening)
 return text[at:text.index(closing,at)+len(closing)]


s=(root/'Horos/Sources/DicomDatabase+Compression.swift').read_text()
a=s.index('    // NS_SWIFT_NOTHROW in the header:')
b=s.index('    @objc(threadBridgeForProcessFilesAtPaths:)',a)
methods=s[a:b]
assert 'func processFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!, mode: Int32, error: NSErrorPointer) -> Bool' in methods
assert 'private final func processChunk(' in methods
result_type=s[s.index('/// What a chunk answered, or the exception it raised.'):s.index('@objc(Compression) @implementation extension DicomDatabase')]
instance=(root/'Horos/Sources/DicomDatabase+Instance.swift').read_text()
helpers=member(instance,'    static func attempt(_ body: () -> Void) -> NSException? {')+member(instance,'    static func log(_ exception: NSException, stack: Bool, _ function: String) {')
database=(root/'Horos/Sources/DicomDatabase.swift').read_text()
helpers+=member(database,'    static func localizedCount(_ count: Int, _ singular: String, _ plural: String) -> String {')
helpers+=member(database,'    static func localizedFileCount(_ count: Int) -> String {')
export=(root/'Horos/Sources/BrowserController+DICOMExport.swift').read_text()
c=export.index('            if compressionTag == 1 || compressionTag == 2 {',export.index('        if files2Compress.count > 0 && !exportAborted {'))
caller=export[c:export.index('\n        }\n',c)+1]
d=export.index('    nonisolated static func reportedError(')
reported=export[d:export.index('\n    }\n',d)+len('\n    }\n')]
capi=(root/'Horos/Sources/BrowserController+CAPI.m').read_bytes().decode('latin1')
e=capi.index('BOOL HorosBrowserProcessFiles(');wrapper=capi[e:capi.index('\n}\n',e)+3]
access=(root/'Horos/Sources/BrowserController+StateAccess.swift').read_text()
f=access.index('    nonisolated static func horos_processFiles(');g=access.index('    nonisolated private static var unexplainedFailure')
swift_wrapper=access[f:access.index('\n    }\n',f)+len('\n    }\n')]+access[g:access.index('\n    }\n',g)+len('\n    }\n')]
bridge=r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "HorosObjCException.h"
// The declarations keep the app's spelling, which mixes annotated and plain pointers.
#pragma clang diagnostic ignored "-Wnullability-completeness"
enum {Compress, Decompress};
// As DicomDatabase.h declares it, without nullability.
@interface DicomDatabase:NSObject
-(BOOL)processFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)destDir mode:(int)mode error:(NSError**)error NS_SWIFT_NOTHROW;
@end
@interface DicomDatabase (Codec)
+(BOOL)compressDicomFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)destDir;
+(BOOL)decompressDicomFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)destDir;
@end
@interface NSThread (Test)
@property(retain) NSString* status;
@property CGFloat progress;
@end
@interface NSArray (Test)
// The Swift name of NSArray+N2.swift's implementation.
- (NSArray* _Nonnull)splitArrayIntoArraysOfMinSize:(NSUInteger)chunkSize maxArrays:(NSUInteger)maxArrays NS_SWIFT_NAME(splitArrayIntoArrays(ofMinSize:maxArrays:));
@end
@interface ThreadsManager:NSObject
+ (ThreadsManager*)defaultManager;
- (void)addThreadAndStart:(NSThread*)thread;
@end
#ifdef __cplusplus
extern "C"
#endif
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
NS_ASSUME_NONNULL_BEGIN
@interface BrowserController:NSObject
@end
#ifdef __cplusplus
extern "C"
#endif
BOOL HorosBrowserProcessFiles(NSArray* _Nullable paths, DicomDatabase* _Nullable database, int mode, NSError* _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
'''
swift=r'''
import Foundation
import IsiXDatabase
enum DicomDatabaseObjC {
HELPERS
}
RESULT
@objc @implementation extension DicomDatabase {
 final var processFilesLock: NSRecursiveLock? = NSRecursiveLock()
METHODS
}
nonisolated(unsafe) var alerts = 0
extension BrowserController {
REPORTED
WRAPPER
 @objc(showDICOMExportError:) func showDICOMExportError(_ error: NSError!) { if !(error?.localizedDescription ?? "").isEmpty { alerts += 1 } }
 @objc(runWithDatabase:files:tag:) func run(_ idatabase: DicomDatabase, files: NSArray, tag compressionTag: Int) -> Bool {
  alerts = 0
  var exportAborted = false
  let files2Compress = NSMutableArray(array: files)
CALLER
  if alerts != (exportAborted ? 1 : 0) { NSException(name: NSExceptionName("alert"), reason: "missing error", userInfo: nil).raise() }
  return exportAborted
 }
}
'''.replace('CALLER',caller).replace('REPORTED',reported).replace('WRAPPER',swift_wrapper).replace('HELPERS',helpers).replace('RESULT',result_type).replace('METHODS',methods)
program=r'''
#import "Bridge.h"
#import "Probe-Swift.h"
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) {}
@implementation NSThread (Test)
- (CGFloat)progress{return 0;}
- (void)setProgress:(CGFloat)x{}
- (NSString*)status{return nil;}
- (void)setStatus:(NSString*)x{}
@end
@implementation NSArray (Test)
- (NSArray*)splitArrayIntoArraysOfMinSize:(NSUInteger)n maxArrays:(NSUInteger)m{
 NSMutableArray *a=[NSMutableArray array];for(id x in self)[a addObject:@[x]];return a;
}
@end
@implementation ThreadsManager
+ (ThreadsManager*)defaultManager{return nil;}
- (void)addThreadAndStart:(NSThread*)t{}
@end
@implementation BrowserController
@end
WRAPPER
@implementation DicomDatabase (Codec)
+ (BOOL)compressDicomFilesAtPaths:(NSArray*)p intoDirAtPath:(NSString*)d{
 if([p containsObject:@"exception"])[NSException raise:@"codec" format:@"failure"];
 return ![p containsObject:@"failure"];
}
+ (BOOL)decompressDicomFilesAtPaths:(NSArray*)p intoDirAtPath:(NSString*)d{return [self compressDicomFilesAtPaths:p intoDirAtPath:d];}
@end
int main(){@autoreleasepool{
 DicomDatabase *db=[DicomDatabase new];
 NSArray *cases=@[@[],@[@"ok"],@[@"ok",@"failure",@"ok"],@[@"ok",@"exception",@"ok"]];
 for(int mode=0;mode<2;mode++)for(int i=0;i<4;i++){
  NSError *error=nil;BOOL ok=[db processFilesAtPaths:cases[i] intoDirAtPath:nil mode:mode error:&error];
  if(ok!=(i<2) || (i>=2 && !error.localizedFailureReason.length))return 1;
  if(![db processFilesAtPaths:@[@"ok"] intoDirAtPath:@"destination" mode:mode error:NULL])return 2;
 }
 BrowserController *probe=[BrowserController new];
 for(int tag=0;tag<3;tag++){
  if([probe runWithDatabase:db files:@[@"failure"] tag:tag]!=(tag!=0))return 3;
  if([probe runWithDatabase:db files:@[@"ok"] tag:tag])return 4;
 }
 [probe release];
 [db release];puts("PASS: both real operation queues propagate failures/exceptions and unlock for subsequent work");
}}
'''.replace('WRAPPER',wrapper)
with tempfile.TemporaryDirectory(prefix='horos-codec-queue-') as folder:
 p=Path(folder);(p/'test.mm').write_text(program);(p/'Bridge.h').write_text(bridge);(p/'Probe.swift').write_text(swift)
 modules=isix_modules.module_flags('IsiXDatabase',p/'IsiXDatabase')
 subprocess.run(['xcrun','swiftc','-parse-as-library','-module-name','Probe','-import-objc-header',str(p/'Bridge.h'),
                 '-I',str(root/'Horos/Sources'),*modules[:2],
                 '-emit-objc-header-path',str(p/'Probe-Swift.h'),'-c',str(p/'Probe.swift'),'-o',str(p/'probe.o')],check=True,timeout=300)
 subprocess.run(['xcrun','clang++','-c','-fmodules','-fcxx-modules','-I',str(p),'-I',str(root/'Horos/Sources'),str(p/'test.mm'),'-o',str(p/'test.o')],check=True,timeout=300)
 subprocess.run(['xcrun','clang','-c','-fobjc-arc','-I',str(root/'Horos/Sources'),str(root/'Horos/Sources/HorosObjCException.m'),'-o',str(p/'exception.o')],check=True,timeout=300)
 subprocess.run(['xcrun','swiftc',str(p/'test.o'),str(p/'probe.o'),str(p/'exception.o'),*modules,'-lc++','-framework','Foundation','-o',str(p/'test')],check=True,timeout=300)
 subprocess.run([str(p/'test')],check=True,timeout=60)
