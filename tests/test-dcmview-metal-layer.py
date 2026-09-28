#!/usr/bin/env python3
"""The viewer is an NSView presented by Metal, with no OpenGL in it (#728).

The DCMView was an NSOpenGLView: the planar Metal frame went through an
IOSurface into OpenGL, the MPR, orthogonal, endoscopy, CPR and preview views
drew legacy OpenGL textures, the graphics were OpenGL immediate mode, captures
read the OpenGL front buffer and the public API carried OpenGL types. Checked
in the sources:
- DCMView.h declares an NSView and includes no OpenGL header, and its API
  carries no OpenGL type;
- the view and its subclasses call no OpenGL function and hold no OpenGL
  context;
- the picture is drawn into a CAMetalLayer presented with the frame's
  transaction, for every view, with or without a volume session;
- a capture and the magnifying lens read the picture back from Metal;
- the planar host renderer imports no OpenGL, and nothing posts
  OsirixDrawObjectsNotification, whose observers draw on the canvas.
The pixels are checked by test-planar-host-renderer.py.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
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
    return (root / path).read_bytes().decode('latin1')


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
            return text[opening:index + 1]
    return ''


failures = []
header = code(read('DCMView.h'))
if not re.search(r'@interface DCMView\s*:\s*NSView\b', header):
    failures.append('DCMView is not an NSView')
for token in ('OpenGL/', 'GLuint', 'GLubyte', 'CGLContextObj', 'NSOpenGL'):
    if token in header:
        failures.append('DCMView.h still carries %s' % token)

GL_CALL = re.compile(r'(?<![A-Za-z0-9_])(gl[A-Z]\w*|CGL[A-Z]\w*)\s*\(')
family = ['DCMView.m', 'MPRDCMView.m', 'OrthogonalMPRView.m', 'OrthogonalMPRPETCTView.m', 'EndoscopyMPRView.m',
          'PreviewView.m', 'CPRMPRDCMView.m', 'CPRStraightenedView.m', 'CPRStretchedView.m', 'CPRTransverseView.m']
for name in family:
    text = code(read(name))
    if not text:
        failures.append('%s is missing' % name)
        continue
    calls = sorted(set(GL_CALL.findall(text)))
    if calls:
        failures.append('%s still calls OpenGL: %s' % (name, ', '.join(calls[:6])))
    for token in ('openGLContext', 'CGLContextObj', 'withContext:', 'fontListGL'):
        if token in text:
            failures.append('%s still uses %s' % (name, token))

view = code(read('DCMView.m'))
picture = block(view, '- (CAMetalLayer *) horosPictureLayer')
if '[CAMetalLayer layer]' not in picture or 'presentsWithTransaction = YES' not in picture:
    failures.append('the picture is not a CAMetalLayer presented with the frame\'s transaction')
frame = block(view, '- (void) drawFrame:(NSRect)aRect')
if 'horosDrawPlanarInLayer: [self horosPictureLayer]' not in frame:
    failures.append('the frame does not draw its picture into its Metal layer')
if 'OsirixDrawObjectsNotification' in frame:
    failures.append('the frame still posts OsirixDrawObjectsNotification')
if 'horosPlanarPixelsWidth:' not in view:
    failures.append('a capture does not read the picture back from Metal')
if 'horosPlanarPixelsSide:' not in block(view, '- (void) drawMagnifyingLens'):
    failures.append('the magnifying lens is not drawn from the picture Metal draws')

bridge = code(read('PlanarHostBridge.m'))
draw = block(bridge, '- (BOOL)horosDrawPlanarInLayer:')
if not draw or 'is2DViewer' in draw:
    failures.append('the picture is not drawn for every view')
if 'HorosPlanarSession(self)' not in draw:
    failures.append('a view without a volume session does not draw')
host = read('PlanarHostRenderer.swift')
if 'import OpenGL' in host or 'CGLTexImageIOSurface2D' in host:
    failures.append('the planar host renderer still hands its frame to OpenGL')
for name in ('ITKSegmentation3DController.m', 'CalciumScoringWindowController.m', 'ViewerSEGSurface.mm'):
    text = code(read(name))
    if 'OsirixDrawObjectsNotification' in text or 'HorosDrawObjectsCanvasNotification' not in text:
        failures.append('%s does not draw its overlay on the canvas' % name)

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: DCMView is an NSView with no OpenGL; every view presents its picture with Metal, '
      'captures and the lens read it back, and the overlays draw on the canvas')
