#!/usr/bin/env python3
"""The real ZIP extraction method pumps modal events and preserves archive data."""
from pathlib import Path
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/BrowserController.m').read_text()
start = source.index('+ (BOOL) unzipFile: (NSString*) file withPassword: (NSString*) pass destination: (NSString*) destination showGUI: (BOOL) showGUI')
end = source.index('\n- (int) askForZIPPassword:', start)
method = source[start:end]
driver = r'''#import <AppKit/AppKit.h>
static BOOL responded;
@interface WaitRendering : NSWindowController
- (id)init:(NSString *)title;
@end
@implementation WaitRendering
- (id)init:(NSString *)title {
    return [super initWithWindow:[[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,200,60)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO] autorelease]];
}
- (void)showWindow:(id)sender {
    [super showWindow:sender];
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.001 repeats:NO block:^(NSTimer *t) { responded = YES; }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}
@end
@interface NSFileManager (TestTemporaryDirectory)
- (NSString *)tmpDirPath;
@end
@implementation NSFileManager (TestTemporaryDirectory)
- (NSString *)tmpDirPath { return NSTemporaryDirectory(); }
@end
#define N2LogExceptionWithStackTrace(e) NSLog(@"%@",e)
@interface BrowserController : NSObject
@property(nonatomic,retain) NSWindow *window;
+ (BrowserController*)currentBrowser;
+ (BOOL)unzipFile:(NSString*)file withPassword:(NSString*)pass destination:(NSString*)destination showGUI:(BOOL)showGUI terminationStatus:(int*)status;
+ (void)offerToDeleteZIPFile:(NSString*)file;
@end
@implementation BrowserController
''' + method + r'''
@end
#define check(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while (0)
int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"HideZIPSuppressionMessage":@YES,@"deleteZIPfile":@NO} forName:NSArgumentDomain];
    NSString *zip = @(argv[1]), *dest = @(argv[2]);
    check([BrowserController unzipFile:zip withPassword:nil destination:dest showGUI:YES]);
    check(responded);
    check(NSApp.modalWindow == nil);
    check([NSFileManager.defaultManager fileExistsAtPath:zip]);
    NSData *bytes = [NSData dataWithContentsOfFile:[dest stringByAppendingPathComponent:@"image.dcm"]];
    check(bytes.length == 64*1024*1024 && ((const char *)bytes.bytes)[bytes.length-1] == 'x');
    check([BrowserController unzipFile:zip withPassword:nil destination:dest showGUI:NO]);
    check(![BrowserController unzipFile:@(argv[3]) withPassword:nil destination:dest showGUI:NO]);
    check(![BrowserController unzipFile:@(argv[3]) withPassword:nil destination:dest showGUI:YES]);
    check(NSApp.modalWindow == nil);
    puts("PASS: ZIP wait processes main-run-loop events, releases its modal session, preserves bytes/archive and handles invalid ZIP");
    return 0;
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-zip-modal-') as temporary:
    folder = Path(temporary)
    archive = folder / 'input.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr('image.dcm', b'x' * (64*1024*1024))
    (folder / 'invalid.zip').write_text('invalid archive')
    (folder / 'main.m').write_text(driver)
    subprocess.run(['xcrun','clang','-fblocks','-framework','AppKit',str(folder/'main.m'),'-o',str(folder/'check')], check=True, capture_output=True)
    subprocess.run([str(folder/'check'),str(archive),str(folder/'output'),str(folder/'invalid.zip')], check=True, capture_output=True)
    print('PASS: responsive modal ZIP extraction and data preservation')
