#!/usr/bin/env python3
"""Every string drawn into the viewer is antialiased.

StringTexture rasterized with antialiasing off unless a caller turned it on,
and a caller that forgot produced hard-edged glyphs beside the smooth ones,
which is what "pixelated annotations" looked like. The viewer's, the ROIs'
and the CPR views' text left it for the overlay's own raster (#726, #727,
#729), and StringTexture left the tree: the overlay has to antialias, and
nothing may build a StringTexture again.
"""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = sorted(list((root / 'Horos/Sources').rglob('*.m')) + list((root / 'Horos/Sources').rglob('*.mm')))
creations = []
for source in sources:
    text = source.read_bytes().decode('latin1')
    for m in re.finditer(r'\[\[StringTexture alloc\]', text):
        creations.append('%s:%d' % (source.relative_to(root), text[:m.start()].count('\n') + 1))
if creations or (root / 'Horos/Sources/StringTexture.m').exists():
    print('FAIL: StringTexture is back, and its text is not antialiased unless asked: %s' % ', '.join(creations))
    sys.exit(1)

overlay = (root / 'Horos/Sources/AnnotationOverlay.swift').read_text()
init = overlay[overlay.index('    init(string: String, font: NSFont, scale requested: CGFloat) {'):]
if 'context.shouldAntialias = true' not in init[:init.index('\n    }\n')]:
    print('FAIL: the overlay rasterizes the viewer text without antialiasing')
    sys.exit(1)

print('PASS: the overlay text raster antialiases, and no StringTexture is built')
