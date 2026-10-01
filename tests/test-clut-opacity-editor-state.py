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
   inCurveAtIndex: did the same. Both now store generic RGB and ignore a
   color that has no RGB form, such as a pattern, or nil.

6. 16-bit CLUTs of earlier versions (#971), NSArchiver files without an
   extension, are read by the restricted reader or refused.
7. 16-bit CLUTs in property lists (#1002). The CLUT menu of the VR reads every
   .plist of the database's CLUT folder (and the bundle's) with
   +presetFromFileWithName:. The former converters forced each element with
   `as!`, so one of another type crashed the app, and they took NaN, opacities
   and colours outside 0...1 and curves without a colour for each point. Each
   malformed file is now refused whole (nil: it leaves the menu) and the
   converters return an empty array, without a crash; valid files - those the
   editor saves and the CLUTs of the bundled 3D presets - read back as before.
   Each file is read in a process of its own, so the negative control reports
   a crash per file. VRController.mm, which reads the 3D states and presets
   (16bitClutCurves/16bitClutColors), is checked to go through the same
   validator.

CLUTOpacityView.swift is compiled as it is, with doubles for the Objective-C++
bridge to the VRView (its -setAdvancedCLUT: reads -redComponent of each color,
as VRView does), BrowserController (no database, so nothing is saved) and a
private pasteboard in place of the general one. Exceptions are caught in
Objective-C. `<git revision>` as an optional argument reads the source from
that revision: that is the negative control.
"""
from pathlib import Path
import copy
import datetime
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as E

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

// 6. 16-bit CLUTs of earlier versions (#971): NSArchiver files without an
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
    """VRController.mm reads the CLUTs of 3D states, presets and previews
    through the shared validator; nothing converts a CLUT half by half."""
    problems = []
    vr = read('Horos/Sources/VRController.mm').decode('latin-1')
    if 'convertCurvesFromPlist' in vr or 'convertPointColorsFromPlist' in vr:
        problems.append('VRController.mm still converts curves and colours separately, without checking them together')
    for key in ('16bitClutCurves', '16bitClutColors'):
        reads = vr.count(f'[preset objectForKey:@"{key}"]') + vr.count(f'[dict objectForKey:@"{key}"]')
        checked = vr.count(f'CLUTWithPlistCurves:[preset objectForKey:@"16bitClutCurves"] colors:[preset objectForKey:@"16bitClutColors"]') + \
            vr.count(f'CLUTWithPlistCurves:[dict objectForKey:@"16bitClutCurves"] colors:[dict objectForKey:@"16bitClutColors"]')
        if reads == 0 or reads != checked:
            problems.append(f'VRController.mm reads {key} {reads} times, {checked} through the shared validator')
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
    (p / 'CLUTOpacityViewVRBridge.h').write_bytes(read('Horos/Sources/CLUTOpacityViewVRBridge.h'))
    (p / 'Bridge.h').write_text(bridge)
    (p / 'Doubles.m').write_text(doubles)
    current_main = main
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
    # The editor's paste decodes through the restricted unarchiver (#818),
    # which catches NSUnarchiver's exceptions with HorosObjCException.
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        (p / name).write_bytes(read('Horos/Sources/' + name))
    swift_sources = [str(p / 'CLUTOpacityView.swift'), str(p / 'main.swift')]
    historical = root / 'Horos/Sources/HistoricalArchive.swift'
    if not revision and historical.is_file():
        (p / 'HistoricalArchive.swift').write_bytes(historical.read_bytes())
        swift_sources.append(str(p / 'HistoricalArchive.swift'))

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
        (p / 'HorosModernControls.swift').write_bytes((root / 'Horos/Sources/HorosModernControls.swift').read_bytes())
        swift_sources.append(str(p / 'HorosModernControls.swift'))

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
        build = subprocess.run(['xcrun', 'swiftc', *warning_flags, '-import-objc-header', str(p / 'Bridge.h'),
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
        failures += check_plist_cluts(p / 'test', plist_folder, plist_cases)
    failures += source_problems()

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: removing curves clears the selected curve and the colors, the selection follows moved curves, '
      'no histogram is drawn without a volume, nothing loops on overlapping curves, colors enter as RGB, '
      'legacy CLUT files read back or are refused without changing the editor or the file, '
      'and property list CLUTs read back or are refused whole without a crash')
