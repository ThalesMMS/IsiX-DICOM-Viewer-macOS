#!/usr/bin/env python3
"""T1 Fit Map is the app's own image filter, and gives way to a plugin of its title.

Plugins > Image Filters > T1 Fit Map is registered, like T2 Fit Map, after the
plugins load and only under a title no loaded plugin holds; HorosNativeFilterMenus
gives it its item only while the filter under the title is the app's class, whose
name is not the former plugin's (MappingT1FitFilter). The viewer side reads the
series through the T2 fit map's grouping, fits through IsiXImaging's T1Fitting and
opens the map in a new viewer, from types of its own: no hub class grows.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

failures = []
manager = source_text('PluginManager')
menus = (root / 'Horos/Sources/NativeFilterMenus.swift').read_text(encoding='utf-8')
app = root / 'Horos/Sources/T1FitMap.swift'
module = root / 'Modules/IsiXImaging/Sources/BufferOperations/T1Fitting.swift'
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')

discover = manager[manager.index('class func discoverPlugins()'):]
registration = 'if plugins[T1FitMapFilter.menuTitle] == nil {\n                        plugins[T1FitMapFilter.menuTitle] = T1FitMapFilter()'
if registration not in discover:
    failures.append('discoverPlugins does not register T1 Fit Map only under a free title')
elif discover.index(registration) < discover.index('PluginManager.loadPlugin(atPath: plugin.path)'):
    failures.append('T1 Fit Map is registered before the plugins load, so it would take a plugin\'s title')
if '("T1 Fit Map", "IsiXT1FitMapFilter", false)' not in menus:
    failures.append('HorosNativeFilterMenus has no image filter item for T1 Fit Map')

if not app.is_file() or not module.is_file():
    failures.append('T1FitMap.swift or IsiXImaging\'s T1Fitting.swift is missing')
else:
    text = app.read_text(encoding='utf-8')
    if '@objc(IsiXT1FitMapFilter)' not in text or 'MappingT1FitFilter' in text:
        failures.append('the filter class must be IsiXT1FitMapFilter, never the former plugin\'s class')
    if 'static let menuTitle = "T1 Fit Map"' not in text:
        failures.append('the filter is not registered under "T1 Fit Map"')
    if re.search(r'^\s*(?:@\w+\s+)*extension\s+(ViewerController|DCMView|BrowserController)\b', text, re.M):
        failures.append('T1FitMap.swift extends a hub class')
    for needed in ('T1Fitting.map(', 'ViewerT2FitMap(viewer: viewer)', 'T1Fitting.acquisition(in:',
                   'ViewerController.newWindow('):
        if needed not in text:
            failures.append(f'T1FitMap.swift does not call {needed}')
    rules = module.read_text(encoding='utf-8')
    for rule in ('t1BoundsMilliseconds: ClosedRange<Double> = 1...10_000', 'signalThresholdFraction = 0.05',
                 'case belowThreshold', 'case notConverged', 'case outOfBounds', 'func despot1(',
                 'enum LevenbergMarquardt'):
        if rule not in rules:
            failures.append(f'T1Fitting lacks {rule}')
if pbx.count('/* T1FitMap.swift in Sources */') != 2 or 'path = T1FitMap.swift;' not in pbx:
    failures.append('T1FitMap.swift is not built into the app')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: T1 Fit Map is registered after the plugins under a free title, has its image filter item, '
      'fits through T1Fitting and grows no hub class')
