#!/usr/bin/env python3
"""Run the actual remote-index receiver with controlled transport failures.

The request goes through `HorosDatabaseTransport`, and only a
request the command classification calls idempotent is sent again — after the
partial index has been discarded. Both are modelled here: the fake transport
hands the receiver partial bytes and then fails, exactly as a connection reset
would, and the real retry-with-reset has to produce whole bytes.

RemoteDicomDatabase is Swift: the same methods are then taken from
RemoteDicomDatabase.swift and compiled with swiftc into a Swift stand-in of the
class, against the same Objective-C stand-ins, the same fake transport (behind
a Swift shim with the real DatabaseTransport signature) and the same checks.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tests'))
from sources import is_swift,source_text  # noqa: E402
source=source_text('RemoteDicomDatabase')
swift=is_swift('RemoteDicomDatabase')
def method(signature):
    start=source.index(signature);opening=source.index('{',start);depth=0
    for end in range(opening,len(source)):
        if source[end]=='{':depth+=1
        elif source[end]=='}':
            depth-=1
            if depth==0:return source[start:end+1]
    raise AssertionError(signature)
constructor=method('@objc(initWithHost:port:update:)' if swift else '-(id)initWithHost:')
assert 'tmpDirectoryPathInTmp' in constructor and 'tmpFilePathInTmp' not in constructor
if swift:
    functions='\n'.join(method(s) for s in (
        'private func remoteDicomDatabaseRaise(','private func remoteDicomDatabaseException(',
        'private func horosSendDatabaseRequest('))
    methods='\n'.join('    '+method(s) for s in (
        '@objc(synchronousRequest:urgent:dataHandlerTarget:selector:context:)',
        '@objc func requestDatabasePasswordOnMainThread()','@objc func prepareAuthentication()','@objc func fetchDatabaseIndex()',
        '@objc(_connection:handleData_fetchDatabaseIndex:context:)'))
else:
    methods='\n'.join(method(s) for s in (
        'static NSData *HorosSendDatabaseRequest(',
        '-(NSData*)synchronousRequest:(NSData*)request urgent:(BOOL)urgent',
        '- (void)requestDatabasePasswordOnMainThread', '- (BOOL)prepareAuthentication {', '- (NSString *)fetchDatabaseIndex',
        '-(NSInteger)_connection:(N2Connection*)connection handleData_fetchDatabaseIndex:'))
code=r'''
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
typedef int OSStatus;
#define noErr 0
#define N2LogExceptionWithStackTrace(e) ((void)0)
#define CurrentDatabaseVersion @"fixture"
static void HorosResetRemoteDownload(id context) {}
static int mode, attempts, operations;
static BOOL cancelPrompt, promptOnMain;
@interface NSThread (Probe)
@property(copy) NSString *status,*progressDetails;
@property double progress;
- (void)enterOperation;- (void)exitOperation;
@end
@implementation NSThread (Probe)
- (void)setStatus:(id)x {} - (id)status{return nil;}
- (void)setProgressDetails:(id)x {} - (id)progressDetails{return nil;}
- (void)setProgress:(double)x {} - (double)progress{return 0;}
- (void)enterOperation{operations++;}- (void)exitOperation{operations--;}
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
@interface N2MutableUInteger:NSObject
@property NSUInteger unsignedIntegerValue;
+ (id)mutableUIntegerWithUInteger:(NSUInteger)n;
@end
@implementation N2MutableUInteger
+ (id)mutableUIntegerWithUInteger:(NSUInteger)n {N2MutableUInteger *x=[self new];x.unsignedIntegerValue=n;return x;}
@end
@interface BrowserController:NSObject
+ (id)currentBrowser;- (NSString*)askPassword;
@end
@implementation BrowserController
+ (id)currentBrowser{return [self new];}
- (NSString*)askPassword {promptOnMain=NSThread.isMainThread;return cancelPrompt?nil:@"fixture";}
@end
// The transport under the real request method: hands the streaming receiver
// its bytes, then either completes or fails the way a reset connection does.
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
    NSData *data=[(mode==1 || (mode==2 && attempts==1)?@"AB":@"ABCD") dataUsingEncoding:NSUTF8StringEncoding];
    if(receiving){NSError *handlerError=nil;receiving(data,&handlerError);}
    if(mode==2 && attempts==1){
        if(error)*error=[NSError errorWithDomain:@"Probe" code:1 userInfo:@{NSLocalizedDescriptionKey:@"connection reset after partial data"}];
        return nil;
    }
    return [NSData data];
}
@end
// Only reads may be sent again; the index fetch is one.
@class N2Connection;   // only a parameter type in the handler signature
@interface HorosSharedDatabaseCommand:NSObject
+ (BOOL)isRetryableRequest:(NSData*)request;
+ (NSString*)actionRequiredForRequest:(NSData*)request;
@end
@implementation HorosSharedDatabaseCommand
+ (BOOL)isRetryableRequest:(NSData*)request{return YES;}
+ (NSString*)actionRequiredForRequest:(NSData*)request{return nil;}
@end
// Authorization framing is covered separately; this transport exercises decoded index bytes.
@interface HorosSharedDatabaseAuthorization:NSObject
+ (BOOL)isPublicCommand:(NSString*)command;
+ (NSData*)authenticatedRequest:(NSData*)request password:(NSString*)password;
@end
@implementation HorosSharedDatabaseAuthorization
+ (BOOL)isPublicCommand:(NSString*)command{return YES;}
+ (NSData*)authenticatedRequest:(NSData*)request password:(NSString*)password{return request;}
@end
@interface RemoteDicomDatabase:NSObject {
    dispatch_semaphore_t _connectionsSemaphoreId;
    BOOL _requiresAuthenticatedRequests;
}
@property BOOL authenticationKnown, requiresAuthenticatedRequests;
@property(copy) NSString *password,*baseDirPath;
@property id host;
@property NSInteger port;
@property(copy) NSString *address;
- (NSString*)fetchDatabaseVersion;- (BOOL)fetchIsPasswordProtected;
- (BOOL)fetchIsRightPassword:(NSString*)password;- (unsigned int)fetchDatabaseIndexSize;
@end
@implementation RemoteDicomDatabase
- (NSString*)fetchDatabaseVersion{return @"fixture";}
- (BOOL)fetchIsPasswordProtected{return YES;}
- (BOOL)fetchIsRightPassword:(NSString*)password{return [password isEqualToString:@"fixture"];}
- (unsigned int)fetchDatabaseIndexSize{return 4;}
- (BOOL)supportsAuthenticatedRequests{return YES;}
ACTUAL_METHODS
@end
int main(int argc,char**argv){@autoreleasepool{
    RemoteDicomDatabase *remote=[RemoteDicomDatabase new];remote.baseDirPath=@(argv[1]);
    __block BOOL done=NO;__block int failed=0;
    [NSThread detachNewThreadWithBlock:^{@autoreleasepool{
        @try {
            NSString *path=[remote fetchDatabaseIndex];
            if(!promptOnMain || ![[NSData dataWithContentsOfFile:path] isEqualToData:[@"ABCD" dataUsingEncoding:NSUTF8StringEncoding]])failed++;
            [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
            mode=1;attempts=0;
            @try {[remote fetchDatabaseIndex];failed++;} @catch(NSException *e) {}
            if([[NSFileManager.defaultManager contentsOfDirectoryAtPath:remote.baseDirPath error:NULL] count]!=0)failed++;
            mode=2;attempts=0;path=[remote fetchDatabaseIndex];
            if(attempts!=2 || ![[NSData dataWithContentsOfFile:path] isEqualToData:[@"ABCD" dataUsingEncoding:NSUTF8StringEncoding]])failed++;
            [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
            remote.password=nil;cancelPrompt=YES;int before=attempts;
            if([remote fetchDatabaseIndex]!=nil || attempts!=before)failed++;
            if(operations!=0)failed++;
        } @catch(NSException *e){NSLog(@"unexpected %@",e);failed++;}
        dispatch_async(dispatch_get_main_queue(),^{done=YES;});
    }}];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while(!done && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    if(!done || failed)return 1;
    puts("ok: main-thread password, cancel, complete index, truncated cleanup and fresh retry bytes");return 0;
}}
'''

# The Swift build: the class under test is a Swift stand-in holding the real
# methods; the Objective-C stand-ins keep their bodies, and what Swift calls of
# them is declared in harness.h under the names the app's Swift sees.
SWIFT_CLASS=r'''
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

func horosResetRemoteDownload(_ context: NSMutableDictionary) {}

@objc(RemoteDicomDatabase) public final class RemoteDicomDatabase: NSObject {
    private var _connectionsSemaphoreId: DispatchSemaphore? = nil
    @objc var authenticationKnown = false
    @objc var requiresAuthenticatedRequests = false
    @objc var password: String? = nil
    @objc var baseDirPath: String? = nil
    @objc var host: AnyObject? = nil
    @objc var port: Int = 0
    @objc var address: String? = nil
    @objc func fetchDatabaseVersion() -> String? { return "fixture" }
    @objc func fetchIsPasswordProtected() -> Bool { return true }
    @objc(fetchIsRightPassword:) func fetchIsRightPassword(_ password: String?) -> Bool { return password == "fixture" }
    @objc func fetchDatabaseIndexSize() -> UInt32 { return 4 }
    @objc func supportsAuthenticatedRequests() -> Bool { return true }
METHODS
}
FUNCTIONS
'''.replace('METHODS',methods).replace('FUNCTIONS',functions if swift else '')


def swift_harness(objc):
    start=objc.index('@interface RemoteDicomDatabase:NSObject {')
    end=objc.index('ACTUAL_METHODS\n@end\n')+len('ACTUAL_METHODS\n@end\n')
    objc=objc[:start]+'''@interface RemoteDicomDatabase:NSObject
@property BOOL authenticationKnown, requiresAuthenticatedRequests;
@property(copy) NSString *password,*baseDirPath;
@property id host;
@property NSInteger port;
@property(copy) NSString *address;
- (NSString*)fetchDatabaseIndex;
@end
'''+objc[end:]
    objc=objc.replace('HorosDatabaseTransport','HorosFakeDatabaseTransport')
    for line in ('#define N2LogExceptionWithStackTrace(e) ((void)0)\n','#define CurrentDatabaseVersion @"fixture"\n',
                 'static void HorosResetRemoteDownload(id context) {}\n'):
        assert line in objc,line
        objc=objc.replace(line,'')
    interfaces=[block for block in re.findall(r'@interface [^\n]*\n.*?@end\n',objc,re.S)
                if not block.startswith('@interface RemoteDicomDatabase')]
    for block in interfaces:
        objc=objc.replace(block,'',1)
    header='#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n'+'\n'.join(interfaces)+'''
extern NSString *const CurrentDatabaseVersion;
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
void RemoteDicomDatabaseAssertPasswordDialogOnMainThread(id object, SEL selector);
@interface N2Connection : NSObject
- (void)close;
@end
'''
    for old,new in (
            ('@interface HorosSharedDatabaseCommand:NSObject','NS_SWIFT_NAME(SharedDatabaseCommand)\n@interface HorosSharedDatabaseCommand:NSObject'),
            ('+ (BOOL)isRetryableRequest:(NSData*)request;','+ (BOOL)isRetryableRequest:(NSData*)request NS_SWIFT_NAME(isRetryable(_:));'),
            ('+ (NSString*)actionRequiredForRequest:(NSData*)request;','+ (NSString*)actionRequiredForRequest:(NSData*)request NS_SWIFT_NAME(actionRequired(for:));'),
            ('@interface HorosSharedDatabaseAuthorization:NSObject','NS_SWIFT_NAME(SharedDatabaseAuthorization)\n@interface HorosSharedDatabaseAuthorization:NSObject'),
            ('+ (id)mutableUIntegerWithUInteger:(NSUInteger)n;','+ (id)mutableUIntegerWithUInteger:(NSUInteger)n NS_SWIFT_NAME(mutableUInteger(with:));'),
            ('+ (id)currentBrowser;','+ (BrowserController*)currentBrowser;')):
        assert old in header,old
        header=header.replace(old,new)
    objc='#import "harness.h"\n'+objc+'''
NSString *const CurrentDatabaseVersion=@"fixture";
@implementation N2Connection
- (void)close {}
@end
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) {}
// NSAssert of -requestDatabasePasswordOnMainThread, as RemoteDicomDatabase+CAPI.m has it.
void RemoteDicomDatabaseAssertPasswordDialogOnMainThread(id self, SEL _cmd) {
    NSAssert(NSThread.isMainThread, @"The remote database password dialog requires the main thread.");
}
'''
    return header,objc


with tempfile.TemporaryDirectory(prefix='horos-remote-index-') as temporary:
    folder=Path(temporary);driver=folder/'main.m';binary=folder/'probe';data=folder/'data';data.mkdir()
    if swift:
        header,objc=swift_harness(code)
        (folder/'harness.h').write_text(header);driver.write_text(objc);(folder/'remote.swift').write_text(SWIFT_CLASS)
        for name in ('HorosObjCException.h','HorosObjCException.m'):
            (folder/name).write_bytes((root/'Horos/Sources'/name).read_bytes())
        steps=[['xcrun','clang','-fno-objc-arc','-fobjc-exceptions','-Wno-objc-method-access','-iquote',str(folder),'-c',str(driver),'-o',str(folder/'main.o')],
               ['xcrun','clang','-fno-objc-arc','-fobjc-exceptions','-iquote',str(folder),'-c',str(folder/'HorosObjCException.m'),'-o',str(folder/'exception.o')],
               ['xcrun','swiftc','-parse-as-library','-suppress-warnings','-module-name','Probe','-import-objc-header',str(folder/'harness.h'),
                str(folder/'remote.swift'),str(folder/'main.o'),str(folder/'exception.o'),'-framework','Foundation','-o',str(binary)]]
    else:
        driver.write_text(code.replace('ACTUAL_METHODS',methods))
        steps=[['xcrun','clang','-fno-objc-arc','-Wno-objc-method-access','-framework','Foundation',str(driver),'-o',str(binary)]]
    for step in steps:
        build=subprocess.run(step,capture_output=True,text=True)
        assert build.returncode==0,build.stdout+build.stderr
    run=subprocess.run([str(binary),str(data)],capture_output=True,text=True,timeout=20)
    assert run.returncode==0,run.stdout+run.stderr
    print(run.stdout,end='')
