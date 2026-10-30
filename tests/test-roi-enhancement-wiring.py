#!/usr/bin/env python3
"""Built-in ROI Enhancement is registered; the former plugin it replaces is refused."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path, source_text  # noqa: E402

# PluginManager and ViewerController (ROIEnhancement) are Swift:
# the same calls, in Swift spelling.
manager = source_text('PluginManager')
viewer = source_path('ViewerController+ROIEnhancement')
header = root / 'Horos/Sources/ViewerController+ROIEnhancement.h'
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
xib = (root / 'Horos/Resources/en.lproj/Viewer.xib').read_text(encoding='latin1', errors='replace')
volume = source_text('ROIVolume')
geometry = root / 'Horos/Sources/ROIIntersliceGeometry.swift'

if 'ROIEnhancementFilter.register(in: plugins)' not in manager:
    print('FAIL: discoverPlugins does not register the built-in ROI Enhancement', file=sys.stderr)
    sys.exit(1)
# The former public plugin it replaces is refused like every former plugin,
# by its extension, before anything of it is read or loaded.
if 'ROIEnhancementCompatibility' in manager or 'PluginAdmission.isManaged(name)' not in manager:
    print('FAIL: the former ROI Enhancement plugin is not refused like every former plugin', file=sys.stderr)
    sys.exit(1)
if 'T2FitMapFilter.register(in: plugins)' not in manager:
    print('FAIL: ROI Enhancement must not remove the built-in T2 Fit Map', file=sys.stderr)
    sys.exit(1)
if not viewer.is_file() or not header.is_file():
    print('FAIL: ViewerController+ROIEnhancement is missing', file=sys.stderr)
    sys.exit(1)
host = source_text('ViewerController+ROIEnhancement')
if 'roiEnhancementProcessCurrentSeries' not in host:
    print('FAIL: viewer category does not process the current 4D series', file=sys.stderr)
    sys.exit(1)
if 'ROIEnhancementEngine' not in host:
    print('FAIL: viewer category must compute through ROIEnhancementEngine', file=sys.stderr)
    sys.exit(1)
if 'computeROI' not in host:
    print('FAIL: viewer category must sample each phase with computeROI like the 2.3.1 plugin', file=sys.stderr)
    sys.exit(1)
if 'maxMovieIndex' not in host:
    print('FAIL: viewer category must require a dynamic 4D series', file=sys.stderr)
    sys.exit(1)
if 'ROIEnhancement.swift' not in pbx:
    print('FAIL: ROIEnhancement.swift is not in the app target', file=sys.stderr)
    sys.exit(1)
if viewer.name not in pbx:
    print(f'FAIL: {viewer.name} is not in the app target', file=sys.stderr)
    sys.exit(1)
if 'ROI Enhancement' in xib or 'roiEnhancement' in xib:
    print('FAIL: Viewer.xib must stay untouched', file=sys.stderr)
    sys.exit(1)
if 'ROIEnhancement' in volume:
    print('FAIL: ROIVolume must stay untouched', file=sys.stderr)
    sys.exit(1)
if geometry.is_file() and 'ROIEnhancement' in geometry.read_text(encoding='utf-8', errors='replace'):
    print('FAIL: ROIIntersliceGeometry.swift must stay untouched', file=sys.stderr)
    sys.exit(1)
print('PASS: built-in ROI Enhancement is registered, the former plugin is refused, and samples 4D ROIs')
