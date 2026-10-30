#!/usr/bin/env python3
"""The 3D view is presented by Metal, without VTK's OpenGL window.

VRView was a VTKView, a vtkCocoaGLView: VTK drew the ray-cast image, the text,
the orientation cube and the widgets in OpenGL, and its interactor moved the
camera and the crop box. Checked in the sources:
- VRView is an NSView and renders through HorosVRRenderWindow and
  HorosVRRenderer, subclasses of VTK's generic window and renderer, not of its
  OpenGL ones; the frame goes to a CAMetalLayer through HorosVRPresenter;
- the renderer draws the surfaces, casts each volume and draws its image,
  creating VTK's headlight when there is no light; the ray-cast mapper no
  longer draws its image in OpenGL;
- the window's pixel and depth reads are the presenter's frame;
- VRView, its previews, endoscopy, overlay, interaction and presentation call
  no OpenGL, hold no OpenGL context and use neither VTK's Cocoa classes nor its
  interactor, box widget, orientation marker or picker;
- on screen, the view renders with Metal whatever engine is asked, and the
  'p' key picks 3D points by ray.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        try:
            return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path],
                                           stderr=subprocess.DEVNULL).decode('latin1')
        except subprocess.CalledProcessError:
            return ''
    full = root / path
    return full.read_bytes().decode('latin1') if full.exists() else ''


def code(text):
    """Without comments, so that what they recall is not taken for a call."""
    text = '\n'.join(line.split('//')[0] for line in text.split('\n'))
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


GL_CALL = re.compile(r'(?<![A-Za-z0-9_])(gl[A-Z]\w*|CGL[A-Z]\w*)\s*\(')
FORBIDDEN = ('NSOpenGL', 'openGLContext', 'CGLContextObj', 'OpenGL/', 'vtkCocoa', '_cocoaRenderWindow',
             'vtkBoxWidget', 'vtkOrientationMarkerWidget', 'vtkInteractorStyle', 'GetInteractor()', 'GetPicker()',
             'vtkOpenGLRenderWindow', 'vtkOpenGLRenderer')
failures = []

header = code(read('Horos/Sources/VRView.h'))
# The class is Swift (VRView.swift) where VRView.m is gone; a revision that
# still has VRView.m is checked the former way.
view = code(read('Horos/Sources/VRView.m'))
swift_class = '' if view else code(read('Horos/Sources/VRView.swift'))
if not re.search(r'@interface VRView\s*:\s*NSView\b', header) and not re.search(r'public class VRView: NSView\b', swift_class):
    failures.append('VRView is not an NSView')
if 'horosPresenter' not in header + swift_class:
    failures.append('VRView has no horosPresenter')
# The view's window and renderer are its VTK adapter's (IsiXVTKVolumeView).
volume_objects = code(read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeViewInternal.hpp'))
for name in ('HorosVRRenderWindow *horosRenderWindow', 'HorosVRRenderer *horosRenderer'):
    if name not in volume_objects:
        failures.append('VRView has no %s' % name.split('*')[1])

# The window and the renderer are the VTK adapter's.
presentation = code(read('Horos/Sources/Adapters/VTK/IsiXVTKVolumePresentation.hpp'))
if not re.search(r'class HorosVRRenderWindow\s*:\s*public vtkRenderWindow\b', presentation):
    failures.append('the 3D view does not render through a window of its own on vtkRenderWindow')
if not re.search(r'class HorosVRRenderer\s*:\s*public vtkRenderer\b', presentation):
    failures.append('the 3D view does not render with a renderer of its own on vtkRenderer')

# The preset previews and the endoscopy's view are Swift subclasses of VRView;
# the fly-through curves and the ROI volumes' actors reach VTK through the adapter.
class_sources = ['Horos/Sources/VRView.m'] if view else ['Horos/Sources/VRView.swift', 'Horos/Sources/VRView+CAPI.m']
sources = [*class_sources, 'Horos/Sources/VRView.h', 'Horos/Sources/VRView+Render.swift',
           'Horos/Sources/VRView+Capture.swift', 'Horos/Sources/VRPresetPreview.swift',
           'Horos/Sources/EndoscopyVRView.swift', 'Horos/Sources/Adapters/VTK/IsiXVTKOverlay.mm',
           'Horos/Sources/Adapters/VTK/IsiXVTKCurves.mm', 'Horos/Sources/Adapters/VTK/IsiXVTKRendererProps.mm',
           'Horos/Sources/Adapters/VTK/IsiXVTKVolumeInteraction.mm', 'Horos/Sources/Adapters/VTK/IsiXVTKVolumeInteraction.hpp',
           'Horos/Sources/Adapters/VTK/IsiXVTKVolumePresentation.mm', 'Horos/Sources/Adapters/VTK/IsiXVTKVolumePresentation.hpp',
           'Horos/Sources/Adapters/VTK/IsiXVTKVolumeScene.mm', 'Horos/Sources/Adapters/VTK/IsiXVTKVolumeView.mm',
           'Horos/Sources/Adapters/VTK/IsiXVTKVolumeViewInternal.hpp', 'Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm',
           'Horos/Sources/Adapters/VTK/IsiXVTKVolumeCamera.mm', 'Horos/Sources/Adapters/VTK/IsiXVTKVolumeCrop.mm',
           'Horos/Sources/Adapters/VTK/IsiXVTKVolumeActors.mm']
for path in sources:
    text = code(read(path))
    if not text:
        failures.append('%s is missing' % path)
        continue
    # The stereo code is not compiled.
    text = re.sub(r'#ifdef _STEREO_VISION_.*?#endif', '', text, flags=re.S)
    calls = sorted(set(GL_CALL.findall(text)))
    if calls:
        failures.append('%s still calls OpenGL: %s' % (path, ', '.join(calls[:6])))
    for token in FORBIDDEN:
        if token in text:
            failures.append('%s still uses %s' % (path, token))


def swift_block(text, signature):
    """A method of a Swift extension of VRView: to the line that closes it at
    the extension's indentation; '' when absent."""
    at = text.find(signature)
    return text[at:text.index('\n    }\n', at)] if at >= 0 else ''

if view:
    init = block(view, '-(id)initWithFrame:(NSRect)frame')
    makes, layer = '[IsiXVTKVolumeView volumeViewWithError: &error]', 'wantsLayer'
else:
    init = swift_block(swift_class, 'public override init(frame: NSRect)')
    makes, layer = 'try IsiXVTKVolumeView.make()', 'wantsLayer = true'
volume_view = code(read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeView.mm'))
made = block(volume_view, '+ (instancetype)volumeViewWithError:(NSError **)error')
if makes not in init or 'HorosVRRenderWindow::New()' not in made or \
        'HorosVRRenderer::New()' not in made or layer not in init:
    failures.append('VRView does not make its own window and renderer and a layer')
# The frame and its layer are Swift (VRView+Render.swift), an extension of VRView.
view_render = code(read('Horos/Sources/VRView+Render.swift'))
draw = swift_block(view_render, 'public override func draw(_ aRect: NSRect)')
# drawRect: renders through -horosRenderFrame, under its frame cycle.
render = swift_block(view_render, 'func horosRenderFrame() -> Bool')
if 'self.horosRenderFrame()' not in draw or 'self.horos_vtk.renderWindow()' not in render or \
        'o->horosRenderWindow->Render()' not in block(volume_view, '- (BOOL)renderWindowWithError:') or 'super.draw(' in draw:
    failures.append('drawRect: does not render through the view\'s own window')
if 'CAMetalLayer()' not in swift_block(view_render, 'func horosPictureLayer() -> CAMetalLayer?') or \
        'presentsWithTransaction = true' not in view_render:
    failures.append('the frame is not shown in a CAMetalLayer with the overlay\'s transaction')
# The engines are Swift (VRView+Engine.swift), an extension of VRView.
view_engine = code(read('Horos/Sources/VRView+Engine.swift'))
if 'drawnEngineFor:' not in block(view, '- (void) setEngine: (long) newEngine showWait:(BOOL) showWait') and \
        'VRInteractionGeometry.drawnEngine(for:' not in swift_block(view_engine, 'func setEngine(_ newEngine: Int, showWait: Bool)'):
    failures.append('an engine other than Metal can still be asked to draw on screen')
# The keys VTK's interactor answered are Swift (VRView+Gestures.swift).
view_gestures = code(read('Horos/Sources/VRView+Gestures.swift'))
if 'horosPick3DPointAtX:' not in block(view, '- (void) horosVTKKeyDown:(NSEvent *) event') and \
        'horosPick3DPointAt(x:' not in swift_block(view_gestures, 'func horosVTKKeyDown(_ event: NSEvent)'):
    failures.append('the \'p\' key does not pick 3D points by ray')

renderer = code(read('Horos/Sources/Adapters/VTK/IsiXVTKVolumePresentation.mm'))
device = block(renderer, 'void HorosVRRenderer::DeviceRender()')
for needle, what in (('RenderVolumetricGeometry', 'cast the volumes'), ('DrawVolumeImage', 'draw the ray-cast images'),
                     ('DrawActor', 'draw the surfaces'), ('CreateLight', 'make VTK\'s headlight'),
                     ('NumberOfPropsRendered', 'let the rays stop at the surfaces')):
    if needle not in device:
        failures.append('the renderer does not %s' % what)
if 'readDepthWithX:' not in block(renderer, 'int HorosVRRenderWindow::GetZbufferData(int x, int y, int x2, int y2, float *z)'):
    failures.append('depth reads are not the presenter\'s frame')
if 'readPixelsWithX:' not in block(renderer, 'NSData *HorosVRRenderWindow::Read('):
    failures.append('pixel reads are not the presenter\'s frame')

mapper = code(read('Horos/Sources/Adapters/VTK/vtkHorosFixedPointVolumeRayCastMapper.cxx'))
if 'RenderTexture' in block(mapper, 'void vtkHorosFixedPointVolumeRayCastMapper::DisplayRenderedImage('):
    failures.append('the ray-cast mapper still draws its image in OpenGL')

presenter = code(read('Horos/Sources/VRPresenter.swift'))
if 'CAMetalLayer' not in presenter or 'nextDrawable' not in presenter:
    failures.append('there is no Metal presenter for the 3D view')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the 3D view, its previews and endoscopy are presented by Metal through a VTK window that draws nothing, '
      'with no OpenGL and none of VTK\'s interactor, widgets or picker')
