#!/usr/bin/env python3
"""The real ZIP extraction method pumps modal events and preserves archive data.

It also takes an archive unzip only warned about (status 1) when every entry was
extracted - an entry under an absolute path, bytes before the archive - and
still refuses one whose encrypted entries a wrong password left behind, which
ends with the same status. The password is typed on unzip's terminal, never
given as -P.

An archive a Windows tool wrote with \\ between folders is one of those: unzip
puts the names right, warns and ends with 1. Its entries for the folders
themselves are not files to look for, while a file that stayed behind still
refuses the archive, and a file whose name really ends in \\ is still a file.
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

# The extraction and the offer to delete the archive are ArchiveImport's
# (ArchiveImport.swift), behind the browser's +unzipFile: selectors
# (BrowserController+Files.swift); they are compiled as they are, on a
# stand-in browser, progress window, preferences and temporary folder.
archives = (root / 'Horos/Sources/ArchiveImport.swift').read_text()
start = archives.index('extension ArchiveImport {\n\n    // MARK: Extraction')
extraction = archives[start:archives.index('\n}\n', start) + 3]
# The password never goes to unzip as -P, which ps shows to every process:
# the module's extraction types it on unzip's own terminal.
if '"-P"' in extraction or 'ProtectedZipArchiver.extract(' not in extraction:
    raise SystemExit('FAIL: the extraction gives unzip its password on the command line')
source = (root / 'Horos/Sources/BrowserController+Files.swift').read_text()
start = source.index('    // MARK: ZIP archives')
end = source.index('    @objc(askForZIPPassword:destination:)', start)
extension = ('import AppKit\nimport IsiXPreferences\n\n'
             '@MainActor final class ArchiveImport {}\n\n'
             'struct PreferencesSource {\n    static let process = PreferencesSource()\n'
             '    var preferences: UserDefaults { .standard }\n}\n\n'
             'extension BrowserController {\n' + source[start:end] + '}\n\n' + extraction)
# The progress window of an expansion on the main thread, a type of the same file.
extension += '\n' + archives[archives.index('/// The progress window of an expansion on the main thread'):]
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
    // The same warning about an absolute path, in an archive that also lists its folder.
    check([BrowserController unzipFile:@(argv[7]) withPassword:nil destination:dest showGUI:NO terminationStatus:&status]);
    check(status == 1);
    check([NSFileManager.defaultManager fileExistsAtPath:[dest stringByAppendingPathComponent:@"ok/IMG2.dcm"]]);
    // Backslashes between folders, without and with entries for the folders.
    for (int i = 8; i <= 9; i++) {
        check([BrowserController unzipFile:@(argv[i]) withPassword:nil destination:dest showGUI:NO terminationStatus:&status]);
        check(status == 1);
        check([NSFileManager.defaultManager fileExistsAtPath:[dest stringByAppendingPathComponent:@"ST_1/IM1.dcm"]]);
        check([NSFileManager.defaultManager fileExistsAtPath:[dest stringByAppendingPathComponent:@"ST_1/IM2.dcm"]]);
    }
    // The same archive with one file left behind, then whole.
    check(![BrowserController unzipFile:@(argv[10]) withPassword:@"wrong" destination:dest showGUI:NO terminationStatus:&status]);
    check(status == 1);
    check([BrowserController unzipFile:@(argv[10]) withPassword:@"secret" destination:dest showGUI:NO terminationStatus:&status]);
    check(status == 1);
    // A file whose name ends in a backslash is no folder: the one left behind is missed.
    check(![BrowserController unzipFile:@(argv[11]) withPassword:@"wrong" destination:dest showGUI:NO terminationStatus:&status]);
    check(status == 1);
    check([BrowserController unzipFile:@(argv[11]) withPassword:@"secret" destination:dest showGUI:NO terminationStatus:&status]);
    check(status == 0);
    puts("PASS: ZIP wait processes main-run-loop events, releases its modal session, preserves bytes/archive, handles invalid ZIP, takes warned archives whole, those with backslashes between folders too, and refuses partial ones");
    return 0;
}}
'''


def as_windows_archive(path):
    """Rewrites an archive /usr/bin/zip made as a Windows tool writes one: every
    entry says it comes from a FAT system, and its name has \\ between folders."""
    data = bytearray(path.read_bytes())
    end = data.rindex(b'PK\x05\x06')
    count, _, at = struct.unpack_from('<HII', data, end + 10)
    for _ in range(count):
        name, extra, comment = struct.unpack_from('<HHH', data, at + 28)
        local, = struct.unpack_from('<I', data, at + 42)
        data[at + 5] = 0  # the system the entry was made on: FAT
        data[at + 46:at + 46 + name] = data[at + 46:at + 46 + name].replace(b'/', b'\\')
        data[local + 30:local + 30 + name] = data[local + 30:local + 30 + name].replace(b'/', b'\\')
        at += 46 + name + extra + comment
    path.write_bytes(data)


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
    # "stripped absolute path spec" again, with an entry for the folder itself.
    with zipfile.ZipFile(folder / 'folders.zip', 'w') as zipped:
        zipped.writestr('ok/', b'')
        zipped.writestr('/abs/IMG1.dcm', b'first synthetic DICOM')
        zipped.writestr('ok/IMG2.dcm', b'second synthetic DICOM')
    # "appears to use backslashes as path separators": unzip ends with 1 on each
    # of these. -D leaves the entry of the folder out; the last has one entry
    # under a password, which a wrong one leaves behind.
    (folder / 'ST_1').mkdir()
    (folder / 'ST_1/IM1.dcm').write_bytes(b'first synthetic DICOM')
    (folder / 'ST_1/IM2.dcm').write_bytes(b'second synthetic DICOM')
    subprocess.run(['/usr/bin/zip', '-q', '-r', '-D', str(folder / 'backslash.zip'), 'ST_1'], cwd=folder, check=True)
    subprocess.run(['/usr/bin/zip', '-q', '-r', str(folder / 'backslash-folders.zip'), 'ST_1'], cwd=folder, check=True)
    subprocess.run(['/usr/bin/zip', '-q', str(folder / 'backslash-partial.zip'), 'ST_1/', 'ST_1/IM1.dcm'], cwd=folder, check=True)
    subprocess.run(['/usr/bin/zip', '-q', '-P', 'secret', str(folder / 'backslash-partial.zip'), 'ST_1/IM2.dcm'], cwd=folder, check=True)
    for name in ('backslash.zip', 'backslash-folders.zip', 'backslash-partial.zip'):
        as_windows_archive(folder / name)
    # Made here, where a backslash is a character of a name like another:
    # unzip leaves such a name alone and writes a file under it.
    (folder / 'odd\\').write_bytes(b'a synthetic file whose name ends in a backslash')
    subprocess.run(['/usr/bin/zip', '-q', str(folder / 'named.zip'), 'odd\\'], cwd=folder, check=True)
    subprocess.run(['/usr/bin/zip', '-q', '-P', 'secret', str(folder / 'named.zip'), 'image.dcm'], cwd=folder, check=True)
    (folder / 'main.m').write_text(driver)
    (folder / 'Bridge.h').write_text(bridge)
    (folder / 'Files.swift').write_text(extension)
    sources = root / 'Horos/Sources'
    # unzip runs through the module's extraction, which types a password on
    # unzip's own terminal.
    # The archiver's ZipCommand is taken alone from its file.
    export_rules = (root / 'Modules/IsiXDatabase/Sources/ExportRules.swift').read_text()
    at = export_rules.index('public enum ZipCommand {')
    (folder / 'ZipCommand.swift').write_text('import Foundation\n' + export_rules[at:export_rules.index('\n}\n', at) + 3])
    zip_sources = [str(root / 'Modules/IsiXDatabase/Sources' / name) for name in
                   ('ProtectedZipArchiver.swift', 'ZipPasswordTerminal.swift')] + [str(folder / 'ZipCommand.swift')]
    for command in (
        ['xcrun', 'swiftc', '-parse-as-library', '-wmo', '-swift-version', '6', '-module-name', 'Horos',
         '-import-objc-header', str(folder / 'Bridge.h'), '-Xcc', '-I', '-Xcc', str(sources),
         *isix_modules.module_flags('IsiXPreferences', folder / 'modules'),
         '-emit-objc-header-path', str(folder / 'Horos-Swift.h'), '-c',
         str(sources / 'ArchiveImportLedger.swift'), str(sources / 'BrowserController+DatabaseSupport.swift'),
         str(sources / 'HorosObjCException+Guards.swift'),
         *zip_sources, str(folder / 'Files.swift'), '-o', str(folder / 'swift.o')],
        ['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(sources), str(sources / 'HorosObjCException.m'), '-o', str(folder / 'exception.o')],
        ['xcrun', 'clang', '-c', '-fmodules', '-fblocks', '-I', str(folder), '-I', str(sources), str(folder / 'main.m'), '-o', str(folder / 'main.o')],
        ['xcrun', 'swiftc', str(folder / 'main.o'), str(folder / 'swift.o'), str(folder / 'exception.o'),
         *isix_modules.module_flags('IsiXPreferences', folder / 'modules'), '-framework', 'AppKit', '-o', str(folder / 'check')],
        [str(folder / 'check'), str(archive), str(folder / 'output'), str(folder / 'invalid.zip'),
         str(folder / 'absolute.zip'), str(folder / 'prefixed.zip'), str(folder / 'mixed.zip'),
         str(folder / 'folders.zip'), str(folder / 'backslash.zip'), str(folder / 'backslash-folders.zip'),
         str(folder / 'backslash-partial.zip'), str(folder / 'named.zip')],
    ):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            print(result.stdout); print(result.stderr); raise SystemExit(1)
    print('PASS: responsive modal ZIP extraction and data preservation')
