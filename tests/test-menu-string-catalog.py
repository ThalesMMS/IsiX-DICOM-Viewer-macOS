#!/usr/bin/env python3
"""Menu titles built in code must be catalog keys in every localized catalog."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
tool = root / 'tools/collect-menu-strings.py'

# A title the sources pass to NSLocalizedString is invisible to the nib
# generator, and the English catalog never needs it, so nothing else reports
# that it stayed English in Italian and Spanish.
subprocess.run([sys.executable, str(tool), '--check'], check=True)

listed = subprocess.check_output([sys.executable, str(tool)], text=True).splitlines()
sources = dict(line.split('\t', 1) for line in listed if line)
titles = set(sources)
# "Export ROIs as JSON..." was the Objective-C witness until its category moved
# to Swift, then "8-bit CLUT Editor" until the toolbar block of
# ViewerController moved to Swift, then "Image Tiling" until its contextual
# menu did, then "Comparatives" until the series list did; the volume
# rendering window, Objective-C++, still builds this one.
assert sources.get('16-bit CLUT Editor', '').endswith(('.m', '.mm')), 'Objective-C menu titles are not being collected'
assert sources.get('Comparatives', '').endswith('.swift'), 'the series list titles of the viewer are not being collected'
assert sources.get('Image Tiling', '').endswith('.swift'), 'the contextual menu titles of the viewer are not being collected'
assert sources.get('8-bit CLUT Editor', '').endswith('.swift'), 'the CLUT menu title of the viewer toolbar is not being collected'
assert 'Export ROIs as JSON...' in titles, 'the ROI interchange menu title is not being collected'
assert 'Automatic Cleanup Preview' in titles, 'Swift window titles are not being collected'
assert 'Apply Grayscale Presentation State…' in titles, 'A UTF-8 ellipsis must survive collection'
assert 'TBD' not in titles, 'A commented-out menu item builds nothing'
assert 'iPhoto' not in titles, 'Product names are exempt'
print(f'PASS: {len(titles)} code-built menu titles present in the Italian and Spanish catalogs')
