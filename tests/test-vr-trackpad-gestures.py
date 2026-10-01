#!/usr/bin/env python3
"""Trackpad pinch and rotation move the Volume Rendering camera.

VRView's magnify and rotate handlers only forwarded the event to plugins, so a
pinch or a two-finger rotation did nothing. They now zoom and roll the camera
with the factors VRInteractionGeometry gives, at the interactive level of
detail while the gesture lasts and at the selected one when it ends.

The factors are executed from the production Swift source; the handlers are
checked in VRView.mm, which needs VTK and a render window to run.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


code = r'''
import AppKit
func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
// A pinch of 10 % zooms by 1.1, and the opposite pinch undoes it to first order.
precondition(close(VRInteractionGeometry.zoomFactor(forMagnification: 0.1), 1.1))
precondition(close(VRInteractionGeometry.zoomFactor(forMagnification: -0.1), 0.9))
// Nothing usable leaves the camera alone: no motion, a collapse, a jump, not a number.
for unusable in [CGFloat(0), -0.95, -1, -2, 20, .nan, .infinity] {
    precondition(VRInteractionGeometry.zoomFactor(forMagnification: unusable) == 0, "\(unusable)")
}
// The roll is the rotation, counterclockwise positive, in degrees.
precondition(close(VRInteractionGeometry.rollDegrees(forRotation: 2.5), 2.5))
precondition(close(VRInteractionGeometry.rollDegrees(forRotation: -7), -7))
for unusable in [Float(0), 180, -400, .nan, .infinity] {
    precondition(VRInteractionGeometry.rollDegrees(forRotation: unusable) == 0, "\(unusable)")
}
print("factors ok")
'''
with tempfile.TemporaryDirectory(prefix='horos-vr-gestures-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(code)
    built = subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/VRInteractionGeometry.swift'), str(p / 'main.swift'),
                            '-o', str(p / 'test')], capture_output=True, text=True, timeout=300)
    require(built.returncode == 0, 'the gesture factors do not compile: ' + built.stderr[-400:])
    if built.returncode == 0:
        ran = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
        require(ran.returncode == 0 and 'factors ok' in ran.stdout, 'the gesture factors are wrong: ' + ran.stderr[-400:])

view = (root / 'Horos/Sources/VRView.mm').read_text(errors='replace')


def method(name):
    start = view.index('-(void) %s:(NSEvent *)event' % name)
    return view[start:view.index('\n}\n', start)]


magnify, rotate = method('magnifyWithEvent'), method('rotateWithEvent')
shared = view[view.index('- (void) horosTrackpadGesture:(NSEvent *)event changedCamera:(BOOL) changed'):]
shared = shared[:shared.index('\n}\n')]
for name, body in (('magnify', magnify), ('rotate', rotate)):
    require('eventToPlugins:event' in body.split('\n')[2], '%s no longer offers the event to plugins first' % name)
    require('[drawLock lock]' in body and '[drawLock unlock]' in body, '%s changes the camera outside the draw lock' % name)
    require('horosTrackpadGesture: event changedCamera:' in body, '%s does not go through the shared rendering step' % name)
require('zoomFactorForMagnification: [event magnification]' in magnify and 'aCamera->Zoom( factor)' in magnify,
        'a pinch does not zoom the camera by the production factor')
require('projectionMode != 2' in magnify and 'aCamera->Dolly( factor)' in magnify,
        'a pinch in endoscopy does not move the camera along its view')
require('rollDegreesForRotation: [event rotation]' in rotate and 'aCamera->Roll( degrees)' in rotate,
        'a rotation does not roll the camera by the production angle')
require(re.search(r'if\( finished == NO\)\s*\[self setLODLow: YES\]', shared) is not None,
        'the gesture does not render at the interactive level of detail')
require(re.search(r'if\( finished\)\s*\[self setLODLow: NO\]', shared) is not None,
        'the end of the gesture does not restore the selected level of detail')
require('OsirixVRCameraDidChangeNotification' in shared, 'the gesture does not announce the camera change')
# The buttons and the wheel are untouched by the gesture handlers.
require('scrollInStack' not in magnify + rotate and 'InvokeEvent' not in magnify + rotate,
        'a gesture handler drives the mouse tools')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: pinch zooms and rotation rolls the Volume Rendering camera, at the interactive level of detail while the gesture lasts')
