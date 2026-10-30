#!/usr/bin/env python3
"""A DCMView frame and a VRView frame go through their cycles.

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

The drawing is read in DCMView+Drawing.swift, or in DCMView.m in revisions
before it moved to Swift. `<git revision>` as an optional argument reads the
sources from that revision: the negative control, which fails before the frame
cycles.
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
swift = read('DCMView+Drawing.swift')
if swift:
    frame = code(block(swift, '@objc(drawFrame:)'))
else:
    frame = code(block(view, '- (void) drawFrame:(NSRect)aRect'))
presenter = code(read('PlanarFramePresenter.swift'))
if not frame:
    raise SystemExit('drawFrame: is gone')

# --- drawFrame: the order of the frame ----------------------------------------
swift_order = [
    'PlanarFrameCycle.begin(in: self',
    'drawingTry({',
    'self.horos_drawingFrameRect = aRect',
    'frame.presentPicture(in: self, layer: self.horosPictureLayer()',
    'frame.imageDrawn()',
    'PlanarFrameGraphics.drawHighlight(',
    'self.horosDrawCLUTBars(clutBars, scale: sf)',
    'PlanarFrameGraphics.beginBorders(size:',
    'PlanarFrameGraphics.drawWindowBorder(size:',
    'PlanarFrameGraphics.drawOverflow(image:',
    'PlanarFrameGraphics.drawTileBorder(size:',
    'PlanarFrameGraphics.enterImage(rotation: self.horos_rotation, origin: self.horos_origin',
    'ROICanvas.current?.resetFrameState()',
    'r.draw(self.horos_scaleValue',
    'self.drawPendingLength()',
    'OSIEnvironment.shared()?.drawDCMView(self)',
    'self.draw2DPointMarker()',
    'NSNotification.Name.HorosDrawObjectsCanvas',
    'self.subDraw(aRect)',
    'PlanarFrameGraphics.drawPatientCrosshair(',
    'self.horosDrawReferenceLines(scale: sf)',
    'PlanarFrameGraphics.beginText(size:',
    'PlanarFrameGraphics.drawRuler(rect:',
    'self.drawTextualData(self.horos_drawingFrameRect, annotations)',
    'self.horosDrawROILabels(is2DViewer)',
    'self.drawRepulsorToolArea()',
    'self.drawROISelectorRegion()',
    'add(box: box, rect: r)',
    'self.drawMagnifyingLens()',
    'self.drawRectAnyway(aRect)',
    'frame.drawNotice(in: self',
    'logDrawingException(exception, "-[DCMView drawFrame:]")',
    'frame.commit(index: Int(self.horos_curImage))',
    'self._checkHasChanged(true)',
]
objc_order = [
    '[HorosPlanarFrameCycle beginInView: self',
    '@try',
    'drawingFrameRect = aRect;',
    '[frame presentPictureInView: self layer: [self horosPictureLayer]',
    '[frame imageDrawn];',
    '[HorosPlanarFrameGraphics drawHighlight:',
    '[self horosDrawCLUTBars: clutBars scale: sf];',
    '[HorosPlanarFrameGraphics beginBordersSize:',
    '[HorosPlanarFrameGraphics drawWindowBorderSize:',
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
for piece in (swift_order if swift else objc_order):
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
if swift:
    references = code(block(swift, '@objc(horosDrawReferenceLinesScale:)'))
    hook = code(block(swift, 'private func drawCrossLinesHook('))
    # The hook sends -drawCrossLines:perpendicular: through the runtime
    # (DCMView+CAPI.m), so that a subclass's override is the one called.
    through = 'self.drawCrossLinesHook(sliceFromTo, perpendicular: true)' in references and \
        ('self.drawCrossLines($0, perpendicular: perpendicular)' in hook or
         'self.arrayMessages.drawCrossLines(line, perpendicular: perpendicular)' in hook)
    labels = code(block(swift, '@objc(horosDrawROILabels:)'))
    released = 'r.drawTextualData()' in labels and 'self.horos_rectArray = nil' in labels
else:
    references = code(block(view, '- (void) horosDrawReferenceLinesScale:(float) sf'))
    through = '[self drawCrossLines: sliceFromTo perpendicular: YES];' in references
    labels = code(block(view, '- (void) horosDrawROILabels:(BOOL) is2DViewer'))
    released = '[r drawTextualData];' in labels and 'rectArray = nil;' in labels
if not through:
    failures.append('the reference lines no longer go through the -drawCrossLines: hook')
if not released:
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
    # The view's planar host (DCMView+PlanarHost.swift).
    for piece in ('view.horosDrawPlanar(in: layer, inverted: inverted)', 'view.horosClear(layer, white: whiteBackground && hasImage',
                  'overlay.commit(inverted: inverted, scale: scale)', 'trace?.endDraw(span, index: index)',
                  'view.horosPlanarFallbackReason()'):
        if piece not in cycle:
            failures.append('the frame cycle does not do its part: ' + piece)
    if '@MainActor' not in presenter.split('public final class PlanarFrameCycle')[0].rsplit('///', 1)[-1] + \
            presenter[presenter.find('public final class PlanarFrameCycle') - 60:presenter.find('public final class PlanarFrameCycle')]:
        failures.append('the frame cycle is not isolated to the main actor')

# --- VRView ----------------------------------------------------------------------
vr = read('VRView.m')
# The frame is Swift (VRView+Render.swift), an extension of VRView; a revision
# whose frame is still in VRView.m is read as Objective-C.
swift_frame = '- (void) drawRect:(NSRect)aRect' not in vr


def swift_block(text, signature):
    """A method of a Swift extension: to the line that closes it at the extension's indentation."""
    at = text.find(signature)
    return text[at:text.index('\n    }\n', at)] if at >= 0 else ''


if swift_frame:
    view_render = read('VRView+Render.swift')
    draw = code(swift_block(view_render, 'public override func draw(_ aRect: NSRect)'))
    render = code(swift_block(view_render, 'func horosRenderFrame() -> Bool'))
    first = code(swift_block(view_render, 'func horosFinishFirstFrame()'))
    draw_pieces = [('VRFrameCycle.begin(firstFrame: self.horos_firstTime)', 'the cycle begins with the first-frame flag'),
                   ('frame.render(succeeded: self.horosRenderFrame(), errorShown: self.horos_alertDisplayed)',
                    'the render\'s outcome is the cycle\'s'),
                   ('#selector(self.displayVTKError)', 'a failure is reported by the view\'s error'),
                   ('frame.finish() == .firstFrameDone', 'the first frame\'s completion'),
                   ('self.horos_hasChanged = true', 'the frame marks the view changed')]
    render_pieces = ('rendered = (try? self.horos_vtk.renderWindow()) != nil', 'self.updateLineMeasurementProjections()',
                     'self.computeOrientationText()')
    first_pieces = ('data[0 + width] = horos_firstPixel', 'data[1 + width] = horos_secondPixel',
                    'applyMovieRangeGuardTo16BitVolume()')
else:
    draw = code(block(vr, '- (void) drawRect:(NSRect)aRect'))
    render = code(block(vr, '- (BOOL) horosRenderFrame'))
    first = code(block(vr, '- (void) horosFinishFirstFrame'))
    draw_pieces = [('[HorosVRFrameCycle beginFirstFrame: firstTime]', 'the cycle begins with the first-frame flag'),
                   ('[frame renderSucceeded: [self horosRenderFrame] errorShown: alertDisplayed]',
                    'the render\'s outcome is the cycle\'s'),
                   ('@selector( displayVTKError)', 'a failure is reported by the view\'s error'),
                   ('[frame finish] == HorosVRFrameCompletionFirstFrameDone', 'the first frame\'s completion'),
                   ('_hasChanged = YES;', 'the frame marks the view changed')]
    render_pieces = ('return [vtk renderWindowWithError: nil];', '[self updateLineMeasurementProjections];',
                     '[self computeOrientationText];')
    first_pieces = ('*(data+0+[firstObject pwidth]) = firstPixel;', '[self applyMovieRangeGuardTo16BitVolume];')
for piece, why in draw_pieces:
    if piece not in draw:
        failures.append('VRView drawRect: - %s (%s)' % (why, piece))
if 'WaitRendering' in draw or re.search(r'(?<!@)\btry\s*\{', draw):
    failures.append('VRView drawRect: still prepares or catches VTK itself')
# The render itself is the VTK adapter's, which catches what VTK throws.
adapter = read('Adapters/VTK/IsiXVTKVolumeView.mm')
render_window = code(block(adapter, '- (BOOL)renderWindowWithError:'))
if not (all(piece in render for piece in render_pieces)
        and 'IsiXVTKVolumeTry(error, "render", {}, [&] { o->horosRenderWindow->Render(); });' in render_window):
    failures.append('the render does not project the measurements, orient and render under a C++ catch')
if not all(piece in first for piece in first_pieces):
    failures.append('the first frame no longer restores the 4D volume\'s pixels')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('frame cycles: drawFrame: begins, presents and commits through HorosPlanarFrameCycle, draws its graphics through '
      'HorosPlanarFrameGraphics, keeps every hook in order (%d lines); VRView drawRect: through HorosVRFrameCycle' % lines)
