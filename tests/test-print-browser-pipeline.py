#!/usr/bin/env python3
"""#384 A executes the actual BrowserController print methods with synthetic model/pixel adapters.

The database and DCMPix adapters are deliberate doubles; this covers caller
selection/wiring/error paths, not native DICOM decoding or visible UI.

-printDatabaseSelection: and -printDatabaseSpool: are Swift since #831, in
BrowserController+DatabaseDragExport+Selection.swift. Both are taken from there
as they stand, with the file's own objcTry/objcIdentical, and compiled with
swiftc as an extension of an Objective-C double of BrowserController, beside the
real PrintSelection.swift and HorosObjCException. The Objective-C doubles keep
the declarations of the application's headers (DicomSeries, DicomImage,
DCMPix, HorosDCMTKObject, HorosAlertPanel), so the Swift code is checked
against the names it sees in the app; Wait, Swift in the app, is a Swift double.
"""
from pathlib import Path
import re
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
browser = (root / 'Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift').read_text(encoding='utf-8')
start = browser.index('    @objc(printDatabaseSelection:)\n    func printDatabaseSelection(_ sender: Any!) {')
end = browser.index('    @objc(databaseDoublePressed:)', start)
methods = browser[start:end]
helpers = ''
for name in ('objcTry', 'objcIdentical'):
    helpers += re.search(r'(?:@inline\(__always\)\n)?fileprivate func ' + name + r'\b.*?\n}\n', browser, re.S).group(0) + '\n'
header = r'''
// Only the annotations Swift reads from the application's headers are written.
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#import "HorosObjCException.h"
#import "HorosBoundedTask.h"
extern int alerts;
@interface HorosAlertPanel : NSObject
+ (NSInteger)runInformationalWithTitle:(nullable NSString *)title
                               message:(nonnull NSString *)message
                         defaultButton:(nullable NSString *)defaultButton
                       alternateButton:(nullable NSString *)alternateButton
                           otherButton:(nullable NSString *)otherButton
    NS_SWIFT_NAME(runInformational(title:message:defaultButton:alternateButton:otherButton:));
@end
@class DicomSeries;
@interface DicomStudy : NSObject
@property(nonatomic, retain) NSSet* series;
@end
@interface DicomSeries : NSObject
@property(retain) NSNumber *id;
@property(nonatomic, retain) NSNumber* windowWidth;
@property(nonatomic, retain) NSNumber* windowLevel;
@property(nonatomic, retain) NSString* seriesSOPClassUID;
@property(nonatomic, retain) NSString* modality;
@property(nonatomic, retain) NSString* name;
@property(retain) NSArray *images;
- (NSArray*) sortedImages;
@end
@interface DicomImage : NSObject
@property(nonatomic, retain) DicomSeries* series;
@property(copy) NSString *path;
@property(retain) NSNumber* numberOfFrames;
@property(nonatomic, retain) NSNumber* frameID;
- (NSString*) completePathResolved;
@end
@interface DCMObject : NSObject
@property(retain) NSData *payload;
- (id)attributeValueWithName:(NSString *)name;
@end
@interface HorosDCMTKObject : DCMObject
+ (nullable instancetype)objectWithContentsOfFile:(nonnull NSString *)path;
@end
extern NSMutableArray *loaded;
@interface DCMPix : NSObject
@property(readonly) BOOL notAbleToLoadImage;
@property (nonatomic) long pwidth, pheight;
@property(nonatomic) float savedWW, savedWL;
@property(nonatomic) double pixelRatio;
- (id) initWithPath:(NSString*) s :(long) pos :(long) tot :(float*) ptr :(long) f :(long) ss isBonjour:(BOOL) hello imageObj: (NSManagedObject*) iO;
- (void) CheckLoad;
- (float) calibratedWindowLevelForStoredLevel:(float) level;
- (void) checkImageAvailble:(float)newWW :(float)newWL;
- (NSImage*) image;
@end
@interface BrowserController : NSWindowController
@property(retain) NSArray *selection;
@property(retain, nullable) NSMatrix* horos_oMatrix;
@property(retain, nullable) NSArray* horos_matrixViewArray;
- (void)horos_superPrint:(id)sender;
- (NSArray *)databaseSelection;
@end
'''
stubs = r'''
#import "Harness.h"
int alerts = 0;
NSMutableArray *loaded;
@implementation HorosAlertPanel
+ (NSInteger)runInformationalWithTitle:(NSString *)title message:(NSString *)message defaultButton:(NSString *)defaultButton alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton { alerts++; return NSAlertFirstButtonReturn; }
@end
@implementation DicomStudy @end
@implementation DicomSeries
- (NSArray*) sortedImages { return self.images; }
@end
@implementation DicomImage
- (NSString*) completePathResolved { return self.path; }
@end
@implementation DCMObject
- (id)attributeValueWithName:(NSString *)name { return [name isEqual:@"EncapsulatedDocument"] ? self.payload : nil; }
@end
// The DCMTK reader the browser uses since #738; same interface.
@implementation HorosDCMTKObject
+ (instancetype)objectWithContentsOfFile:(NSString *)path {
    HorosDCMTKObject *object = [[[self alloc] init] autorelease];
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    if (bytes.length > 5) object.payload = [bytes subdataWithRange:NSMakeRange(5, bytes.length-5)];
    return object;
}
@end
@implementation DCMPix { NSImage *_image; BOOL _notAble; }
- (id) initWithPath:(NSString*) path :(long) a :(long) b :(float*) c :(long) frame :(long) e isBonjour:(BOOL) bonjour imageObj: (NSManagedObject*) object {
    if ((self=[super init])) {
        [loaded addObject:@[path.lastPathComponent, @(frame)]];
        _notAble = [path.lastPathComponent isEqual:@"missing"];
        self.pwidth=8; self.pheight=12; self.pixelRatio=2; self.savedWW=100; self.savedWL=50;
        unsigned char rgba[8*12*4];
        for (int i=0; i<8*12; i++) { rgba[4*i]=240; rgba[4*i+1]=frame*30; rgba[4*i+2]=17; rgba[4*i+3]=255; }
        NSData *data = [NSData dataWithBytes:rgba length:sizeof(rgba)];
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGImageRef image = CGImageCreate(8,12,8,32,8*4,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast,provider,NULL,NO,kCGRenderingIntentDefault);
        _image = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(8,12)];
        CGImageRelease(image); CGColorSpaceRelease(space); CGDataProviderRelease(provider);
    } return self;
}
- (void)dealloc { [_image release]; [super dealloc]; }
- (BOOL)notAbleToLoadImage { return _notAble; }
- (NSImage*) image { return _image; }
- (void) CheckLoad {}
// This selection test uses MONOCHROME2; native polarity is covered separately.
- (float) calibratedWindowLevelForStoredLevel:(float) level { return level; }
- (void) checkImageAvailble:(float)width :(float)level { NSCAssert(width == 400 && level == 40, @"stored WL/WW was lost"); }
@end
@interface NSWindowController (PrintDeclaration)
- (void)print:(id)sender;
@end
@implementation BrowserController
- (NSArray *)databaseSelection { return self.selection; }
- (void)horos_superPrint:(id)sender { [super print:sender]; }
@end
'''
wait = r'''
import AppKit
// Wait is Swift in the application (#714); the members the print uses.
final class Wait: NSObject {
    private let indicator = NSProgressIndicator()
    init!(string str: String!, _ useSession: Bool) { super.init() }
    func setCancel(_ val: Bool) {}
    func progress() -> NSProgressIndicator! { indicator }
    func showWindow(_ sender: Any?) {}
    func increment(by delta: Double) {}
    func pollCancellation() -> Bool { cancelAfter >= 0 && indicator.doubleValue >= Double(cancelAfter) }
    func close() {}
}
var cancelAfter = -1
var calls = 0

// Foundation's NSTemporaryDirectory() is the user's temporary folder whatever
// TMPDIR says, and every print test, and any Horos the user runs, spools
// there. Declared in the harness's own module, this one shadows it for the
// real PrintSelection.swift and for main.swift alike: the spool folders are
// made, discarded and counted in the folder the probe is given, and nothing
// else changes the count (#912).
func NSTemporaryDirectory() -> String {
    (CommandLine.arguments[1] as NSString).appendingPathComponent("tmp") + "/"
}
'''
extension = 'import AppKit\n\n' + helpers + 'extension BrowserController {\n' + methods + '}\n'
main = r'''
import AppKit
import PDFKit

final class ProbeBrowser: BrowserController {
    var printed: [Data] = []
    override func printDatabaseSpool(_ object: Any!) {
        let spool = object as! PrintSpool
        precondition(spool.success && !spool.cancelled, "partial job reached printing")
        printed = spool.pages.map { try! Data(contentsOf: $0.url!) }
        calls += 1
    }
}
func check(_ condition: Bool, _ line: Int = #line) {
    if !condition { FileHandle.standardError.write("FAIL line \(line)\n".data(using: .utf8)!); exit(1) }
}
func image(_ series: DicomSeries, _ path: String, _ frame: Int, _ frames: Int) -> DicomImage {
    let item = DicomImage(); item.series = series; item.path = path
    item.frameID = NSNumber(value: frame); item.numberOfFrames = NSNumber(value: frames); return item
}
func series(_ identifier: Int) -> DicomSeries {
    let item = DicomSeries(); item.id = NSNumber(value: identifier)
    item.seriesSOPClassUID = PrintSelection.ctImageStorage; item.modality = "CT"; item.name = "fixture"
    item.windowWidth = 400; item.windowLevel = 40; return item
}
func spools() -> Set<String> {
    precondition(NSTemporaryDirectory().hasPrefix(CommandLine.arguments[1]), "the spool folder is not the probe's")
    return Set(((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
        .filter { $0.hasPrefix(PrintSelection.spoolDirectoryPrefix) })
}
_ = NSApplication.shared
loaded = NSMutableArray()
let before = spools()
let window = NSWindow(contentRect: NSMakeRect(0, 0, 300, 300), styleMask: .borderless, backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let browser = ProbeBrowser(window: window)
let first = series(1), multi = series(2), archive = series(3)
first.images = [image(first, "first-0", 0, 1), image(first, "first-1", 0, 1), image(first, "first-2", 0, 1)]
multi.images = [image(multi, "multi", 0, 4)]
archive.name = "OsiriX ROI"; archive.images = [image(archive, "archive", 0, 1)]
let study = DicomStudy(); study.series = Set([archive, multi, first])
browser.selection = [study, first.images[1]]
browser.printDatabaseSelection(nil)
check(calls == 1 && alerts == 0 && browser.printed.count == 7 && loaded.count == 7)
check(loaded.isEqual(to: [["first-0", 0], ["first-1", 0], ["first-2", 0], ["multi", 0], ["multi", 1], ["multi", 2], ["multi", 3]]))
let page = PDFDocument(data: browser.printed[0])!
check(NSEqualRects(page.page(at: 0)!.bounds(for: .mediaBox), NSMakeRect(0, 0, 8, 24)))
check(spools() == before)

let matrix = NSMatrix(frame: NSMakeRect(0, 0, 100, 100), mode: .listModeMatrix, cellClass: NSActionCell.self, numberOfRows: 3, numberOfColumns: 1)
browser.horos_oMatrix = matrix
browser.horos_matrixViewArray = first.images
for i in 0..<3 { let cell = matrix.cell(atRow: i, column: 0)!; cell.tag = i; cell.isEnabled = true }
matrix.selectCell(atRow: 1, column: 0)
window.contentView = matrix
window.makeFirstResponder(matrix)
loaded.removeAllObjects()
browser.printDatabaseSelection(nil) // File > Print with thumbnail focus.
check(calls == 2 && browser.printed.count == 1 && loaded.isEqual(to: [["first-1", 0]]))
window.contentView = NSView(frame: NSMakeRect(0, 0, 100, 100))
window.makeFirstResponder(nil)

cancelAfter = 1; loaded.removeAllObjects()
browser.printDatabaseSelection(nil)
check(calls == 2 && alerts == 0 && loaded.count == 1 && spools() == before)
cancelAfter = -1
let bad = series(9); bad.images = [image(bad, "first", 0, 1), image(bad, "missing", 0, 1)]
browser.selection = [bad]
browser.printDatabaseSelection(nil)
check(calls == 2 && alerts == 1 && spools() == before)

// Fake DICOM envelope makes passing the whole file as PDF fail: the caller
// must ask DCMObject for EncapsulatedDocument instead.
let folder = CommandLine.arguments[1]
let path = (folder as NSString).appendingPathComponent("encapsulated.dcm")
var bytes = Data("DICOM".utf8)
let three = PDFDocument()
let one = PDFDocument(data: browser.printed[0])!
for i in 0..<3 { three.insert(one.page(at: 0)!.copy() as! PDFPage, at: i) }
bytes.append(three.dataRepresentation()!)
try! bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
let report = series(10); report.seriesSOPClassUID = PrintSelection.encapsulatedPDF; report.modality = "DOC"
report.images = [image(report, path, 0, 3), image(report, path, 1, 3), image(report, path, 2, 3)]; browser.selection = [report]
browser.printDatabaseSelection(nil)
check(calls == 3 && alerts == 1 && browser.printed.count == 3)
browser.horos_matrixViewArray = report.images
matrix.selectCell(atRow: 1, column: 0)
browser.printDatabaseSelection(matrix)
check(calls == 4 && alerts == 1 && browser.printed.count == 1)
check((try? Data(contentsOf: URL(fileURLWithPath: path))) == bytes)
check(spools() == before)
print("PASS: actual browser methods select full ordered series/frames and focused matrix subset; dedup, WL/WW, pixel aspect, cancellation, failure, encapsulated PDF extraction, temp cleanup")
'''
with tempfile.TemporaryDirectory(prefix='horos-print-384-browser-') as temporary:
    folder = Path(temporary)
    (folder / 'Harness.h').write_text(header)
    (folder / 'Harness.m').write_text(stubs)
    (folder / 'Wait.swift').write_text(wait)
    (folder / 'Print.swift').write_text(extension)
    (folder / 'main.swift').write_text(main)
    include = ['-I', str(folder), '-I', str(root / 'Horos/Sources')]
    subprocess.run(['xcrun', 'clang', '-c', '-fblocks', *include, str(folder / 'Harness.m'), '-o', str(folder / 'Harness.o')], check=True, timeout=60)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', *include, str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(folder / 'HorosObjCException.o')], check=True, timeout=60)
    subprocess.run(['xcrun', 'swiftc', *include, '-import-objc-header', str(folder / 'Harness.h'),
                    str(root / 'Horos/Sources/PrintSelection.swift'), str(folder / 'Wait.swift'), str(folder / 'Print.swift'), str(folder / 'main.swift'),
                    str(folder / 'Harness.o'), str(folder / 'HorosObjCException.o'), '-o', str(folder / 'check')], check=True, timeout=120)
    # The spool folders are made and counted in <folder>/tmp, which the
    # harness's NSTemporaryDirectory() returns (TMPDIR does not move
    # Foundation's), so another print test running alongside cannot change
    # the count.
    (folder / 'tmp').mkdir()
    subprocess.run([str(folder / 'check'), str(folder)], check=True, timeout=30)
