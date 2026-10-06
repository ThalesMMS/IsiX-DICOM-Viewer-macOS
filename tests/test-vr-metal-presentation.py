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
if not re.search(r'@interface VRView\s*:\s*NSView\b', header):
    failures.append('VRView is not an NSView')
for name in ('horosRenderWindow', 'horosRenderer', 'horosPresenter'):
    if name not in header:
        failures.append('VRView has no %s' % name)

presentation = code(read('Horos/Sources/VRPresentation.h'))
if not re.search(r'class HorosVRRenderWindow\s*:\s*public vtkRenderWindow\b', presentation):
    failures.append('the 3D view does not render through a window of its own on vtkRenderWindow')
if not re.search(r'class HorosVRRenderer\s*:\s*public vtkRenderer\b', presentation):
    failures.append('the 3D view does not render with a renderer of its own on vtkRenderer')

sources = ['Horos/Sources/VRView.mm', 'Horos/Sources/VRView.h', 'Horos/Sources/VRPresetPreview.mm',
           'Horos/Sources/EndoscopyVRView.mm', 'Horos/Sources/VRView+Overlay.mm', 'Horos/Sources/VRInteraction.mm',
           'Horos/Sources/VRInteraction.h', 'Horos/Sources/VRPresentation.mm', 'Horos/Sources/VRPresentation.h']
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

view = code(read('Horos/Sources/VRView.mm'))
init = block(view, '-(id)initWithFrame:(NSRect)frame')
if 'HorosVRRenderWindow::New()' not in init or 'HorosVRRenderer::New()' not in init or 'wantsLayer' not in init:
    failures.append('VRView does not make its own window and renderer and a layer')
draw = block(view, '- (void) drawRect:(NSRect)aRect')
# drawRect: renders through -horosRenderFrame, under its frame cycle.
render = block(view, '- (BOOL) horosRenderFrame')
if '[self horosRenderFrame]' not in draw or 'horosRenderWindow->Render()' not in render or '[super drawRect:' in draw:
    failures.append('drawRect: does not render through the view\'s own window')
if 'CAMetalLayer' not in block(view, '- (CAMetalLayer *) horosPictureLayer') or 'presentsWithTransaction' not in view:
    failures.append('the frame is not shown in a CAMetalLayer with the overlay\'s transaction')
if 'drawnEngineFor:' not in block(view, '- (void) setEngine: (long) newEngine showWait:(BOOL) showWait'):
    failures.append('an engine other than Metal can still be asked to draw on screen')
if 'horosPick3DPointAtX:' not in block(view, '- (void) horosVTKKeyDown:(NSEvent *) event'):
    failures.append('the \'p\' key does not pick 3D points by ray')

renderer = code(read('Horos/Sources/VRPresentation.mm'))
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

mapper = code(read('Horos/Sources/vtkHorosFixedPointVolumeRayCastMapper.cxx'))
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
