#!/usr/bin/env python3
"""VR and the MIP panel open the aligned 4D time, not volume 0."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def body(source, signature):
    at = 0
    while True:
        at = source.find(signature, at)
        if at < 0:
            return ''
        brace = source.find('{', at)
        semi = source.find(';', at)
        if brace >= 0 and (semi < 0 or brace < semi):
            break
        at += len(signature)
    depth, index = 0, brace
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[brace:index + 1]
        index += 1
    return ''


code = r'''
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

// The host asks for the time its player shows; the renderer wraps the same way
// when it stores the frame, so both land on one subscript of 0 ..< N.
for count in 1...4 {
    for requested in -8...8 {
        let host = FourDSeriesGuard.alignedTimeIndex(requested: requested, count: count)
        check(host >= 0 && host < count, "host index out of 0 ..< \(count)")
        check(FourDSeriesGuard.wrappedIndex(host, count: count) == host,
              "setMovieFrame: must not move an already aligned index")
    }
}

check(FourDSeriesGuard.alignedTimeIndex(requested: 2, count: 3) == 2, "three times at index 2")
check(FourDSeriesGuard.alignedTimeIndex(requested: 0, count: 3) == 0, "time 0 stays 0")
check(FourDSeriesGuard.alignedTimeIndex(requested: 3, count: 3) == 0, "wrap past the end")
check(FourDSeriesGuard.alignedTimeIndex(requested: -1, count: 3) == 2, "negative wrap")
check(FourDSeriesGuard.alignedTimeIndex(requested: 4, count: 0) == 0, "no time opens 0")

// A renderer that refused a middle time holds fewer slots than the host; the
// wrap still stays inside what it actually loaded.
check(FourDSeriesGuard.wrappedIndex(2, count: 2) == 0, "short renderer stays in range")
print("PASS: VR shares the 4D wrap with the 2D player")
'''
with tempfile.TemporaryDirectory(prefix='horos-vr-4d-time-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(code)
    subprocess.run([
        'xcrun', 'swiftc',
        str(root / 'Horos/Sources/FourDSeriesGuard.swift'),
        str(p / 'main.swift'), '-o', str(p / 'test')
    ], check=True)
    subprocess.run([str(p / 'test')], check=True)

# The 3D viewers are opened by ThreeDViewerLauncher; the viewer's selectors are its façade.
viewer = (root / 'Horos/Sources/ThreeDViewerLauncher.swift').read_text(encoding='utf-8')

for name, signature in (('openVRViewerForMode', 'func volumeRenderingWindow(mode: String?) -> VRController?'),
                        ('Panel3D', 'func openVolumeRenderingPanel(_ sender: Any?)')):
    scope = body(viewer, signature)
    check(scope, '%s is missing' % name)
    check('FourDSeriesGuard.alignedTimeIndex(requested: Int(viewer.horos_curMovieIndex), count: movies)' in scope,
          '%s must wrap the shared 4D index through FourDSeriesGuard' % name)
    check('renderer?.setMovieFrame(time)' in scope,
          '%s must apply the shared index with setMovieFrame:' % name)
    # The times have to reach the renderer in order for the index to mean the
    # same thing on both sides, so time 0 still seeds the renderer.
    load = scope.find('addMovie(i, to: renderer)')
    apply_at = scope.find('renderer?.setMovieFrame(time)')
    check(load >= 0, '%s must still load every time' % name)
    check(load >= 0 and apply_at > load,
          '%s must call setMovieFrame: after loading the times in order' % name)
    check('let firstAtTime = viewer.horos_pixArray(time).first' in scope and 'firstAtTime.isRGB' in scope
          and 'horos_pixArray(0)' not in scope,
          '%s must read the displayed time, not volume 0, for the CLUT choice' % name)

lookup = body(viewer, 'private func openRenderer(style: String, modes: [String]?) -> VRController?')
check('findRelatedViewers(pixList: viewer.horos_pixList(at: 0))' in lookup,
      'FindRelatedViewers may still identify the series by pixList[0]')
standard = body(viewer, 'func volumeRenderingWindow(mode: String?) -> VRController?')
check('openRenderer(style: "standard", modes: ["VR", "MIP"])' in standard,
      'openVRViewerForMode must look for an open VR or MIP window')
panel = body(viewer, 'func openVolumeRenderingPanel(_ sender: Any?)')
check('openRenderer(style: "panel", modes: nil)' in panel,
      'Panel3D must look for an open panel')

# Leaves from earlier issues must not be reopened by this one.
sr = body(viewer, 'func surfaceRenderingWindow() -> SRController?')
check('FourDSeriesGuard.wrappedIndex(Int(viewer.horos_curMovieIndex)' in sr, 'Surface Rendering wrap must stay')
mpr = body(viewer, 'func orthogonalMPRWindow() -> OrthogonalMPRViewer?')
check('FourDSeriesGuard.alignedTimeIndex(requested:' in mpr, 'Orthogonal MPR wrap must stay')
petct = body(viewer, 'func orthogonalPETCTWindow() -> OrthogonalMPRPETCTViewer?')
check('FourDSeriesGuard.fusionOverlayIndex(hostTime:' in petct, 'PET-CT overlay pin must stay')
# ActivateBlending: is ViewerFusion's (ViewerController+Blending.swift keeps
# the selector); its body, under the reentry guard, is activateBlendingInside.
blending_source = sources.source_text('ViewerFusion')
blend = body(blending_source, 'func activateBlending(_ bC: ViewerController!)') + \
    body(blending_source, 'func activateBlendingInside(_ bC: ViewerController!)')
check('fourDFusionRefusalReason' in blend or 'refuseFourDFusionWithTitle' in blend
      or 'fusionRefusalHostTimes' in blend,
      'ActivateBlending fusion refusal must stay')

renderer = sources.class_text('VRController')
frame = body(renderer, 'public override func setMovieFrame(_ l: Int)')
check('FourDSeriesGuard.wrappedIndex(l, count: Int(maxMovieIndex))' in frame,
      'setMovieFrame: must keep wrapping into the times it loaded')

if failures:
    for item in failures:
        print('FAIL:', item, file=sys.stderr)
    sys.exit(1)
print('PASS: VR and the MIP panel open the aligned 4D time')
