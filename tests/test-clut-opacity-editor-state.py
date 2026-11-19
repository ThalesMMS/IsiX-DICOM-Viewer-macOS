#!/usr/bin/env python3
"""The volume rendering CLUT/opacity editor keeps its state consistent.

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
   inCurveAtIndex: did the same. Both now store generic RGB and ignore a
   color that has no RGB form, such as a pattern, or nil.

6. 16-bit CLUTs of earlier versions, NSArchiver files without an
   extension, are read by the restricted reader or refused.
7. 16-bit CLUTs in property lists. The CLUT menu of the VR reads every
   .plist of the database's CLUT folder (and the bundle's) with
   +presetFromFileWithName:. The former converters forced each element with
   `as!`, so one of another type crashed the app, and they took NaN, opacities
   and colours outside 0...1 and curves without a colour for each point. Each
   malformed file is now refused whole (nil: it leaves the menu) and the
   converters return an empty array, without a crash; valid files - those the
   editor saves and the CLUTs of the bundled 3D presets - read back as before.
   Each file is read in a process of its own, so the negative control reports
   a crash per file. VRController (VRController*.swift), which reads the 3D
   states and presets (16bitClutCurves/16bitClutColors), is checked to go
   through the same validator.
8. Curves removed with the mouse, by mouse events in passes of the run loop
   of their own, as the undo manager groups them. The «−» button of the side
   bar removes one curve per click: the second click of a double-click took
   the undo of a double-click on the curves, which put the curve back in the
   editor and not in the volume. With a point selected it removes that
   point's curve (it removed the point, or nothing), and the Delete key only
   the point; the next curve is selected after each removal. The curves "+"
   adds lie 40 HU apart: a click on a curve's square selects that curve, not
   a point or the square of another curve in the click box. The volume
   receives what the editor shows, the empty CLUT when no curve is left
   (nothing was sent, and the volume kept the curves removed). A click on a
   line adds a point and selects that point, not its curve: the Delete key
   removes the point (it removed the curve). A click on nothing unselects the
   curve too: «−» then removes nothing (it removed a curve drawn unselected).
   The selected curve is drawn by its index: when undo moves it, its square
   is still drawn selected (it was drawn unselected and «−» removed it).
   Undo and redo wait for the mouse up of a drag (undo in a drag raised), and
   after the undo of a double-click the volume receives the curves as the
   editor has them again.
9. The undo history acts on curves by their index. Remove All Curves is
   undone, curves and colours together (undo raised NSRangeException), and
   a CLUT loaded from the menu, a preset or the saved state, or another kind
   of CLUT, forgets the history (undo removed a curve of the CLUT loaded, or
   raised).
10. «Send to back» and the colour panel act on the selected curve by its
   index, as «−» and Delete do. They looked for the square at the position
   the click on it stored: after an undo, a windowing in the VR or a zoom of
   the editor moved the square, they did nothing until the curve was clicked
   again. A click on a point gives the colour panel the point's colour; its
   notification must not colour the curve selected before the click.
   The curves' order is an edit the volume receives: of two curves' points
   at one value, the front curve's is the volume's. Send to back, and a curve
   brought to the front by its index, left the volume with the order before
   until the next edit, and a click on a line of a curve behind, which adds a
   point and brings that curve to the front, did not send the point either. A
   click on the square or on a point of a curve behind still sends the curves
   once: the point's colour, which the click gives the colour panel, changes
   nothing, and the mouse up sent the curves again when the panel held another
   colour.
11. An open end. The bundled bone presets end their bone curve with a point
   at 3071 HU, the top of a CT's range, at the height of the point before it,
   so that the curve holds that height for the densest values. Windowing in
   the VR, the window the editor gives the volume, the curve's square (a drag,
   an Option-drag), the Option-drag of its last point and a drag of that point
   act on the curve as on the curve without that end, which stays at 3071 HU
   at the height of the point before it. They measured the curve up to 3071
   HU: a window of 3024 HU, the square off the editor, and a narrower window
   collapsed the bone ramp. A last point at 3071 HU at another height, or a
   flat end below it, stays an ordinary point.
12. The colour of an open end. A colour given to the point before an open end
   reaches the end too, while the end has that point's colour, as the point's
   height does: in the editor, in the volume and in the CLUT saved and read
   back, and undo and redo act on both. The end kept its colour, so the curve's
   colour faded from the point's to the end's up to 3071 HU. A colour of the
   end's own stays, as does the colour of a last point at 3071 HU at another
   height.
13. An open end kept and drawn. A click near the flat line before an open end
   added the point at the click's height, a little above the end's, so the
   end was no longer open: the window and the square went back to 3071 HU,
   and the end's colour no longer followed. The point now lies on a flat
   line. The Delete key on the point before an open end that stays open left
   the end in the removed point's colour, fading from the point now before
   it; the end now takes that point's colour while it had the removed one's,
   and undo and redo act on both. On a range above 3071 HU the volume holds
   an open end's height on to the series' maximum, short of any curve above
   it; the editor drew the curve dropping to 0 at 3071 HU, and now draws it
   on to the top of its range, short of a curve above it.

CLUTOpacityView.swift is compiled as it is, with doubles for the VRView and
its controller (the VRView's -setAdvancedCLUT: reads -redComponent of each
color, as VRView does; a revision whose editor sent them through the former
Objective-C++ bridge gets a double of the bridge), BrowserController (no
database, so nothing is saved) and a private pasteboard in place of the
general one. Exceptions are caught in
Objective-C. `<git revision>` as an optional argument reads the source from
that revision: that is the negative control.
"""
from pathlib import Path
import copy
import datetime
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as E

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

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
BRIDGE_IMPORT
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

/// What the VRView double hands the harness: the CLUT it was sent, and the
/// window level it keeps.
void HarnessReceiveCLUT(NSDictionary * _Nullable clut);
void HarnessGetWL(float * _Nonnull wl, float * _Nonnull ww);
void HarnessSetWL(float wl, float ww);

/// The exception the block raised, nil if none.
NSException * _Nullable HarnessTry(NS_NOESCAPE void (^ _Nonnull block)(void));
void HarnessUsePrivatePasteboard(void);
void HarnessReleasePrivatePasteboard(void);
/// The database's CLUT folder; nil, the default, for no browser at all.
void HarnessSetCLUTsPath(NSString * _Nullable path);
'''

doubles = r'''
#import "Bridge.h"
#import <objc/runtime.h>

NSString* const OsirixUpdateVolumeDataNotification = @"OsirixUpdateVolumeDataNotification";
NSString* const OsirixUpdateCLUTMenuNotification = @"OsirixUpdateCLUTMenuNotification";

static NSString *clutsPath;
static BrowserController *browser;

@implementation DicomDatabase
- (NSString *)clutsDirPath { return clutsPath; }
@end

@implementation BrowserController
+ (BrowserController *)currentBrowser { return browser; }
@end

void HarnessSetCLUTsPath(NSString *path)
{
    clutsPath = [path copy];
    if (path && !browser) {
        browser = [BrowserController new];
        browser.database = [DicomDatabase new];
    } else if (!path) {
        browser = nil;
    }
}

static NSInteger clutCount, rejectedCLUTs;
static NSDictionary *lastCLUT;
static float savedWL, savedWW;

@implementation HarnessVR
+ (NSInteger)clutCount { return clutCount; }
+ (NSDictionary *)lastCLUT { return lastCLUT; }
+ (NSInteger)rejectedCLUTs { return rejectedCLUTs; }
@end

void HarnessReceiveCLUT(NSDictionary *clut)
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
void HarnessGetWL(float *wl, float *ww) { *wl = savedWL; *ww = savedWW; }
void HarnessSetWL(float wl, float ww) { savedWL = wl; savedWW = ww; }
BRIDGE_DOUBLE

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

# A revision whose editor sent its messages to the VRView through the former
# Objective-C++ bridge gets a double of the bridge; the current one, doubles
# of the VRView and its controller.
BRIDGE_DOUBLE = r'''
@implementation CLUTOpacityViewVRBridge
+ (void)setAdvancedCLUT:(NSMutableDictionary *)clut lowResolution:(BOOL)lowRes ofVRView:(NSView *)vrView { HarnessReceiveCLUT(clut); }
+ (void)getWL:(float *)wl ww:(float *)ww ofVRView:(NSView *)vrView { HarnessGetWL(wl, ww); }
+ (void)setWL:(float)wl ww:(float)ww ofVRView:(NSView *)vrView { HarnessSetWL(wl, ww); }
+ (void)squareVRView:(NSView *)vrView sender:(id)sender {}
+ (void)setCurCLUTMenu:(NSString *)name ofVRView:(NSView *)vrView {}
+ (void)closeCLUTOpacityDrawerOfVRView:(NSView *)vrView {}
@end
'''

VR_DOUBLES = r'''
import AppKit

final class VRController: NSObject {
    /// How many times the editor named the CLUT in the menu.
    static var named = 0
    static let shared = VRController()
    func clutOpacityDrawer() -> HorosCLUTPanel? { nil }
    func setCurCLUTMenu(_ name: String!) { VRController.named += 1 }
}

final class VRView: NSView {
    func controller() -> VRController? { VRController.shared }
    func setAdvancedCLUT(_ clut: NSMutableDictionary!, lowResolution: Bool) { HarnessReceiveCLUT(clut as? [AnyHashable: Any]) }
    func getWLWW(_ wl: UnsafeMutablePointer<Float>!, _ ww: UnsafeMutablePointer<Float>!) { HarnessGetWL(wl, ww) }
    func setWLWW(_ wl: Float, _ ww: Float) { HarnessSetWL(wl, ww) }
    func squareView(_ sender: Any!) {}
}

/// The editors' VRView: the outlet is weak.
let harnessVRView = VRView(frame: .zero)

// The graphs the editor reaches the browser's database through: the graph of
// the VR window's viewer, and the process's for the class methods. Both hand
// out the double browser's database, which exists only with a CLUT folder.
final class BrowserWindowGraph {
    var database: DicomDatabase? { BrowserController.currentBrowser()?.database }
}

final class OSIWindowController {
    static func browserWindowGraph(serving object: Any?) -> BrowserWindowGraph? {
        BrowserController.currentBrowser() == nil ? nil : BrowserWindowGraph()
    }
}

struct BrowserDatabaseSource {
    static let process = BrowserDatabaseSource()
    var browserDatabase: DicomDatabase? { BrowserController.currentBrowser()?.database }
}
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
    HARNESS_VR_VIEW
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

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "removal" {
    // 8. and 9. In a process of its own: once an application has run, the
    // undo manager leaves its grouping by pass of the run loop to it. Here
    // each event comes in a pass of its own, which the timer keeps turning.
    _ = NSApplication.shared
    let runLoopKeeper = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
    func pass() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }

    func click(_ view: CLUTOpacityView, at position: NSPoint, count: Int = 1) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            pass()
        }
    }

    /// "+" and «−» of a 200-point-high editor: the second and third 15-point
    /// buttons of the side bar from the top, 5 points from its left edge.
    let plusButton = NSPoint(x: 12.5, y: 162.5), minusButton = NSPoint(x: 12.5, y: 142.5)

    func curvePoints(_ view: CLUTOpacityView) -> [[[Float]]] {
        (view.convertCurvesForPlist() as! [[[String: NSNumber]]]).map { $0.map { [$0["x"]!.floatValue, $0["y"]!.floatValue] } }
    }

    /// The curves the volume received last, at the precision of the editor's.
    func volumePoints() -> [[[Float]]] {
        ((HarnessVR.lastCLUT()?["curves"] as? [[NSValue]]) ?? []).map { $0.map { [Float($0.pointValue.x), Float($0.pointValue.y)] } }
    }

    func sameInVolume(_ view: CLUTOpacityView, _ when: String) {
        let shown = curvePoints(view), received = volumePoints()
        if shown != received {
            fail("\(when), the editor shows \(shown.count) curves (\(shown.map { $0.count }) points, from \(shown.map { $0.first?.first ?? 0 })) "
                 + "and the volume received \(received.count) (\(received.map { $0.count }), from \(received.map { $0.first?.first ?? 0 }))")
        }
    }

    /// An editor laid out as drawn, with three curves added by clicks on "+".
    func threeCurves() -> CLUTOpacityView {
        let view = editor()
        _ = render(view)
        for _ in 0..<3 { click(view, at: plusButton) }
        if curvePoints(view).count != 3 { fail("three clicks on + made \(curvePoints(view).count) curves") }
        return view
    }

    func undoOrRedo(_ view: CLUTOpacityView, _ step: String) -> String? {
        let r = raised(step) { step == "undo" ? view.undo(nil) : view.redo(nil) }
        pass()
        return r
    }

    // 8. Quick clicks on «−»: clickCount 1, 2 and 3, one curve each.
    do {
        let view = threeCurves()
        view.selectCurve(at: 1)
        pass()
        for (count, left, selected) in [(1, 2, 1), (2, 1, 0), (3, 0, -1)] {
            click(view, at: minusButton, count: count)
            if curvePoints(view).count != left { fail("the «−» click with clickCount \(count) leaves \(curvePoints(view).count) curves, not \(left)") }
            if view.selectedCurveIndex() != Int32(selected) {
                fail("after the «−» click with clickCount \(count) the selected curve is \(view.selectedCurveIndex()), not \(selected)")
            }
            sameInVolume(view, "after the «−» click with clickCount \(count)")
        }
        for (step, left) in [("undo", 1), ("undo", 2), ("redo", 1)] {
            if let r = undoOrRedo(view, step) { fail("after the «−» clicks, \(r)") }
            if curvePoints(view).count != left { fail("\(step) after the «−» clicks leaves \(curvePoints(view).count) curves, not \(left)") }
            sameInVolume(view, "after \(step) of a «−» click")
        }
    }

    // 8. «−» with a point selected removes its curve; the Delete key, only a point.
    do {
        let view = threeCurves()
        func position(_ curve: Int, _ point: Int) -> NSPoint {
            let p = (view.convertCurvesForPlist() as! [[[String: NSNumber]]])[curve][point]
            return view.transform().transform(NSPoint(x: p["x"]!.doubleValue, y: p["y"]!.doubleValue))
        }
        click(view, at: position(0, 2))
        if view.selectedCurveIndex() != -1 { fail("a click on a point selected the curve \(view.selectedCurveIndex())") }
        let removed = firstX(view, 0)
        click(view, at: minusButton)
        let firsts = (0..<curvePoints(view).count).map { firstX(view, $0) }
        if firsts.count != 2 || firsts.contains(removed) {
            fail("the «−» click with a point selected leaves the curves from \(firsts) with \(curvePoints(view).map { $0.count }) points, not the two others whole")
        }
        if view.selectedCurveIndex() != 0 { fail("after the «−» click with a point selected the selected curve is \(view.selectedCurveIndex()), not 0") }
        sameInVolume(view, "after the «−» click with a point selected")

        // The second point of the curve from 12, 40 HU from the next curve's.
        click(view, at: position(1, 1))
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                      context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!
        view.keyDown(with: delete)
        pass()
        let counts = Dictionary(uniqueKeysWithValues: (0..<curvePoints(view).count).map { (firstX(view, $0), curvePoints(view)[$0].count) })
        if counts != [12: 3, 52: 4] { fail("the Delete key on the second point of the curve from 12 leaves points \(counts), not [12: 3, 52: 4]") }
        sameInVolume(view, "after the Delete key on a point")
    }

    // 8. A click on a curve's square selects that curve; «−» then removes it.
    do {
        let view = threeCurves()
        // The oldest first: its square lies within the click box of the newest curve's second point.
        for first in [12.0, 52.0, 92.0] {
            guard let index = (0..<3).first(where: { firstX(view, $0) == first }) else { continue }
            click(view, at: view.controlPointForCurve(at: Int32(index)))
            if view.selectedCurveIndex() != 0 || firstX(view, 0) != first {
                fail("a click on the square of the curve from \(first) selected the curve \(view.selectedCurveIndex()), the one from \(firstX(view, 0)) in front")
            }
        }
        if let index = (0..<3).first(where: { firstX(view, $0) == 52 }) {
            click(view, at: view.controlPointForCurve(at: Int32(index)))
            click(view, at: minusButton)
            let firsts = (0..<curvePoints(view).count).map { firstX(view, $0) }
            if firsts.sorted() != [12, 92] { fail("«−» after a click on the square of the curve from 52 leaves the curves from \(firsts)") }
            sameInVolume(view, "after «−» on a curve selected by its square")
        }
    }

    /// An editor laid out as drawn with curves of four points 1,600 HU apart,
    /// the first from 0 to 1,200 HU, flat at 0.6 from 400 to 800: their
    /// squares and lines lie far from any other point.
    func separateCurves(_ count: Int) -> CLUTOpacityView {
        let view = editor()
        _ = render(view)
        let curves = (0..<count).map { k in [0.0, 400, 800, 1200].enumerated().map { NSValue(point: NSPoint(x: $1 + 1600.0 * Double(k), y: $0 == 0 || $0 == 3 ? 0 : 0.6)) } }
        view.setCurves(NSMutableArray(array: curves.map { NSMutableArray(array: $0) }))
        view.setPointColors(NSMutableArray(array: curves.map { c in NSMutableArray(array: c.map { _ in NSColor.white.usingColorSpace(.genericRGB)! }) }))
        view.setCLUTtoVRView(false)
        pass()
        return view
    }

    let deleteKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                     context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!

    // 8. A click on a line adds a point and selects it, not its curve: the
    // Delete key removes that point.
    do {
        let view = separateCurves(1)
        click(view, at: view.transform().transform(NSPoint(x: 600, y: 0.6)))
        if curvePoints(view).map(\.count) != [5] { fail("a click on a line between two points leaves points \(curvePoints(view).map(\.count)), not [5]") }
        if view.selectedCurveIndex() != -1 { fail("a click on a line selected the curve \(view.selectedCurveIndex()), not only the point it added") }
        view.keyDown(with: deleteKey)
        pass()
        if curvePoints(view).map(\.count) != [4] { fail("the Delete key on the point a click on a line added leaves points \(curvePoints(view).map(\.count)), not [4]") }
        sameInVolume(view, "after the Delete key on the point a click on a line added")
    }

    // 8. A click on nothing unselects the curve too: «−» then removes nothing.
    do {
        let view = separateCurves(1)
        click(view, at: view.controlPointForCurve(at: 0))
        click(view, at: view.transform().transform(NSPoint(x: 2500, y: 0.9)))
        if view.selectedCurveIndex() != -1 { fail("a click on nothing left the curve \(view.selectedCurveIndex()) selected") }
        click(view, at: minusButton)
        if curvePoints(view).count != 1 { fail("«−» after a click on nothing removed the curve the click unselected") }
        sameInVolume(view, "after «−» with nothing selected")
    }

    // 8. A curve's square dragged: undo and redo wait for the mouse up. The
    // drag undone, the curve is still drawn selected, as «−» sees it.
    do {
        let view = separateCurves(1)
        let before = curvePoints(view), square = view.controlPointForCurve(at: 0)
        func mouse(_ type: NSEvent.EventType) -> String? {
            let event = NSEvent.mouseEvent(with: type, location: square, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            defer { pass() }
            return raised("the mouse \(type == .leftMouseDown ? "down" : "up")") { type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event) }
        }
        var problems = [mouse(.leftMouseDown)]
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: .zero, mouseButton: .left)!
        drag.setIntegerValueField(.mouseEventDeltaX, value: 30)
        view.mouseDragged(with: NSEvent(cgEvent: drag)!)
        pass()
        let dragged = curvePoints(view)
        if dragged == before { fail("a drag of a curve's square did not move the curve") }
        problems += [undoOrRedo(view, "undo"), undoOrRedo(view, "redo")]
        if curvePoints(view) != dragged { fail("undo and redo in a drag of a curve's square left the curve at \(curvePoints(view)), not at \(dragged)") }
        problems.append(mouse(.leftMouseUp))
        for problem in problems.compactMap({ $0 }) { fail("in a drag of a curve's square, \(problem)") }
        for (step, expected) in [("undo", before), ("redo", dragged), ("undo", before)] {
            if let r = undoOrRedo(view, step) { fail("after a drag of a curve's square, \(r)") }
            if curvePoints(view) != expected { fail("\(step) after a drag of a curve's square leaves the curve at \(curvePoints(view)), not at \(expected)") }
            sameInVolume(view, "after \(step) of a drag of a curve's square")
        }
        if view.selectedCurveIndex() != 0 {
            fail("the undo of a drag of a curve's square left the curve \(view.selectedCurveIndex()) selected, not 0")
        } else {
            func pixels(_ rep: NSBitmapImageRep) -> Data { Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh) }
            let drawn = pixels(render(view))
            view.selectCurve(at: 0)
            if drawn != pixels(render(view)) { fail("after the undo of a drag of its square, the selected curve, the one «−» removes, is drawn unselected") }
        }
    }

    // 8. A drag whose mouse up comes after another kind of CLUT was chosen:
    // the mouse up sends nothing, so the volume keeps the CLUT chosen.
    do {
        let view = separateCurves(1)
        let square = view.controlPointForCurve(at: 0)
        func mouse(_ type: NSEvent.EventType) {
            let event = NSEvent.mouseEvent(with: type, location: square, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if let r = raised("the mouse \(type == .leftMouseDown ? "down" : "up")", { type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event) }) {
                fail("in a drag ended after another kind of CLUT was chosen, \(r)")
            }
            pass()
        }
        mouse(.leftMouseDown)
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: .zero, mouseButton: .left)!
        drag.setIntegerValueField(.mouseEventDeltaX, value: 30)
        view.mouseDragged(with: NSEvent(cgEvent: drag)!)
        pass()
        view.cleanup()
        let sent = HarnessVR.clutCount()
        mouse(.leftMouseUp)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        if HarnessVR.clutCount() != sent { fail("the mouse up of a drag ended after another kind of CLUT was chosen sent the empty editor's CLUT to the volume") }
    }

    // 8. A double-click on the square of the curve behind: the undo of the
    // double-click puts it back behind, in the editor and in the volume.
    do {
        let view = separateCurves(2)
        click(view, at: view.controlPointForCurve(at: 1), count: 2)
        NSColorPanel.shared.orderOut(nil)
        sameInVolume(view, "after a double-click on the square of the curve behind")
    }

    // 10. «Send to back» and the colour panel act on the curve drawn selected
    // after an undo, a windowing in the VR or a zoom of the editor moved its
    // square from where the click on it was.
    for change in ["the undo of a drag", "a windowing in the VR", "a zoom of the editor"] {
        let view = separateCurves(2), square = view.controlPointForCurve(at: 0)
        func mouse(_ type: NSEvent.EventType) {
            let event = NSEvent.mouseEvent(with: type, location: square, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            pass()
        }
        mouse(.leftMouseDown)
        if change == "the undo of a drag" {
            let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: .zero, mouseButton: .left)!
            drag.setIntegerValueField(.mouseEventDeltaX, value: 30)
            view.mouseDragged(with: NSEvent(cgEvent: drag)!)
            pass()
        }
        mouse(.leftMouseUp)
        switch change {
        case "the undo of a drag": if let r = undoOrRedo(view, "undo") { fail("after a drag of a curve's square, \(r)") }
        case "a windowing in the VR": view.setWL(700, ww: 1200)  // the curve from 0 to 1,200 HU, 100 HU up
        default: view.setZoomFator(NSNumber(value: 2))
        }
        pass()
        let selected = curvePoints(view)[0], other = curvePoints(view)[1]
        if view.selectedCurveIndex() != 0 { fail("after \(change) the curve selected by a click on its square is \(view.selectedCurveIndex()), not 0") }
        NSColorPanel.shared.color = NSColor(colorSpace: .genericRGB, components: [1, 0, 0, 1], count: 4)
        view.openColourPanel(); view.changePointColor(Notification(name: NSColorPanel.colorDidChangeNotification, object: NSColorPanel.shared))
        pass()
        let reds = (view.convertPointColorsForPlist() as! [[[String: NSNumber]]]).map { $0.map { $0["red"]!.doubleValue > 0.99 && $0["green"]!.doubleValue < 0.01 } }
        if reds != [[true, true, true, true], [false, false, false, false]] { fail("after \(change), the colour panel coloured the points \(reds), not the selected curve's") }
        view.sendToBack(nil)
        pass()
        if curvePoints(view) != [other, selected] || view.selectedCurveIndex() != 1 {
            fail("after \(change), Send to back left the curves from \(curvePoints(view).map { $0[0][0] }), not \([other[0][0], selected[0][0]]), with \(view.selectedCurveIndex()) selected")
        }
    }

    // 10. A click on a point while a curve is selected colours nothing: the
    // click gives the colour panel the point's colour, and the panel's
    // notification comes while the curve clicked before is still selected.
    for (target, label) in [(0, "the selected curve"), (1, "the other curve")] {
        let view = separateCurves(2)
        let shades = [NSColor.black, .red, .yellow, .white].map { $0.usingColorSpace(.genericRGB)! }
        view.setPointColors(NSMutableArray(array: (0..<2).map { _ in NSMutableArray(array: shades) }))
        NSColorPanel.shared.color = NSColor(colorSpace: .genericRGB, components: [0, 0, 1, 1], count: 4)
        pass()
        /// Each curve's colours, by its first point: a click sends the curve clicked to the front.
        func colours() -> [Float: [[String: NSNumber]]] {
            Dictionary(uniqueKeysWithValues: zip(curvePoints(view).map { $0[0][0] }, view.convertPointColorsForPlist() as! [[[String: NSNumber]]]))
        }
        let before = colours()
        click(view, at: view.controlPointForCurve(at: 0))
        let p = curvePoints(view)[target][1]  // red, between black and yellow
        click(view, at: view.transform().transform(NSPoint(x: Double(p[0]), y: Double(p[1]))))
        if view.selectedCurveIndex() != -1 { fail("a click on a point of \(label) left the curve \(view.selectedCurveIndex()) selected") }
        if colours() != before { fail("a click on a point of \(label), with a curve selected, changed the colours from \(before) to \(colours())") }
        sameInVolume(view, "after a click on a point of \(label), with a curve selected")
    }

    // 11. An open end: Dark Bone's bone curve, as the bundled preset ends it,
    // goes on to 3071 HU at its last height. Windowing, its square, the
    // scaling by its ends and a drag of its last point act on it as on the
    // curve without that end, which stays at 3071 HU at the height of the
    // point before it.
    do {
        let bone = [NSPoint(x: 46.7, y: 0), NSPoint(x: 135, y: 0.26), NSPoint(x: 244.7, y: 0.53)]
        let skin = [NSPoint(x: -812, y: 0), NSPoint(x: -622, y: 0.164), NSPoint(x: -420, y: 0.365), NSPoint(x: -262.8, y: 0)]
        /// The bone curve in front, as the preset has it, with its end or without, selected as a 3D preset selects its first curve.
        func boneEditor(_ end: NSPoint?) -> CLUTOpacityView {
            let view = editor()
            _ = render(view)
            let curves = [bone + (end.map { [$0] } ?? []), skin]
            view.setCurves(NSMutableArray(array: curves.map { NSMutableArray(array: $0.map { NSValue(point: $0) }) }))
            view.setPointColors(NSMutableArray(array: curves.map { c in NSMutableArray(array: c.map { _ in NSColor.white.usingColorSpace(.genericRGB)! }) }))
            view.selectCurve(at: 0)
            pass()
            return view
        }
        /// The window level and width the editor gives the volume.
        func window(_ view: CLUTOpacityView) -> [Float] {
            view.setCLUTtoVRView(false)
            var wl: Float = 0, ww: Float = 0
            HarnessGetWL(&wl, &ww)
            return [wl, ww]
        }
        func mouse(_ view: CLUTOpacityView, _ type: NSEvent.EventType, at position: NSPoint) {
            let event = NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: view.mouseDragged(with: event)
            }
            pass()
        }
        /// A drag by deltas, as the square and the scaling by an end read it.
        func shift(_ view: CLUTOpacityView, _ dx: Int64, _ dy: Int64, option: Bool) {
            let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: .zero, mouseButton: .left)!
            drag.setIntegerValueField(.mouseEventDeltaX, value: dx)
            drag.setIntegerValueField(.mouseEventDeltaY, value: dy)
            drag.flags = option ? .maskAlternate : []
            view.mouseDragged(with: NSEvent(cgEvent: drag)!)
            pass()
        }
        func position(_ view: CLUTOpacityView, _ p: NSPoint) -> NSPoint { view.transform().transform(p) }
        let steps: [(String, (CLUTOpacityView) -> Void)] = [
            ("the 3D preset applied", { _ in }),
            ("a windowing in the VR, 100 HU up", { $0.setWL(245.7, ww: 198) }),
            ("a windowing in the VR, 48 HU narrower", { $0.setWL(145.7, ww: 150) }),
            ("a windowing in the VR, 300 HU wider", { $0.setWL(145.7, ww: 498) }),
            ("a drag of the curve's square", { v in
                let square = v.controlPointForCurve(at: 0)
                mouse(v, .leftMouseDown, at: square); shift(v, 30, 10, option: false); mouse(v, .leftMouseUp, at: square) }),
            ("an Option-drag of the curve's square", { v in
                let square = v.controlPointForCurve(at: 0)
                mouse(v, .leftMouseDown, at: square); shift(v, 20, 0, option: true); mouse(v, .leftMouseUp, at: square) }),
            ("an Option-drag of the last point", { v in
                let last = position(v, bone[2])
                mouse(v, .leftMouseDown, at: last); shift(v, 20, 0, option: true); mouse(v, .leftMouseUp, at: last) }),
            ("a drag of the last point", { v in
                let last = position(v, bone[2]), target = position(v, NSPoint(x: 400, y: 0.7))
                mouse(v, .leftMouseDown, at: last); mouse(v, .leftMouseDragged, at: target); mouse(v, .leftMouseUp, at: target) }),
        ]
        let preset = curvePoints(boneEditor(NSPoint(x: 3071, y: 0.53)))[0]
        for (step, act) in steps {
            let open = boneEditor(NSPoint(x: 3071, y: 0.53)), closed = boneEditor(nil)
            act(open)
            let openWindow = window(open)
            sameInVolume(open, "after \(step) on the curve with an open end")
            act(closed)
            let closedWindow = window(closed)
            let o = curvePoints(open), c = curvePoints(closed)
            if o.count != 2 || c.count != 2 || o[0].count != 4 || c[0].count != 3 {
                fail("after \(step), the curves have \(o.map(\.count)) and \(c.map(\.count)) points, not [4, 4] and [3, 4]")
                continue
            }
            if Array(o[0].prefix(3)) != c[0] || o[1] != c[1] {
                fail("after \(step), the curve with an open end is at \(o), not as the curve without it, at \(c)")
            }
            if o[0][3] != [3071, o[0][2][1]] { fail("after \(step), the open end is at \(o[0][3]), not at 3071 at the height of the point before it, \(o[0][2][1])") }
            if openWindow != closedWindow { fail("after \(step), the curve with an open end gives the volume the window \(openWindow), not \(closedWindow)") }
            if open.controlPointForCurve(at: 0) != closed.controlPointForCurve(at: 0) {
                fail("after \(step), the square of the curve with an open end is at \(open.controlPointForCurve(at: 0)), not at \(closed.controlPointForCurve(at: 0))")
            }
            if step == "a drag of the last point" {
                if let r = undoOrRedo(open, "undo") { fail("after \(step), \(r)") }
                if curvePoints(open)[0] != preset { fail("the undo of \(step) leaves the curve with an open end at \(curvePoints(open)[0]), not at \(preset)") }
            }
        }
        // A last point at 3071 HU at another height, and a flat end below it, are ordinary points: the window spans them.
        for end in [NSPoint(x: 3071, y: 0.3), NSPoint(x: 300, y: 0.53)] {
            let found = window(boneEditor(end)), first = Double(bone[0].x), last = Double(end.x)
            let expected = [Float((last + first) / 2.0), Float(last - first)]
            if found != expected { fail("the curve ending at \(end) gives the volume the window \(found), not \(expected)") }
        }

        // 12. The colour the panel gives the point before an open end reaches
        // the end too while the end has that point's colour, as the point's
        // height does: in the editor, in the volume and in the CLUT saved and
        // read back. Undo and redo act on both. A colour of the end's own stays,
        // and so does the colour of a last point at 3071 HU at another height.
        // The colour panel is shared: its colour reaches every editor with a
        // point or a curve selected. The editors above go first, and each one
        // here is unselected before the next one takes a colour.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("horos-open-end-\(UUID().uuidString)").path
            try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            HarnessSetCLUTsPath(folder)
            defer {
                HarnessSetCLUTsPath(nil)
                try? FileManager.default.removeItem(atPath: folder)
            }
            let white: [Float] = [1, 1, 1], red: [Float] = [1, 0, 0], green: [Float] = [0, 1, 0], blue: [Float] = [0, 0, 1]
            func panelColour(_ rgb: [Float]) -> NSColor { NSColor(colorSpace: .genericRGB, components: rgb.map { CGFloat($0) } + [1], count: 4) }
            /// The bone curve's colours, as the editor holds and saves them.
            func colours(_ view: CLUTOpacityView) -> [[Float]] {
                (view.convertPointColorsForPlist() as! [[[String: NSNumber]]])[0].map { [$0["red"]!.floatValue, $0["green"]!.floatValue, $0["blue"]!.floatValue] }
            }
            /// The bone curve's colours as the volume received them last.
            func received() -> [[Float]] {
                ((HarnessVR.lastCLUT()?["colors"] as? [[NSColor]]) ?? [[]])[0].map { c in
                    let c = c.usingColorSpace(.genericRGB)!
                    return [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
                }
            }
            /// A click on the point before the end, at 244.7 HU, and a colour chosen in the panel.
            func colourPointBefore(_ view: CLUTOpacityView, _ rgb: [Float]) {
                let p = position(view, bone[2])
                mouse(view, .leftMouseDown, at: p)
                mouse(view, .leftMouseUp, at: p)
                NSColorPanel.shared.color = panelColour(rgb)
                view.openColourPanel(); view.changePointColor(Notification(name: NSColorPanel.colorDidChangeNotification, object: NSColorPanel.shared))
                pass()
            }
            func expect(_ view: CLUTOpacityView, _ expected: [[Float]], _ when: String) {
                if colours(view) != expected { fail("\(when), the bone curve's colours are \(colours(view)), not \(expected)") }
            }
            let view = boneEditor(NSPoint(x: 3071, y: 0.53))
            colourPointBefore(view, red)
            expect(view, [white, white, red, red], "after the colour panel on the point before an open end")
            if received() != colours(view) { fail("after the colour panel on the point before an open end, the volume received the colours \(received()), not \(colours(view))") }
            view.saveWithName("Open end")
            for (step, expected) in [("undo", [white, white, white, white]), ("redo", [white, white, red, red])] {
                if let r = undoOrRedo(view, step) { fail("after the colour panel on the point before an open end, \(r)") }
                expect(view, expected, "after \(step) of the colour panel on the point before an open end")
            }
            view.setColor(panelColour(blue), forPointAt: 3, inCurveAt: 0)
            pass()
            colourPointBefore(view, green)
            expect(view, [white, white, green, blue], "after the colour panel on the point before an open end of a colour of its own")
            view.unselectPoints()

            let reopened = editor()
            _ = render(reopened)
            reopened.loadFromFile(withName: "Open end")
            expect(reopened, [white, white, red, red], "in the CLUT saved after the colour panel on the point before an open end")
            colourPointBefore(reopened, blue)
            expect(reopened, [white, white, blue, blue], "after the colour panel on the point before the open end of the CLUT read back")
            reopened.unselectPoints()

            let ordinary = boneEditor(NSPoint(x: 3071, y: 0.3))
            colourPointBefore(ordinary, red)
            expect(ordinary, [white, white, red, white], "after the colour panel on the point before a last point at 3071 HU at another height")
            ordinary.unselectPoints()
        }

        // 13. A point added by a click near the line before an open end lies
        // on that flat line, and the end stays open. The Delete key on the
        // point before an open end that stays open gives the end the colour
        // of the point now before it, when the end had the removed point's;
        // undo and redo act on both. On a range above 3071 HU the editor
        // draws an open end's height on to the top of its range, short of a
        // curve above it, as the volume holds it.
        do {
            let view = boneEditor(NSPoint(x: 3071, y: 0.53))
            var near = position(view, NSPoint(x: 1500, y: 0.53))
            near.y += 5
            mouse(view, .leftMouseDown, at: near)
            mouse(view, .leftMouseUp, at: near)
            let added = curvePoints(view)[0]
            if added.count != 5 || added[3][1] != added[2][1] || added[4] != [3071, added[2][1]] {
                fail("a click 5 points above the line before an open end leaves the curve at \(added), not with a point on the line and the end open")
            } else {
                let found = window(view), expected = added[3][0] - added[0][0]
                if abs(found[1] - expected) > 0.01 { fail("after a click on the line before an open end, the window is \(found), not \(expected) wide up to the point added") }
            }
            sameInVolume(view, "after a click on the line before an open end")
            view.unselectPoints()
        }
        func rgbColour(_ rgb: [CGFloat]) -> NSColor { NSColor(colorSpace: .genericRGB, components: rgb + [1], count: 4) }
        do {
            let white = rgbColour([1, 1, 1]), yellow = rgbColour([1, 1, 0]), blue = rgbColour([0, 0, 1])
            /// The bone curve with a second point on its plateau, at 600 HU, and the end's colour.
            func plateauEditor(_ end: NSColor) -> CLUTOpacityView {
                let view = boneEditor(NSPoint(x: 3071, y: 0.53))
                view.setCurves(NSMutableArray(array: [NSMutableArray(array: (bone + [NSPoint(x: 600, y: 0.53), NSPoint(x: 3071, y: 0.53)]).map { NSValue(point: $0) }),
                                                      NSMutableArray(array: skin.map { NSValue(point: $0) })]))
                view.setPointColors(NSMutableArray(array: [NSMutableArray(array: [white, white, yellow, white, end]), NSMutableArray(array: skin.map { _ in white })]))
                view.selectCurve(at: 0)
                pass()
                return view
            }
            func ends(_ view: CLUTOpacityView) -> [[Float]] {
                (view.convertPointColorsForPlist() as! [[[String: NSNumber]]])[0].suffix(2).map { [$0["red"]!.floatValue, $0["green"]!.floatValue, $0["blue"]!.floatValue] }
            }
            func delete(_ view: CLUTOpacityView, at p: NSPoint) {
                let at = position(view, p)
                mouse(view, .leftMouseDown, at: at)
                mouse(view, .leftMouseUp, at: at)
                view.keyDown(with: deleteKey)
                pass()
            }
            let y: [Float] = [1, 1, 0], w: [Float] = [1, 1, 1], b: [Float] = [0, 0, 1]
            let view = plateauEditor(white)
            delete(view, at: NSPoint(x: 600, y: 0.53))
            if curvePoints(view)[0].count != 4 || ends(view) != [y, y] { fail("the Delete key on the point before an open end leaves \(curvePoints(view)[0].count) points coloured \(ends(view)) at the end, not 4 and [yellow, yellow]") }
            sameInVolume(view, "after the Delete key on the point before an open end")
            for (step, count, expected) in [("undo", 5, [w, w]), ("redo", 4, [y, y])] {
                if let r = undoOrRedo(view, step) { fail("after the Delete key on the point before an open end, \(r)") }
                if curvePoints(view)[0].count != count || ends(view) != expected {
                    fail("\(step) of the Delete key on the point before an open end leaves \(curvePoints(view)[0].count) points ending \(ends(view)), not \(count) and \(expected)")
                }
            }
            view.unselectPoints()
            let own = plateauEditor(blue)
            delete(own, at: NSPoint(x: 600, y: 0.53))
            if ends(own) != [y, b] { fail("the Delete key on the point before an open end of a colour of its own leaves the end \(ends(own)), not \([y, b])") }
            own.unselectPoints()
            // Without the point before it, Dark Bone's end at 3071 HU is an ordinary point: it keeps its colour.
            let closing = boneEditor(NSPoint(x: 3071, y: 0.53))
            closing.setPointColors(NSMutableArray(array: [NSMutableArray(array: [white, yellow, white, white]), NSMutableArray(array: skin.map { _ in white })]))
            delete(closing, at: bone[2])
            if curvePoints(closing)[0].count != 3 || ends(closing) != [y, w] {
                fail("the Delete key on the only point before an open end leaves \(curvePoints(closing)[0]) ending \(ends(closing)), not 3 points ending [yellow, white]")
            }
            closing.unselectPoints()
        }
        do {
            /// Whether the editor paints its curve area at a value and a height: not the black background.
            func painted(_ view: CLUTOpacityView, _ rep: NSBitmapImageRep, _ value: Double, _ height: Double) -> NSColor? {
                let scale = CGFloat(rep.pixelsWide) / view.bounds.width, p = position(view, NSPoint(x: value, y: height))
                guard let c = rep.colorAt(x: Int(p.x * scale), y: Int((view.bounds.height - p.y) * scale))?.usingColorSpace(.deviceRGB) else { return nil }
                return max(c.redComponent, c.greenComponent, c.blueComponent) > 8.0 / 255.0 ? c : nil
            }
            let red = rgbColour([1, 0, 0]), green = rgbColour([0, 1, 0])
            let band = [NSPoint(x: 12000, y: 0), NSPoint(x: 13000, y: 0.8), NSPoint(x: 15000, y: 0.8), NSPoint(x: 16000, y: 0)]
            for (end, others, expected) in [(NSPoint(x: 3071, y: 0.53), [] as [[NSPoint]], [(1000.0, true), (10000, true), (18000, true)]),
                                            (NSPoint(x: 3071, y: 0.53), [band], [(1000, true), (10000, true), (18000, false)]),
                                            (NSPoint(x: 3071, y: 0.3), [], [(1000, true), (10000, false), (18000, false)])] {
                let view = editor()
                view.setHUmin(-1000, HUmax: 20000)
                _ = render(view)
                let curves = [bone + [end]] + others
                view.setCurves(NSMutableArray(array: curves.map { NSMutableArray(array: $0.map { NSValue(point: $0) }) }))
                view.setPointColors(NSMutableArray(array: curves.enumerated().map { k, c in NSMutableArray(array: c.map { _ in k == 0 ? red : green }) }))
                let rep = render(view)
                for (value, filled) in expected {
                    let colour = painted(view, rep, value, 0.2)
                    if (colour != nil) != filled || (colour.map { $0.redComponent < 0.5 || $0.greenComponent > 0.35 } ?? false) {
                        fail("on a range to 20000 HU with \(others.count) curves above, the curve ending at \(end) paints \(value) HU \(colour.map { "\($0)" } ?? "not at all"), not \(filled ? "red" : "nothing")")
                    }
                }
            }
        }
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))  // the high-resolution sends left pending, before the cases that count sends

    // 10. The curves' order reaches the volume, where of two curves' points at
    // one value the front curve's is the volume's: Send to back, a curve
    // brought to the front by its index and a click on a line of the curve
    // behind (it adds a point and brings that curve to the front) send the
    // curves. A click on the square or on a point of the curve behind sends
    // them once, as before.
    do {
        let view = separateCurves(2)
        // Blue, a colour no point has: a click on a point gives the panel the
        // point's white, which changes nothing and sends nothing more.
        NSColorPanel.shared.color = NSColor(colorSpace: .genericRGB, components: [0, 0, 1, 1], count: 4)
        pass()
        /// How many times an action sends the curves to the volume.
        func sends(_ action: () -> Void) -> Int {
            let before = HarnessVR.clutCount()
            action()
            return HarnessVR.clutCount() - before
        }
        func position(_ curve: Int, _ point: Int) -> NSPoint {
            let p = curvePoints(view)[curve][point]
            return view.transform().transform(NSPoint(x: Double(p[0]), y: Double(p[1])))
        }
        let squareClick = sends { click(view, at: view.controlPointForCurve(at: 1)) }
        if squareClick != 1 { fail("a click on the square of the curve behind sent the curves \(squareClick) times, not once") }
        sameInVolume(view, "after a click on the square of the curve behind")
        view.sendToBack(nil)
        pass()
        sameInVolume(view, "after Send to back of the curve selected by its square")
        let pointClick = sends { click(view, at: position(1, 1)) }
        if pointClick != 1 { fail("a click on a point of the curve behind sent the curves \(pointClick) times, not once") }
        sameInVolume(view, "after a click on a point of the curve behind")
        view.sendToFrontCurve(at: 1)
        view.updateView()
        pass()
        sameInVolume(view, "after the curve behind was brought to the front by its index")
        let line = curvePoints(view)[1]  // flat at 0.6 between its second and third points
        click(view, at: view.transform().transform(NSPoint(x: Double(line[1][0] + line[2][0]) / 2, y: Double(line[1][1]))))
        if curvePoints(view).map(\.count) != [5, 4] { fail("a click on a line of the curve behind leaves points \(curvePoints(view).map(\.count)), not [5, 4]") }
        sameInVolume(view, "after a click on a line of the curve behind")
    }

    // 11. Send to back names the CLUT «16-bit CLUT» in the menu only when the
    // order gives the volume another CLUT: where a curve behind has a point
    // at a value of the curve sent back. A click on the square or on a point
    // of the front curve, which changes nothing, sends the curves once (the
    // mouse up sent them again).
    do {
        func counted(_ action: () -> Void) -> (sends: Int, names: Int) {
            let sends = HarnessVR.clutCount(), names = VRController.named
            action()
            return (HarnessVR.clutCount() - sends, VRController.named - names)
        }
        let apart = separateCurves(2)
        NSColorPanel.shared.color = NSColor(colorSpace: .genericRGB, components: [0, 0, 1, 1], count: 4)
        pass()
        let frontSquare = counted { click(apart, at: apart.controlPointForCurve(at: 0)) }
        if frontSquare.sends != 1 { fail("a click on the square of the front curve sent the curves \(frontSquare.sends) times, not once") }
        let frontPoint = counted {
            let p = curvePoints(apart)[0][1]
            click(apart, at: apart.transform().transform(NSPoint(x: Double(p[0]), y: Double(p[1]))))
        }
        if frontPoint.sends != 1 { fail("a click on a point of the front curve sent the curves \(frontPoint.sends) times, not once") }
        click(apart, at: apart.controlPointForCurve(at: 0))
        let unshared = counted { apart.sendToBack(nil); pass() }
        if unshared.names != 0 { fail("Send to back of a curve that shares no value with another named the CLUT in the menu \(unshared.names) times") }
        if apart.selectedCurveIndex() != 1 { fail("Send to back of a curve that shares no value left the selection on \(apart.selectedCurveIndex()), not 1") }
        sameInVolume(apart, "after Send to back of a curve that shares no value with another")

        // Two curves with a point at 800 HU each, of other heights.
        let sharing = editor()
        _ = render(sharing)
        let shapes: [[(Double, Double)]] = [[(0, 0), (400, 0.6), (800, 0.6), (1200, 0)], [(800, 0), (1000, 0.9), (1400, 0.9), (1800, 0)]]
        sharing.setCurves(NSMutableArray(array: shapes.map { c in NSMutableArray(array: c.map { NSValue(point: NSPoint(x: $0.0, y: $0.1)) }) }))
        sharing.setPointColors(NSMutableArray(array: shapes.map { c in NSMutableArray(array: c.map { _ in NSColor.white.usingColorSpace(.genericRGB)! }) }))
        sharing.setCLUTtoVRView(false)
        pass()
        sharing.selectCurve(at: 0)
        pass()
        let shared = counted { sharing.sendToBack(nil); pass() }
        if shared.names != 1 || shared.sends < 1 {
            fail("Send to back of a curve with a point at a value of the curve behind named the CLUT \(shared.names) times and sent it \(shared.sends) times")
        }
        sameInVolume(sharing, "after Send to back of a curve that shares a value with another")
    }

    // 12. The colour panel is the application's: it colours the curve of the
    // editor whose double click opened it, and no other editor's (a colour
    // well of any window, or a click in another 3D window's editor, coloured
    // the curve selected here), until the panel closes.
    do {
        func reds(_ view: CLUTOpacityView) -> [Bool] {
            (view.convertPointColorsForPlist() as! [[[String: NSNumber]]]).map { $0.allSatisfy { $0["red"]!.doubleValue > 0.99 && $0["green"]!.doubleValue < 0.01 } }
        }
        let red = Notification(name: NSColorPanel.colorDidChangeNotification, object: NSColorPanel.shared)
        let one = separateCurves(2), other = separateCurves(2)
        one.selectCurve(at: 0)
        other.selectCurve(at: 1)
        pass()
        // A double click on the first editor's square: the panel is its own.
        click(one, at: one.controlPointForCurve(at: 0), count: 2)
        NSColorPanel.shared.color = NSColor(colorSpace: .genericRGB, components: [1, 0, 0, 1], count: 4)
        one.changePointColor(red)
        other.changePointColor(red)
        pass()
        if reds(one) != [true, false] { fail("the colour panel a double click opened did not colour the curve of its editor: \(reds(one))") }
        if reds(other) != [false, false] { fail("the colour panel opened by one editor coloured the selected curve of another: \(reds(other))") }
        // The panel closed: a colour it tells of later is no editor's.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
        one.selectCurve(at: 1)
        NSColorPanel.shared.color = NSColor(colorSpace: .genericRGB, components: [1, 0, 0, 1], count: 4)
        one.changePointColor(red)
        pass()
        if reds(one) != [true, false] { fail("after the colour panel closed, a colour chosen elsewhere coloured the selected curve: \(reds(one))") }
        NSColorPanel.shared.orderOut(nil)
    }

    // 9. Remove All Curves, undone with its colours, redone, undone again.
    do {
        let view = threeCurves()
        view.setColor(NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.9, alpha: 1), forCurveAt: 1)
        pass()
        let before = (view.convertCurvesForPlist(), view.convertPointColorsForPlist())
        view.removeAllCurves(nil)
        pass()
        sameInVolume(view, "after Remove All Curves")
        for (step, empty) in [("undo", false), ("redo", true), ("undo", false)] {
            if let r = undoOrRedo(view, step) { fail("after Remove All Curves, \(r)") }
            let now = (view.convertCurvesForPlist(), view.convertPointColorsForPlist())
            if empty ? (now.0.count != 0 || now.1.count != 0) : (!now.0.isEqual(before.0) || !now.1.isEqual(before.1)) {
                fail("\(step) after Remove All Curves leaves \(now.0.count) curves and \(now.1.count) colour sets, not \(empty ? "none" : "the three as they were")")
            }
            sameInVolume(view, "after \(step) of Remove All Curves")
        }
    }

    // 9. A preset's or the saved state's CLUT, then another kind of CLUT: undo
    // and redo have nothing to act on, and the empty editor sends nothing.
    do {
        let view = threeCurves()
        let curve = NSMutableArray(array: [NSPoint(x: 100, y: 0), NSPoint(x: 300, y: 0.5), NSPoint(x: 500, y: 0.9)].map { NSValue(point: $0) })
        let colors = NSMutableArray(array: [NSColor.red, NSColor.green, NSColor.blue].map { $0.usingColorSpace(.genericRGB)! })
        view.setCurves(NSMutableArray(array: [curve]))
        view.setPointColors(NSMutableArray(array: [colors]))
        view.setCLUTtoVRView(false)
        pass()
        let loaded = curvePoints(view)
        for step in ["undo", "redo"] {
            if let r = undoOrRedo(view, step) { fail("after a preset's CLUT, \(r)") }
            if curvePoints(view) != loaded { fail("\(step) after a preset's CLUT leaves \(curvePoints(view).count) curves, not its one") }
            sameInVolume(view, "after \(step) following a preset's CLUT")
        }
        view.setWL(400, ww: 800)  // leaves a high-resolution send pending
        let sent = HarnessVR.clutCount()
        view.cleanup()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        if HarnessVR.clutCount() != sent { fail("switching to another kind of CLUT sent the empty editor's CLUT to the volume") }
        if let r = undoOrRedo(view, "undo") { fail("after switching to another kind of CLUT, \(r)") }
        if curvePoints(view).count != 0 { fail("undo after switching to another kind of CLUT brought \(curvePoints(view).count) curves back") }
    }

    // 9. A saved CLUT chosen in the menu over curves with an undo history.
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("horos-menu-cluts-\(UUID().uuidString)").path
        try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        HarnessSetCLUTsPath(folder)
        defer {
            HarnessSetCLUTsPath(nil)
            try? FileManager.default.removeItem(atPath: folder)
        }
        let saved = editor()
        saved.newCurve()
        saved.saveWithName("Chosen")
        let view = threeCurves()
        view.loadFromFile(withName: "Chosen")
        view.setCLUTtoVRView(false)
        pass()
        let loaded = curvePoints(view)
        if loaded != curvePoints(saved) { fail("the saved CLUT chosen in the menu reads back as \(loaded)") }
        for step in ["undo", "redo"] {
            if let r = undoOrRedo(view, step) { fail("after a CLUT chosen in the menu, \(r)") }
            if curvePoints(view) != loaded { fail("\(step) after a CLUT chosen in the menu leaves \(curvePoints(view).count) curves, not its one") }
            sameInVolume(view, "after \(step) following a CLUT chosen in the menu")
        }
    }
    _ = runLoopKeeper
    print("removal done")
    exit(0)
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

if CommandLine.arguments.count > 3 && CommandLine.arguments[1] == "plist" {
    // 7. One property list CLUT, in a process of its own: the former
    // converters crashed on an element of another type.
    let folder = CommandLine.arguments[2], name = CommandLine.arguments[3]
    HarnessSetCLUTsPath(folder)
    func number(_ value: CGFloat) -> Any { value.isFinite ? Double(value) : "\(value)" }
    var out: [String: Any] = [:]
    if let clut = CLUTOpacityView.presetFromFile(withName: name) {
        let curves = (clut["curves"] as? [[NSValue]]) ?? []
        let colors = (clut["colors"] as? [[NSColor]]) ?? []
        out["curves"] = curves.map { $0.map { [number($0.pointValue.x), number($0.pointValue.y)] } }
        out["colors"] = colors.map { $0.map { color -> [Any] in
            guard let c = color.usingColorSpace(.genericRGB) else { return [] }
            return [number(c.redComponent), number(c.greenComponent), number(c.blueComponent)]
        } }
    }
    // The editor keeps its CLUT when a file does not load.
    let view = editor()
    view.newCurve()
    let before = view.convertCurvesForPlist() as! NSArray
    view.loadFromFile(withName: name)
    out["editorChanged"] = !(view.convertCurvesForPlist() as! NSArray).isEqual(before)
    let file = NSDictionary(contentsOfFile: folder + "/" + name + ".plist")
    out["convertedCurves"] = CLUTOpacityView.convertCurvesFromPlist(file?["curves"] as? NSArray).count
    out["convertedColors"] = CLUTOpacityView.convertPointColorsFromPlist(file?["colors"] as? NSArray).count
    print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
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
    if view.selectedCurveIndex() != 0 {
        fail("after deleting the selected curve 1 of 2 the index is \(view.selectedCurveIndex()), not 0 (the curve left)")
    }
    if view.convertCurvesForPlist().count != 1 { fail("deleting the selected curve of 2 leaves \(view.convertCurvesForPlist().count)") }
    // The command again removes the curve left: the curves added go one after the other.
    if let r = raised("-delete: again", { view.delete(nil) }) { fail("deleting the curve left: \(r)") }
    if view.convertCurvesForPlist().count != 0 || view.selectedCurveIndex() != -1 {
        fail("a second Delete leaves \(view.convertCurvesForPlist().count) curves, selection \(view.selectedCurveIndex())")
    }
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
    if colors.contains(where: { $0.colorSpace != .genericRGB }) {
        fail("the curve's colors are not in generic RGB")
    }
    let reds = colors.map { Double($0.usingColorSpace(.genericRGB)?.redComponent ?? -1) }
    let darkGray = Double(NSColor(deviceWhite: 0.25, alpha: 1).usingColorSpace(.genericRGB)!.redComponent)
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

// 6. 16-bit CLUTs of earlier versions: NSArchiver files without an
// extension in the database's CLUT folder, read by the restricted reader.
var clutMarkerRuns = 0
/// Records that a CLUT file had it instantiated.
@objc(HorosCLUTMarker)
final class CLUTMarker: NSObject, NSCoding {
    override init() { super.init() }
    init?(coder: NSCoder) { clutMarkerRuns += 1; super.init() }
    func encode(with coder: NSCoder) {}
}

do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("horos-legacy-cluts-\(UUID().uuidString)").path
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    HarnessSetCLUTsPath(folder)
    defer {
        HarnessSetCLUTsPath(nil)
        try? FileManager.default.removeItem(atPath: folder)
    }

    func point(_ x: Double, _ y: Double) -> NSValue { NSValue(point: NSPoint(x: x, y: y)) }
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }
    func legacy(_ curves: [[Any]], _ colors: [[Any]]) -> NSMutableDictionary {
        let clut = NSMutableDictionary()
        clut["curves"] = NSMutableArray(array: curves.map { NSMutableArray(array: $0) })
        clut["colors"] = NSMutableArray(array: colors.map { NSMutableArray(array: $0) })
        return clut
    }
    var written: [String: Data] = [:]
    func write(_ name: String, _ data: Data) {
        try! data.write(to: URL(fileURLWithPath: folder + "/" + name))
        written[name] = data
    }
    func write(_ name: String, archiving object: Any) { write(name, NSArchiver.archivedData(withRootObject: object)) }

    let points: [[(Double, Double)]] = [[(-100, 0), (40, 0.35), (300, 0.8)], [(500, 0.1), (1200, 0.999)]]
    let colors: [[NSColor]] = [[rgb(1, 0, 0), rgb(0.25, 0.5, 0.75), rgb(1, 1, 0)],
                               [rgb(0, 0, 1), NSColor(calibratedWhite: 0.5, alpha: 1)]]
    let valid = legacy(points.map { $0.map { point($0.0, $0.1) } }, colors)
    write("Legacy", archiving: valid)
    // As a 32-bit version archived its points.
    let floatPoints = points.map { curve in curve.map { p -> NSValue in
        var xy = (Float(p.0), Float(p.1))
        return NSValue(bytes: &xy, objCType: "{_NSPoint=ff}")
    } }
    write("Legacy32", archiving: legacy(floatPoints, colors))

    func components(_ color: NSColor) -> [Double] {
        guard let c = color.usingColorSpace(.genericRGB) else { return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) }
    }
    func sameCLUT(_ clut: NSDictionary?, _ label: String) {
        guard let curves = clut?["curves"] as? [[NSValue]], let pointColors = clut?["colors"] as? [[NSColor]] else {
            fail("\(label): not read (\(String(describing: clut)))")
            return
        }
        let read: [[NSPoint]] = curves.map { $0.map { $0.pointValue } }
        var close = read.count == points.count
        for (curve, expected) in zip(read, points) {
            close = close && curve.count == expected.count
            for (p, e) in zip(curve, expected) {
                let dx = abs(Double(p.x) - Double(Float(e.0))), dy = abs(Double(p.y) - Double(Float(e.1)))
                close = close && dx < 1e-4 && dy < 1e-6
            }
        }
        if !close { fail("\(label): the points read back as \(read)") }
        let readColors = pointColors.map { $0.map(components) }
        let expectedColors = colors.map { $0.map(components) }
        let sameColors = readColors.count == expectedColors.count && zip(readColors, expectedColors).allSatisfy { a, b in
            a.count == b.count && zip(a, b).allSatisfy { x, y in x.count == 3 && zip(x, y).allSatisfy { abs($0 - $1) < 1e-6 } }
        }
        if !sameColors { fail("\(label): the colours read back as \(readColors), not \(expectedColors)") }
    }

    sameCLUT(CLUTOpacityView.presetFromFile(withName: "Legacy"), "a legacy CLUT")
    sameCLUT(CLUTOpacityView.presetFromFile(withName: "Legacy32"), "a legacy CLUT with 32-bit points")

    // Loaded in the editor and sent to the VRView, as the CLUT menu does.
    let view = editor()
    view.loadFromFile(withName: "Legacy")
    let rejected = HarnessVR.rejectedCLUTs()
    view.setCLUTtoVRView(false)
    sameCLUT(HarnessVR.lastCLUT() as NSDictionary?, "a legacy CLUT loaded in the editor and sent to the VRView")
    if HarnessVR.rejectedCLUTs() != rejected { fail("the VRView's -redComponent raised on a legacy CLUT's colours") }
    let loaded = view.convertCurvesForPlist() as! NSArray
    let loadedColors = view.convertPointColorsForPlist() as! NSArray

    // Refused files: nothing decoded, the marker never instantiated, the
    // editor's CLUT kept, the file left as it was.
    func refuse(_ name: String, _ label: String) {
        clutMarkerRuns = 0
        if let clut = CLUTOpacityView.presetFromFile(withName: name) { fail("\(label): read as \(clut)") }
        view.loadFromFile(withName: name)
        if clutMarkerRuns != 0 { fail("\(label): the marker class was instantiated") }
        if !(view.convertCurvesForPlist() as! NSArray).isEqual(loaded) || !(view.convertPointColorsForPlist() as! NSArray).isEqual(loadedColors) {
            fail("\(label): loading it replaced the editor's CLUT")
        }
    }
    let validPoints = points.map { $0.map { point($0.0, $0.1) } }
    write("Truncated", written["Legacy"]!.dropLast(10))
    write("Text", Data("not an archive".utf8))
    write("Keyed", NSKeyedArchiver.archivedData(withRootObject: valid))
    write("Marker", archiving: legacy(validPoints, [[rgb(1, 0, 0), CLUTMarker(), rgb(0, 0, 0)], colors[1]]))
    write("MarkerRoot", archiving: CLUTMarker())
    write("Array", archiving: NSArray(array: [valid]))
    write("CurvesString", archiving: NSDictionary(dictionary: ["curves": "curves", "colors": valid["colors"]!]))
    write("NumberPoint", archiving: legacy([[point(0, 0), NSNumber(value: 3), point(10, 1)], validPoints[1]], colors))
    write("RectPoint", archiving: legacy([[point(0, 0), NSValue(rect: .zero), point(10, 1)], validPoints[1]], colors))
    write("NaN", archiving: legacy([[point(0, 0), point(.nan, 0.5), point(10, 1)], validPoints[1]], colors))
    write("Infinite", archiving: legacy([[point(0, 0), point(.infinity, 0.5), point(10, 1)], validPoints[1]], colors))
    write("Opacity", archiving: legacy([[point(0, 0), point(5, 1.5), point(10, 1)], validPoints[1]], colors))
    write("NegativeOpacity", archiving: legacy([[point(0, -0.1), point(5, 0.5), point(10, 1)], validPoints[1]], colors))
    write("StringColour", archiving: legacy(validPoints, [[rgb(1, 0, 0), "red", rgb(0, 0, 0)], colors[1]]))
    write("CurveCount", archiving: legacy(validPoints, [colors[0]]))
    write("ColourCount", archiving: legacy(validPoints, [colors[0], [colors[1][0]]]))
    write("Empty", archiving: legacy([], []))
    write("EmptyCurve", archiving: legacy([[]], [[]]))
    let refusals: [(String, String)] = [
        ("Truncated", "a truncated file"), ("Text", "a file that is no archive"), ("Keyed", "a keyed archive"),
        ("Marker", "a CLUT holding the marker among its colours"), ("MarkerRoot", "the marker as the root"),
        ("Array", "an array where the dictionary belongs"), ("CurvesString", "a string for the curves"),
        ("NumberPoint", "a number for a point"), ("RectPoint", "a rect for a point"),
        ("NaN", "a NaN point"), ("Infinite", "an infinite point"), ("Opacity", "an opacity of 1.5"),
        ("NegativeOpacity", "an opacity of -0.1"), ("StringColour", "a string for a colour"),
        ("CurveCount", "two curves and one colour set"), ("ColourCount", "a curve with fewer colours than points"),
        ("Empty", "no curve"), ("EmptyCurve", "an empty curve"),
    ]
    for (name, label) in refusals { refuse(name, "a legacy CLUT with \(label)") }
    for (name, data) in written where (try? Data(contentsOf: URL(fileURLWithPath: folder + "/" + name))) != data {
        fail("the legacy CLUT \(name) was changed on disk")
    }
}
// 7. A CLUT the editor saves as a .plist reads back into the editor.
if let folder = ProcessInfo.processInfo.environment["HOROS_PLIST_CLUTS"] {
    HarnessSetCLUTsPath(folder)
    defer { HarnessSetCLUTsPath(nil) }
    let view = editor()
    view.newCurve()
    view.newCurve()
    view.setColor(NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.9, alpha: 1), forCurveAt: 1)
    view.setColor(NSColor(calibratedRed: 1, green: 0.5, blue: 0, alpha: 1), forPointAt: 1, inCurveAt: 0)
    view.saveWithName("Saved by the editor")
    let saved = (view.convertCurvesForPlist() as! NSArray, view.convertPointColorsForPlist() as! NSArray)
    if CLUTOpacityView.presetFromFile(withName: "Saved by the editor") == nil { fail("a CLUT the editor saved as a .plist is refused") }
    let other = editor()
    other.loadFromFile(withName: "Saved by the editor")
    if !(other.convertCurvesForPlist() as! NSArray).isEqual(saved.0) || !(other.convertPointColorsForPlist() as! NSArray).isEqual(saved.1) {
        fail("a CLUT the editor saved as a .plist reads back as \(other.convertCurvesForPlist()) \(other.convertPointColorsForPlist()), not \(saved)")
    }
}
print("done")
'''

def as_float(value):
    """A value at the precision the editor saves and reads it (a float)."""
    return struct.unpack('f', struct.pack('f', value))[0]


def plist_clut_cases(folder):
    """7. Property list CLUTs in `folder`: {name: (expected, malformed half)}.
    `expected` is (points, colours) for a CLUT that must read back, None for
    one that must be refused; the malformed half is the one the converters
    must return empty ('curves', 'colors' or None)."""
    curves = [[{'x': -100.0, 'y': 0.0}, {'x': 40.0, 'y': 0.35}, {'x': 300.0, 'y': 0.8}],
              [{'x': 500.0, 'y': 0.1}, {'x': 1200.0, 'y': 0.999}]]
    colors = [[{'red': 1.0, 'green': 0.0, 'blue': 0.0}, {'red': 0.25, 'green': 0.5, 'blue': 0.75},
               {'red': 1.0, 'green': 1.0, 'blue': 0.0}],
              [{'red': 0.0, 'green': 0.0, 'blue': 1.0}, {'red': 0.5, 'green': 0.5, 'blue': 0.5}]]
    cases = {}

    def expected(cs, cls):
        return ([[[as_float(p['x']), as_float(p['y'])] for p in c] for c in cs],
                [[[as_float(k['red']), as_float(k['green']), as_float(k['blue'])] for k in c] for c in cls])

    def write(name, data, expect, bad=None):
        (folder / f'{name}.plist').write_bytes(data)
        cases[name] = (expect, bad)

    def clut(name, cs, cls, expect=None, bad=None, fmt=plistlib.FMT_XML):
        write(name, plistlib.dumps({'curves': cs, 'colors': cls}, fmt=fmt), expect, bad)

    def changed(edit):
        cs, cls = copy.deepcopy(curves), copy.deepcopy(colors)
        edit(cs, cls)
        return cs, cls

    clut('Valid', curves, colors, expected(curves, colors))
    integers = [[{'x': int(p['x']), 'y': p['y']} for p in c] for c in curves]
    clut('Integers', integers, colors, expected(integers, colors))
    clut('Binary', curves, colors, expected(curves, colors), fmt=plistlib.FMT_BINARY)
    # The CLUTs of the bundled 3D presets, as a .plist of the CLUT folder.
    for preset in sorted((root / 'Horos/Resources/3DPRESETS').glob('*.plist')):
        d = plistlib.loads(preset.read_bytes())
        if '16bitClutCurves' in d:
            clut(f'Preset {preset.stem}', d['16bitClutCurves'], d['16bitClutColors'],
                 expected(d['16bitClutCurves'], d['16bitClutColors']))

    def element(path, value):
        def edit(cs, cls):
            target = cs if path[0] == 'curves' else cls
            for key in path[1:-1]:
                target = target[key]
            if value is KeyError:
                del target[path[-1]]
            else:
                target[path[-1]] = value
        return edit

    malformed = [
        ('CurveString', element(('curves', 0), 'a curve'), 'curves'),
        ('PointNumber', element(('curves', 0, 1), 3.0), 'curves'),
        ('PointArray', element(('curves', 0, 1), [40.0, 0.35]), 'curves'),
        ('XString', element(('curves', 0, 1, 'x'), '40'), 'curves'),
        ('YBoolean', element(('curves', 0, 1, 'y'), True), 'curves'),
        ('NoY', element(('curves', 0, 1, 'y'), KeyError), 'curves'),
        ('Opacity', element(('curves', 0, 1, 'y'), 1.5), 'curves'),
        ('NegativeOpacity', element(('curves', 1, 0, 'y'), -0.1), 'curves'),
        ('HugeX', element(('curves', 0, 1, 'x'), 1e300), 'curves'),
        ('ColourSetString', element(('colors', 1), 'blue'), 'colors'),
        ('ColourString', element(('colors', 0, 1), 'red'), 'colors'),
        ('ColourDate', element(('colors', 0, 1, 'red'), datetime.datetime(2026, 1, 1)), 'colors'),
        ('NoBlue', element(('colors', 0, 1, 'blue'), KeyError), 'colors'),
        ('ColourAbove', element(('colors', 0, 1, 'green'), 1.2), 'colors'),
        ('ColourBelow', element(('colors', 1, 0, 'red'), -0.5), 'colors'),
    ]
    for name, edit, bad in malformed:
        cs, cls = changed(edit)
        clut(name, cs, cls, None, bad)
    # NaN and infinity, which only a binary property list holds reliably.
    for name, path, value, bad in [('NaN', ('curves', 0, 1, 'x'), float('nan'), 'curves'),
                                   ('Infinite', ('curves', 1, 1, 'x'), float('inf'), 'curves'),
                                   ('NaNOpacity', ('curves', 0, 2, 'y'), float('nan'), 'curves'),
                                   ('NaNColour', ('colors', 0, 0, 'blue'), float('nan'), 'colors')]:
        cs, cls = changed(element(path, value))
        clut(name, cs, cls, None, bad, fmt=plistlib.FMT_BINARY)
    clut('CurveCount', curves, colors[:1])
    clut('ColourSetCount', curves[:1], colors)
    clut('ColourCount', curves, [colors[0], colors[1][:1]])
    clut('PointCount', [curves[0], curves[1][:1]], colors)
    clut('Empty', [], [])
    clut('EmptyCurve', [[]], [[]])
    write('NoColours', plistlib.dumps({'curves': curves}), None)
    write('CurvesString', plistlib.dumps({'curves': 'curves', 'colors': colors}), None, 'curves')
    valid = (folder / 'Valid.plist').read_bytes()
    write('Truncated', valid[:len(valid) // 2], None)
    write('RootArray', plistlib.dumps([curves, colors]), None)
    write('Text', b'not a property list', None)
    # An 8-bit CLUT of the bundle's CLUT folder is no 16-bit CLUT, as before.
    write('EightBit', (root / 'Horos/Resources/CLUTs/Jet.plist').read_bytes(), None)
    return cases


def check_plist_cluts(binary, folder, cases):
    problems = []
    for name, (expect, bad) in sorted(cases.items()):
        label = f'the .plist CLUT {name}'
        try:
            run = subprocess.run([str(binary), 'plist', str(folder), name], capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            problems.append(f'{label}: did not return within 30 s')
            continue
        lines = [line for line in run.stdout.splitlines() if line.startswith('{')]
        if run.returncode or not lines:
            problems.append(f'{label}: the process stopped with status {run.returncode} '
                            f'({(run.stderr.strip().splitlines() or ["no output"])[-1][:200]})')
            continue
        out = json.loads(lines[-1])
        if expect is None:
            if 'curves' in out:
                problems.append(f'{label}: read as {len(out["curves"])} curves instead of being refused')
            if out.get('editorChanged'):
                problems.append(f'{label}: loading it replaced the editor\'s CLUT')
        else:
            points, colours = expect
            got = (out.get('curves'), out.get('colors'))
            close = got[0] is not None and len(got[0]) == len(points) and len(got[1]) == len(colours)
            if close:
                for a, e in zip(got[0] + got[1], points + colours):
                    close = close and len(a) == len(e) and all(
                        len(x) == len(y) and all(abs(u - v) < 1e-6 for u, v in zip(x, y)) for x, y in zip(a, e))
            if not close:
                problems.append(f'{label}: read as {got}, not {expect}')
        if bad and out.get('convertedCurves' if bad == 'curves' else 'convertedColors'):
            problems.append(f'{label}: +convertCurvesFromPlist:/+convertPointColorsFromPlist: converted the malformed {bad}')
    return problems


def source_problems():
    """VRController reads the CLUTs of 3D states, presets and previews
    through the shared validator; nothing converts a CLUT half by half."""
    problems = []
    vr = ''.join(path.read_text() for path in sorted((root / 'Horos/Sources').glob('VRController*.swift')))
    if 'convertCurvesFromPlist' in vr or 'convertPointColorsFromPlist' in vr:
        problems.append('VRController still converts curves and colours separately, without checking them together')
    for key in ('16bitClutCurves', '16bitClutColors'):
        reads = len(re.findall(r'\b(?:preset|dict)\??\.object\(forKey: "%s"\)' % key, vr))
        checked = len(re.findall(r'RestrictedUnarchiver\.plistCLUT\(curves: (preset|dict)\??\.object\(forKey: "16bitClutCurves"\),\s*'
                                 r'colors: \1\??\.object\(forKey: "16bitClutColors"\)', vr))
        if reads == 0 or reads != checked:
            problems.append(f'VRController reads {key} {reads} times, {checked} through the shared validator')
    editor_source = read('Horos/Sources/CLUTOpacityView.swift').decode('utf-8')
    start = editor_source.find('convertPointColorsFromPlist(_')
    converters = editor_source[start:editor_source.find('// MARK: - Connection to VRView', start)]
    if 'as!' in converters:
        problems.append('CLUTOpacityView.swift still forces a property list CLUT element with as!')
    return problems


PANEL_TEST = r'''
@objc(CLUTPanelProbeOwner) @objcMembers final class CLUTPanelProbeOwner: NSObject {
    @IBOutlet var clutOpacityView: CLUTOpacityView?
    @IBOutlet var clutOpacityDrawer: HorosCLUTPanel?
}
func endEditorEvent() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
if let nibPath = ProcessInfo.processInfo.environment["HOROS_CLUT_PANEL_NIB"] {
    _ = NSApplication.shared
    let owner = CLUTPanelProbeOwner()
    var objects: NSArray?
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: nibPath)), bundle: nil)
    if !nib.instantiate(withOwner: owner, topLevelObjects: &objects) { fatalError("CLUT panel nib did not decode") }
    guard let view = owner.clutOpacityView, let panel = owner.clutOpacityDrawer,
          let parent = panel.parentWindow else { fatalError("real drawer/editor outlets missing") }
    if panel.contentView !== view || panel.delegate !== owner || view.vrView !== parent.contentView {
        fail("real drawer/editor/VR bindings no longer refer to the same objects")
    }
    if view.chooseNameAndSaveWindow == nil || view.clutSavedName == nil { fail("real editor save outlets missing") }
    view.setFrameSize(NSSize(width: 600, height: 200))
    view.setHUmin(-1000, HUmax: 3000)
    view.addCurveIfNeeded()
    endEditorEvent()
    let initialPoints = view.convertCurvesForPlist(), initialColors = view.convertPointColorsForPlist()
    if initialPoints.count != 1 || initialColors.count != 1 { fail("nib-created editor did not initialize paired curve/colors") }
    view.undo(nil)
    if view.convertCurvesForPlist().count != 0 || view.convertPointColorsForPlist().count != 0 { fail("first curve undo left curve/colors") }
    view.redo(nil)
    if !view.convertCurvesForPlist().isEqual(initialPoints) || !view.convertPointColorsForPlist().isEqual(initialColors) { fail("first curve redo changed points/colors") }
    endEditorEvent()
    view.setColor(.green, forCurveAt: 0)
    endEditorEvent()
    let changedColors = view.convertPointColorsForPlist()
    view.undo(nil)
    if !view.convertPointColorsForPlist().isEqual(initialColors) { fail("color undo lost pre-edit snapshot") }
    view.redo(nil)
    if !view.convertPointColorsForPlist().isEqual(changedColors) { fail("color redo lost edited colors") }
    endEditorEvent()
    view.replacePoint(at: 1, inCurveAt: 0, with: NSPoint(x: 250, y: 0.25))
    endEditorEvent()
    let editedPoints = view.convertCurvesForPlist()
    view.undo(nil)
    if !view.convertCurvesForPlist().isEqual(initialPoints) { fail("point undo lost original position") }
    view.redo(nil)
    if !view.convertCurvesForPlist().isEqual(editedPoints) { fail("point redo lost edited position") }
    view.removePoint(at: 1, inCurveAt: 0)
    endEditorEvent()
    view.undo(nil)
    if !view.convertCurvesForPlist().isEqual(editedPoints) || !view.convertPointColorsForPlist().isEqual(changedColors) { fail("removed point undo did not restore paired points/colors") }
    if paintedPixels(render(view), of: view) == 0 { fail("nib-created editor no longer draws after undo/redo") }
    // Events go only to this process's panel and menu, never the desktop or
    // another application's windows. Close only this test-owned panel.
    func exerciseResponderRoute() {
    let eventPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
    eventPanel.isReleasedWhenClosed = false
    eventPanel.contentView = view
    NSApp.activate()
    eventPanel.makeKeyAndOrderFront(nil)
    defer { eventPanel.orderOut(nil); eventPanel.close() }
    let applicationMenu = NSMenu()
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    let undoItem = NSMenuItem(title: "Undo", action: #selector(CLUTOpacityView.undo(_:)), keyEquivalent: "z")
    undoItem.keyEquivalentModifierMask = .command
    let redoItem = NSMenuItem(title: "Redo", action: #selector(CLUTOpacityView.redo(_:)), keyEquivalent: "Z")
    redoItem.keyEquivalentModifierMask = .command
    editMenu.addItem(undoItem); editMenu.addItem(redoItem)
    editItem.submenu = editMenu; applicationMenu.addItem(editItem)
    let previousMenu = NSApp.mainMenu
    NSApp.mainMenu = applicationMenu
    defer { NSApp.mainMenu = previousMenu }
    endEditorEvent()
    for _ in 0..<20 {
        if NSApp.isActive { break }
        if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
    eventPanel.makeKey()
    if !NSApp.isActive || !eventPanel.isKeyWindow { fail("CLUT keyboard proof requires an active test app and key panel") }
    let beforeDrag = view.convertCurvesForPlist()
    let downPoint = view.transform().transform(NSPoint(x: 250, y: 0.25))
    let dragPoint = NSPoint(x: downPoint.x + 20, y: downPoint.y + 15)
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: eventPanel.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)!
    }
    eventPanel.sendEvent(mouse(.leftMouseDown, downPoint, 1))
    eventPanel.sendEvent(mouse(.leftMouseDragged, dragPoint, 2))
    eventPanel.sendEvent(mouse(.leftMouseUp, dragPoint, 3))
    endEditorEvent()
    let afterDrag = view.convertCurvesForPlist()
    let dragChanged = !afterDrag.isEqual(beforeDrag)
    let firstIsEditor = eventPanel.firstResponder === view
    let undoEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: eventPanel.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    let undoRouted = applicationMenu.performKeyEquivalent(with: undoEvent)
    let undoRestored = view.convertCurvesForPlist().isEqual(beforeDrag)
    let redoEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: eventPanel.windowNumber, context: nil, characters: "Z", charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: 6)!
    let redoRouted = applicationMenu.performKeyEquivalent(with: redoEvent)
    let redoRestored = view.convertCurvesForPlist().isEqual(afterDrag)
    print("CLUT_PANEL_ROUTE active=\(NSApp.isActive) canKey=\(eventPanel.canBecomeKey) needsKey=\(view.needsPanelToBecomeKey) keyOnlyIfNeeded=\(eventPanel.becomesKeyOnlyIfNeeded) visible=\(eventPanel.isVisible) key=\(eventPanel.isKeyWindow) first=\(String(describing: eventPanel.firstResponder)) dragChanged=\(dragChanged) firstIsEditor=\(firstIsEditor) undoRouted=\(undoRouted) undoRestored=\(undoRestored) redoRouted=\(redoRouted) redoRestored=\(redoRestored)")
    if !dragChanged { fail("test panel did not process the directed drag") }
    if dragChanged && (!firstIsEditor || !undoRouted || !undoRestored || !redoRouted || !redoRestored) { fail("CLUT panel drag did not route undo/redo through its first responder") }
    }
    NSApp.setActivationPolicy(.regular)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        exerciseResponderRoute()
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
    }
    NSApp.run()
    print("PASS: real CLUT panel nib bindings, Swift 6 first curve, paired curve/color/point undo-redo and display")
}
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-clut-editor-') as tmp:
    p = Path(tmp)
    (p / 'CLUTOpacityView.swift').write_bytes(read('Horos/Sources/CLUTOpacityView.swift'))
    uses_bridge = b'CLUTOpacityViewVRBridge' in read('Horos/Sources/CLUTOpacityView.swift')
    if uses_bridge:
        (p / 'CLUTOpacityViewVRBridge.h').write_bytes(read('Horos/Sources/CLUTOpacityViewVRBridge.h'))
    (p / 'Bridge.h').write_text(bridge.replace('BRIDGE_IMPORT', '#import "CLUTOpacityViewVRBridge.h"' if uses_bridge else ''))
    (p / 'Doubles.m').write_text(doubles.replace('BRIDGE_DOUBLE', BRIDGE_DOUBLE if uses_bridge else ''))
    current_main = main.replace('HARNESS_VR_VIEW', '' if uses_bridge else 'view.vrView = harnessVRView')
    if not revision:
        # Historical fixtures still use Foundation's released writer directly,
        # while current production source is compiled without warning masking.
        current_main = current_main.replace(
            'NSArchiver.archivedData(withRootObject: object)',
            '(NSClassFromString("NSArchiver") as! NSObject.Type).perform('
            'NSSelectorFromString("archivedDataWithRootObject:"), with: object)!'
            '.takeUnretainedValue() as! Data')
        current_main = current_main.replace('convertCurvesForPlist() as! NSArray', 'convertCurvesForPlist()')
        current_main = current_main.replace('convertPointColorsForPlist() as! NSArray', 'convertPointColorsForPlist()')
        current_main = current_main.replace(
            'NSKeyedArchiver.archivedData(withRootObject: valid)',
            'try! NSKeyedArchiver.archivedData(withRootObject: valid, requiringSecureCoding: false)')
    if not revision:
        current_main = current_main.replace('if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "overlap" {',
                                            PANEL_TEST + '\nif CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "overlap" {')
    (p / 'main.swift').write_text(current_main)
    # The editor's paste decodes through the restricted unarchiver,
    # which catches NSUnarchiver's exceptions with HorosObjCException.
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        (p / name).write_bytes(read('Horos/Sources/' + name))
    swift_sources = [str(p / 'CLUTOpacityView.swift'), str(p / 'main.swift')]
    if not uses_bridge:
        (p / 'VRDoubles.swift').write_text(VR_DOUBLES)
        swift_sources.append(str(p / 'VRDoubles.swift'))
    # The save sheet ends through NSWindow's -orderOutAndEndSheet.
    (p / 'NSWindow+N2.swift').write_bytes(read('Nitrogen/Sources/NSWindow+N2.swift'))
    swift_sources.append(str(p / 'NSWindow+N2.swift'))
    try:
        (p / 'HistoricalArchive.swift').write_bytes(read('Horos/Sources/HistoricalArchive.swift'))
        swift_sources.append(str(p / 'HistoricalArchive.swift'))
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass   # a revision before it

    if not revision:
        # Decode the real drawer adapter/editor/save-window trees; only the VR
        # renderer and file owner are doubles. No window is ordered on screen.
        original = E.parse(root / 'Horos/Resources/en.lproj/VR.xib').getroot()
        document = E.Element('document', {**original.attrib})
        for child in original:
            if child.tag != 'objects':
                document.append(copy.deepcopy(child))
        objects = E.SubElement(document, 'objects')
        owner = E.SubElement(objects, 'customObject', id='-2', userLabel="File's Owner", customClass='CLUTPanelProbeOwner')
        connections = E.SubElement(owner, 'connections')
        actual_owner = original.find('./objects/customObject[@id="-2"]/connections')
        for outlet in actual_owner:
            if outlet.get('property') in ('clutOpacityDrawer', 'clutOpacityView'):
                connections.append(copy.deepcopy(outlet))
        E.SubElement(objects, 'customObject', id='-1', customClass='FirstResponder')
        for identifier in ('1026', '1029', '1006'):
            objects.append(copy.deepcopy(original.find(f'./objects/*[@id="{identifier}"]')))
        parent = E.SubElement(objects, 'window', id='144', title='Synthetic VR parent', releasedWhenClosed='NO', visibleAtLaunch='NO')
        E.SubElement(parent, 'windowStyleMask', key='styleMask', titled='YES')
        E.SubElement(parent, 'rect', key='contentRect', x='100', y='100', width='600', height='600')
        renderer = E.SubElement(parent, 'view', key='contentView', id='146')
        E.SubElement(renderer, 'rect', key='frame', x='0', y='0', width='600', height='600')
        E.ElementTree(document).write(p / 'CLUTPanel.xib', encoding='utf-8', xml_declaration=True)
        compiled = subprocess.run(['xcrun', 'ibtool', '--errors', '--warnings', '--minimum-deployment-target', '26.0',
                                  '--compile', str(p / 'CLUTPanel.nib'), str(p / 'CLUTPanel.xib')],
                                 capture_output=True, text=True, check=True)
        output = E.fromstring(compiled.stdout)
        values = list(output.find('dict'))
        for i in range(0, len(values), 2):
            if values[i].text in ('com.apple.ibtool.document.warnings', 'com.apple.ibtool.document.errors'):
                assert len(values[i + 1]) == 0, compiled.stdout

    # The VRController double hands out the drawer, a HorosCLUTPanel.
    try:
        (p / 'HorosModernControls.swift').write_bytes(read('Horos/Sources/HorosModernControls.swift'))
        swift_sources.append(str(p / 'HorosModernControls.swift'))
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass   # a revision before it

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
        warning_flags = ['-suppress-warnings'] if revision else [
            '-warnings-as-errors', '-swift-version', '6', '-default-isolation', 'MainActor',
            '-strict-concurrency=complete']
        # The editor takes the rule of a curve's open end from IsiXVolumeRendering; a revision before that imports nothing.
        module_flags = isix_modules.module_flags('IsiXVolumeRendering', p / 'modules') \
            if b'import IsiXVolumeRendering' in read('Horos/Sources/CLUTOpacityView.swift') else []
        build = subprocess.run(['xcrun', 'swiftc', *warning_flags, *module_flags, '-import-objc-header', str(p / 'Bridge.h'),
                                '-I', str(p), *swift_sources,
                                str(p / 'Doubles.o'), str(p / 'HorosObjCException.o'), '-o', str(p / 'test')],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr[-3000:])
            failures.append('the editor does not compile')
    plist_folder = p / 'plist-cluts'
    plist_folder.mkdir()
    plist_cases = plist_clut_cases(plist_folder)
    if not failures:
        if not revision:
            # LaunchServices gives the existing AppKit probe its own GUI
            # identity; a bare CLI cannot become active/key on this SDK.
            app = p / 'CLUTResponderProbe.app'
            macos = app / 'Contents/MacOS'
            macos.mkdir(parents=True)
            shutil.copy2(p/'test', macos/'Probe')
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'org.horos.validation.clut.' + p.name.rsplit('-', 1)[-1],
                'CFBundleExecutable': 'Probe', 'CFBundleName': 'CLUT Responder Probe',
                'CFBundlePackageType': 'APPL',
            }))
            stdout, stderr = p/'native.stdout', p/'native.stderr'
            launched = subprocess.run(['open', '-n', '-W', '-a', str(app),
                                       '--stdout', str(stdout), '--stderr', str(stderr),
                                       '--env', 'HOROS_PLIST_CLUTS=' + str(plist_folder),
                                       '--env', 'HOROS_CLUT_PANEL_NIB=' + str(p/'CLUTPanel.nib')],
                                      capture_output=True, text=True, timeout=120)
            done = subprocess.CompletedProcess(launched.args, launched.returncode,
                stdout.read_text() if stdout.exists() else '',
                stderr.read_text() if stderr.exists() else launched.stderr)
        else:
            done = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=120,
                                  env={**os.environ, 'HOROS_PLIST_CLUTS': str(plist_folder)})
        failures += [line[6:] for line in done.stdout.splitlines() if line.startswith('FAIL: ')]
        if not revision:
            for line in done.stdout.splitlines():
                if line.startswith('CLUT_PANEL_ROUTE '): print(line)
            nib_result = 'PASS: real CLUT panel nib bindings, Swift 6 first curve, paired curve/color/point undo-redo and display'
            if nib_result not in done.stdout.splitlines():
                failures.append('the real CLUT panel nib/undo case did not finish')
            else:
                print(nib_result)

        if done.returncode or 'done' not in done.stdout.splitlines():
            failures.append(f'the harness stopped with status {done.returncode}: {done.stderr[-500:]}')
        try:
            overlap = subprocess.run([str(p / 'test'), 'overlap'], capture_output=True, text=True, timeout=10)
            if 'returned' not in overlap.stdout:
                failures.append(f'resolving overlapping curves failed (status {overlap.returncode})')
        except subprocess.TimeoutExpired:
            failures.append('-resolveOverlappingCurves did not return within 10 s on two overlapping curves')
        try:
            removal = subprocess.run([str(p / 'test'), 'removal'], capture_output=True, text=True, timeout=120)
            failures += [line[6:] for line in removal.stdout.splitlines() if line.startswith('FAIL: ')]
            if removal.returncode or 'removal done' not in removal.stdout.splitlines():
                failures.append(f'the curve removal and undo cases stopped with status {removal.returncode}: {removal.stderr[-500:]}')
        except subprocess.TimeoutExpired:
            failures.append('the curve removal and undo cases did not finish within 120 s')
        failures += check_plist_cluts(p / 'test', plist_folder, plist_cases)
    failures += source_problems()

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: removing curves clears the selected curve and the colors, the selection follows moved curves, '
      'no histogram is drawn without a volume, nothing loops on overlapping curves, colors enter as RGB, '
      'legacy CLUT files read back or are refused without changing the editor or the file, '
      'property list CLUTs read back or are refused whole without a crash, «−» removes one curve per click '
      'and a click on a square selects its curve, the Delete key after a click on a line removes only the point, '
      'a click on nothing leaves nothing for «−», the selected curve stays drawn selected after undo, '
      'Send to back and the colour panel act on it after an undo, a windowing or a zoom, '
      'a click on a point colours no curve, the curves\' order reaches the volume after Send to back, a bring-to-front '
      'by index and a click on a line, a click on the square or on a point of a curve behind sends the curves once, '
      'a curve\'s open end at 3071 HU stays out of its windowing and its square, '
      'and takes the colour given to the point before it, '
      'stays open after a click on its line or the Delete key on the point before it, and is drawn on as the volume holds it, '
      'the volume receives what the editor shows, Remove All Curves '
      'is undone and a CLUT loaded forgets the undo history')
