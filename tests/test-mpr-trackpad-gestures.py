#!/usr/bin/env python3
"""Execute production MPR gesture math and handlers with observable camera stubs.

The event deliberately has deltaZ == 0: native pinch input is magnification,
not a synthetic scroll event. No app build, renderer, fixture or UI is needed.
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
    source = sources.source_text('MPRDCMView')
    helper = block(source, 'enum MPRTrackpadGesture')
    handlers = '\n\n'.join(
        block(source, f'public override dynamic func {name}(with anEvent: NSEvent)')
        .replace('public override dynamic func', 'func', 1)
        for name in ('magnify', 'rotate')
    )
except ValueError as error:
    raise SystemExit(f'FAIL: production MPR gesture extraction: {error}') from error

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
import Foundation
import simd

struct NSEvent {
    struct Phase: OptionSet, Sendable {
        let rawValue: Int
        static let changed = Phase(rawValue: 1)
        static let ended = Phase(rawValue: 2)
        static let cancelled = Phase(rawValue: 4)
    }
    var magnification: CGFloat = 0
    var rotation: Float = 0
    var phase: Phase = .changed
    let deltaZ: CGFloat = 0
}
struct Point3D {
    var x: Float
    var y: Float
    var z: Float
    var vector: SIMD3<Float> { SIMD3(x, y, z) }
    static func point(withX x: Float, y: Float, z: Float) -> Point3D {
        Point3D(x: x, y: y, z: z)
    }
}
final class Camera {
    var parallelScale: Float = 80
    var forceUpdate = false
    var viewUp: Point3D? = Point3D(x: 0, y: 1, z: 0)
    var position: Point3D? = Point3D(x: 10, y: 20, z: 30)
    var focalPoint: Point3D? = Point3D(x: 10, y: 20, z: 20)
    var windowCenterX: Float = 0.25
    var windowCenterY: Float = -0.5
    var bits: [UInt32] {
        [parallelScale.bitPattern, windowCenterX.bitPattern, windowCenterY.bitPattern]
        + [viewUp, position, focalPoint].flatMap {
            $0.map { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
                ?? [UInt32.max]
        } + [forceUpdate ? 1 : 0]
    }
    var basis: [Float] {
        let up = viewUp!.vector
        let normal = simd_normalize(focalPoint!.vector - position!.vector)
        let right = simd_cross(up, normal)
        return [right.x, right.y, right.z, up.x, up.y, up.z,
                normal.x, normal.y, normal.z]
    }
}
final class Controller {
    var lowLOD = false
    var pendingRefresh: Double?
    var cancellations = 0
    var onCancel: (() -> Void)?
}
enum MPRDCMView {
    static let delayedFullLODRendering = "delayedFullLODRendering:"
}
enum NSObject {
    static func cancelPreviousPerformRequests(withTarget controller: Controller,
                                              selector: String, object: Any?) {
        precondition(selector == "delayedFullLODRendering:" && object == nil,
                     "completion must cancel the matching full-LOD request")
        controller.pendingRefresh = nil
        controller.cancellations += 1
        controller.onCancel?()
    }
}
final class Pix {
    var matrix: [Float]
    var reads = 0
    init(_ camera: Camera) { matrix = camera.basis }
    func orientation(_ values: inout [Float]) {
        reads += 1
        values = matrix
    }
}
final class VRView {
    let camera: Camera
    var reads = 0
    init(_ camera: Camera) { self.camera = camera }
    func getCosMatrix(_ values: inout [Float]) -> Bool {
        reads += 1
        values = camera.basis
        return true
    }
}
enum MPRController {
    static func angleBetweenVector(_ after: inout [Float],
                                   andPlane before: inout [Float]) -> Double {
        let oldUp = SIMD3(before[3], before[4], before[5])
        let newUp = SIMD3(after[3], after[4], after[5])
        let normal = SIMD3(before[6], before[7], before[8])
        return Double(atan2(simd_dot(simd_cross(oldUp, newUp), normal),
                            simd_dot(oldUp, newUp))) * 180 / .pi
    }
}
final class GestureView {
    var _camera: Camera?
    let windowControllerIvar: Controller? = Controller()
    var _pix: Pix?
    var _vrView: VRView?
    var _angleMPR: Float = 0
    var restores = 0
    var updates: [Bool] = []
    var refreshDelays: [Double] = []
    var forceSeenAtUpdate: [Bool] = []
    var renderLOD: [Bool] = []
    var renderedScale: [Float] = []
    var renderedUp: [SIMD3<Float>] = []
    var phases: [String] = []
    init(_ camera: Camera? = Camera()) {
        _camera = camera
        if let camera {
            _pix = Pix(camera)
            _vrView = VRView(camera)
        }
        windowControllerIvar?.onCancel = { [weak self] in self?.phases.append("cancel") }
    }
    func restoreCamera() {
        restores += 1
        phases.append("restore")
    }
    func updateViewMPR(_ computeCrossReference: Bool) {
        updates.append(computeCrossReference)
        phases.append("update")
        let forced = _camera?.forceUpdate ?? false
        forceSeenAtUpdate.append(forced)
        // restoreCamera already applied the geometry to the renderer. Like
        // hasCameraChanged, an unchanged camera renders only when invalidated;
        // the invalidation is consumed by this update, including at full LOD.
        guard let camera = _camera, forced else { return }
        camera.forceUpdate = false
        renderLOD.append(windowControllerIvar!.lowLOD)
        renderedScale.append(camera.parallelScale)
        renderedUp.append(camera.viewUp!.vector)
        _pix?.matrix = camera.basis
    }
    func scheduleDelayedFullLODRendering(_ object: Any?, afterDelay delay: Double) {
        precondition(object == nil, "refresh must target the current view")
        refreshDelays.append(delay)
        windowControllerIvar?.pendingRefresh = delay
        phases.append("refresh")
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
func near(_ value: Float, _ wanted: Float, _ message: String) {
    expect(value.isFinite && abs(value - wanted) < 0.0001, message)
}
func nearVector(_ value: SIMD3<Float>, _ wanted: SIMD3<Float>, _ message: String) {
    expect(simd_length(value - wanted) < 0.0001, message)
}
func checkInteractive(_ view: GestureView, count: Int) {
    expect(!view._camera!.forceUpdate, "render consumes camera invalidation")
    expect(view.forceSeenAtUpdate == Array(repeating: true, count: count),
           "every interactive render is invalidated")
    expect(view.windowControllerIvar!.lowLOD, "interactive LOD")
    expect(view.renderLOD == Array(repeating: true, count: count), "interactive renders use low LOD")
    expect(view.windowControllerIvar!.pendingRefresh == 0.4 &&
           view.windowControllerIvar!.cancellations == 0, "full LOD refresh remains pending")
    expect(view.restores == count * 2, "camera restored before and after edit")
    expect(view.updates == Array(repeating: false, count: count),
           "gesture updates must avoid recomputing cross references")
    expect(view.refreshDelays == Array(repeating: 0.4, count: count),
           "full LOD refresh must be delayed")
    expect(view.phases == (0..<count).flatMap { _ in ["restore", "restore", "update", "refresh"] },
           "render and refresh order")
}
func checkGeometry(_ camera: Camera, position: SIMD3<Float>, focal: SIMD3<Float>) {
    nearVector(camera.position!.vector, position, "camera position preserved")
    nearVector(camera.focalPoint!.vector, focal, "focal point preserved")
    near(camera.windowCenterX, 0.25, "horizontal center preserved")
    near(camera.windowCenterY, -0.5, "vertical center preserved")
}

// A native pinch has no scroll delta. Positive opens the image, negative closes it.
let pinch = GestureView()
let pinchCamera = pinch._camera!
let originalPosition = pinchCamera.position!.vector
let originalFocal = pinchCamera.focalPoint!.vector
let event = NSEvent(magnification: 0.25)
expect(event.deltaZ == 0 && event.magnification != 0, "native pinch event contract")
pinch.magnify(with: event)
near(pinchCamera.parallelScale, 64, "positive pinch zooms in with zero scroll delta")
nearVector(pinchCamera.viewUp!.vector, SIMD3(0, 1, 0), "pinch preserves view up")
checkGeometry(pinchCamera, position: originalPosition, focal: originalFocal)
checkInteractive(pinch, count: 1)
pinch.magnify(with: NSEvent(magnification: -0.2))
near(pinchCamera.parallelScale, 80, "inverse pinch restores scale")
checkInteractive(pinch, count: 2)
pinch.magnify(with: NSEvent(magnification: -0.5))
near(pinchCamera.parallelScale, 160, "negative pinch zooms out")
pinch.magnify(with: NSEvent(magnification: 1))
near(pinchCamera.parallelScale, 80, "zoom out followed by inverse restores scale")
checkGeometry(pinchCamera, position: originalPosition, focal: originalFocal)
checkInteractive(pinch, count: 4)

// Rotation is about the line of sight, not an orbit of the camera or focal point.
let rotation = GestureView()
let rotationCamera = rotation._camera!
rotation.rotate(with: NSEvent(rotation: 90))
nearVector(rotationCamera.viewUp!.vector, SIMD3(1, 0, 0), "90 degrees rotates in plane")
near(rotationCamera.parallelScale, 80, "rotation preserves zoom")
checkGeometry(rotationCamera, position: originalPosition, focal: originalFocal)
expect(rotation._pix!.reads == 1 && rotation._vrView!.reads == 1,
       "rotation reads pre-edit orientation and post-edit renderer basis")
expect(abs(rotation._angleMPR) > 1, "rotation updates MPR angle")
checkInteractive(rotation, count: 1)
rotation.rotate(with: NSEvent(rotation: -90))
nearVector(rotationCamera.viewUp!.vector, SIMD3(0, 1, 0), "negative rotation reverses in-plane edit")
near(rotation._angleMPR, 0, "inverse rotation restores MPR angle")
checkInteractive(rotation, count: 2)

// An oblique plane catches a hard-coded screen Z axis or wrong focal subtraction.
let oblique = GestureView()
let obliqueCamera = oblique._camera!
obliqueCamera.position = Point3D(x: 3, y: 5, z: 7)
obliqueCamera.focalPoint = Point3D(x: 6, y: 9, z: 7)
obliqueCamera.viewUp = Point3D(x: 0, y: 0, z: 1)
oblique._pix = Pix(obliqueCamera)
oblique.rotate(with: NSEvent(rotation: 90))
nearVector(obliqueCamera.viewUp!.vector, SIMD3(0.8, -0.6, 0), "oblique line-of-sight rotation")
near(simd_dot(obliqueCamera.viewUp!.vector, SIMD3(0.6, 0.8, 0)), 0,
     "rotated up remains in the oblique plane")
near(simd_length(obliqueCamera.viewUp!.vector), 1, "rotation preserves up-vector length")
checkGeometry(obliqueCamera, position: SIMD3(3, 5, 7), focal: SIMD3(6, 9, 7))
oblique.rotate(with: NSEvent(rotation: -90))
nearVector(obliqueCamera.viewUp!.vector, SIMD3(0, 0, 1), "oblique rotation is reversible")
checkInteractive(oblique, count: 2)

func noRender(_ name: String, camera: Camera? = Camera(),
              configure: (Camera) -> Void = { _ in },
              setup: (GestureView) -> Void = { _ in }, gesture: (GestureView) -> Void) {
    if let camera { configure(camera) }
    // Invalid geometry is never consumed by Pix/VR: retain valid inert stubs.
    let view = GestureView()
    view._camera = camera
    setup(view)
    let original = camera?.bits
    gesture(view)
    expect(camera?.bits == original, "\(name): invalid gesture mutates camera")
    expect(view.restores == 0 && view.updates.isEmpty && view.refreshDelays.isEmpty,
           "\(name): invalid gesture must not render or schedule work")
    expect((view._pix?.reads ?? 0) == 0 && (view._vrView?.reads ?? 0) == 0,
           "\(name): invalid gesture must not read renderer geometry")
    expect(view.windowControllerIvar!.cancellations == 0,
           "\(name): uninitialized or invalid gesture must not cancel work")
    expect(!view.windowControllerIvar!.lowLOD && view._angleMPR == 0,
           "\(name): invalid gesture changes interaction state")
}
for magnification: CGFloat in [0, -1, -2, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
    noRender("pinch \(magnification)") {
        $0.magnify(with: NSEvent(magnification: magnification))
    }
}
for scale: Float in [0, -1, .nan, .infinity, -.infinity] {
    noRender("scale \(scale)", configure: { $0.parallelScale = scale }) {
        $0.magnify(with: NSEvent(magnification: 0.25))
    }
}
noRender("scale underflow", configure: { $0.parallelScale = .leastNonzeroMagnitude }) {
    $0.magnify(with: NSEvent(magnification: 10))
}
noRender("scale overflow", configure: { $0.parallelScale = .greatestFiniteMagnitude }) {
    $0.magnify(with: NSEvent(magnification: -0.5))
}
noRender("pinch missing camera", camera: nil) {
    $0.magnify(with: NSEvent(magnification: 0.25))
}
for angle: Float in [0, .nan, .infinity, -.infinity] {
    noRender("rotation \(angle)") { $0.rotate(with: NSEvent(rotation: angle)) }
}
noRender("rotation missing camera", camera: nil) {
    $0.rotate(with: NSEvent(rotation: 30))
}
let invalidGeometry: [(String, (Camera) -> Void)] = [
    ("missing up", { $0.viewUp = nil }),
    ("missing position", { $0.position = nil }),
    ("missing focal point", { $0.focalPoint = nil }),
    ("zero viewing direction", { $0.focalPoint = $0.position }),
    ("zero up", { $0.viewUp = Point3D(x: 0, y: 0, z: 0) }),
    ("NaN up", { $0.viewUp!.x = .nan }),
    ("infinite up", { $0.viewUp!.y = .infinity }),
    ("NaN position", { $0.position!.z = .nan }),
    ("infinite focal point", { $0.focalPoint!.x = .infinity }),
]
for (name, configure) in invalidGeometry {
    noRender(name, configure: configure) { $0.rotate(with: NSEvent(rotation: 30)) }
}
// An uninitialized view must not render even if the event terminates a gesture.
for phase: NSEvent.Phase in [.changed, .ended, .cancelled] {
    for missingPix in [true, false] {
        let setup: (GestureView) -> Void = {
            if missingPix { $0._pix = nil } else { $0._vrView = nil }
        }
        noRender("pinch missing pix/VR", setup: setup) {
            $0.magnify(with: NSEvent(magnification: 0.25, phase: phase))
        }
        noRender("rotation missing pix/VR", setup: setup) {
            $0.rotate(with: NSEvent(rotation: 30, phase: phase))
        }
        noRender("terminal pinch missing camera", camera: nil) {
            $0.magnify(with: NSEvent(phase: phase))
        }
        noRender("terminal rotation missing camera", camera: nil) {
            $0.rotate(with: NSEvent(phase: phase))
        }
    }
}

// End/cancel commonly has a zero delta. It must cancel the pending timer and
// render at full LOD. A final nonzero delta must be applied before that render.
for rotates in [false, true] {
    for phase: NSEvent.Phase in [.ended, .cancelled, [.ended, .changed]] {
        for finalDelta in [false, true] {
            let view = GestureView()
            if rotates {
                view.rotate(with: NSEvent(rotation: 45))
            } else {
                view.magnify(with: NSEvent(magnification: 0.25))
            }
            checkInteractive(view, count: 1)
            let before = view._camera!.bits
            if rotates {
                view.rotate(with: NSEvent(rotation: finalDelta ? -45 : 0, phase: phase))
            } else {
                view.magnify(with: NSEvent(magnification: finalDelta ? -0.2 : 0, phase: phase))
            }
            let changes = finalDelta ? 2 : 1
            expect(!view.windowControllerIvar!.lowLOD, "terminal gesture restores full LOD")
            expect(view.forceSeenAtUpdate == Array(repeating: true, count: changes + 1),
                   "unchanged camera must be invalidated again for full LOD completion")
            expect(!view._camera!.forceUpdate, "full LOD render consumes final invalidation")
            expect(view.windowControllerIvar!.pendingRefresh == nil &&
                   view.windowControllerIvar!.cancellations == 1,
                   "terminal gesture cancels scheduled full LOD rendering")
            expect(view.renderLOD == Array(repeating: true, count: changes) + [false],
                   "final delta is rendered interactively before full LOD completion")
            expect(view.updates == Array(repeating: false, count: changes + 1),
                   "completion avoids cross-reference recomputation")
            expect(view.restores == changes * 2 + 1, "completion restores camera")
            expect(view.refreshDelays == Array(repeating: 0.4, count: changes),
                   "zero terminal delta adds no delayed work")
            expect(view.phases == (0..<changes).flatMap { _ in
                ["restore", "restore", "update", "refresh"]
            } + ["cancel", "restore", "update"], "completion order")
            if finalDelta {
                near(view.renderedScale.last!, 80, "final full LOD render includes final pinch delta")
                nearVector(view.renderedUp.last!, SIMD3(0, 1, 0),
                           "final full LOD render includes final rotation delta")
            } else {
                expect(view._camera!.bits == before, "zero terminal delta preserves camera")
            }
            checkGeometry(view._camera!, position: originalPosition, focal: originalFocal)
        }
    }
}
print("PASS: native pinch/rotation, preserved camera, invalid/uninitialized no-ops and ended/cancelled full-LOD completion")
'''

# Keep the helper at file scope; the methods are the production bodies verbatim.
code = header + stubs.split('final class GestureView {')[0] + '\n' + helper + '\n' \
    + 'final class GestureView {' + stubs.split('final class GestureView {')[1] \
    + '\n' + handlers + '\n' + checks

with tempfile.TemporaryDirectory(prefix='horos-mpr-gestures-') as directory:
    folder = Path(directory)
    swift = folder / 'main.swift'
    swift.write_text(code)
    executable = folder / 'gestures'
    build = subprocess.run(
        ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-O',
         str(swift), '-o', str(executable)], capture_output=True, text=True
    )
    if build.returncode:
        raise SystemExit('FAIL: production gesture handlers do not compile:\n' + build.stdout + build.stderr)
    run = subprocess.run([str(executable)], capture_output=True, text=True)
    if run.returncode:
        raise SystemExit('FAIL: production MPR gesture behavior:\n' + run.stdout + run.stderr)
    print(run.stdout.strip())
