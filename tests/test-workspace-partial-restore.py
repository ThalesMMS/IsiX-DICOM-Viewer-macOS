#!/usr/bin/env python3
"""A workspace that opens only part of its viewers tiles them anew.

A study's workspace can hold viewers of series no longer in the database,
or, if saved before each patient kept only its own viewers, of another
patient, which -databaseOpenStudy: skips. Opening that study restored the
remaining viewer at the frame its column had in the whole layout: a lone
viewer took the right half of the screen, the left column empty, unless the
deferred automatic tiling happened to run after it. A layout saved as part
of a larger one carries no frames at all. When fewer viewers are restored
than the workspace holds, or they have no frames, the loader
in BrowserController+DatabaseDragExport.swift applies none of the saved
frames, keeps the tiling of the whole layout out of
LastWindowsTilingRowsColumns, and tiles the viewers it opened at the end.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/BrowserController+DatabaseDragExport.swift').read_text(encoding='utf-8')
start = source.index('    func databaseOpenStudy(_ item: NSManagedObject!) {')
loader = source[start:source.index('\n    }\n', start)]

restore = loader[loader.index('let displayedViewers = (ViewerController.getDisplayed2DViewers() as NSArray?) ?? []'):]
assert 'let partialWorkspace = viewersToLoad.count != viewers.count ||' in restore, 'a partial workspace is not detected'
assert 'viewersToLoad.contains { objcValue($0, "window position") == nil }' in restore, 'a layout saved without frames is not tiled'
assert 'var validWindowsPosition = !partialWorkspace' in restore, 'a partial workspace still applies its saved frames'
frame = restore.index('v?.setWindowFrame(r, showWindow: false)')
assert 'if validWindowsPosition {' in restore[frame - 120:frame], 'saved frames are not gated by validWindowsPosition'
assert 'objcValue(dict, "LastWindowsTilingRowsColumns") != nil && !partialWorkspace' in restore, \
    "a partial workspace overwrites LastWindowsTilingRowsColumns with the whole layout's tiling"
tile = restore[restore.index('if validWindowsPosition == false {'):]
tile = tile[:tile.index('AppController.shared()?.tileWindows(d)') + 40]
assert 'let rw = partialWorkspace ? nil : UserDefaults.standard.string(forKey: "LastWindowsTilingRowsColumns")' in tile, \
    "a partial workspace is tiled with the whole layout's rows and columns"
# The viewers restored are the ones whose series were found, in the order saved.
assert 'let dict = viewersToLoad.object(at: i)' in restore
print('PASS: a partial workspace tiles the viewers it opens instead of placing them at the saved frames')
