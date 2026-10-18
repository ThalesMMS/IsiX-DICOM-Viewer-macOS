#!/usr/bin/env python3
"""A ROI drawn on one series is shown on the series propagated with it.

Checks the geometry that places it (which image, which points) by compiling
ROISeriesTransfer.swift with a driver, and the wiring: the observer starts at
launch, and the choice is in the Propagate Between Series submenu, in ROI >
Propagate and in the Propagate button's pull-down, all on the same default.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


driver = r'''
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}

// The nearest plane within half a slice.
check(ROISeriesTransfer.targetImage(distances: [-6, -3, 0.2, 3, 6], current: 0, tolerance: 1.5) == 2,
      "the image whose plane holds the ROI")
check(ROISeriesTransfer.targetImage(distances: [-6, -3, -1.6, 3], current: 0, tolerance: 1.5) == nil,
      "no image when the ROI is beyond the other series")
// Three phases stacked in one series repeat every position: each viewer keeps
// the ROI in the phase it shows.
let stacked: [Double] = [-3, 0, 3, -3, 0, 3, -3, 0, 3]
check(ROISeriesTransfer.targetImage(distances: stacked, current: 0, tolerance: 1.5) == 1, "first phase")
check(ROISeriesTransfer.targetImage(distances: stacked, current: 4, tolerance: 1.5) == 4, "second phase")
check(ROISeriesTransfer.targetImage(distances: stacked, current: 8, tolerance: 1.5) == 7, "third phase")
// A nearer plane still wins over the phase.
check(ROISeriesTransfer.targetImage(distances: [0.9, 0.1, 0.9], current: 0, tolerance: 1.5) == 1, "nearer plane first")

// Points carried into the other series must lie on one plane parallel to it.
check(ROISeriesTransfer.isFlat(depths: [0.2, 0.25, 0.21], tolerance: 1.5), "parallel planes")
check(!ROISeriesTransfer.isFlat(depths: [-4, 0, 4], tolerance: 1.5), "oblique planes")
check(!ROISeriesTransfer.isFlat(depths: [], tolerance: 1.5), "no points")

// A series with half the pixel size and its origin 10 pixels further.
let map: (NSPoint) -> NSPoint = { NSPoint(x: $0.x * 2 + 10, y: $0.y * 2 + 10) }
let oval = ROISeriesTransfer.mapRect(NSRect(x: 20, y: 30, width: 5, height: 8), kind: .centreAndRadii, map: map)
check(oval == NSRect(x: 50, y: 70, width: 10, height: 16), "oval: centre and radii \(oval)")
let rectangle = ROISeriesTransfer.mapRect(NSRect(x: 20, y: 30, width: -5, height: 8), kind: .cornerAndExtent, map: map)
check(rectangle == NSRect(x: 50, y: 70, width: -10, height: 16), "rectangle: corner and signed extent \(rectangle)")
let text = ROISeriesTransfer.mapRect(NSRect(x: 20, y: 30, width: 40, height: 12), kind: .point, map: map)
check(text == NSRect(x: 50, y: 70, width: 40, height: 12), "text: the position moves, its box does not \(text)")
let polygon = NSRect(x: 1, y: 2, width: 3, height: 4)
check(ROISeriesTransfer.mapRect(polygon, kind: .pointsOnly, map: map) == polygon, "points-only ROI keeps its rect")
// A plane turned a quarter turn sends each radius onto the other axis.
let turned = ROISeriesTransfer.mapRect(NSRect(x: 0, y: 0, width: 5, height: 8), kind: .centreAndRadii,
                                       map: { NSPoint(x: -$0.y, y: $0.x) })
check(turned == NSRect(x: 0, y: 0, width: 8, height: 5), "turned oval \(turned)")
print("PASS: target image, flatness and mapped rectangles")
'''

with tempfile.TemporaryDirectory(prefix='horos-roi-series-') as tmp:
    work = Path(tmp)
    (work / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(sources / 'ROISeriesTransfer.swift'),
                            str(work / 'main.swift'), '-o', str(work / 'check')])
    if build.returncode:
        fail('ROISeriesTransfer.swift does not build with the driver')
    if subprocess.run([str(work / 'check')]).returncode:
        raise SystemExit(1)

glue = (sources / 'ROISeriesPropagation.swift').read_text(encoding='utf-8')
for needle, why in (
    ('name: .OsirixROIChange', 'follows the ROI changes'),
    ('name: .OsirixRemoveROI', 'follows the ROI deletions'),
    ('static let defaultsKey = "PropagateROIsBetweenSeries"', 'reads its default'),
    ('"COPYSETTINGS"', 'only while settings are propagated between series'),
    ('Self.seriesUID(other) != Self.seriesUID(viewer)', 'leaves a viewer of the same series alone'),
    ('registeredViewer()', 'accepts registered series'),
    ('ROISeriesTransfer.targetImage(', 'places the ROI with the shared rule'),
    ('ROISeriesTransfer.isFlat(', 'refuses planes that are not parallel'),
    ('!Self.isCopy(roi)', 'does not propagate a copy back'),
    ('!viewer.windowWillClose()', 'keeps the copies when the viewer that drew the ROI closes'),
):
    if needle not in glue:
        fail(f'the propagation no longer {why}: {needle!r} is missing')

app = (sources / 'AppController.swift').read_text(encoding='utf-8')
start = app.index('func applicationDidFinishLaunching(')
if 'ROISeriesPropagation.start()' not in app[start:start + 4000]:
    fail('the ROI propagation is not started at launch')

menu = (root / 'Horos/Resources/en.lproj/MainMenu.xib').read_text(encoding='utf-8')
for item in ('Prp-ro-Itm', 'Rpr-sy-Itm'):
    at = menu.index(f'id="{item}"')
    block = menu[at:menu.index('</menuItem>', at)]
    if 'keyPath="values.PropagateROIsBetweenSeries"' not in block:
        fail(f'{item} is not bound to PropagateROIsBetweenSeries')
    if 'name="enabled" keyPath="values.COPYSETTINGS"' not in block:
        fail(f'{item} is not dimmed while settings are not propagated')
pb = menu[menu.index('id="Ppb-sm-Mnu"'):]
pb = pb[:pb.index('</menu>')]
if pb.index('id="Prp-rt-Itm"') > pb.index('id="Prp-ro-Itm"'):
    fail('ROIs comes after Rotation in Propagate Between Series')

toolbar = (sources / 'ViewerToolbarItemViews.swift').read_text(encoding='utf-8')
if 'key: "PropagateROIsBetweenSeries", negated: false, needsPropagation: true' not in toolbar:
    fail("the Propagate button's pull-down has no ROIs choice")

pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
for name in ('ROISeriesTransfer.swift', 'ROISeriesPropagation.swift'):
    if f'{name} in Sources' not in pbx:
        fail(f'{name} is not compiled into the app')
print('PASS: ROIs follow the propagated series from the menu bar, ROI menu and toolbar')
