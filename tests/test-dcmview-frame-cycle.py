#!/usr/bin/env python3
"""A DCMView frame and a VRView frame go through their cycles (#977).

`-[DCMView drawFrame:]` hands its preparation and presentation to
HorosPlanarFrameCycle (overlay and canvas, the picture in the Metal layer, the
notice, the commit) and the graphics that depend only on their inputs to
HorosPlanarFrameGraphics. `-[VRView drawRect:]` hands its first-frame
preparation, the render's outcome and its completion to HorosVRFrameCycle.
Checked in the sources:
- drawFrame: begins the cycle before its @try and commits it after its
  @catch, presents the picture after the frame rectangle is set, and keeps
  every subclass hook, plugin call and notification in the order it had;
- drawFrame: shrank, and the graphics it no longer draws are not drawn there;
- the cycle keeps nothing between frames (no view, no cache, no renderer) and
  the graphics are static functions of what they are given;
- VRView's drawRect: begins the cycle, catches VTK's C++ exceptions in its own
  method, reports a failure once and restores the 4D pixels after the first
  frame.

`<git revision>` as an optional argument reads the sources from that
revision: the negative control, which fails before #977.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(name):
    path = 'Horos/Sources/' + name
    if revision:
        try:
            return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path],
                                           stderr=subprocess.DEVNULL).decode('latin1')
        except subprocess.CalledProcessError:
            return ''
    file = root / path
    return file.read_bytes().decode('latin1') if file.exists() else ''


def code(text):
    """Without comments, so that what they recall is not taken for a call."""
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    return ''


failures = []
view = read('DCMView.m')
frame = code(block(view, '- (void) drawFrame:(NSRect)aRect'))
presenter = code(read('PlanarFramePresenter.swift'))
if not frame:
    raise SystemExit('drawFrame: is gone')

# --- drawFrame: the order of the frame ----------------------------------------
order = [
    '[HorosPlanarFrameCycle beginInView: self',
    '@try',
    'drawingFrameRect = aRect;',
    '[frame presentPictureInView: self layer: [self horosPictureLayer]',
    '[frame imageDrawn];',
    '[HorosPlanarFrameGraphics drawHighlight:',
    '[self horosDrawCLUTBars: clutBars scale: sf];',
    '[HorosPlanarFrameGraphics beginBordersSize:',
    '[HorosPlanarFrameGraphics drawKeyViewBorderSize:',
    '[HorosPlanarFrameGraphics drawOverflowImageRect:',
    '[HorosPlanarFrameGraphics drawTileBorderSize:',
    '[HorosPlanarFrameGraphics enterImageRotation: rotation origin: origin',
    '[[HorosROICanvas current] resetFrameState];',
    '[r drawROI: scaleValue',
    '[self drawPendingLength];',
    '[[OSIEnvironment sharedEnvironment] drawDCMView:self];',
    '[self draw2DPointMarker];',
    'HorosDrawObjectsCanvasNotification',
    '[self subDrawRect: aRect];',
    '[HorosPlanarFrameGraphics drawPatientCrosshairX:',
    '[self horosDrawReferenceLinesScale: sf];',
    '[HorosPlanarFrameGraphics beginTextSize:',
    '[HorosPlanarFrameGraphics drawRulerRect:',
    '[self drawTextualData: drawingFrameRect :annotations];',
    '[self horosDrawROILabels: is2DViewer];',
    '[self drawRepulsorToolArea];',
    '[self drawROISelectorRegion];',
    'addBox: showDescriptionInLargeText',
    '[self drawMagnifyingLens];',
    '[self drawRectAnyway:aRect];',
    '[frame drawNoticeInView: self',
    '@catch',
    '[frame commitIndex: curImage];',
    '[self _checkHasChanged:YES];',
]
at = -1
for piece in order:
    found = frame.find(piece, at + 1)
    if found < 0:
        failures.append('drawFrame: does not call %s after what precedes it' % piece)
    else:
        at = found
lines = frame.count('\n') + 1
if lines > 300:
    failures.append('drawFrame: has %d lines; its graphics were not handed over' % lines)
for gone in ('roiBegin(GL_QUADS)', 'BARPOSX1', 'roiLineStipple', 'LINELENGTH', 'OsirixDrawObjectsNotification',
             'beginFrameWidth:', 'commitInverted:', 'beginDrawForIndex:', 'horosDrawPlanarInLayer:'):
    if gone in frame:
        failures.append('drawFrame: still does itself what the cycle or the graphics do: ' + gone)
references = code(block(view, '- (void) horosDrawReferenceLinesScale:(float) sf'))
if '[self drawCrossLines: sliceFromTo perpendicular: YES];' not in references:
    failures.append('the reference lines no longer go through the -drawCrossLines: hook')
labels = code(block(view, '- (void) horosDrawROILabels:(BOOL) is2DViewer'))
if '[r drawTextualData];' not in labels or 'rectArray = nil;' not in labels:
    failures.append('the ROI labels are not drawn, or the frame\'s label rectangles are not released')

# --- the components: explicit inputs, nothing kept ----------------------------
cycle = presenter[presenter.find('public final class PlanarFrameCycle'):presenter.find('public final class PlanarFrameGraphics')]
graphics = presenter[presenter.find('public final class PlanarFrameGraphics'):presenter.find('public final class VRFrameCycle')]
if not cycle or not graphics:
    failures.append('the frame cycle or the graphics are missing')
else:
    if re.search(r'(let|var)\s+view\b|:\s*DCMView\b\s*$', cycle, re.M) or 'weak var' in cycle:
        failures.append('the frame cycle keeps its view')
    if re.search(r'static\s+var', presenter):
        failures.append('the frame components keep state between frames')
    members = re.findall(r'^    (?:@objc\S*\s+)?((?:public |private )?(?:static )?(?:func|let|var|init))\b', graphics, re.M)
    if not members or any('static' not in member for member in members):
        failures.append('the graphics hold instance state or instance methods: %s' % [m for m in members if 'static' not in m])
    for piece in ('view.horosDrawPlanar(in: layer, inverted: inverted)', 'view.horosClearLayer(layer, white: whiteBackground && hasImage',
                  'overlay.commit(inverted: inverted, scale: scale)', 'trace?.endDraw(span, index: index)',
                  'view.horosPlanarFallbackReason()'):
        if piece not in cycle:
            failures.append('the frame cycle does not do its part: ' + piece)
    if '@MainActor' not in presenter.split('public final class PlanarFrameCycle')[0].rsplit('///', 1)[-1] + \
            presenter[presenter.find('public final class PlanarFrameCycle') - 60:presenter.find('public final class PlanarFrameCycle')]:
        failures.append('the frame cycle is not isolated to the main actor')

# --- VRView ----------------------------------------------------------------------
vr = read('VRView.mm')
draw = code(block(vr, '- (void) drawRect:(NSRect)aRect'))
render = code(block(vr, '- (BOOL) horosRenderFrame'))
first = code(block(vr, '- (void) horosFinishFirstFrame'))
for piece, why in [('[HorosVRFrameCycle beginFirstFrame: firstTime]', 'the cycle begins with the first-frame flag'),
                   ('[frame renderSucceeded: [self horosRenderFrame] errorShown: alertDisplayed]', 'the render\'s outcome is the cycle\'s'),
                   ('@selector( displayVTKError)', 'a failure is reported by the view\'s error'),
                   ('[frame finish] == HorosVRFrameCompletionFirstFrameDone', 'the first frame\'s completion'),
                   ('_hasChanged = YES;', 'the frame marks the view changed')]:
    if piece not in draw:
        failures.append('VRView drawRect: - %s (%s)' % (why, piece))
if 'WaitRendering' in draw or re.search(r'(?<!@)\btry\s*\{', draw):
    failures.append('VRView drawRect: still prepares or catches VTK itself')
if not ('catch (...)' in render and 'horosRenderWindow->Render();' in render and '[self updateLineMeasurementProjections];' in render
        and '[self computeOrientationText];' in render):
    failures.append('the render does not project the measurements, orient and render under a C++ catch')
if '*(data+0+[firstObject pwidth]) = firstPixel;' not in first or '[self applyMovieRangeGuardTo16BitVolume];' not in first:
    failures.append('the first frame no longer restores the 4D volume\'s pixels')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('frame cycles: drawFrame: begins, presents and commits through HorosPlanarFrameCycle, draws its graphics through '
      'HorosPlanarFrameGraphics, keeps every hook in order (%d lines); VRView drawRect: through HorosVRFrameCycle' % lines)
