#!/usr/bin/env python3
"""The volume rendering CLUT/opacity editor keeps its state consistent (#756).

1. Selected curve. CLUTOpacityView kept the index of the selected curve when
   curves were removed. With curve 1 selected, "Remove All Curves" followed by
   -niceDisplay (which adds a curve), -setWL:ww: (sent by the VRView while
   windowing), -copy:, -delete: or -setCLUTtoVRView: raised an index out of
   range. The raise left the re-entry flags of -updateView and
   -setCLUTtoVRView: set, so the editor stopped sending its CLUT to the VRView.
   Deleting the selected curve among two raised the same way. The index now
   follows its curve when curves are inserted, removed or moved, and becomes
   -1 (nothing selected) when that curve is removed. A new curve is selected
   as it is drawn. "Send to back" used to leave the index on the curve that
   took the selected one's place, so -delete: removed that other curve.
2. Colors. -removeAllCurves: emptied the curves but not their colors. The
   stale colors were saved with the next preset.
3. Histogram without a volume. The buffer was allocated, never filled, and
   drawn anyway. Nothing is drawn now until there is a volume. A volume still
   draws its histogram, which shows that the check can see one.
4. -resolveOverlappingCurves, unfinished and never called, looped forever on
   overlapping curves. It is gone, along with -doesCurve:overlapCurve:, which
   only it used. Neither was ever declared in the header.
5. Non-RGB colors. -setColor:forCurveAtIndex: stored a gray color as given, and
   the VRView's -redComponent raised on it. -setColor:forPointAtIndex:
   inCurveAtIndex: did the same. Both now store calibrated RGB and ignore a
   color that has no RGB form, such as a pattern, or nil.

CLUTOpacityView.swift is compiled as it is, with doubles for the Objective-C++
bridge to the VRView (its -setAdvancedCLUT: reads -redComponent of each color,
as VRView does), BrowserController (no database, so nothing is saved) and a
private pasteboard in place of the general one. Exceptions are caught in
Objective-C. `<git revision>` as an optional argument reads the source from
that revision: that is the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


bridge = r'''
#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import <Accelerate/Accelerate.h>
#import "CLUTOpacityViewVRBridge.h"
#import "HorosObjCException.h"

extern NSString* const OsirixUpdateVolumeDataNotification;
extern NSString* const OsirixUpdateCLUTMenuNotification;

@interface DicomDatabase : NSObject
- (NSString *)clutsDirPath;
@end

@interface BrowserController : NSObject
+ (BrowserController *)currentBrowser;
@property(retain, nonatomic) DicomDatabase *database;
@end

/// What the VRView double received.
@interface HarnessVR : NSObject
+ (NSInteger)clutCount;
+ (nullable NSDictionary *)lastCLUT;
/// -redComponent raised on one of the colors of this many CLUTs.
+ (NSInteger)rejectedCLUTs;
@end

/// The exception the block raised, nil if none.
NSException * _Nullable HarnessTry(NS_NOESCAPE void (^ _Nonnull block)(void));
void HarnessUsePrivatePasteboard(void);
void HarnessReleasePrivatePasteboard(void);
'''

doubles = r'''
#import "Bridge.h"
#import <objc/runtime.h>

NSString* const OsirixUpdateVolumeDataNotification = @"OsirixUpdateVolumeDataNotification";
NSString* const OsirixUpdateCLUTMenuNotification = @"OsirixUpdateCLUTMenuNotification";

@implementation DicomDatabase
- (NSString *)clutsDirPath { return nil; }
@end

@implementation BrowserController
+ (BrowserController *)currentBrowser { return nil; }
@end

static NSInteger clutCount, rejectedCLUTs;
static NSDictionary *lastCLUT;
static float savedWL, savedWW;

@implementation HarnessVR
+ (NSInteger)clutCount { return clutCount; }
+ (NSDictionary *)lastCLUT { return lastCLUT; }
+ (NSInteger)rejectedCLUTs { return rejectedCLUTs; }
@end

@implementation CLUTOpacityViewVRBridge
+ (void)setAdvancedCLUT:(NSMutableDictionary *)clut lowResolution:(BOOL)lowRes ofVRView:(NSView *)vrView
{
    clutCount++;
    // As -[VRView setAdvancedCLUT:lowResolution:] reads them.
    @try {
        for (NSArray *colors in clut[@"colors"])
            for (NSColor *color in colors)
                (void)[color redComponent];
    } @catch (NSException *e) {
        rejectedCLUTs++;
    }
    NSMutableArray *colors = [NSMutableArray array];
    for (NSArray *c in clut[@"colors"]) [colors addObject:[c copy]];
    NSMutableArray *curves = [NSMutableArray array];
    for (NSArray *c in clut[@"curves"]) [curves addObject:[c copy]];
    lastCLUT = @{@"curves": curves, @"colors": colors};
}
+ (void)getWL:(float *)wl ww:(float *)ww ofVRView:(NSView *)vrView { *wl = savedWL; *ww = savedWW; }
+ (void)setWL:(float)wl ww:(float)ww ofVRView:(NSView *)vrView { savedWL = wl; savedWW = ww; }
+ (void)squareVRView:(NSView *)vrView sender:(id)sender {}
+ (void)setCurCLUTMenu:(NSString *)name ofVRView:(NSView *)vrView {}
+ (void)closeCLUTOpacityDrawerOfVRView:(NSView *)vrView {}
@end

NSException *HarnessTry(NS_NOESCAPE void (^block)(void))
{
    @try { block(); }
    @catch (NSException *e) { return e; }
    return nil;
}

static NSPasteboard *privatePasteboard;
static id PrivateGeneralPasteboard(id self, SEL _cmd) { return privatePasteboard; }

void HarnessUsePrivatePasteboard(void)
{
    privatePasteboard = [NSPasteboard pasteboardWithUniqueName];
    method_setImplementation(class_getClassMethod([NSPasteboard class], @selector(generalPasteboard)),
                             (IMP)PrivateGeneralPasteboard);
}

void HarnessReleasePrivatePasteboard(void) { [privatePasteboard releaseGlobally]; }
'''

main = r'''
import AppKit

func fail(_ reason: String) { print("FAIL: \(reason)") }

func raised(_ what: String, _ block: () -> Void) -> String? {
    if let e = HarnessTry(block) { return "\(what) raised \(e.name.rawValue): \(e.reason ?? "")" }
    return nil
}

func editor() -> CLUTOpacityView {
    let view = CLUTOpacityView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    view.setHUmin(-1000, HUmax: 3000)
    return view
}

func render(_ view: CLUTOpacityView) -> NSBitmapImageRep {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// Pixels of the curve area (right of the 30-point side bar) that are not the black background.
func paintedPixels(_ rep: NSBitmapImageRep, of view: CLUTOpacityView) -> Int {
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    var painted = 0
    for y in 0..<rep.pixelsHigh {
        for x in Int(32 * scale)..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if max(c.redComponent, c.greenComponent, c.blueComponent) > 8.0 / 255.0 { painted += 1 }
        }
    }
    return painted
}

func firstX(_ view: CLUTOpacityView, _ curve: Int) -> Double {
    let curves = view.convertCurvesForPlist() as! [[[String: NSNumber]]]
    return curves[curve][0]["x"]!.doubleValue
}

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "overlap" {
    // 4. Run in a process of its own: the former method never returned.
    let view = editor()
    view.newCurve()
    view.newCurve()
    let selector = NSSelectorFromString("resolveOverlappingCurves")
    if view.responds(to: selector) { _ = view.perform(selector) }
    print("returned")
    exit(0)
}

HarnessUsePrivatePasteboard()
defer { HarnessReleasePrivatePasteboard() }

// 1. Remove all curves with curve 1 selected, then use the editor.
do {
    let view = editor()
    view.newCurve()
    view.newCurve()
    view.selectCurve(at: 1)
    view.removeAllCurves(nil)
    if view.selectedCurveIndex() != -1 {
        fail("after Remove All Curves the selected curve index is \(view.selectedCurveIndex()), not -1 (none)")
    }
    var raises: [String] = []
    raises += [raised("-setWL:ww: without curves") { view.setWL(400, ww: 800) }].compactMap { $0 }
    raises += [raised("-niceDisplay") { view.niceDisplay() }].compactMap { $0 }
    if view.selectedCurveIndex() != 0 {
        fail("the curve -niceDisplay adds is not selected: index \(view.selectedCurveIndex())")
    }
    raises += [raised("-copy:") { view.copy(nil) }].compactMap { $0 }
    raises += [raised("-paste:") { view.paste(nil) }].compactMap { $0 }
    raises += [raised("-setWL:ww:") { view.setWL(400, ww: 800) }].compactMap { $0 }
    raises += [raised("-setCLUTtoVRView:") { view.setCLUTtoVRView(false) }].compactMap { $0 }
    raises += [raised("-delete:") { view.delete(nil) }].compactMap { $0 }
    raises.forEach { fail("after Remove All Curves with curve 1 selected, \($0)") }
    if view.convertCurvesForPlist().count != 1 {
        fail("copy, paste and delete of the new curve leave \(view.convertCurvesForPlist().count) curves, not 1")
    }

    // The re-entry flags must not be left set: the CLUT still reaches the VRView.
    view.newCurve()
    var before = HarnessVR.clutCount()
    _ = raised("-setCLUTtoVRView:") { view.setCLUTtoVRView(false) }
    if HarnessVR.clutCount() == before { fail("-setCLUTtoVRView: no longer sends the CLUT to the VRView") }
    before = HarnessVR.clutCount()
    _ = raised("-setWL:ww:") { view.setWL(300, ww: 600) }
    if HarnessVR.clutCount() == before { fail("-updateView no longer sends a changed CLUT to the VRView") }
}

// 1. Delete the selected curve of two.
do {
    let view = editor()
    view.newCurve()
    view.newCurve()
    view.selectCurve(at: 1)
    if let r = raised("-delete:", { view.delete(nil) }) { fail("deleting the selected curve 1 of 2: \(r)") }
    if view.selectedCurveIndex() != -1 {
        fail("after deleting the selected curve the index is \(view.selectedCurveIndex()), not -1 (none)")
    }
    if view.convertCurvesForPlist().count != 1 { fail("deleting the selected curve of 2 leaves \(view.convertCurvesForPlist().count)") }
}

// 1. "Send to back" moves the selection with the curve; delete removes that curve.
do {
    let view = editor()
    _ = render(view)  // lays the curve area out, as the drawer shows it
    view.newCurve()
    view.newCurve()
    let front = firstX(view, 0), back = firstX(view, 1)
    view.sendToBack(nil)
    if firstX(view, 1) != front { fail("Send to back did not move the new curve back") }
    if view.selectedCurveIndex() != 1 {
        fail("after Send to back the selected curve index is \(view.selectedCurveIndex()), not the moved curve's 1")
    }
    _ = raised("-delete:") { view.delete(nil) }
    if view.convertCurvesForPlist().count != 1 || firstX(view, 0) != back {
        fail("after Send to back, -delete: removed the curve that was not selected")
    }
}

// 2. Remove All Curves empties the colors too.
do {
    let view = editor()
    view.newCurve()
    view.newCurve()
    view.removeAllCurves(nil)
    let colors = view.convertPointColorsForPlist().count
    if colors != 0 { fail("after Remove All Curves \(colors) color sets remain for 0 curves") }
    view.newCurve()
    view.setCLUTtoVRView(false)
    let clut = HarnessVR.lastCLUT()
    let sent = ((clut?["curves"] as? NSArray)?.count ?? -1, (clut?["colors"] as? NSArray)?.count ?? -1)
    if sent.0 != 1 || sent.1 != 1 { fail("the VRView receives \(sent.0) curves and \(sent.1) color sets, not 1 and 1") }
}

// 3. No volume: nothing drawn in the curve area. A volume: its histogram is drawn.
do {
    let view = editor()
    let empty = paintedPixels(render(view), of: view)
    if empty != 0 { fail("without a volume the histogram area has \(empty) painted pixels") }

    let voxels = 100 * 100
    let volume = UnsafeMutablePointer<Float>.allocate(capacity: voxels)
    for i in 0..<voxels { volume[i] = i % 2 == 0 ? 40 : Float(-1000 + (i * 37) % 4000) }
    view.setVolumePointer(volume, width: 100, height: 100, numberOfSlices: 1)
    view.callComputeHistogram()
    let drawn = paintedPixels(render(view), of: view)
    if drawn < 1000 { fail("a volume's histogram paints only \(drawn) pixels: the check cannot see a histogram") }
    view.setVolumePointer(nil, width: 0, height: 0, numberOfSlices: 0)
    view.callComputeHistogram()
    let cleared = paintedPixels(render(view), of: view)
    if cleared != 0 { fail("after the volume goes, \(cleared) pixels of its histogram are still drawn") }
    volume.deallocate()
}

// 5. Colors enter the curves as RGB; one without an RGB form is refused.
do {
    let view = editor()
    view.newCurve()
    let gray = NSColor(calibratedWhite: 0.5, alpha: 1)
    if let r = raised("-setColor:forCurveAtIndex:", { view.setColor(gray, forCurveAt: 0) }) { fail(r) }
    if let r = raised("-setColor:forPointAtIndex:inCurveAtIndex:", { view.setColor(NSColor(deviceWhite: 0.25, alpha: 1), forPointAt: 1, inCurveAt: 0) }) { fail(r) }
    var rejected = HarnessVR.rejectedCLUTs()
    view.setCLUTtoVRView(false)
    if HarnessVR.rejectedCLUTs() != rejected { fail("the VRView's -redComponent raised on a gray color set on a curve") }
    let colors = ((HarnessVR.lastCLUT()?["colors"] as? [[NSColor]]) ?? [[]])[0]
    let names = Set(colors.map { $0.colorSpaceName.rawValue })
    if names != [NSColorSpaceName.calibratedRGB.rawValue] { fail("the curve's colors are in \(names.sorted()), not calibrated RGB") }
    let reds = colors.map { Double($0.usingColorSpaceName(.calibratedRGB)?.redComponent ?? -1) }
    let darkGray = Double(NSColor(deviceWhite: 0.25, alpha: 1).usingColorSpaceName(.calibratedRGB)!.redComponent)
    if reds.count != 4 || abs(reds[0] - 0.5) > 0.001 || abs(reds[1] - darkGray) > 0.001 || abs(reds[2] - 0.5) > 0.001 {
        fail("the gray colors became reds \(reds), not 0.5, \(darkGray), 0.5, 0.5")
    }

    let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 4, height: 4)))
    if let r = raised("-setColor:forCurveAtIndex: with a pattern", { view.setColor(pattern, forCurveAt: 0) }) { fail(r) }
    if let r = raised("-setColor:forPointAtIndex:inCurveAtIndex: with a pattern", { view.setColor(pattern, forPointAt: 2, inCurveAt: 0) }) { fail(r) }
    if let r = raised("-setColor:forCurveAtIndex: with nil", { view.setColor(nil, forCurveAt: 0) }) { fail(r) }
    rejected = HarnessVR.rejectedCLUTs()
    view.setCLUTtoVRView(false)
    if HarnessVR.rejectedCLUTs() != rejected { fail("the VRView's -redComponent raised on a pattern color set on a curve") }
    let after = ((HarnessVR.lastCLUT()?["colors"] as? [[NSColor]]) ?? [[]])[0]
    if after != colors { fail("a pattern color changed the curve's colors") }
}
print("done")
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-clut-editor-') as tmp:
    p = Path(tmp)
    (p / 'CLUTOpacityView.swift').write_bytes(read('Horos/Sources/CLUTOpacityView.swift'))
    (p / 'CLUTOpacityViewVRBridge.h').write_bytes(read('Horos/Sources/CLUTOpacityViewVRBridge.h'))
    (p / 'Bridge.h').write_text(bridge)
    (p / 'Doubles.m').write_text(doubles)
    (p / 'main.swift').write_text(main)
    # The editor's paste decodes through the restricted unarchiver (#818),
    # which catches NSUnarchiver's exceptions with HorosObjCException.
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        (p / name).write_bytes(read('Horos/Sources/' + name))
    swift_sources = [str(p / 'CLUTOpacityView.swift'), str(p / 'main.swift')]
    try:
        (p / 'RestrictedUnarchiver.swift').write_bytes(read('Horos/Sources/RestrictedUnarchiver.swift'))
        swift_sources.append(str(p / 'RestrictedUnarchiver.swift'))
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass   # a revision before it

    build = subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-w', '-I', str(p), str(p / 'Doubles.m'),
                            '-o', str(p / 'Doubles.o')], capture_output=True, text=True)
    if build.returncode:
        print(build.stderr[-2000:])
        failures.append('the doubles do not compile')
    build = subprocess.run(['xcrun', 'clang', '-c', '-fobjc-exceptions', '-w', str(p / 'HorosObjCException.m'),
                            '-o', str(p / 'HorosObjCException.o')], capture_output=True, text=True)
    if build.returncode:
        print(build.stderr[-2000:])
        failures.append('HorosObjCException does not compile')
    if not failures:
        build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-import-objc-header', str(p / 'Bridge.h'),
                                '-I', str(p), *swift_sources,
                                str(p / 'Doubles.o'), str(p / 'HorosObjCException.o'), '-o', str(p / 'test')],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr[-3000:])
            failures.append('the editor does not compile')
    if not failures:
        done = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=120)
        failures += [line[6:] for line in done.stdout.splitlines() if line.startswith('FAIL: ')]
        if done.returncode or 'done' not in done.stdout.splitlines():
            failures.append(f'the harness stopped with status {done.returncode}: {done.stderr[-500:]}')
        try:
            overlap = subprocess.run([str(p / 'test'), 'overlap'], capture_output=True, text=True, timeout=10)
            if 'returned' not in overlap.stdout:
                failures.append(f'resolving overlapping curves failed (status {overlap.returncode})')
        except subprocess.TimeoutExpired:
            failures.append('-resolveOverlappingCurves did not return within 10 s on two overlapping curves')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: removing curves clears the selected curve and the colors, the selection follows moved curves, '
      'no histogram is drawn without a volume, nothing loops on overlapping curves, and colors enter as RGB')
