#!/usr/bin/env python3
"""The real ZIP extraction method pumps modal events and preserves archive data.

It also takes an archive unzip only warned about (status 1) when every entry was
extracted - an entry under an absolute path, bytes before the archive - and
still refuses one whose encrypted entries a wrong password left behind, which
ends with the same status.
"""
from pathlib import Path
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
# The extraction and the offer to delete the archive are Swift
# (BrowserController+Files.swift); they are compiled as they are, on a
# stand-in browser, progress window and temporary folder.
source = (root / 'Horos/Sources/BrowserController+Files.swift').read_text()
start = source.index('    // MARK: ZIP archives')
end = source.index('    /// Expands an encrypted archive, asking for its password', start)
extension = 'import AppKit\n\nextension BrowserController {\n' + source[start:end] + '}\n'
bridge = r'''#import <AppKit/AppKit.h>
#import "HorosObjCException.h"
NS_SWIFT_UI_ACTOR
@interface WaitRendering : NSWindowController
- (id)init:(NSString *)title;
@end
@interface NSFileManager (TestTemporaryDirectory)
- (NSString *)tmpDirPath;
@end
NS_SWIFT_UI_ACTOR
@interface BrowserController : NSObject
@property(nonatomic,retain) NSWindow *window;
+ (BrowserController*)currentBrowser;
@end
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
void DicomDatabaseLogError(const char* function, const char* file, int line, NSString* message);
'''
driver = r'''#import "Bridge.h"
#import "Horos-Swift.h"
static BOOL responded;
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%s: %@", pf, e); }
void DicomDatabaseLogError(const char* function, const char* file, int line, NSString* message) { NSLog(@"%s: %@", function, message); }
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
@implementation NSFileManager (TestTemporaryDirectory)
- (NSString *)tmpDirPath { return NSTemporaryDirectory(); }
@end
@implementation BrowserController
@synthesize window;
+ (BrowserController*)currentBrowser { return nil; }
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
    int status = -1;
    for (int i = 4; i <= 5; i++) {
        check([BrowserController unzipFile:@(argv[i]) withPassword:nil destination:dest showGUI:NO terminationStatus:&status]);
        check(status == 1);
        check([NSFileManager.defaultManager fileExistsAtPath:[dest stringByAppendingPathComponent:@"abs/IMG1.dcm"]]);
        check([NSFileManager.defaultManager fileExistsAtPath:[dest stringByAppendingPathComponent:@"ok/IMG2.dcm"]]);
    }
    check(![BrowserController unzipFile:@(argv[6]) withPassword:@"wrong" destination:dest showGUI:NO terminationStatus:&status]);
    check(status == 1);
    check([BrowserController unzipFile:@(argv[6]) withPassword:@"secret" destination:dest showGUI:NO terminationStatus:&status]);
    check(status == 0);
    puts("PASS: ZIP wait processes main-run-loop events, releases its modal session, preserves bytes/archive, handles invalid ZIP, takes warned archives whole and refuses partial ones");
    return 0;
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-zip-modal-') as temporary:
    folder = Path(temporary)
    archive = folder / 'input.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr('image.dcm', b'x' * (64*1024*1024))
    (folder / 'invalid.zip').write_text('invalid archive')
    # unzip ends with 1 on both: "stripped absolute path spec", and "extra bytes
    # at beginning or within zipfile".
    with zipfile.ZipFile(folder / 'absolute.zip', 'w') as zipped:
        zipped.writestr('/abs/IMG1.dcm', b'first synthetic DICOM')
        zipped.writestr('ok/IMG2.dcm', b'second synthetic DICOM')
    (folder / 'prefixed.zip').write_bytes(b'preamble' + (folder / 'absolute.zip').read_bytes())
    (folder / 'plain.dcm').write_bytes(b'plain synthetic DICOM')
    (folder / 'image.dcm').write_bytes(b'encrypted synthetic DICOM')
    subprocess.run(['/usr/bin/zip', '-q', str(folder / 'mixed.zip'), 'plain.dcm'], cwd=folder, check=True)
    subprocess.run(['/usr/bin/zip', '-q', '-P', 'secret', str(folder / 'mixed.zip'), 'image.dcm'], cwd=folder, check=True)
    (folder / 'main.m').write_text(driver)
    (folder / 'Bridge.h').write_text(bridge)
    (folder / 'Files.swift').write_text(extension)
    sources = root / 'Horos/Sources'
    for command in (
        ['xcrun', 'swiftc', '-parse-as-library', '-wmo', '-swift-version', '6', '-module-name', 'Horos',
         '-import-objc-header', str(folder / 'Bridge.h'), '-Xcc', '-I', '-Xcc', str(sources),
         '-emit-objc-header-path', str(folder / 'Horos-Swift.h'), '-c',
         str(sources / 'ArchiveImportLedger.swift'), str(sources / 'BrowserController+DatabaseSupport.swift'),
         str(folder / 'Files.swift'), '-o', str(folder / 'swift.o')],
        ['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(sources), str(sources / 'HorosObjCException.m'), '-o', str(folder / 'exception.o')],
        ['xcrun', 'clang', '-c', '-fmodules', '-fblocks', '-I', str(folder), '-I', str(sources), str(folder / 'main.m'), '-o', str(folder / 'main.o')],
        ['xcrun', 'swiftc', str(folder / 'main.o'), str(folder / 'swift.o'), str(folder / 'exception.o'), '-framework', 'AppKit', '-o', str(folder / 'check')],
        [str(folder / 'check'), str(archive), str(folder / 'output'), str(folder / 'invalid.zip'),
         str(folder / 'absolute.zip'), str(folder / 'prefixed.zip'), str(folder / 'mixed.zip')],
    ):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            print(result.stdout); print(result.stderr); raise SystemExit(1)
    print('PASS: responsive modal ZIP extraction and data preservation')
