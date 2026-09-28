#!/usr/bin/env python3
"""Exercise production print preparation and restoration with a controlled viewer."""
from pathlib import Path
import subprocess
import tempfile
from sources import source_text
root=Path(__file__).resolve().parent.parent
# AYNSImageToDicom is Swift since #717: the method is compiled as it is in the
# app, against a controlled viewer declared with the shapes of the real headers.
source=source_text('AYNSImageToDicom')
start=source.index('    @objc(dicomFileListForViewer:destinationPath:options:fileList:asColorPrint:withAnnotations:)')
method=source[start:source.index('\n    //********',start)]
header=r'''
#import <AppKit/AppKit.h>
extern BOOL FULL32BITPIPELINE;
extern NSString* const OsirixGLFontChangeNotification;
@interface OSIWindow : NSObject
+ (BOOL)dontConstrainWindow;
+ (void)setDontConstrainWindow:(BOOL)v;
@end
@interface OSIWindowController : NSObject
+ (BOOL)dontEnterMagneticFunctions;
+ (BOOL)dontWindowDidChangeScreen;
+ (void)setDontEnterMagneticFunctions:(BOOL)v;
+ (void)setDontEnterWindowDidChangeScreen:(BOOL)v;
@end
@interface NSFont (QA)
+ (void)resetFont:(int)n;
@end
// One object stands for the viewer, its image view, series view, window and
// screen, as in the former test.
@interface ViewerController : NSObject
@property short curImage;
@property int rowsValue, columnsValue;
@property BOOL magneticValue, matrixVisibleValue, displayed;
@property NSRect frame;
@property(readonly) NSRect visibleFrame;
- (ViewerController*)imageView;
- (ViewerController*)seriesView;
@property(readonly) ViewerController *window, *screen;
- (int)imageRows;
- (int)imageColumns;
- (BOOL)magnetic;
- (void)setMagnetic:(BOOL)v;
- (void)setMatrixVisible:(BOOL)v;
- (BOOL)checkFrameSize;
- (float)scaleValue;
- (void)setFrame:(NSRect)frame display:(BOOL)display;
- (void)setImageRows:(int)rows columns:(int)columns;
- (void)setImageIndex:(long)index;
- (void)setIndex:(short)index;
- (void)sendSyncMessage:(short)message;
- (void)adjustSlider;
- (void)display;
@end
void QAUseDefaults(NSUserDefaults *defaults);
#import "HorosObjCException.h"
'''
stubs=r'''
#import "qa.h"
#import <objc/runtime.h>
BOOL FULL32BITPIPELINE;
static BOOL constrainFlag, magneticFlag, screenFlag;
NSString* const OsirixGLFontChangeNotification=@"QA font";
@implementation OSIWindow
+ (BOOL)dontConstrainWindow { return constrainFlag; }
+ (void)setDontConstrainWindow:(BOOL)v { constrainFlag=v; }
@end
@implementation OSIWindowController
+ (BOOL)dontEnterMagneticFunctions { return magneticFlag; }
+ (BOOL)dontWindowDidChangeScreen { return screenFlag; }
+ (void)setDontEnterMagneticFunctions:(BOOL)v { magneticFlag=v; }
+ (void)setDontEnterWindowDidChangeScreen:(BOOL)v { screenFlag=v; }
@end
@implementation NSFont (QA)
+ (void)resetFont:(int)n {}
@end
static NSUserDefaults *qaDefaults;
@interface NSUserDefaults (QA)
+ (NSUserDefaults*)qa_standardUserDefaults;
@end
@implementation NSUserDefaults (QA)
+ (NSUserDefaults*)qa_standardUserDefaults { return qaDefaults; }
@end
void QAUseDefaults(NSUserDefaults *defaults) {
 if(!qaDefaults) method_exchangeImplementations(class_getClassMethod([NSUserDefaults class],@selector(standardUserDefaults)),class_getClassMethod([NSUserDefaults class],@selector(qa_standardUserDefaults)));
 qaDefaults=defaults;
}
@implementation ViewerController
- (ViewerController*)imageView { return self; }
- (ViewerController*)seriesView { return self; }
- (ViewerController*)window { return self; }
- (ViewerController*)screen { return self; }
- (int)imageRows { return self.rowsValue; }
- (int)imageColumns { return self.columnsValue; }
- (BOOL)magnetic { return self.magneticValue; }
- (void)setMagnetic:(BOOL)v { self.magneticValue=v; }
- (void)setMatrixVisible:(BOOL)v { self.matrixVisibleValue=v; }
- (BOOL)checkFrameSize { return self.matrixVisibleValue; }
- (float)scaleValue { return 0.5; }
- (NSRect)visibleFrame { return NSMakeRect(0,0,1200,900); }
- (void)setFrame:(NSRect)frame display:(BOOL)display { self.frame=frame; }
- (void)setImageRows:(int)rows columns:(int)columns { self.rowsValue=rows;self.columnsValue=columns; }
- (void)setImageIndex:(long)index { self.curImage=(short)index; }
- (void)setIndex:(short)index { self.curImage=index; }
- (void)sendSyncMessage:(short)message {}
- (void)adjustSlider {}
- (void)display { self.displayed=YES; }
@end
'''
program=r'''
import AppKit
final class Converter: NSObject {
 var failureMode = 0
 var previewImages: NSMutableArray! = NSMutableArray()
 var annotatedPreviewImages: NSMutableArray! = NSMutableArray()
 func _createDicomImage(with viewer: ViewerController!, toDestinationPath path: String!, asColorPrint color: Bool, withAnnotations annotations: Bool) -> String! {
  if viewer.curImage == 1 {
   if failureMode == 1 { return nil }
   if failureMode == 2 { return "" }
   if failureMode == 3 { NSException(name: NSExceptionName("QA"), reason: "synthetic render failure", userInfo: nil).raise() }
  }
  let file = (path as NSString).appendingPathComponent("\(viewer.curImage).dcm")
  try? "synthetic bytes".write(toFile: file, atomically: true, encoding: .utf8); return file
 }
METHOD
}
func check(_ v: Bool, _ what: String) { if !v { print("failed: " + what); exit(1) } }
let root = CommandLine.arguments[1]
let suite = "horos.qa.print." + UUID().uuidString
let qaDefaults = UserDefaults(suiteName: suite)!
QAUseDefaults(qaDefaults)
for initial in [false, true] { for failure in 0..<4 {
 FULL32BITPIPELINE = ObjCBool(initial); OSIWindow.setDontConstrain(initial); OSIWindowController.setDontEnterMagneticFunctions(initial); OSIWindowController.setDontEnterWindowDidChangeScreen(initial)
 qaDefaults.set(initial, forKey: "allowSmartCropping"); qaDefaults.set(Float(12), forKey: "FONTSIZE")
 qaDefaults.set(true, forKey: "printAt100%Minimum"); qaDefaults.set(4096, forKey: "MAXWindowSize")
 let viewer = ViewerController(); viewer.curImage = 7; viewer.rowsValue = 2; viewer.columnsValue = 3; viewer.magneticValue = true; viewer.matrixVisibleValue = true; viewer.frame = NSMakeRect(30, 40, 400, 300)
 let converter = Converter(); converter.failureMode = failure
 let dir = (root as NSString).appendingPathComponent("\(initial ? 1 : 0)-\(failure)")
 check((try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil, "createDirectory")
 let files = converter.dicomFileList(forViewer: viewer, destinationPath: dir, options: ["rows": 2, "columns": 3] as NSDictionary, fileList: [0, 1, 2] as NSArray, asColorPrint: false, withAnnotations: false)!
 check(files.count == (failure != 0 ? 0 : 3), "files.count==(failure?0:3)"); check((try! FileManager.default.contentsOfDirectory(atPath: dir)).count == files.count, "contents count == files.count")
 check(viewer.curImage == 7 && viewer.rowsValue == 2 && viewer.columnsValue == 3 && viewer.magneticValue && viewer.matrixVisibleValue && viewer.displayed, "viewer restored")
 check(NSEqualRects(viewer.frame, NSMakeRect(30, 40, 400, 300)), "frame restored")
 check(FULL32BITPIPELINE.boolValue == initial && OSIWindow.dontConstrainWindow() == initial && OSIWindowController.dontEnterMagneticFunctions() == initial && OSIWindowController.dontWindowDidChangeScreen() == initial, "flags restored")
 check(qaDefaults.bool(forKey: "allowSmartCropping") == initial && qaDefaults.float(forKey: "FONTSIZE") == 12, "preferences restored")
} }
qaDefaults.removePersistentDomain(forName: suite)
print("PASS: success/nil/empty/exception restore index, layout, window, flags and preferences; failures discard all partial files")
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-print-restore-') as directory:
 p=Path(directory);(p/'qa.h').write_text(header);(p/'stubs.m').write_text(stubs);(p/'main.swift').write_text(program)
 for name,src in [('stubs.o',p/'stubs.m'),('exception.o',root/'Horos/Sources/HorosObjCException.m')]:
  subprocess.run(['xcrun','clang','-c','-fobjc-arc','-fsanitize=address','-I',str(p),'-I',str(root/'Horos/Sources'),str(src),'-o',str(p/name)],check=True)
 subprocess.run(['xcrun','swiftc','-sanitize=address','-Xcc','-I'+str(root/'Horos/Sources'),'-import-objc-header',str(p/'qa.h'),str(p/'main.swift'),str(p/'stubs.o'),str(p/'exception.o'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p)],check=True)
