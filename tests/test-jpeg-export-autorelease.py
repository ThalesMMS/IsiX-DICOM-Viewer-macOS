#!/usr/bin/env python3
"""Execute the database export method with tracked image lifetimes and real JPEG/TIFF encoding.

The export is Swift (BrowserController+MovieExport.swift, with the file names
of IsiXDatabase's ExportNaming): the method runs here as it is, with the real
sanitizer, series-folder helper and HorosAlertPanel, over a Wait and a DCMPix
written without ARC like the app's, whose images are autoreleased.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
source = (sources / 'BrowserController+MovieExport.swift').read_text()
a = source.index('    @objc(exportImageAs:sender:)\n')
b = source.index('    @objc(exportJPEG:)', a)
method = source[a:b].replace('NSOpenPanel()', 'TestPanel()').replace('as! NSManagedObject', 'as! NSDictionary')
a = source.index('    nonisolated static func applySeriesWindow(')
window = source[a:source.index('\n    }\n', a) + len('\n    }\n')].replace('of image: NSManagedObject', 'of image: NSDictionary')
a = source.index('private func formatted(')
formatted = source[a:source.index('\n}\n', a) + 3]
export = (sources / 'BrowserController+DICOMExport.swift').read_text()
a = export.index('    @objc(replaceNotAdmitted:)\n')
sanitizer = export[a:export.index('    /// The patient folder the export', a)]
support = (sources / 'BrowserController+DatabaseSupport.swift').read_text()
helpers = ''
for name in ('    static func intValue(', '    static func literallyEqual('):
    a = support.index(name)
    helpers += support[a:support.index('\n    }\n', a) + len('\n    }\n')]
bridge = r'''
#import <Cocoa/Cocoa.h>
// Use the production response ABI referenced by the extracted exporter.
#import "HorosAlertPanel.h"
// The exporter names each series through this helper, a static function in a
// header of its own; compiling the real one keeps the harness exercising the
// real naming rather than a stand-in.
#import "HorosRasterSeriesFolder.h"
NS_ASSUME_NONNULL_BEGIN
extern NSUInteger liveImages, peakImages, encodedImages, cancelAfter;
@interface Wait : NSObject
- (nullable instancetype)initWithString:(NSString*)s :(BOOL)b;
- (void)setCancel:(BOOL)b;
- (void)showWindow:(nullable id)x;
- (nullable NSProgressIndicator*)progress;
- (void)incrementBy:(double)x;
- (BOOL)aborted;
- (void)close;
@end
@interface DCMPix : NSObject
- (nullable instancetype)initWithPath:(nullable NSString*)p :(long)a :(long)b :(nullable float*)c :(long)d :(long)e isBonjour:(BOOL)f imageObj:(nullable id)g;
- (void)checkImageAvailble:(float)a :(float)b;
@property(readonly) float savedWW, savedWL;
- (float)calibratedWindowLevelForStoredLevel:(float)level;
- (nullable NSImage*)image;
@end
NS_ASSUME_NONNULL_END
'''
native = r'''
#import "Bridge.h"
NSUInteger liveImages, peakImages, encodedImages, cancelAfter;
@interface TrackedImage : NSImage @end
@implementation TrackedImage
- (id)init { if((self=[super initWithSize:NSMakeSize(64,64)])) {
 liveImages++;peakImages=MAX(peakImages,liveImages);
 NSBitmapImageRep *rep=[[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:64 pixelsHigh:64 bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:192 bitsPerPixel:24] autorelease];
 memset(rep.bitmapData,100,64*192);[self addRepresentation:rep];
 } return self; }
- (void)dealloc {liveImages--;[super dealloc];}
@end
@implementation Wait
- (id)initWithString:(NSString*)s :(BOOL)b {return [super init];}
- (void)setCancel:(BOOL)b {} - (void)showWindow:(id)x {} - (NSProgressIndicator*)progress {return nil;}
- (void)incrementBy:(double)x {} - (BOOL)aborted {return cancelAfter && encodedImages>=cancelAfter;}
- (void)close {}
@end
@implementation DCMPix
- (id)initWithPath:(NSString*)p :(long)a :(long)b :(float*)c :(long)d :(long)e isBonjour:(BOOL)f imageObj:(id)g {return [super init];}
- (void)checkImageAvailble:(float)a :(float)b {} - (float)savedWW {return 256;} - (float)savedWL {return 128;}
- (float)calibratedWindowLevelForStoredLevel:(float)level {return level;}
// Autoreleased, as the app's DCMPix returns it.
- (NSImage*)image {encodedImages++;return [[[TrackedImage alloc] init] autorelease];}
@end
'''
program = r'''
import Cocoa
import IsiXDatabase
nonisolated(unsafe) var output = ""
nonisolated(unsafe) var alertCalls = 0
FORMATTED
enum BrowserObjC {
HELPERS
}
final class TestPanel {
 var canChooseDirectories = false, canChooseFiles = false, allowsMultipleSelection = false, canCreateDirectories = false
 var message = "", prompt = "", title = ""
 func runModal() -> NSApplication.ModalResponse { .OK }
 var url: URL? { URL(fileURLWithPath: output, isDirectory: true) }
}
final class Database { func isLocal() -> Bool { true } }
@objc(BrowserController) public final class BrowserController: NSObject {
 var window: NSWindow? { nil }
 var horos_oMatrix: NSObject?
 var database: Database? = Database()
 // The export is sent from no menu: not the thumbnails' context menu.
 func isThumbnailMenuItem(_ sender: Any!) -> Bool { false }
 func files(forDatabaseOutlineSelection images: NSMutableArray) -> NSMutableArray? {
  let paths = NSMutableArray()
  for i in 0..<64 {
   images.add(["instanceNumber": i / 2 + 1, "frameID": 0, "completePathResolved": "synthetic",
               "series": ["name": "Series", "id": 1, "study": ["name": "Patient", "studyName": "Study", "id": 1]]] as NSDictionary)
   paths.add("synthetic")
  }
  return paths
 }
 func files(forDatabaseMatrixSelection images: NSMutableArray) -> NSMutableArray? { files(forDatabaseOutlineSelection: images) }
}
extension BrowserController {
SANITIZER
WINDOW
METHOD
}
@main struct Main {
 static func main() {
  let runModal = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal))!
  let answer: @convention(block) (NSAlert) -> NSApplication.ModalResponse = { _ in alertCalls += 1; return .alertFirstButtonReturn }
  method_setImplementation(runModal, imp_implementationWithBlock(answer))
  let arguments = CommandLine.arguments
  var status = 0
  autoreleasepool {
   output = arguments[1]
   cancelAfter = arguments.count > 2 ? UInt(arguments[2])! : 0
   let format = arguments.count > 3 ? arguments[3] : "jpg"
   BrowserController().exportImage(as: format, sender: nil)
   var count = 0
   for case let relative as String in FileManager.default.enumerator(atPath: output)! where (relative as NSString).pathExtension == format {
    let data = try! Data(contentsOf: URL(fileURLWithPath: (output as NSString).appendingPathComponent(relative)))
    let rep = NSBitmapImageRep(data: data)!
    if rep.pixelsWide != 64 || rep.pixelsHigh != 64 { exit(2) }
    count += 1
   }
   print("encoded=\(encodedImages) readable=\(count) peak-live=\(peakImages) live-before-idle=\(liveImages)")
   let expected = cancelAfter != 0 ? Int(cancelAfter) : 64
   if count != expected || encodedImages != UInt(expected) || peakImages > 1 || liveImages != 0 { status = 1 }
  }
  print("live-after-outer-pool=\(liveImages)")
  if status != 0 || liveImages != 0 || alertCalls != 0 { exit(1) }
  print("PASS: per-image temporaries drain before the next image; JPEG/TIFF outputs and deferred collision renames remain valid")
 }
}
'''.replace('METHOD', method).replace('WINDOW', window).replace('SANITIZER', sanitizer).replace('HELPERS', helpers).replace('FORMATTED', formatted)
with tempfile.TemporaryDirectory(prefix='horos-jpeg-pool-') as folder:
    p = Path(folder)
    (p / 'main.swift').write_text(program)
    (p / 'Bridge.h').write_text(bridge)
    (p / 'native.m').write_text(native)
    for name, path in (('native.o', p / 'native.m'), ('alert.o', sources / 'HorosAlertPanel.m')):
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-Wno-deprecated-declarations', '-I', str(p), '-I', str(sources),
                        str(path), '-o', str(p / name)], check=True)
    flags = module_flags('IsiXDatabase', p / 'modules')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-import-objc-header', str(p / 'Bridge.h'), '-Xcc', '-I', '-Xcc', str(sources), *flags,
                    str(p / 'main.swift'), str(p / 'native.o'), str(p / 'alert.o'), '-framework', 'Cocoa', '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test'), str(p / 'output')], check=True)
    subprocess.run([str(p / 'test'), str(p / 'cancelled'), '5'], check=True)
    subprocess.run([str(p / 'test'), str(p / 'tiff'), '0', 'tif'], check=True)
