#!/usr/bin/env python3
"""Magnetic windows snap when the window is dropped, not while it is dragged.

On current macOS windowDidMove: arrives continuously during a title-bar drag.
Snapping there pulled the window away from the cursor, so a viewer could not be
dragged onto its neighbour to swap places with it. The move handlers now only
record that the user is moving the window and arm a drop check; the check is
re-armed while a mouse button is pressed and, after the release, runs the
snapping and the swap once.

The handlers need windows, screens and the mouse of a running app, so the source
is read: the contract below is what keeps the snapping out of the drag.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

text = sources.source_text('OSIWindowController')
failures = []


def method(signature):
    start = text.find(signature)
    if start < 0:
        failures.append('%s is gone' % signature)
        return ''
    end = text.find('\n}\n', start)
    return text[start:end]


will_move = method('- (void)windowWillMove:(NSNotification *)notification')
did_move = method('- (void)windowDidMove:(NSNotification *)notification')
schedule = method('- (void) scheduleMagneticDropCheck')
drop = method('- (void) magneticDropCheck')
magnets = method('- (void) applyMagnetsAfterUserMove')
closing = method('- (void) windowWillCloseNotification: (NSNotification*) notification')

# During the drag: nothing moves the window.
for name, body in (('windowWillMove:', will_move), ('windowDidMove:', did_move)):
    if 'resizeWindowWithAnimation' in body or 'setFrame' in body or 'applyMagnetsAfterUserMove' in body:
        failures.append('%s moves the window while the button may still be down' % name)
if 'scheduleMagneticDropCheck' not in did_move or 'windowIsMovedByTheUserO' not in did_move:
    failures.append('windowDidMove: no longer arms the drop check for a user move')
if not re.search(r'pressedMouseButtons\]\s*!=\s*0\)\s*\{\s*windowIsMovedByTheUserO = YES;\s*\[self scheduleMagneticDropCheck\]', will_move):
    failures.append('windowWillMove: no longer marks a move made with the button down')
if not re.search(r'if\( windowIsMovedByTheUserO == NO\)\s*savedWindowsFrameO = ', will_move):
    failures.append('a move in progress may lose the frame it started from, where a swap sends the other window')

# The drop check runs in every run loop mode (title-bar drags may track in
# NSEventTrackingRunLoopMode) and replaces, not stacks, its pending request.
if 'cancelPreviousPerformRequestsWithTarget: self selector: @selector(magneticDropCheck)' not in schedule:
    failures.append('the drop check is not de-duplicated before it is armed again')
if 'inModes: @[NSRunLoopCommonModes]' not in schedule:
    failures.append('the drop check does not run in the common run loop modes')

# The drop check: waits for the release, stops for a closed window, snaps once.
held = re.search(r'if\( \[NSEvent pressedMouseButtons\] != 0\)\s*\{\s*\[self scheduleMagneticDropCheck\];\s*return;', drop)
if not held:
    failures.append('the drop check does not wait while a mouse button is pressed')
visible = drop.find('isVisible] == NO')
if visible < 0 or (held and visible > held.start()):
    failures.append('the drop check could keep re-arming for a closed or hidden window')
release = drop.rfind('windowIsMovedByTheUserO = NO;')
call = drop.find('[self applyMagnetsAfterUserMove]')
if call < 0 or release < 0 or release > call:
    failures.append('the drop does not end the move before snapping, once')
if 'cancelMagneticDropCheck' not in closing:
    failures.append('closing the window leaves its drop check armed')
if 'cancelPreviousPerformRequestsWithTarget: self]' not in method('- (void) dealloc'):
    failures.append('dealloc no longer cancels pending requests')

# The snapping and the swap are the ones the drag used to run, with the same
# reach, the same switches and the modifier state read when the button is released.
for needle, why in (
        ('boolForKey:@"MagneticWindows"', 'the Magnetic windows preference is not honoured'),
        ('[NSEvent modifierFlags] & NSEventModifierFlagOption) return;', 'Option at the drop no longer disables the snapping'),
        ('myFrame.size.width/4', 'the horizontal reach is no longer a quarter of the width'),
        ('myFrame.size.height/4', 'the vertical reach is no longer a quarter of the height'),
        ('usefullRectForScreen:', 'the screen edges are no longer magnets'),
        ('fabs( frame.origin.x - myFrame.origin.x) < 30 && fabs( NSMaxY( frame) - NSMaxY( myFrame)) < 30', 'the swap rule changed'),
        ('resizeWindowWithAnimation: window newSize: savedWindowsFrameO', 'the other window is not sent to where the drag started'),
):
    if needle not in magnets:
        failures.append(why)
if 'currentEvent' in magnets:
    failures.append('the snapping reads the last event instead of the modifier state at the drop')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: magnetic windows follow the mouse while dragged and snap or swap once, on release')
