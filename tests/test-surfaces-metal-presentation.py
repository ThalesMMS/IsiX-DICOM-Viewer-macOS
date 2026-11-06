#!/usr/bin/env python3
"""Surface rendering, the ROI volume and the SEG panel are presented by Metal.

SRView and ROIVolumeView (the SEG panel's view too) were VTKViews: VTK drew
their surfaces, text and orientation cube in OpenGL. Checked in the sources:
- HorosSceneView is an NSView that renders through the VR's own VTK window and
  renderer, and moves the camera through HorosVRInteractor;
- SRView and ROIVolumeView are HorosSceneViews;
- their files, the scene view and the scene overlay call no OpenGL, hold no
  OpenGL context and use neither VTK's Cocoa classes nor its interactor
  style, orientation marker or picker;
- the views are Swift, over the VTK adapter (IsiXVTKScene and its actors and
  overlay frame in Adapters/VTK), which these checks read with them;
- the renderer draws polylines and wireframes, and blends translucent
  surfaces as VTK 8.2's order independent translucency did, before the
  volumes.

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
    """Without comments, and without the stereo code, which is not compiled."""
    text = '\n'.join(line.split('//')[0] for line in text.split('\n')
                     if not line.lstrip().startswith('#pragma mark'))
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'#ifdef _STEREO_VISION_.*?#endif', '', text, flags=re.S)


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
             'vtkOrientationMarkerWidget', 'vtkInteractorStyle', 'GetInteractorStyle', 'GetPicker()',
             'vtkOpenGLRenderWindow', 'vtkOpenGLRenderer')
failures = []

scene = code(read('Horos/Sources/SceneView.swift'))
if not re.search(r'class HorosSceneView\s*:\s*NSView\b', scene):
    failures.append('there is no scene view on NSView')
for path, name in (('Horos/Sources/SRView.swift', 'SRView'), ('Horos/Sources/ROIVolumeView.swift', 'ROIVolumeView')):
    if not re.search(r'class %s\s*:\s*HorosSceneView\b' % name, code(read(path))):
        failures.append('%s is not a HorosSceneView' % name)

ADAPTER = 'Horos/Sources/Adapters/VTK/'
sources = ['Horos/Sources/SRView.swift', 'Horos/Sources/SRView+Camera.swift', 'Horos/Sources/SRView+Mouse.swift',
           'Horos/Sources/SRView+Points.swift', 'Horos/Sources/SRView+Export.swift', 'Horos/Sources/ROIVolumeView.swift',
           'Horos/Sources/SceneView.swift', 'Horos/Sources/SceneOverlay.swift', 'Horos/Sources/ViewerSEGSurface.swift',
           ADAPTER + 'IsiXVTKScene.h', ADAPTER + 'IsiXVTKScene.mm', ADAPTER + 'IsiXVTKSceneActors.mm',
           ADAPTER + 'IsiXVTKSceneOverlay.h', ADAPTER + 'IsiXVTKSceneOverlay.mm']
for path in sources:
    text = code(read(path))
    if not text:
        failures.append('%s is missing' % path)
        continue
    calls = sorted(set(GL_CALL.findall(text)))
    if calls:
        failures.append('%s still calls OpenGL: %s' % (path, ', '.join(calls[:6])))
    for token in FORBIDDEN:
        if token in text:
            failures.append('%s still uses %s' % (path, token))

adapter = code(read(ADAPTER + 'IsiXVTKScene.mm'))
init = block(adapter, '- (instancetype)initWithError:(NSError **)error')
if not all(re.search(r'\b%s\b>?::New\(\)' % name, init) for name in ('HorosVRRenderWindow', 'HorosVRRenderer', 'HorosVRInteractor')):
    failures.append('the scene does not render through its own window and renderer, or has no interactor')
if 'IsiXVTKScene.make()' not in scene:
    failures.append('the scene view does not make a scene of its own')
if 'scene.render()' not in block(scene, 'func renderScene()') or '_window->Render()' not in block(adapter, '- (BOOL)renderWithError:'):
    failures.append('the scene view does not render through its own window')
if 'HorosSceneOverlay.draw(' not in block(scene, '@objc func horosDrawOverlay()'):
    failures.append('the scene view does not draw its 2D actors and cube on the overlay')

renderer = code(read('Horos/Sources/Adapters/VTK/IsiXVTKVolumePresentation.mm'))
device = block(renderer, 'void HorosVRRenderer::DeviceRender()')
if 'compositeTranslucent' not in device:
    failures.append('translucent surfaces are not blended before the volumes')
draw = block(renderer, 'bool HorosVRRenderer::DrawActor(')
if 'VTK_WIREFRAME' not in draw or 'drawLinesWithVertices' not in draw:
    failures.append('wireframes and polylines are not drawn')

presenter = code(read('Horos/Sources/VRPresenter.swift'))
if 'vrMeshAccumulate' not in presenter or 'vrCompositeFragment' not in presenter:
    failures.append('translucency is not accumulated and composited as VTK\'s order independent pass did')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: surface rendering, the ROI volume and the SEG panel are presented by Metal on a scene view, '
      'with no OpenGL and none of VTK\'s interactor style, orientation marker or picker')
