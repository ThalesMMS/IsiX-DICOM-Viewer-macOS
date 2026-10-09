#!/usr/bin/env python3
"""Execute the production 3D MPR scroll handlers with recording stubs.

Scrolling reconstructs only the plane that moves: the other two planes follow
the cross when the scroll pauses or ends. The drag with the stack scroll tool
does as the wheel does. Wheel events that arrive while the plane is being
reconstructed or drawn are applied together, in order, with one reconstruction
and one drawing. When the scroll ends, a thin slab's plane, already
reconstructed at full resolution while it moved, is not reconstructed again;
the other two planes and a thicker slab's are. No app build, renderer, fixture
or UI is needed.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401
import sources


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index + 1]
    raise ValueError(f'unbalanced production block: {marker}')


try:
    view_source = sources.source_text('MPRDCMView')
    drag = block(view_source, 'public override dynamic func mouseDraggedImageScroll(_ event: NSEvent!)') \
        .replace('public override dynamic func', 'func', 1)
    wheel = '\n\n'.join(
        block(view_source, marker).replace('public override dynamic func', 'func', 1).replace('private func', 'func', 1)
        for marker in ('public override dynamic func scrollWheel(with theEvent: NSEvent)',
                       'private func applyPendingScrollEvents()'))
    pending = next(line for line in view_source.splitlines()
                   if line.strip() == 'private var pendingScrollEvents: [NSEvent] = []')
    controller_source = sources.source_text('MPRController')
    finishing = '\n\n'.join(
        block(controller_source, marker).replace('private dynamic func', 'func', 1)
        .replace('public dynamic func', 'func', 1).replace('private func', 'func', 1)
        for marker in ('private dynamic func delayedFullLODRendering(_ sender: Any?)',
                       'public dynamic func finishScroll(of view: MPRDCMView)',
                       'public dynamic func updateViewsAccordingToFrame(_ sender: Any!)',
                       'private func updateViewsAccordingToFrame(_ sender: Any!, keeping kept: MPRDCMView?)'))
except ValueError as error:
    raise SystemExit(f'FAIL: production MPR scroll extraction: {error}') from error

header = '''//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.
'''

stubs = r'''
import CoreGraphics
import Foundation

final class NSEvent {
    let location: NSPoint
    init(_ location: NSPoint) { self.location = location }
}
final class Controller {
    var lowLOD = false
}
final class VRView {
    var steps: [Float] = []
    func scroll(inStack delta: Float) { steps.append(delta) }
}
final class ScrollView {
    let windowControllerIvar: Controller? = Controller()
    var _vrView: VRView? = VRView()
    var horos_start = NSPoint(x: 100, y: 100)
    var horos_previous = NSPoint(x: 100, y: 100)
    var horos_scrollMode = 0
    let frame = CGRect(x: 0, y: 0, width: 512, height: 512)
    var log: [String] = []
    var updates: [Bool] = []
    var lowLODAtUpdate: [Bool] = []
    var finishing: [(ScrollView, Double)] = []
    func checkCursor() {}
    func convertToBacking(_ size: NSSize) -> NSSize { size }
    func currentPoint(inView event: NSEvent!) -> NSPoint { event.location }
    func restoreCamera() { log.append("restore") }
    func updateViewMPR(_ computeCrossReferenceLines: Bool) {
        updates.append(computeCrossReferenceLines)
        lowLODAtUpdate.append(windowControllerIvar!.lowLOD)
        log.append("update")
    }
    // The production overload: with the cross, which reconstructs the other planes.
    func updateViewMPR() { updateViewMPR(true) }
    func updateMousePosition(_ event: NSEvent!) { log.append("mouse") }
    func scheduleDelayedFullLODRendering(_ object: Any?, afterDelay delay: Double) {
        finishing.append((object as! ScrollView, delay))
        log.append("finish")
    }
'''

checks = r'''
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        print("FAIL: \(message)")
        exit(1)
    }
}

// A stack scroll drag: up and down by 4 points, as the stack scroll tool's
// -mouseDragged: hands each event over after it keeps the previous point.
let view = ScrollView()
var y: CGFloat = 100
for index in 0..<6 {
    y += index % 2 == 0 ? 4 : -4
    view.mouseDraggedImageScroll(NSEvent(NSPoint(x: 100, y: y)))
    view.horos_previous = NSPoint(x: 100, y: y)
}
expect(view.horos_scrollMode == 1, "a vertical drag scrolls vertically")
expect(view._vrView!.steps.count == 6 && view._vrView!.steps.allSatisfy { abs(abs($0) - 8) < 0.0001 },
       "every event moves the plane by its own delta")
expect(view._vrView!.steps.reduce(0, +) == 0, "the drag ends where it started")
expect(view.updates == Array(repeating: false, count: 6),
       "the drag reconstructs only its own plane, not the other two through the cross")
expect(view.lowLODAtUpdate == Array(repeating: true, count: 6), "the drag reconstructs at the interactive LOD")
expect(!view.windowControllerIvar!.lowLOD, "the drag leaves the full LOD on between events")
expect(view.finishing.count == 6 && view.finishing.allSatisfy { $0.0 === view && $0.1 == 0.2 },
       "a pause in the drag brings the other planes to the cross, as a pause of the wheel does")
expect(view.log == (0..<6).flatMap { _ in ["restore", "update", "mouse", "finish"] },
       "camera restored, plane reconstructed, then the pause scheduled")
print("PASS: stack scroll drag reconstructs its own plane and leaves the others to the pause or the mouse-up")
'''

wheel_stubs = r'''
import Foundation

final class NSEvent {
    let deltaY: Float
    init(_ deltaY: Float) { self.deltaY = deltaY }
}
final class Window {
    var firstResponder: AnyObject?
    func makeFirstResponder(_ responder: AnyObject?) { firstResponder = responder }
}
@MainActor final class Controller {
    var lowLOD = false
    var closing = false
    var undo: [String] = []
    func add(toUndoQueue string: String) { undo.append(string) }
    func windowWillClose() -> Bool { closing }
}
@MainActor final class VRView {
    var steps: [Float] = []
    func scrollWheel(with event: NSEvent) { steps.append(event.deltaY) }
}
@MainActor final class WheelView {
    let window: Window? = Window()
    let windowControllerIvar: Controller? = Controller()
    var _vrView: VRView? = VRView()
    var log: [String] = []
    func restoreCamera() { log.append("restore") }
    func updateViewMPR(_ computeCrossReferenceLines: Bool) {
        log.append(computeCrossReferenceLines ? "update+cross" : "update")
    }
    func updateMousePosition(_ event: NSEvent!) { log.append("mouse \(event.deltaY)") }
    func displayIfNeeded() { log.append("draw") }
    func scheduleDelayedFullLODRendering(_ object: Any?, afterDelay delay: Double) {
        log.append((object as AnyObject) === self && delay == 0.2 ? "finish" : "finish?")
    }
'''

wheel_checks = r'''
}

@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        print("FAIL: \(message)")
        exit(1)
    }
}
@MainActor func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }

@MainActor func run() {
    // Five events reach the view before the main queue turns, as events that
    // waited while the plane was drawn: one reconstruction for the lot.
    let busy = WheelView()
    for delta: Float in [1.5, -1.5, 3, 1.5, -0.5] { busy.scrollWheel(with: NSEvent(delta)) }
    expect(busy.window!.firstResponder === busy, "the wheel makes the view the first responder")
    expect(busy._vrView!.steps.isEmpty && busy.log.isEmpty, "an event alone neither moves nor reconstructs the plane")
    drain()
    expect(busy._vrView!.steps == [1.5, -1.5, 3, 1.5, -0.5], "every event moves the plane, in order")
    expect(busy.log == ["restore", "update", "mouse -0.5", "draw", "finish"],
           "one reconstruction and one drawing for the lot, then the pause scheduled")
    expect(busy.windowControllerIvar!.undo == ["mprCamera"], "one undo step for the lot")
    expect(busy.windowControllerIvar!.lowLOD, "the lot is reconstructed at the interactive LOD")

    // Events that come one at a time, each after the last was drawn, are each
    // reconstructed, as before.
    let idle = WheelView()
    for delta: Float in [1.5, -1.5, 1.5] {
        idle.scrollWheel(with: NSEvent(delta))
        drain()
    }
    expect(idle._vrView!.steps == [1.5, -1.5, 1.5], "every event moves the plane")
    expect(idle.log.filter { $0 == "update" }.count == 3 && idle.log.filter { $0 == "draw" }.count == 3,
           "an event that arrives alone is reconstructed and drawn alone")
    expect(idle.windowControllerIvar!.undo.count == 3, "one undo step per reconstruction")

    // A window that closes before the main queue turns is left alone.
    let closing = WheelView()
    closing.scrollWheel(with: NSEvent(1.5))
    closing.windowControllerIvar!.closing = true
    drain()
    expect(closing._vrView!.steps.isEmpty && closing.log.isEmpty && closing.windowControllerIvar!.undo.isEmpty,
           "a closing window is neither moved nor reconstructed")
    closing.windowControllerIvar!.closing = false
    closing.scrollWheel(with: NSEvent(-1.5))
    drain()
    expect(closing._vrView!.steps == [-1.5], "the events of a closing window are dropped, not kept for later")
    print("PASS: wheel events that wait are applied in order with one reconstruction and one drawing")
}
MainActor.assumeIsolated { run() }
'''

finishing_stubs = r'''
import AppKit

final class Camera: NSObject {
    var forceUpdate = false
}
final class Window {
    var firstResponder: NSResponder?
    func makeFirstResponder(_ responder: NSResponder?) { firstResponder = responder }
}
final class HiddenVRView {
    var lowResLODFactor: Float = 1
}
// A plane is reconstructed when its camera was invalidated or moved; the sender's
// update brings the other planes to the cross, as computeCrossReferenceLines does.
final class MPRDCMView: NSResponder {
    @objc var camera: Camera? = Camera()
    var needsDisplay = false
    var moved = false
    var reconstructions = 0
    var lowLODAtReconstruction: [Bool] = []
    weak var controller: Controller?
    @objc func restoreCamera() {}
    func reconstructIfNeeded() {
        if camera!.forceUpdate || moved {
            reconstructions += 1
            lowLODAtReconstruction.append(controller!._lowLOD)
        }
        camera!.forceUpdate = false
        moved = false
    }
    @objc func updateViewMPR() {
        reconstructIfNeeded()
        for view in controller!.views where view !== self { view.reconstructIfNeeded() }
    }
}
@MainActor final class Controller {
    var horos_windowWillClose = false
    var hiddenVRView: HiddenVRView? = HiddenVRView()
    var _lowLOD = true
    let window: Window? = Window()
    var horos_FullScreenOn = false
    var horos_FullScreenWindow: Window?
    let mprView1: MPRDCMView? = MPRDCMView()
    let mprView2: MPRDCMView? = MPRDCMView()
    let mprView3: MPRDCMView? = MPRDCMView()
    var views: [MPRDCMView] { [mprView1!, mprView2!, mprView3!] }
    init() {
        for view in views { view.controller = self }
        window?.firstResponder = mprView2
    }
    func selectedView() -> MPRDCMView? { mprView1 }
'''

finishing_checks = r'''
}

@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        print("FAIL: \(message)")
        exit(1)
    }
}
@MainActor func counts(_ controller: Controller) -> [Int] { controller.views.map(\.reconstructions) }

@MainActor func run() {
    // A thin slab: the wheel's pause brings the other planes to the cross, and its
    // own plane, already final, is not reconstructed again.
    let thin = Controller()
    thin.delayedFullLODRendering(thin.mprView1)
    expect(counts(thin) == [0, 1, 1], "a thin slab's scrolled plane is kept, the other two follow the cross")
    expect(thin.views[1].lowLODAtReconstruction == [false], "the other planes are reconstructed at full LOD")
    expect(thin._lowLOD, "the interactive LOD is set back after the pass")
    expect(thin.window!.firstResponder === thin.mprView2, "the first responder is given back")
    expect(thin.views.allSatisfy { $0.needsDisplay && !$0.camera!.forceUpdate }, "every view redraws, nothing stays invalidated")

    // The same plane is reconstructed when its camera moved after the scroll.
    let moved = Controller()
    moved.mprView1!.moved = true
    moved.delayedFullLODRendering(moved.mprView1)
    expect(counts(moved) == [1, 1, 1], "a moved camera is reconstructed")

    // The mouse-up of the stack scroll drag finishes the same way.
    let drag = Controller()
    drag.finishScroll(of: drag.mprView3!)
    expect(counts(drag) == [1, 1, 0], "the drag's plane is kept at the mouse-up")

    // A thicker slab moved at a reduced resolution: every plane is reconstructed.
    let thick = Controller()
    thick.hiddenVRView!.lowResLODFactor = 1.5
    thick.delayedFullLODRendering(thick.mprView1)
    expect(counts(thick) == [1, 1, 1], "a thick slab's plane is reconstructed at full resolution")
    let thickGesture = Controller()
    thickGesture.hiddenVRView!.lowResLODFactor = 1.5
    thickGesture.delayedFullLODRendering(nil)
    expect(counts(thickGesture) == [1, 1, 1], "a gesture's pass reconstructs every plane of a thick slab")

    // Without a view, a thin slab has nothing to finish; a frame change still
    // reconstructs every plane.
    let gesture = Controller()
    gesture.delayedFullLODRendering(nil)
    expect(counts(gesture) == [0, 0, 0], "a gesture on a thin slab has no pass")
    let frame = Controller()
    frame.updateViewsAccordingToFrame(frame.mprView1)
    expect(counts(frame) == [1, 1, 1], "a frame change reconstructs every plane")

    let closing = Controller()
    closing.horos_windowWillClose = true
    closing.delayedFullLODRendering(closing.mprView1)
    expect(counts(closing) == [0, 0, 0], "a closing window is left alone")
    print("PASS: the end of a scroll keeps a thin slab's final plane and brings the other planes to the cross")
}
MainActor.assumeIsolated { run() }
'''


def compile_and_run(name, code):
    with tempfile.TemporaryDirectory(prefix='horos-mpr-scroll-') as directory:
        folder = Path(directory)
        swift = folder / 'main.swift'
        swift.write_text(code)
        executable = folder / name
        build = subprocess.run(
            ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-O',
             str(swift), '-o', str(executable)], capture_output=True, text=True
        )
        if build.returncode:
            raise SystemExit(f'FAIL: production MPR {name} code does not compile:\n' + build.stdout + build.stderr)
        run = subprocess.run([str(executable)], capture_output=True, text=True)
        if run.returncode:
            raise SystemExit(f'FAIL: production MPR {name} behavior:\n' + run.stdout + run.stderr)
        print(run.stdout.strip())


compile_and_run('drag', header + stubs + '\n' + drag + '\n' + checks)
compile_and_run('wheel', header + wheel_stubs + '\n' + pending + '\n' + wheel + '\n' + wheel_checks)
compile_and_run('finishing', header + finishing_stubs + '\n' + finishing + '\n' + finishing_checks)
