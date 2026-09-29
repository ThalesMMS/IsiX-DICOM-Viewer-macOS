#!/usr/bin/env python3
"""Run the actual remote image download against a controlled transport (#644).

`-[RemoteDicomDatabase downloadRemotePaths:toLocalPaths:]` created its context
with the expected files only. The protocol state and the set of files still to
come were made by `HorosResetRemoteDownload`, which `-synchronousRequest:…`
called only before a retry. On the first attempt the handler found no file
remaining and refused the response ("Unexpected file count in remote
response."), and a protected database, whose `AUTHR` requests were not
classified as retryable, never got a second one: no image was ever downloaded.

The real methods are compiled here - the request, the download and its
streaming handler - under a fake transport that answers with the files the
request asks for, in small chunks:

* a single attempt downloads every file, byte for byte;
* a response cut inside a file and failed is sent again, the partial file is
  discarded and the files come out whole;
* a response with more files than were asked is refused, and nothing of it is
  left in the temporary folder.

RemoteDicomDatabase is Swift since #829: the same methods are then taken from
RemoteDicomDatabase.swift and compiled with swiftc into a Swift stand-in of the
class, against the same Objective-C stand-ins, the same fake transport (behind
a Swift shim with the real DatabaseTransport signature) and the same checks.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import is_swift, source_text  # noqa: E402

source = source_text('RemoteDicomDatabase')
swift = is_swift('RemoteDicomDatabase')


def method(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0:
                return source[start:end + 1]
    raise AssertionError(signature)


if swift:
    functions = '\n'.join(method(s) for s in (
        'private func remoteDicomDatabaseRaise(', 'private func remoteDicomDatabaseException(',
        'private func remoteDicomDatabaseAdd(',
        'private func horosCleanupRemoteDownload(', 'private func horosResetRemoteDownload(',
        'private func horosSendDatabaseRequest('))
    methods = '\n'.join('    ' + method(s) for s in (
        '@objc(_data:appendInt:)', '@objc(_data:appendStringUTF8:)',
        '@objc(synchronousRequest:urgent:dataHandlerTarget:selector:context:)',
        '@objc(downloadRemotePaths:toLocalPaths:)',
        '@objc(_connection:handleData_fetchDataForImage:context:)'))
else:
    functions = '\n'.join(method(s) for s in (
        'static void HorosCleanupRemoteDownload(', 'static void HorosResetRemoteDownload(',
        'static NSData *HorosSendDatabaseRequest('))
    methods = '\n'.join(method(s) for s in (
        '+(void)_data:(NSMutableData*)data appendInt:', '+(void)_data:(NSMutableData*)data appendStringUTF8:',
        '-(NSData*)synchronousRequest:(NSData*)request urgent:(BOOL)urgent dataHandlerTarget:',
        '- (BOOL)downloadRemotePaths:(NSArray *)remotePaths toLocalPaths:(NSArray *)localPaths {',
        '-(NSInteger)_connection:(N2Connection*)connection handleData_fetchDataForImage:'))

code = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#define N2LogExceptionWithStackTrace(e) ((void)0)
static int mode, attempts;
static BOOL retryable;
@interface N2MutableUInteger:NSObject
@property NSUInteger unsignedIntegerValue;
+ (id)mutableUIntegerWithUInteger:(NSUInteger)n;
- (void)increment;
@end
@implementation N2MutableUInteger
+ (id)mutableUIntegerWithUInteger:(NSUInteger)n {N2MutableUInteger *x=[[self new] autorelease];x.unsignedIntegerValue=n;return x;}
- (void)increment {self.unsignedIntegerValue=self.unsignedIntegerValue+1;}
@end
@interface NSFileManager (Probe)
- (NSString*)tmpFilePathInDir:(NSString*)directory;
@end
@implementation NSFileManager (Probe)
- (NSString*)tmpFilePathInDir:(NSString*)directory {
    NSString *path=[directory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [self createFileAtPath:path contents:[NSData data] attributes:nil];return path;
}
@end
static BOOL HorosReplaceReportFile(NSString *source, NSString *destination, NSError **error) {return NO;}
@class N2Connection;
@interface HorosSharedDatabaseCommand:NSObject
+ (BOOL)isRetryableRequest:(NSData*)request;
+ (NSString*)actionRequiredForRequest:(NSData*)request;
@end
@implementation HorosSharedDatabaseCommand
+ (BOOL)isRetryableRequest:(NSData*)request{return retryable;}
+ (NSString*)actionRequiredForRequest:(NSData*)request{return nil;}
@end
// Authorization framing and its classification are covered by test-database-transport.py.
@interface HorosSharedDatabaseAuthorization:NSObject
+ (BOOL)isPublicCommand:(NSString*)command;
+ (NSData*)authenticatedRequest:(NSData*)request password:(NSString*)password;
@end
@implementation HorosSharedDatabaseAuthorization
+ (BOOL)isPublicCommand:(NSString*)command{return YES;}
+ (NSData*)authenticatedRequest:(NSData*)request password:(NSString*)password{return request;}
@end

static NSData *content(NSUInteger index) {
    NSMutableData *data=[NSMutableData data];
    for (NSUInteger i=0; i<4000+index*777; i++) {uint8_t byte=(uint8_t)((i*31+index*7)&255);[data appendBytes:&byte length:1];}
    return data;
}
static void appendInt(NSMutableData *data, unsigned int value) {unsigned int big=NSSwapHostIntToBig(value);[data appendBytes:&big length:4];}
static NSString *readString(NSData *request, NSUInteger *offset) {
    unsigned int big;[request getBytes:&big range:NSMakeRange(*offset,4)];unsigned int length=NSSwapBigIntToHost(big);
    NSString *s=[[[NSString alloc] initWithBytes:(const char*)request.bytes+*offset+4 length:length-1 encoding:NSUTF8StringEncoding] autorelease];
    *offset+=4+length;return s;
}

// The server's answer to a DICOM request, handed over in 7-byte chunks; unconsumed
// bytes stay for the next chunk, as HorosDatabaseTransport keeps them.
@interface HorosDatabaseTransport:NSObject
+ (NSData*)sendRequest:(NSData*)request toHost:(NSString*)host port:(NSInteger)port
             receiving:(NSInteger (^)(NSData*, NSError**))receiving
             cancelled:(BOOL (^)(void))cancelled error:(NSError**)error;
@end
@implementation HorosDatabaseTransport
+ (NSData*)sendRequest:(NSData*)request toHost:(NSString*)host port:(NSInteger)port
             receiving:(NSInteger (^)(NSData*, NSError**))receiving
             cancelled:(BOOL (^)(void))cancelled error:(NSError**)error {
    attempts++;
    unsigned int big;[request getBytes:&big range:NSMakeRange(6,4)];unsigned int count=NSSwapBigIntToHost(big);
    NSUInteger offset=10;
    for (unsigned int i=0;i<count;i++) readString(request,&offset);
    NSMutableArray *destinations=[NSMutableArray array];
    for (unsigned int i=0;i<count;i++) [destinations addObject:readString(request,&offset)];
    if (mode==2) [destinations addObject:destinations.firstObject];   // one file more than was asked
    NSMutableData *response=[NSMutableData data];
    appendInt(response,(unsigned int)destinations.count);
    for (NSUInteger i=0;i<destinations.count;i++) {
        NSData *file=content(i);appendInt(response,(unsigned int)file.length);[response appendData:file];
        const char *name=[destinations[i] UTF8String];appendInt(response,(unsigned int)strlen(name)+1);[response appendBytes:name length:strlen(name)+1];
    }
    // Mode 1: the first answer stops inside the second file and the connection fails.
    NSUInteger end=(mode==1 && attempts==1)?response.length-2000:response.length;
    NSMutableData *pending=[NSMutableData data];
    for (NSUInteger at=0; at<end; at+=7) {
        [pending appendData:[response subdataWithRange:NSMakeRange(at,MIN(7,end-at))]];
        NSError *handlerError=nil;
        NSInteger consumed=receiving(pending,&handlerError);
        if (consumed<0) {if(error)*error=handlerError;return nil;}
        [pending replaceBytesInRange:NSMakeRange(0,consumed) withBytes:NULL length:0];
    }
    if (end<response.length || pending.length) {
        if(error)*error=[NSError errorWithDomain:@"Probe" code:1 userInfo:@{NSLocalizedDescriptionKey:@"connection reset inside a file"}];
        return nil;
    }
    return [NSData data];
}
@end

@interface RemoteDicomDatabase:NSObject {
    dispatch_semaphore_t _connectionsSemaphoreId;
}
@property BOOL authenticationKnown, requiresAuthenticatedRequests;
@property(copy) NSString *password,*address,*tempDirPath;
@property NSInteger port;
- (BOOL)prepareAuthentication;
- (BOOL)downloadRemotePaths:(NSArray *)remotePaths toLocalPaths:(NSArray *)localPaths;
@end
FUNCTIONS
@implementation RemoteDicomDatabase
- (BOOL)prepareAuthentication {self.authenticationKnown=YES;return YES;}
METHODS
@end

int main(int argc,char**argv){@autoreleasepool{
    NSString *base=@(argv[1]);
    RemoteDicomDatabase *remote=[RemoteDicomDatabase new];
    remote.address=@"127.0.0.1";remote.port=1;remote.authenticationKnown=YES;
    remote.tempDirPath=[base stringByAppendingPathComponent:@"TEMP"];
    NSString *cache=[base stringByAppendingPathComponent:@"cache"];
    for (NSString *folder in @[remote.tempDirPath,cache]) [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSArray *remotePaths=@[@"1/10.dcm",@"/linked/in place/é.dcm"];
    NSArray *localPaths=@[[cache stringByAppendingPathComponent:@"10.dcm"],[cache stringByAppendingPathComponent:@"é linked.dcm"]];
    int failed=0;
    BOOL (^whole)(void)=^BOOL{
        for (NSUInteger i=0;i<localPaths.count;i++) if(![[NSData dataWithContentsOfFile:localPaths[i]] isEqualToData:content(i)]) return NO;
        return YES;
    };
    NSUInteger (^leftovers)(void)=^NSUInteger{return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:remote.tempDirPath error:NULL] count];};

    mode=0;attempts=0;retryable=NO;
    BOOL ok=[remote downloadRemotePaths:remotePaths toLocalPaths:localPaths];
    if(!ok || attempts!=1 || !whole()){printf("FAIL: one attempt: returned %d after %d attempts, files whole %d\n",ok,attempts,whole());failed++;}
    if(leftovers()){printf("FAIL: one attempt left %lu temporary files\n",(unsigned long)leftovers());failed++;}

    for (NSString *path in localPaths) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    mode=1;attempts=0;retryable=YES;
    ok=[remote downloadRemotePaths:remotePaths toLocalPaths:localPaths];
    if(!ok || attempts!=2 || !whole()){printf("FAIL: retry after a cut: returned %d after %d attempts, files whole %d\n",ok,attempts,whole());failed++;}
    if(leftovers()){printf("FAIL: the retry left %lu temporary files\n",(unsigned long)leftovers());failed++;}

    for (NSString *path in localPaths) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    mode=2;attempts=0;retryable=NO;
    ok=[remote downloadRemotePaths:remotePaths toLocalPaths:localPaths];
    if(ok){printf("FAIL: a response with a file more than asked was accepted\n");failed++;}
    if(leftovers()){printf("FAIL: a refused response left %lu temporary files\n",(unsigned long)leftovers());failed++;}
    if(failed) return 1;
    puts("ok: one attempt downloads every file, a cut response is sent again whole, an extra file is refused");
    return 0;
}}
'''

# The Swift build: the class under test is a Swift stand-in holding the real
# methods; the Objective-C stand-ins keep their bodies, and what Swift calls of
# them is declared in harness.h under the names the app's Swift sees.
SWIFT_CLASS = r'''
import Foundation

// DatabaseTransport's signature, over the fake transport of the Objective-C build.
public final class DatabaseTransport {
    public typealias Receiver = (Data?, AutoreleasingUnsafeMutablePointer<NSError?>) -> Int
    public static func sendRequest(_ request: Data, toHost host: String, port: Int,
                                   receiving: Receiver?, cancelled: @escaping () -> Bool) throws -> Data {
        let block: ((Data?, NSErrorPointer) -> Int)? = receiving.map { receiving in { data, error in receiving(data, error!) } }
        return try HorosFakeDatabaseTransport.sendRequest(request, toHost: host, port: port, receiving: block, cancelled: cancelled)
    }
}

@objc(RemoteDicomDatabase) public final class RemoteDicomDatabase: NSObject {
    private var _connectionsSemaphoreId: DispatchSemaphore? = nil
    @objc var authenticationKnown = false
    @objc var requiresAuthenticatedRequests = false
    @objc var password: String? = nil
    @objc var address: String? = nil
    @objc var port: Int = 0
    private var _tempDirPath: String? = nil
    @objc(tempDirPath) func tempDirPath() -> String! { return _tempDirPath }
    @objc(setTempDirPath:) func setTempDirPath(_ path: String?) { _tempDirPath = path }
    @objc func prepareAuthentication() -> Bool { self.authenticationKnown = true; return true }
METHODS
}
FUNCTIONS
'''.replace('METHODS', methods).replace('FUNCTIONS', functions)


def swift_harness(objc):
    start = objc.index('@interface RemoteDicomDatabase:NSObject {')
    end = objc.index('METHODS\n@end\n') + len('METHODS\n@end\n')
    objc = objc[:start] + '''@interface RemoteDicomDatabase:NSObject
@property BOOL authenticationKnown, requiresAuthenticatedRequests;
@property(copy) NSString *password,*address,*tempDirPath;
@property NSInteger port;
- (BOOL)prepareAuthentication;
- (BOOL)downloadRemotePaths:(NSArray *)remotePaths toLocalPaths:(NSArray *)localPaths;
@end
''' + objc[end:]
    objc = objc.replace('HorosDatabaseTransport', 'HorosFakeDatabaseTransport')
    replacement = 'static BOOL HorosReplaceReportFile(NSString *source, NSString *destination, NSError **error) {return NO;}\n'
    objc = objc.replace(replacement, '')
    interfaces = [block for block in re.findall(r'@interface [^\n]*\n.*?@end\n', objc, re.S)
                  if not block.startswith('@interface RemoteDicomDatabase')]
    for block in interfaces:
        objc = objc.replace(block, '', 1)
    header = '#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n' + '\n'.join(interfaces) + '''
static inline ''' + replacement + '''void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
@interface N2Connection : NSObject
- (void)close;
@end
'''
    for old, new in (
            ('@interface HorosSharedDatabaseCommand:NSObject', 'NS_SWIFT_NAME(SharedDatabaseCommand)\n@interface HorosSharedDatabaseCommand:NSObject'),
            ('+ (BOOL)isRetryableRequest:(NSData*)request;', '+ (BOOL)isRetryableRequest:(NSData*)request NS_SWIFT_NAME(isRetryable(_:));'),
            ('+ (NSString*)actionRequiredForRequest:(NSData*)request;', '+ (NSString*)actionRequiredForRequest:(NSData*)request NS_SWIFT_NAME(actionRequired(for:));'),
            ('@interface HorosSharedDatabaseAuthorization:NSObject', 'NS_SWIFT_NAME(SharedDatabaseAuthorization)\n@interface HorosSharedDatabaseAuthorization:NSObject'),
            ('+ (id)mutableUIntegerWithUInteger:(NSUInteger)n;', '+ (id)mutableUIntegerWithUInteger:(NSUInteger)n NS_SWIFT_NAME(mutableUInteger(with:));')):
        assert old in header, old
        header = header.replace(old, new)
    objc = '#import "harness.h"\n' + objc.replace('#define N2LogExceptionWithStackTrace(e) ((void)0)\n', '') + '''
@implementation N2Connection
- (void)close {}
@end
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) {}
'''
    return header, objc


with tempfile.TemporaryDirectory(prefix='horos-remote-download-') as temporary:
    folder = Path(temporary)
    driver = folder / 'main.m'
    binary = folder / 'probe'
    data = folder / 'data'
    data.mkdir()
    if swift:
        header, objc = swift_harness(code)
        (folder / 'harness.h').write_text(header)
        driver.write_text(objc)
        (folder / 'remote.swift').write_text(SWIFT_CLASS)
        for name in ('HorosObjCException.h', 'HorosObjCException.m'):
            (folder / name).write_bytes((root / 'Horos/Sources' / name).read_bytes())
        steps = [['xcrun', 'clang', '-fno-objc-arc', '-fobjc-exceptions', '-Wno-objc-method-access', '-iquote', str(folder),
                  '-c', str(driver), '-o', str(folder / 'main.o')],
                 ['xcrun', 'clang', '-fno-objc-arc', '-fobjc-exceptions', '-iquote', str(folder),
                  '-c', str(folder / 'HorosObjCException.m'), '-o', str(folder / 'exception.o')],
                 ['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings', '-module-name', 'Probe',
                  '-import-objc-header', str(folder / 'harness.h'), str(folder / 'remote.swift'),
                  str(folder / 'main.o'), str(folder / 'exception.o'), '-framework', 'Foundation', '-o', str(binary)]]
    else:
        driver.write_text(code.replace('FUNCTIONS', functions).replace('METHODS', methods))
        steps = [['xcrun', 'clang', '-fno-objc-arc', '-Wno-objc-method-access', '-framework', 'Foundation',
                  str(driver), '-o', str(binary)]]
    for step in steps:
        build = subprocess.run(step, capture_output=True, text=True)
        if build.returncode != 0:
            print('FAIL: the download methods do not build: ' + (build.stdout + build.stderr)[-3000:])
            raise SystemExit(1)
    run = subprocess.run([str(binary), str(data)], capture_output=True, text=True, timeout=60)
    if run.returncode != 0:
        print((run.stdout + run.stderr).strip() or f'FAIL: exit {run.returncode}')
        raise SystemExit(1)
    print(run.stdout, end='')
