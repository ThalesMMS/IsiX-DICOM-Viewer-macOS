#!/usr/bin/env python3
"""Compile the production sensitivity helper and its ROI/zoom event consumers.

A precise drag keeps the system cursor on the point it moves: the cursor is
detached from the mouse, the point advances by the mouse's movement times the
factor, and the cursor is put back on it. The ROI handlers then take that point
as it is.
"""
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
point_methods = block(dragging, '    func preciseDragApplies(')
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
final class Recorder: PreciseDragCursor {
    var calls: [String] = []
    func detach(at p: CGPoint) { calls.append("detach \(p.x),\(p.y)") }
    func move(to p: CGPoint) { calls.append("move \(p.x),\(p.y)") }
    func attach() { calls.append("attach") }
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
    let imageEnd = view.convert(fromNSView2GL: view.eventPoint)
    for enabled in [false, true] {
        defaults.set(enabled, forKey: PreciseMouse.enabledKey)
        for selectedFactor in [0.25, 0.5, 0.75] {
            defaults.set(selectedFactor, forKey: PreciseMouse.factorKey)
            let factor = enabled ? selectedFactor : 1
            precondition(PreciseMouse.appliedDelta(-80) == -80 * factor)
            precondition(PreciseMouse.point(point, from: anchor) == NSPoint(x: -10 + 80 * factor, y: 20 - 80 * factor))
            // The drag already scaled the point: a ROI takes it unchanged.
            for kind in [Kind.tMesure, .tROI, .tOval, .tPencil, .tOPolygon, .tPlain] {
                roi.type = kind
                roi.roImode = ROI_selectedModify
                _ = view.checkROIsForHit(at: imageEnd, for: nil)
                precondition(roi.received == imageEnd)
            }
            view.mouseDraggedZoom(nil)
            precondition(view.scaleValue == Float(2 + factor))
            view.scaleValue = 2
        }
    }
    // Which drags slow down: handles, measurements being drawn, 2D points moved.
    for kind in [Kind.tMesure, .tArrow, .tROI, .tOval, .tAngle, .tPencil, .tOPolygon, .t2DPoint] {
        roi.type = kind; roi.roImode = ROI_selectedModify
        precondition(view.preciseDragApplies(to: roi))
    }
    for kind in [Kind.tPlain, .tText] {
        roi.type = kind; roi.roImode = ROI_selectedModify
        precondition(!view.preciseDragApplies(to: roi))
    }
    for kind in [Kind.tMesure, .tArrow, .tROI, .tOval, .tAngle] {
        roi.type = kind; roi.roImode = ROI_drawing
        precondition(view.preciseDragApplies(to: roi))
    }
    for kind in [Kind.tPencil, .tOPolygon, .tPlain, .tText] {
        roi.type = kind; roi.roImode = ROI_drawing
        precondition(!view.preciseDragApplies(to: roi))
    }
    roi.type = .t2DPoint; roi.roImode = ROI_selected
    precondition(view.preciseDragApplies(to: roi))
    roi.clickInTextBox = true
    precondition(!view.preciseDragApplies(to: roi))
    roi.clickInTextBox = false
    roi.type = .tMesure
    precondition(!view.preciseDragApplies(to: roi))
    roi.type = .t2DPoint; roi.locked = true
    precondition(!view.preciseDragApplies(to: roi))
    roi.locked = false

    // The drag session, against a recorded cursor.
    let recorder = Recorder()
    PreciseDrag.cursor = recorder
    let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    func display(_ x: CGFloat, _ y: CGFloat) -> String { "\(x + 100),\(top - (y + 200))" }
    let start = NSPoint(x: 10, y: 10)
    defaults.set(true, forKey: PreciseMouse.enabledKey)
    defaults.set(0.5, forKey: PreciseMouse.factorKey)
    // The first movement: the point takes half of what the cursor went, and the cursor goes there.
    var at = PreciseDrag.step(in: window, location: NSPoint(x: 30, y: 50), delta: CGVector(dx: 20, dy: 40), dragged: true, anchor: start, precise: true)
    precondition(at == NSPoint(x: 20, y: 30) && recorder.calls == ["detach " + display(20, 30)])
    // Then the mouse's own movement, halved, whatever the event's location says.
    at = PreciseDrag.step(in: window, location: NSPoint(x: 20, y: 30), delta: CGVector(dx: 8, dy: -4), dragged: true, anchor: start, precise: true)
    precondition(at == NSPoint(x: 24, y: 28) && recorder.calls.last == "move " + display(24, 28))
    at = PreciseDrag.step(in: window, location: NSPoint(x: 99, y: 99), delta: .zero, dragged: false, anchor: start, precise: true)
    precondition(at == NSPoint(x: 24, y: 28) && recorder.calls.count == 2)
    precondition(PreciseDrag.trackedLocation(of: nil, in: window) == NSPoint(x: 24, y: 28))
    PreciseDrag.end()
    precondition(recorder.calls.last == "attach" && recorder.calls.count == 3)
    PreciseDrag.end()
    precondition(recorder.calls.count == 3, "the mouse is attached twice")
    precondition(PreciseDrag.trackedLocation(of: nil, in: window) == .zero)
    // The synthetic drags of a click and of a two-click length have no movement and start nothing.
    at = PreciseDrag.step(in: window, location: NSPoint(x: 30, y: 50), delta: .zero, dragged: true, anchor: start, precise: true)
    precondition(at == NSPoint(x: 30, y: 50) && recorder.calls.count == 3)
    // A drag that stops being precise gives the mouse back at once.
    _ = PreciseDrag.step(in: window, location: NSPoint(x: 30, y: 50), delta: CGVector(dx: 1, dy: 1), dragged: true, anchor: start, precise: true)
    at = PreciseDrag.step(in: window, location: NSPoint(x: 31, y: 51), delta: CGVector(dx: 1, dy: 1), dragged: true, anchor: start, precise: false)
    precondition(at == NSPoint(x: 31, y: 51) && recorder.calls.suffix(2) == ["detach " + display(20, 30), "attach"])
    // So does the application going to the background.
    _ = PreciseDrag.step(in: window, location: NSPoint(x: 30, y: 50), delta: CGVector(dx: 1, dy: 1), dragged: true, anchor: start, precise: true)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(recorder.calls.last == "attach" && recorder.calls.count == 7)
    // Off, or at full speed, the cursor is never touched.
    defaults.set(false, forKey: PreciseMouse.enabledKey)
    at = PreciseDrag.step(in: window, location: NSPoint(x: 30, y: 50), delta: CGVector(dx: 20, dy: 40), dragged: true, anchor: start, precise: true)
    precondition(at == NSPoint(x: 30, y: 50) && recorder.calls.count == 7)
    for invalid in [0.0, -1, 1, 42, Double.infinity] {
        defaults.set(invalid, forKey: PreciseMouse.factorKey)
        precondition(PreciseMouse.effectiveFactor == 1)
        defaults.set(true, forKey: PreciseMouse.enabledKey)
        precondition(PreciseMouse.effectiveFactor == 0.5)
        defaults.set(false, forKey: PreciseMouse.enabledKey)
    }
    defaults.removeObject(forKey: PreciseMouse.enabledKey)
    defaults.removeObject(forKey: PreciseMouse.factorKey)
    print("PASS: ROIs take the dragged point, the precise drag keeps the cursor on it and always gives the mouse back")
}
'''.replace('POINT_METHODS', point_methods).replace('ROI_METHOD', roi_method).replace('ZOOM_METHOD', zoom_method)
interaction = (root / 'Horos/Sources/VRInteraction.mm').read_text()
vr = (root / 'Horos/Sources/VRView.mm').read_text()
dcm = (root / 'Horos/Sources/DCMView.m').read_text()
dolly = block(interaction, 'void HorosVRInteractor::Dolly()')
endoscopy = re.search(r'aCamera->Dolly\( 1\.0 \+ \[HorosPreciseMouse appliedDelta:.*?;', vr).group()
wheel = re.search(r'deltaX = \(float\)\[HorosPreciseMouse appliedDelta: deltaX\];\s*\[self setScaleValue:sScaleValue \+ deltaX \* scaleValue / 10\];', dcm).group()
# The drag reads its point once, from the session, and every handler after it the same.
mouse_dragged = block(dragging, '    @objc(mouseDragged:)')
assert 'PreciseDrag.location(of: event, in: self.window' in mouse_dragged
assert 'event.locationInWindow\n' not in mouse_dragged.split('PreciseDrag.location(of:')[1]
assert 'PreciseDrag.trackedLocation(of: event, in: self.window)' in block(dragging, '    @objc(currentPointInView:)')
assert 'PreciseMouse.point' not in dragging, 'a ROI handler scales the point the drag already scaled'
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
