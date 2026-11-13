#!/usr/bin/env python3
"""Exercise production print preparation and restoration with a controlled viewer.

The capture turns smart cropping off and enlarges the font of the annotations
while it draws. Neither is a choice of the user: the preferences the
application stores must be, after a job that succeeded or failed, exactly
what they were, whether they held the two values or only the factory's applied
(the capture once stored both when it put them back). The drawing code still
reads the changed values during the capture, and a value given at launch is
there again afterwards. Nothing else of the DICOM print path writes a
preference but the list of printers.

What the capture changes goes through TemporaryPreference of IsiXPreferences,
the same type the print on paper uses: the method is compiled against the real
module.
"""
from pathlib import Path
import subprocess
import tempfile
import isix_modules
from sources import source_text
root=Path(__file__).resolve().parent.parent
# AYNSImageToDicom is Swift: the method is compiled as it is in the
# app, against a controlled viewer declared with the shapes of the real headers.
source=source_text('AYNSImageToDicom')
start=source.index('    @objc(dicomFileListForViewer:destinationPath:options:fileList:asColorPrint:withAnnotations:)')
method=source[start:source.index('\n    //********',start)]
# What the method changes of the preferences goes through the module's type.
assert method.count('TemporaryPreference(ViewerPreferences.')==2 and method.count('.restore()')==2,'the capture changes two preferences and takes both back'
# The print window uses it too, and neither file stores anything but the printers.
controller=source_text('AYDicomPrintWindowController')
stored=[line.strip() for text in (source,controller) for line in text.splitlines() if 'UserDefaults.standard.set(' in line]
assert stored==['UserDefaults.standard.set(printers, forKey: "AYDicomPrinter")'],stored
assert controller.count('TemporaryPreference(ViewerPreferences.alwaysScaleToFit)')==controller.count('alwaysScaleToFit.restore()')==2
header=r'''
#import <AppKit/AppKit.h>
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
@property NSInteger curImage;
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
- (void)setIndex:(NSInteger)index;
- (void)sendSyncMessage:(NSInteger)message;
- (void)adjustSlider;
- (void)display;
@end
void QAUseDefaults(NSUserDefaults *defaults);
#import "HorosObjCException.h"
'''
stubs=r'''
#import "qa.h"
#import <objc/runtime.h>
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
- (void)setImageIndex:(long)index { self.curImage=index; }
- (void)setIndex:(NSInteger)index { self.curImage=index; }
- (void)sendSyncMessage:(NSInteger) message {}
- (void)adjustSlider {}
- (void)display { self.displayed=YES; }
@end
'''
program=r'''
import AppKit
import IsiXPreferences
final class Converter: NSObject {
 var failureMode = 0
 var seenCropping: [Bool] = [], seenFont: [Float] = []
 var previewImages: NSMutableArray! = NSMutableArray()
 var annotatedPreviewImages: NSMutableArray! = NSMutableArray()
 func _createDicomImage(with viewer: ViewerController!, toDestinationPath path: String!, asColorPrint color: Bool, withAnnotations annotations: Bool) -> String! {
  // What the drawing code reads while the image is captured.
  seenCropping.append(UserDefaults.standard[ViewerPreferences.allowSmartCropping]); seenFont.append(UserDefaults.standard[ViewerPreferences.fontSize])
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
let launchArguments = qaDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
// The two values stored by the user, or only the factory's; then one given at launch as well.
for (kept, launched) in [(true, false), (false, false), (true, true), (false, true)] { for initial in [false, true] { for failure in 0..<4 {
 OSIWindow.setDontConstrain(initial); OSIWindowController.setDontEnterMagneticFunctions(initial); OSIWindowController.setDontEnterWindowDidChangeScreen(initial)
 if kept { qaDefaults.set(initial, forKey: "allowSmartCropping"); qaDefaults.set(Float(12), forKey: "FONTSIZE") }
 else { qaDefaults.removeObject(forKey: "allowSmartCropping"); qaDefaults.removeObject(forKey: "FONTSIZE"); qaDefaults.register(defaults: ["allowSmartCropping": initial, "FONTSIZE": Float(12)]) }
 var arguments = launchArguments
 if launched { arguments["FONTSIZE"] = Float(16) }
 qaDefaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
 let font: Float = launched ? 16 : 12
 qaDefaults.set(true, forKey: "printAt100%Minimum"); qaDefaults.set(4096, forKey: "MAXWindowSize")
 let storedBefore = (qaDefaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary
 check((storedBefore["FONTSIZE"] != nil) == kept && (storedBefore["allowSmartCropping"] != nil) == kept, "the case is set up: stored \(kept)")
 let viewer = ViewerController(); viewer.curImage = 7; viewer.rowsValue = 2; viewer.columnsValue = 3; viewer.magneticValue = true; viewer.matrixVisibleValue = true; viewer.frame = NSMakeRect(30, 40, 400, 300)
 let converter = Converter(); converter.failureMode = failure
 let dir = (root as NSString).appendingPathComponent("\(initial ? 1 : 0)-\(failure)")
 check((try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil, "createDirectory")
 let files = converter.dicomFileList(forViewer: viewer, destinationPath: dir, options: ["rows": 2, "columns": 3] as NSDictionary, fileList: [0, 1, 2] as NSArray, asColorPrint: false, withAnnotations: false)!
 check(files.count == (failure != 0 ? 0 : 3), "files.count==(failure?0:3)"); check((try! FileManager.default.contentsOfDirectory(atPath: dir)).count == files.count, "contents count == files.count")
 check(viewer.curImage == 7 && viewer.rowsValue == 2 && viewer.columnsValue == 3 && viewer.magneticValue && viewer.matrixVisibleValue && viewer.displayed, "viewer restored")
 check(NSEqualRects(viewer.frame, NSMakeRect(30, 40, 400, 300)), "frame restored")
 check(OSIWindow.dontConstrainWindow() == initial && OSIWindowController.dontEnterMagneticFunctions() == initial && OSIWindowController.dontWindowDidChangeScreen() == initial, "flags restored")
 let what = "stored \(kept), given at launch \(launched), smart cropping \(initial), failure \(failure)"
 check(qaDefaults.bool(forKey: "allowSmartCropping") == initial && qaDefaults.float(forKey: "FONTSIZE") == font, "preferences read as before: " + what)
 check(((qaDefaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary).isEqual(storedBefore), "the stored preferences are what they were: " + what
       + " -> \((qaDefaults.persistentDomain(forName: suite) ?? [:]).filter { $0.key == "FONTSIZE" || $0.key == "allowSmartCropping" })")
 check((qaDefaults.volatileDomain(forName: UserDefaults.argumentDomain) as NSDictionary).isEqual(arguments), "what the launch gave is what it was: " + what)
 check(!converter.seenCropping.isEmpty && !converter.seenCropping.contains(true), "smart cropping is off while the images are captured: " + what)
 check(!converter.seenFont.contains(font), "the font is enlarged while the images are captured: " + what)
} } }
qaDefaults.setVolatileDomain(launchArguments, forName: UserDefaults.argumentDomain)
qaDefaults.removePersistentDomain(forName: suite)
print("PASS: success/nil/empty/exception restore index, layout, window, flags and preferences; failures discard all partial files; "
      + "the stored preferences and the launch's are untouched, kept by the user or not, while the capture reads its own values")
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-print-restore-') as directory:
 p=Path(directory);(p/'qa.h').write_text(header);(p/'stubs.m').write_text(stubs);(p/'main.swift').write_text(program)
 for name,src in [('stubs.o',p/'stubs.m'),('exception.o',root/'Horos/Sources/HorosObjCException.m')]:
  subprocess.run(['xcrun','clang','-c','-fobjc-arc','-fsanitize=address','-I',str(p),'-I',str(root/'Horos/Sources'),str(src),'-o',str(p/name)],check=True)
 subprocess.run(['xcrun','swiftc','-sanitize=address','-Xcc','-I'+str(root/'Horos/Sources'),'-import-objc-header',str(p/'qa.h'),str(p/'main.swift'),str(p/'stubs.o'),str(p/'exception.o'),
                 *isix_modules.module_flags('IsiXPreferences',p/'modules'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p)],check=True)
