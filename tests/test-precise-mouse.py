#!/usr/bin/env python3
"""Compile the production sensitivity helper and its ROI/zoom event consumers."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
dragging = (root / 'Horos/Sources/DCMView+MouseDragging.swift').read_text()

def block(source, signature):
    start = source.index(signature)
    pos = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[pos] == '{') - (source[pos] == '}')
        pos += 1
    return source[start:pos]

roi_method = block(dragging, '    @objc(checkROIsForHitAtPoint:forEvent:)')
zoom_method = block(dragging, '    @objc(mouseDraggedZoom:)')
point_methods = block(dragging, '    func preciseROIDragPoint(') + '\n' + block(dragging, '    func preciseMagnifyLensPoint(')
code = r'''
import AppKit
let kRoi: NSString = "roi"
let kMouseClickZoomCentered: NSString = "MouseClickZoomCentered"
let ROI_selectedModify = 2, ROI_drawing = 1, ROI_selected = 3
enum Kind { case tPlain, tText, tMesure, tArrow, tROI, tOval, tAngle, tPencil, tOPolygon, t2DPoint }
final class TestROI: NSObject {
    var locked = false, clickInTextBox = false, roImode = ROI_selectedModify
    var type: Kind = .tMesure
    var received = NSPoint.zero
    func mouseRoiDragged(_ p: NSPoint, _ modifiers: UInt32, _ scale: Float) -> Bool { received = p; return true }
}
typealias ROI = TestROI
func asROI(_ object: Any) -> TestROI { object as! TestROI }
final class Controller { func draggingAddToUndoQueue(_ name: NSString) {} }
@MainActor func windowControllerOf(_ view: DCMView) -> Controller? { Controller() }
final class Defaults { func draggingBoolForKey(_ key: NSString) -> Bool { UserDefaults.standard.bool(forKey: key as String) } }
func standardDefaults() -> Defaults? { Defaults() }
struct Pixel { let pwidth = 512 }
@MainActor class DCMView: NSView {
    var horos_curRoiList: NSArray? = NSArray()
    var horos_mouseDraggedForROIUndo = false
    var horos_scaleValue: Float = 2
    var scaleValue: Float { get { horos_scaleValue } set { horos_scaleValue = newValue } }
    var horos_startScaleValue: Float = 2
    var horos_start = NSPoint(x: 40, y: 60)
    var eventPoint = NSPoint(x: 120, y: 140)
    var curDCM: Pixel? = Pixel()
    var horos_drawingFrameRect = NSRect(x: 0, y: 0, width: 512, height: 512)
    var horos_xFlipped = false, horos_yFlipped = false
    var horos_rotation: Float = 0
    static let horos_static_deg2rad = Double.pi / 180
    var horos_originStart = NSPoint.zero
    func currentPoint(inView event: NSEvent!) -> NSPoint { eventPoint }
    // Exercise an affine image transform rather than only identical coordinate spaces.
    func convert(fromNSView2GL point: NSPoint) -> NSPoint { NSPoint(x: point.x * 2 + 7, y: -point.y * 3 + 11) }
    func setOriginX(_ x: Float, y: Float) {}
    POINT_METHODS
    ROI_METHOD
    ZOOM_METHOD
}
MainActor.assumeIsolated {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: PreciseMouse.enabledKey)
    defaults.removeObject(forKey: PreciseMouse.factorKey)
    precondition(PreciseMouse.effectiveFactor == 1)
    let anchor = NSPoint(x: -10, y: 20), point = NSPoint(x: 70, y: -60)
    precondition(PreciseMouse.point(point, from: anchor) == point)
    let view = DCMView(frame: .zero)
    let roi = TestROI()
    view.horos_curRoiList = [roi] as NSArray
    let imageAnchor = view.convert(fromNSView2GL: view.horos_start)
    let imageEnd = view.convert(fromNSView2GL: view.eventPoint)
    for enabled in [false, true] {
        defaults.set(enabled, forKey: PreciseMouse.enabledKey)
        for selectedFactor in [0.25, 0.5, 0.75] {
            defaults.set(selectedFactor, forKey: PreciseMouse.factorKey)
            let factor = enabled ? selectedFactor : 1
            precondition(PreciseMouse.appliedDelta(-80) == -80 * factor)
            precondition(PreciseMouse.point(point, from: anchor) == NSPoint(x: -10 + 80 * factor, y: 20 - 80 * factor))
            for kind in [Kind.tMesure, .tROI, .tOval, .tPencil, .tOPolygon] {
                roi.type = kind
                roi.roImode = ROI_selectedModify
                _ = view.checkROIsForHit(at: imageEnd, for: nil)
                precondition(roi.received == NSPoint(x: imageAnchor.x + (imageEnd.x-imageAnchor.x)*factor, y: imageAnchor.y + (imageEnd.y-imageAnchor.y)*factor))
                // Repeating the event must not shorten the already-shortened displacement.
                _ = view.checkROIsForHit(at: imageEnd, for: nil)
                precondition(roi.received == PreciseMouse.point(imageEnd, from: imageAnchor))
                precondition(view.preciseMagnifyLensPoint(imageEnd) == roi.received)
            }
            roi.type = .tMesure; roi.roImode = ROI_drawing
            _ = view.checkROIsForHit(at: imageEnd, for: nil)
            precondition(roi.received == PreciseMouse.point(imageEnd, from: imageAnchor))
                precondition(view.preciseMagnifyLensPoint(imageEnd) == roi.received)
            for kind in [Kind.tPlain, .tPencil, .tOPolygon, .tText] {
                roi.type = kind
                _ = view.checkROIsForHit(at: imageEnd, for: nil)
                precondition(roi.received == imageEnd)
                precondition(view.preciseMagnifyLensPoint(imageEnd) == imageEnd)
            }
            roi.type = .t2DPoint; roi.roImode = ROI_selected
            precondition(view.preciseMagnifyLensPoint(imageEnd) == PreciseMouse.point(imageEnd, from: imageAnchor))
            roi.clickInTextBox = true
            precondition(view.preciseMagnifyLensPoint(imageEnd) == imageEnd)
            roi.clickInTextBox = false
            roi.locked = true
            precondition(view.preciseMagnifyLensPoint(imageEnd) == imageEnd)
            roi.locked = false
            view.mouseDraggedZoom(nil)
            precondition(view.scaleValue == Float(2 + factor))
        }
    }
    for invalid in [0.0, -1, 1, 42, Double.infinity] {
        defaults.set(invalid, forKey: PreciseMouse.factorKey)
        precondition(PreciseMouse.effectiveFactor == 0.5)
    }
    defaults.removeObject(forKey: PreciseMouse.enabledKey)
    defaults.removeObject(forKey: PreciseMouse.factorKey)
    print("PASS: production ROI/zoom methods, default off, 25/50/75%, affine coordinates, no compounding, freehand unchanged")
}
'''.replace('POINT_METHODS', point_methods).replace('ROI_METHOD', roi_method).replace('ZOOM_METHOD', zoom_method)
interaction = (root / 'Horos/Sources/VRInteraction.mm').read_text()
vr = (root / 'Horos/Sources/VRView.mm').read_text()
dcm = (root / 'Horos/Sources/DCMView.m').read_text()
dolly = block(interaction, 'void HorosVRInteractor::Dolly()')
endoscopy = re.search(r'aCamera->Dolly\( 1\.0 \+ \[HorosPreciseMouse appliedDelta:.*?;', vr).group()
wheel = re.search(r'deltaX = \(float\)\[HorosPreciseMouse appliedDelta: deltaX\];\s*\[self setScaleValue:sScaleValue \+ deltaX \* scaleValue / 10\];', dcm).group()
assert 'self.computeMagnifyLens(self.preciseMagnifyLensPoint(tempPt))' in dragging
assert 'r.type == .t2DPoint ? PreciseMouse.point(offset, from: .zero) : offset' in dragging
# The generic camera operation also serves non-mouse inputs and keeps its factor unchanged.
assert 'PreciseMouse' not in block(interaction, 'void HorosVRInteractor::Dolly(double factor)')
cpp = r'''
#import <Foundation/Foundation.h>
#import "PreciseMouse-Swift.h"
#include <cmath>
#include <cassert>
#include <initializer_list>
struct Renderer { double center[2] = {256,256}; double *GetCenter() { return center; } };
struct HorosVRInteractor {
    Renderer renderer, *Renderer = &renderer;
    int EventPosition[2] = {0,120}, LastEventPosition[2] = {0,40};
    double MotionFactor = 10, result = 0;
    void Dolly();
    void Dolly(double factor) { result = factor; }
};
DOLLY
struct Camera { double result = 0; void Dolly(double value) { result = value; } };
@interface Event: NSObject
-(double)deltaY;
@end
@implementation Event
-(double)deltaY { return -80; }
@end
@interface Wheel: NSObject
@property float scaleValue;
-(void)apply;
@end
@implementation Wheel
-(void)apply {
    float scaleValue = 2, sScaleValue = 2, deltaX = 2;
    WHEEL
}
@end
int main() { @autoreleasepool {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (int enabled = 0; enabled < 2; enabled++) {
        [defaults setBool:enabled forKey:@"PreciseMouseForMeasuringAndZoom"];
        for (double selected : {0.25, 0.5, 0.75}) {
            [defaults setDouble:selected forKey:@"PreciseMouseFactor"];
            double factor = enabled ? selected : 1;
            HorosVRInteractor interactor; interactor.Dolly();
            assert(fabs(interactor.result - pow(1.1, 10*80*factor/256)) < 1e-12);
            Camera camera, *aCamera = &camera;
            Event *theEvent = [Event new];
            ENDOSCOPY
            assert(fabs(camera.result - (1 + 80*factor/1200)) < 1e-12);
            Wheel *wheel = [Wheel new]; [wheel apply];
            assert(fabs(wheel.scaleValue - (2 + 0.4*factor)) < 1e-6);
        }
    }
    [defaults removeObjectForKey:@"PreciseMouseForMeasuringAndZoom"];
    [defaults removeObjectForKey:@"PreciseMouseFactor"];
    NSLog(@"PASS: actual VR/MPR Dolly, endoscopy and horizontal-wheel zoom consumers");
} }
'''.replace('DOLLY', dolly).replace('ENDOSCOPY', endoscopy).replace('WHEEL', wheel)
with tempfile.TemporaryDirectory(prefix='horos-precise-mouse-') as directory:
    tmp = Path(directory)
    (tmp/'main.swift').write_text(code)
    (tmp/'test.mm').write_text(cpp)
    helper = root/'Horos/Sources/PreciseMouse.swift'
    subprocess.run(['xcrun','swiftc',str(helper),str(tmp/'main.swift'),'-o',str(tmp/'swift-test')],check=True)
    subprocess.run([str(tmp/'swift-test')],check=True)
    subprocess.run(['xcrun','swiftc',str(helper),'-emit-library','-module-name','PreciseMouse','-emit-objc-header','-emit-objc-header-path',str(tmp/'PreciseMouse-Swift.h'),'-o',str(tmp/'libPreciseMouse.dylib')],check=True)
    subprocess.run(['xcrun','clang++','-std=c++17','-framework','Foundation',str(tmp/'test.mm'),str(tmp/'libPreciseMouse.dylib'),'-o',str(tmp/'objc-test')],check=True)
    subprocess.run([str(tmp/'objc-test')],check=True)
