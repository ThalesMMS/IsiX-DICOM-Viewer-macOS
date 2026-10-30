#!/usr/bin/env python3
"""Leaving full screen with viewers propagating zoom changes the zoom once.

The fullscreen window closing left another viewer main; restoring COPYSETTINGS
then made that viewer copy its zoom over the fit this one took back, and the
key that ended full screen first propagated the zoom scaled to the window.
The exit makes this viewer's window key again and fits it before either.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (((root / 'Horos/Sources/ViewerController.m').read_text(encoding='latin1')) if (root / 'Horos/Sources/ViewerController.m').exists() else '')
SWIFT = '-(IBAction) fullScreenMenu:(id) sender' not in source
if SWIFT:
    # The full screen is Swift since ViewerController+FullScreen.swift.
    source = (root / 'Horos/Sources/ViewerController+FullScreen.swift').read_text()
    start = source.index('    func fullScreenMenu(_ sender: Any!) {')
    exit_path = source[start:source.index('        } else {\n            horos_previousPropagate', start)]
else:
    start = source.index('-(IBAction) fullScreenMenu:(id) sender')
    exit_path = source[start:source.index('else // FullScreenOn == false', start)]


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


def at(needle):
    if needle not in exit_path:
        fail(f'the fullscreen exit no longer has {needle!r}')
    return exit_path.index(needle)


if SWIFT:
    frame = at('startingWindow?.setFrame(horos_previousFrameRect, display: true)')
    key = at('startingWindow?.makeKeyAndOrderFront(self)')
    fit = at('horos_imageView?.scaleToFit()')
    delayed = at('horos_imageView?.perform(#selector(DCMView.scaleToFit as (DCMView) -> () -> Void), with: nil, afterDelay: 0.01)')
    restore = at('defaults.set(horos_previousPropagate != 0, forKey: "COPYSETTINGS")')
else:
    frame = at('[StartingWindow setFrame: previousFrameRect display: YES];')
    key = at('[StartingWindow makeKeyAndOrderFront: self];')
    fit = at('[imageView scaleToFit];')
    delayed = at('[imageView performSelector: @selector( scaleToFit) withObject: nil afterDelay: 0.01];')
    restore = at('setBool:previousPropagate forKey: @"COPYSETTINGS"')

if not frame < key < restore:
    fail('the viewer is not made key before COPYSETTINGS is restored')
if not frame < fit < restore:
    fail('the fit is not applied before COPYSETTINGS is restored')
if not fit < delayed:
    fail('the delayed fit is no longer a second pass after the immediate one')
if exit_path.index('layoutSubtreeIfNeeded') > fit:
    fail('the window is not laid out before it is fitted')
print('PASS: leaving full screen keys the viewer and fits it before propagation resumes')
