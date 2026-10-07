#!/usr/bin/env python3
"""Run the browser's archive Activity job with real threads and unzip processes."""
from pathlib import Path
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/BrowserController.m').read_text()
start = source.index('- (void) expandArchiveIntoIncomingFolder: (NSString*) archive\n{')
end = source.index('\n- (void) addFilesAndFolderToDatabase:', start)
activity = source[start:end]
start = source.index('+ (BOOL) unzipFile: (NSString*) file withPassword: (NSString*) pass destination: (NSString*) destination showGUI: (BOOL) showGUI\n{')
end = source.index('\n- (int) askForZIPPassword:', start)
extraction = source[start:end]

driver = r'''#import <AppKit/AppKit.h>
#import <objc/runtime.h>
static NSString *workingDirectory, *originalIncoming, *otherIncoming;
static unsigned prompts, errors, ticks;
static NSMutableArray *answers;
static void check(BOOL ok, const char *message) {
    if (!ok) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
@interface NSThread (ActivityTest)
@property(nonatomic,copy) NSString *status;
@property(nonatomic) float progress;
@property(nonatomic) BOOL supportsCancel;
@end
@implementation NSThread (ActivityTest)
- (void)setStatus:(NSString*)v { objc_setAssociatedObject(self,@selector(status),v,OBJC_ASSOCIATION_COPY); }
- (NSString*)status { return objc_getAssociatedObject(self,@selector(status)); }
- (void)setProgress:(float)v { objc_setAssociatedObject(self,@selector(progress),@(v),OBJC_ASSOCIATION_RETAIN); }
- (float)progress { return [objc_getAssociatedObject(self,@selector(progress)) floatValue]; }
- (void)setSupportsCancel:(BOOL)v { objc_setAssociatedObject(self,@selector(supportsCancel),@(v),OBJC_ASSOCIATION_RETAIN); }
- (BOOL)supportsCancel { return [objc_getAssociatedObject(self,@selector(supportsCancel)) boolValue]; }
@end
@interface NSFileManager (TestTemporaryDirectory)
- (NSString*)tmpDirPath;
@end
@implementation NSFileManager (TestTemporaryDirectory)
- (NSString*)tmpDirPath { return workingDirectory; }
@end
@interface ThreadsManager : NSObject
@property(nonatomic,retain) NSMutableArray *threads;
+ (id)defaultManager;
- (void)addThreadAndStart:(NSThread*)thread;
@end
@implementation ThreadsManager
+ (id)defaultManager { static ThreadsManager *m; if (!m) { m=[ThreadsManager new];m.threads=[NSMutableArray array]; } return m; }
- (void)addThreadAndStart:(NSThread*)thread {
    check(NSThread.isMainThread,"Activity registration must happen on main");
    check([thread.name isEqualToString:@"Uncompressing..."] && thread.progress==-1 && thread.supportsCancel,
          "Activity needs an indeterminate, cancellable extraction task");
    [self.threads addObject:thread]; [thread start];
}
@end
@interface DicomDatabase : NSObject
@property(nonatomic,copy) NSString *incomingDirPath;
@property(nonatomic) unsigned importRequests;
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting;
@end
@implementation DicomDatabase
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting { self.importRequests++; }
@end
@class FakeAlert;
@interface FakeWindow : NSObject
@property(nonatomic,assign) FakeWindow *sheetParent;
@property(nonatomic,assign) FakeAlert *owner;
- (void)endSheet:(FakeWindow*)sheet returnCode:(NSInteger)code;
- (BOOL)makeFirstResponder:(id)responder;
@end
@interface FakeAlert : NSObject
@property(nonatomic,copy) NSString *messageText, *informativeText;
@property(nonatomic,retain) id accessoryView;
@property(nonatomic,retain) FakeWindow *window;
@property(nonatomic,copy) void (^completion)(NSInteger);
@property(nonatomic) BOOL showsSuppressionButton;
@property(nonatomic,retain) NSButton *suppressionButton;
- (NSButton*)addButtonWithTitle:(NSString*)title;
- (void)beginSheetModalForWindow:(id)window completionHandler:(void (^)(NSInteger))completion;
- (NSInteger)runModal;
@end
@implementation FakeWindow
- (BOOL)makeFirstResponder:(id)responder { check(NSThread.isMainThread,"password field accessed off main");return YES; }
- (void)endSheet:(FakeWindow*)sheet returnCode:(NSInteger)code {
    check(NSThread.isMainThread,"password sheet dismissed off main");
    void (^callback)(NSInteger)=[sheet.owner.completion copy];
    sheet.sheetParent=nil; callback(code); [callback release];
}
@end
@implementation FakeAlert
- (id)init { if ((self=[super init])) { self.window=[[[FakeWindow alloc]init]autorelease]; self.window.owner=self; } return self; }
- (NSButton*)addButtonWithTitle:(NSString*)title { return nil; }
- (NSInteger)runModal { return NSAlertSecondButtonReturn; }
- (void)beginSheetModalForWindow:(id)window completionHandler:(void (^)(NSInteger))completion {
    check(NSThread.isMainThread,"alert created off main");
    if (!completion) { errors++; return; }
    prompts++; self.completion=completion;self.window.sheetParent=window;
    id answer=answers.count ? [[[answers objectAtIndex:0] retain] autorelease] : @"secret";
    if (answers.count) [answers removeObjectAtIndex:0];
    if (answer==NSNull.null) return; // Simulated user leaves the password sheet open.
    [self.accessoryView setStringValue:answer];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.window.sheetParent endSheet:self.window returnCode:NSAlertFirstButtonReturn]; });
}
- (void)dealloc { [_messageText release];[_informativeText release];[_accessoryView release];[_window release];[_completion release];[_suppressionButton release];[super dealloc]; }
@end
// Only user decisions are simulated. The product's password coordinator,
// cancellation, extraction, file handoff and Activity entry point run verbatim.
#define NSAlert FakeAlert
@interface WaitRendering : NSObject
@property(nonatomic,retain) NSWindow *window;
- (id)init:(NSString*)title;
- (void)showWindow:(id)sender;
- (void)close;
@end
@implementation WaitRendering
- (id)init:(NSString*)title { check(NO,"Activity extraction created a modal progress window");return nil; }
- (void)showWindow:(id)sender { check(NO,"Activity extraction displayed a modal window"); }
- (void)close {}
@end
#define N2LogExceptionWithStackTrace(e) NSLog(@"%@",e)
@interface BrowserController : NSObject
+ (BrowserController*)currentBrowser;
@property(nonatomic,retain) DicomDatabase *database;
@property(nonatomic,retain) FakeWindow *window;
- (void)expandArchiveThread:(NSDictionary*)parameters;
- (NSString*)passwordForArchive:(NSString*)archive;
- (void)showArchiveImportError:(NSString*)archive;
+ (void)offerToDeleteZIPFile:(NSString*)file;
+ (BOOL)unzipFile:(NSString*)file withPassword:(NSString*)pass destination:(NSString*)destination showGUI:(BOOL)showGUI terminationStatus:(int*)status;
@end
@implementation BrowserController
''' + activity + extraction + r'''
@end
static void pumpUntil(BOOL (^ready)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while (!ready() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    check(ready(),"background operation or password callback timed out");
}
static NSThread *lastThread(void) { return [[ThreadsManager defaultManager] threads].lastObject; }
static void finish(NSThread *thread) {
    pumpUntil(^BOOL{ return thread.isFinished; });
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static NSArray *entries(NSString *path) { return [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:NULL] ?: @[]; }
static NSArray *stagingFolders(void) {
    NSMutableArray *paths=[NSMutableArray array];
    for (NSString *incoming in @[originalIncoming,otherIncoming])
        for (NSString *name in entries(incoming))
            if ([name hasPrefix:@".horos-extract-"])
                [paths addObject:[incoming stringByAppendingPathComponent:name]];
    return paths;
}
int main(int argc,char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"HideZIPSuppressionMessage":@YES,@"deleteZIPfile":@NO} forName:NSArgumentDomain];
    NSString *root=@(argv[1]), *zip=@(argv[2]), *encrypted=@(argv[3]), *corrupt=@(argv[4]);
    workingDirectory=[root stringByAppendingPathComponent:@"working"];
    [NSFileManager.defaultManager createDirectoryAtPath:workingDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    DicomDatabase *original=[DicomDatabase new], *other=[DicomDatabase new];
    original.incomingDirPath=[root stringByAppendingPathComponent:@"original"];
    other.incomingDirPath=[root stringByAppendingPathComponent:@"other"];
    originalIncoming=original.incomingDirPath;otherIncoming=other.incomingDirPath;
    for (NSString *path in @[original.incomingDirPath,other.incomingDirPath])
        [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
    BrowserController *browser=[BrowserController new];browser.database=original;browser.window=[[[FakeWindow alloc]init]autorelease];
    NSTimer *timer=[NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *t){ticks++;}];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    NSTimeInterval before=NSDate.timeIntervalSinceReferenceDate;
    [browser expandArchiveIntoIncomingFolder:zip]; NSThread *first=lastThread();
    check(NSDate.timeIntervalSinceReferenceDate-before<0.1,"Import blocked the main thread");
    browser.database=other;
    finish(first);
    check(ticks>0,"main loop did not respond while extraction ran");
    check(entries(original.incomingDirPath).count==1 && entries(other.incomingDirPath).count==0,
          "switching database redirected extraction");
    NSString *folder=[original.incomingDirPath stringByAppendingPathComponent:entries(original.incomingDirPath).firstObject];
    NSData *payload=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"image.dcm"]];
    check(payload.length==64*1024*1024 && ((const char*)payload.bytes)[payload.length-1]=='x',"published incomplete data");
    check(([NSFileManager.defaultManager attributesOfItemAtPath:folder error:NULL].filePosixPermissions & 0777)==0700,"staging lost private permissions");
    check(original.importRequests==1 && other.importRequests==0,"import resumed in another database");

    browser.database=original;
    [browser expandArchiveIntoIncomingFolder:zip];NSThread *second=lastThread();
    [browser expandArchiveIntoIncomingFolder:zip];NSThread *third=lastThread();
    finish(second);finish(third);
    check(entries(original.incomingDirPath).count==3,"concurrent archives collided");

    unsigned oldErrors=errors,oldPrompts=prompts;
    [browser expandArchiveIntoIncomingFolder:corrupt];finish(lastThread());
    check(errors==oldErrors+1 && prompts==oldPrompts,"corrupt ZIP requested a password instead of an error");
    check(entries(original.incomingDirPath).count==3 && stagingFolders().count==0,"partial corrupt extraction was published or left behind");

    answers=[NSMutableArray arrayWithObjects:@"wrong",@"secret",nil];
    [browser expandArchiveIntoIncomingFolder:encrypted];finish(lastThread());
    check(prompts==oldPrompts+2 && entries(original.incomingDirPath).count==4,"password retry did not extract successfully");

    // ZIP's short password check can accept an incorrect password, then fail CRC.
    unsigned promptsBeforeCRC=prompts;
    answers=[NSMutableArray arrayWithObjects:@(argv[5]),@"secret",nil];
    [browser expandArchiveIntoIncomingFolder:encrypted];finish(lastThread());
    check(prompts==promptsBeforeCRC+2 && entries(original.incomingDirPath).count==5,
          "password producing a CRC error did not allow another attempt");

    answers=[NSMutableArray arrayWithObject:NSNull.null];
    unsigned promptBefore=prompts;
    [browser expandArchiveIntoIncomingFolder:encrypted];NSThread *waiting=lastThread();
    pumpUntil(^BOOL{return prompts>promptBefore;});[waiting cancel];finish(waiting);
    check(entries(original.incomingDirPath).count==5 && stagingFolders().count==0,"cancelling a password request leaked staging or published data");

    [browser expandArchiveIntoIncomingFolder:zip];NSThread *running=lastThread();
    pumpUntil(^BOOL{
        for (NSString *name in stagingFolders()) {
            NSString *file=[name stringByAppendingPathComponent:@"image.dcm"];
            if ([NSFileManager.defaultManager fileExistsAtPath:file]) return YES;
        }
        return NO;
    });
    [running cancel];finish(running);
    check(entries(original.incomingDirPath).count==5 && stagingFolders().count==0,"cancelling unzip published partial data or left staging");
    for (NSString *file in @[zip,encrypted,corrupt]) check([NSFileManager.defaultManager fileExistsAtPath:file],"source archive deleted");
    [timer invalidate];
    puts("PASS: Activity returns immediately; main loop, pinned database, concurrent jobs, private complete files, corrupt ZIP, password retry and both cancellation paths work");
    return 0;
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-archive-activity-') as temporary:
    folder = Path(temporary)
    with zipfile.ZipFile(folder/'input.zip', 'w', compression=zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr('image.dcm', b'x'*(64*1024*1024))
    (folder/'image.dcm').write_bytes(b'encrypted synthetic DICOM')
    (folder/'plain.dcm').write_bytes(b'plain synthetic DICOM')
    subprocess.run(['/usr/bin/zip','-q',str(folder/'encrypted.zip'),'plain.dcm'],cwd=folder,check=True)
    subprocess.run(['/usr/bin/zip','-q','-P','secret',str(folder/'encrypted.zip'),'image.dcm'],cwd=folder,check=True)
    # Find an incorrect password accepted by ZIP's one-byte header check.
    # Use the real archive reader to select it, then confirm unzip reports 2.
    crc_password = None
    with zipfile.ZipFile(folder/'encrypted.zip') as zipped:
        for attempt in range(8192):
            candidate = f'incorrect-{attempt}'
            try:
                zipped.read('image.dcm', pwd=candidate.encode())
            except zipfile.BadZipFile:
                probe = subprocess.run(['/usr/bin/unzip','-qq','-o','-P',candidate,
                                        str(folder/'encrypted.zip'),'-d',str(folder/'probe')],
                                       stdin=subprocess.DEVNULL, capture_output=True)
                if probe.returncode == 2:
                    crc_password = candidate
                    break
            except RuntimeError:
                pass
    assert crc_password is not None, 'could not reproduce incorrect-password CRC status'
    with zipfile.ZipFile(folder/'corrupt.zip','w') as zipped:
        zipped.writestr('valid.dcm',b'valid synthetic DICOM')
        zipped.writestr('broken.dcm',b'CRC must fail')
    with zipfile.ZipFile(folder/'corrupt.zip') as zipped:
        info=zipped.getinfo('broken.dcm')
        offset=info.header_offset+30+len(info.filename.encode())+len(info.extra)
    damaged=bytearray((folder/'corrupt.zip').read_bytes());damaged[offset]^=1
    (folder/'corrupt.zip').write_bytes(damaged)
    (folder/'main.m').write_text(driver)
    for command in ([ 'xcrun','clang','-fblocks','-framework','AppKit',str(folder/'main.m'),'-o',str(folder/'check') ],
                    [str(folder/'check'),str(folder),str(folder/'input.zip'),str(folder/'encrypted.zip'),str(folder/'corrupt.zip'),crc_password]):
        result=subprocess.run(command,capture_output=True,text=True)
        if result.returncode:
            print(result.stdout);print(result.stderr);raise SystemExit(result.returncode)
        if result.stdout:print(result.stdout.strip())
