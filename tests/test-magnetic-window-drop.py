#!/usr/bin/env python3
"""Magnetic windows snap when the window is dropped, not while it is dragged.

On current macOS windowDidMove: arrives continuously during a title-bar drag.
Snapping there pulled the window away from the cursor, so a viewer could not be
dragged onto its neighbour to swap places with it. The move handlers now only
record that the user is moving the window and arm a drop check; the check is
re-armed while a mouse button is pressed and, after the release, runs the
snapping and the swap once.

The handlers need windows, screens and the mouse of a running app, so the source
is read: the contract below is what keeps the snapping out of the drag. The
class is Swift (OSIWindowController.swift and its +MagneticWindows extension);
where the snapped frame goes is MagneticWindowSnapping's.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

text = sources.class_text('OSIWindowController')
snapping = sources.source_text('MagneticWindowSnapping')
failures = []


def method(source, signature):
    """The body of the Swift function whose declaration starts with `signature`."""
    start = source.find(signature)
    if start < 0:
        failures.append('%s is gone' % signature)
        return ''
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        depth += {'{': 1, '}': -1}.get(source[index], 0)
        if depth == 0:
            return source[start:index + 1]
    return source[start:]


will_move = method(text, 'private func windowWillMove(_ notification: Notification)')
did_move = method(text, 'private func windowDidMove(_ notification: Notification)')
schedule = method(text, 'private func scheduleMagneticDropCheck()')
drop = method(text, 'private func magneticDropCheck()')
magnets = method(text, 'private func applyMagnetsAfterUserMove()')
closing = method(text, 'private func windowWillCloseNotification(_ notification: Notification)')
dropped = method(snapping, 'static func dropped(')
swaps = method(snapping, 'static func swaps(')
around = method(text, 'private func magnets(around window: NSWindow?)')

# During the drag: nothing moves the window.
for name, body in (('windowWillMove:', will_move), ('windowDidMove:', did_move)):
    if 'resizeWindow(withAnimation' in body or 'setFrame' in body or 'applyMagnetsAfterUserMove' in body:
        failures.append('%s moves the window while the button may still be down' % name)
if 'scheduleMagneticDropCheck' not in did_move or 'windowIsMovedByTheUser' not in did_move:
    failures.append('windowDidMove: no longer arms the drop check for a user move')
if not re.search(r'NSEvent\.pressedMouseButtons != 0 \{\s*windowIsMovedByTheUser = true\s*scheduleMagneticDropCheck\(\)', will_move):
    failures.append('windowWillMove: no longer marks a move made with the button down')
if not re.search(r'if windowIsMovedByTheUser == false \{\s*savedWindowsFrame = ', will_move):
    failures.append('a move in progress may lose the frame it started from, where a swap sends the other window')

# The drop check runs in every run loop mode (title-bar drags may track in
# NSEventTrackingRunLoopMode) and replaces, not stacks, its pending request.
if 'NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(magneticDropCheck), object: nil)' not in schedule:
    failures.append('the drop check is not de-duplicated before it is armed again')
if 'inModes: [.common]' not in schedule:
    failures.append('the drop check does not run in the common run loop modes')

# The drop check: waits for the release, stops for a closed window, snaps once.
held = re.search(r'if NSEvent\.pressedMouseButtons != 0 \{\s*scheduleMagneticDropCheck\(\)\s*return', drop)
if not held:
    failures.append('the drop check does not wait while a mouse button is pressed')
visible = drop.find('isVisible ?? false) == false')
if visible < 0 or (held and visible > held.start()):
    failures.append('the drop check could keep re-arming for a closed or hidden window')
release = drop.rfind('windowIsMovedByTheUser = false')
call = drop.find('applyMagnetsAfterUserMove()')
if call < 0 or release < 0 or release > call:
    failures.append('the drop does not end the move before snapping, once')
if 'cancelMagneticDropCheck' not in closing:
    failures.append('closing the window leaves its drop check armed')
if 'NSObject.cancelPreviousPerformRequests(withTarget: self)' not in method(text, 'deinit'):
    failures.append('dealloc no longer cancels pending requests')

# The snapping and the swap are the ones the drag used to run, with the same
# reach, the same switches and the modifier state read when the button is released.
for body, needle, why in (
        (magnets, 'bool(forKey: "MagneticWindows")', 'the Magnetic windows preference is not honoured'),
        (magnets, 'if NSEvent.modifierFlags.contains(.option) { return }', 'Option at the drop no longer disables the snapping'),
        (magnets, 'MagneticWindowSnapping.dropped(myFrame, magnets: magnets(around: theWindow))', 'the drop does not snap'),
        (dropped, 'var gravityX = Float(myFrame.size.width / 4)', 'the horizontal reach is no longer a quarter of the width'),
        (dropped, 'var gravityY = Float(myFrame.size.height / 4)', 'the vertical reach is no longer a quarter of the height'),
        (around, 'AppController.usefullRect(for: self.window?.screen)', 'the screen edges are no longer magnets'),
        (swaps, 'abs(frame.origin.x - myFrame.origin.x) < 30 && abs(frame.maxY - myFrame.maxY) < 30', 'the swap rule changed'),
        (magnets, 'MagneticWindowSnapping.swaps(frame, with: myFrame)', 'the swap rule is not applied'),
        (magnets, 'AppController.resizeWindow(withAnimation: window, newSize: savedWindowsFrame)', 'the other window is not sent to where the drag started'),
):
    if needle not in body:
        failures.append(why)
if 'currentEvent' in magnets:
    failures.append('the snapping reads the last event instead of the modifier state at the drop')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: magnetic windows follow the mouse while dragged and snap or swap once, on release')
