#!/usr/bin/env python3
"""The dotted marks where an image overflows its view: a choice, and clear of the window's frame.

The marks follow OVERFLOWLINES, registered on. The Viewers pane has a check
for it, once in each of its ten copies, in the image display group, and its
title is in the twelve catalogs.

A window among others has a frame, drawn inside the view's edge. The marks
used to stand four points from the edge, on top of it. The frame now tells how
far it reaches into the view, and the marks stand four points inside it, as
they stand from a bare edge without a frame.
"""
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
import pane_titles  # noqa: E402

failures = []
TITLE = 'Show dotted lines where the image extends beyond the window'

if default_preferences.registered().get('OVERFLOWLINES') != '1':
    failures.append('OVERFLOWLINES is not registered on')

variants = pane_titles.variants('OSIViewerPreferencePanePref.xib')
if len(variants) != 10:
    failures.append(f'{len(variants)} copies of the Viewers pane')
for language, path in variants.items():
    root = ET.parse(path).getroot()
    checks = [button for button in root.iter('button')
              if button.find('.//binding[@name="value"][@keyPath="values.OVERFLOWLINES"]') is not None]
    if len(checks) != 1:
        failures.append(f'{language}: {len(checks)} checks bound to OVERFLOWLINES')
        continue
    box = next((box for box in root.iter('box') if checks[0] in list(box.iter('button'))), None)
    if box is None or box.find('.//binding[@keyPath="interpolationMode"]') is None:
        failures.append(f'{language}: the check is not in the image display group')

for path in sorted((ROOT / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    data = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'binary1', '-o', '-', str(path)]))
    if not data.get(TITLE):
        failures.append(f'{path.parent.name}: no title for the check')
    elif path.parent.name != 'en.lproj' and data[TITLE] == TITLE:
        failures.append(f'{path.parent.name}: the title of the check is in English')

graphics = (ROOT / 'Horos/Sources/PlanarFramePresenter.swift').read_text()
border = graphics[graphics.index('public static func drawWindowBorder('):graphics.index('public static func drawOverflow(')]
overflow = graphics[graphics.index('public static func drawOverflow('):graphics.index('public static func drawTileBorder(')]
for piece, where, what in [
    ('let width: Float = active ? 5 : 2', border, 'the frame is 5 points on the key view and 2 on the others'),
    ('canvas.lineWidth(CGFloat(width * sf))', border, 'the frame is drawn with that width'),
    ('halfWidth: Float(Double(size.width) / 2) - width * sf / 2, halfHeight: Float(Double(size.height) / 2) - width * sf / 2)', border,
     'the whole line is inside the view'),
    ('return CGFloat(width)', border, 'the frame tells how far it reaches into the view'),
    ('let offset = (4 + Float(inset)) * sf', overflow, 'the marks stand four points inside the frame'),
]:
    if piece not in where:
        failures.append(f'PlanarFrameGraphics: {what}')
drawing = (ROOT / 'Horos/Sources/DCMView+Drawing.swift').read_text()
frame = drawing[drawing.index('var frameInset: CGFloat = 0'):drawing.index('PlanarFrameGraphics.drawTileBorder(')]
for piece, what in [
    ('frameInset = PlanarFrameGraphics.drawWindowBorder(', 'the view keeps how far its frame reaches in'),
    ('if DCMView.horos_static_OVERFLOWLINES && is2DViewer && self.stringID == nil {', 'the marks follow the preference'),
    ('scale: CGFloat(sf), inset: frameInset)', 'the marks are told where the frame ends'),
]:
    if piece not in frame:
        failures.append(f'DCMView: {what}')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the overflow marks follow their preference, which the pane offers in every language, and stand inside the window frame')
