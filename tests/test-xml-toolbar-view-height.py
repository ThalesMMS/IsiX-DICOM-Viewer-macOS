#!/usr/bin/env python3
"""The metadata window's DICOM Editing toolbar item fits its toolbar.

Its view was 55 points high in the nib, and ToolbarPolicy keeps a toolbar view
at its designed height: the unified toolbar does not give a labelled item that
much, so the Edit, Add and Apply buttons and the first row of the level radios
were cut at the top of the window. The search view beside it, 42 points high,
fits.

In each language's XMLViewer.xib:
- the editing view is no higher than the search view;
- what it stacks fits that height: the buttons under their top margin, the
  labels under the buttons, and the radio matrix between its two margins;
- the languages share one geometry.
"""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def frame(node):
    rect = node.find('rect[@key="frame"]')
    return tuple(float(rect.get(key)) for key in ('x', 'y', 'width', 'height'))


def constant(view, identifier):
    return float(view.find(f'constraints/constraint[@id="{identifier}"]').get('constant'))


geometries = {}
for path in sorted((root / 'Horos/Resources').glob('*.lproj/XMLViewer.xib')):
    language = path.parent.name
    tree = ET.parse(path)
    editing = tree.find('.//customView[@id="53"]')
    search = tree.find('.//customView[@id="26"]')
    check(editing is not None and search is not None, f'{language}: the toolbar views are not where they were')
    if editing is None or search is None:
        continue
    height, limit = frame(editing)[3], frame(search)[3]
    check(height <= limit, f'{language}: the editing view is {height:g} points high, the search view {limit:g}')
    button = editing.find('.//button[@id="54"]')
    label = editing.find('.//textField[@id="70"]')
    matrix = editing.find('.//matrix[@id="55"]')
    button_height = float(button.find('constraints/constraint[@firstAttribute="height"]').get('constant'))
    stacked = constant(editing, '1Vl-Tj-Hpb') + button_height + constant(editing, 'Inh-xS-ozB') + frame(label)[3]
    check(stacked <= height, f'{language}: buttons and labels need {stacked:g} of {height:g} points')
    radios = constant(editing, 'BT9-9f-c8b') + frame(matrix)[3] + constant(editing, '8Fi-Pf-4Dp')
    check(radios == height, f'{language}: the radio matrix and its margins make {radios:g}, not {height:g} points')
    for node in list(editing.find('subviews')):
        x, y, width, tall = frame(node)
        check(y >= 0 and y + tall <= height, f'{language}: {node.tag} {node.get("id")} leaves the view ({y:g}+{tall:g} of {height:g})')
    geometries[language] = [frame(node) for node in [editing] + list(editing.find('subviews'))]

check(len(geometries) >= 10, f'only {len(geometries)} XMLViewer.xib found')
check(len({tuple(value) for value in geometries.values()}) == 1, 'the languages do not share one geometry')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print(f'ok: the editing toolbar view fits in {len(geometries)} languages')
