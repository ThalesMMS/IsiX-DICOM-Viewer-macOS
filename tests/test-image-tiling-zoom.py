#!/usr/bin/env python3
"""Changing the image tiling keeps the field of view.

-[SeriesView setImageViewMatrixForRows:columns:rescale:] multiplied the zoom
(of the first view, or of every image with a zoom of its own) by the change in
rows. Each DCMView already rescales its image as its size changes, in -reshape,
so the change was applied twice: a 1×1 view fitted to the window became a 2×2
tile at half the tile's fit, and back at twice the window's. The tiling now
leaves the zoom to the views.

Read from the sources: the tiling no longer touches the scale or the offsets,
and -reshape still scales the image, the origin and the other images' zoom
with the view's size.
"""
from pathlib import Path
import sys

from sources import source_text

failures = []
series = source_text('SeriesView')
start = series.index('public func setImageViewMatrix(forRows rows: Int32, columns: Int32, rescale: Bool)')
tiling = series[start:series.index('@objc(updateImageTiling:)', start)]
for needle in ['"scale"', '"xOffset"', '"yOffset"', 'scaleValue', 'setOriginX', 'updatePresentationState']:
    if needle in tiling:
        failures.append(f'the tiling still rescales the views itself: {needle}')
if 'resizeSubviews(withOldSize: bounds.size)' not in tiling:
    failures.append('the tiling no longer resizes the views')

view = source_text('DCMView')
reshape = view[view.index('- (void) reshape'):]
reshape = reshape[:reshape.index('\n}\n')]
for needle in ['self.scaleValue = scaleValue * yChanged;', 'origin.x *= yChanged;',
               '[pix.imageObj setValue: [NSNumber numberWithFloat: s * yChanged] forKey: @"scale"];']:
    if needle not in reshape:
        failures.append(f'-[DCMView reshape] no longer scales with the view: {needle}')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: the image tiling leaves the zoom to the views, which keep the field of view')
