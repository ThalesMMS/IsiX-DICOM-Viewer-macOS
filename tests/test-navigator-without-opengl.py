#!/usr/bin/env python3
"""The Navigator and the other windows outside the DCMView draw without OpenGL (#730).

The NavigatorView was an NSOpenGLView: its thumbnails were intensity textures
modulated by a grey or white colour, the frames of the selected images were
smooth line loops, the scroll bars blended polygons, and the ROIs a canvas
laid over them. Calcium Scoring and the 3D segmentation drew their seed on
OpenGL's objects notification, the window class under OSIWindow is named for
OpenGL, and the DCM framework had an OpenGL view. Checked in the sources:
- NavigatorView.h declares an NSView and no OpenGL type;
- NavigatorView.m calls no OpenGL function and holds no OpenGL context; its
  frame is a canvas with its own transform, the thumbnails are the canvas's
  intensity pictures in the grey or white they were modulated by, and the
  canvas is shown over the visible rect;
- Calcium Scoring, the 3D segmentation and N2OpenGLViewWithSplitsWindow call
  no OpenGL and hold no OpenGL context, and the DCM framework's OpenGL view is
  gone.
The canvas's pictures are checked by test-roi-canvas.py.

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
OPENGL_TOKENS = ('NSOpenGL', 'openGLContext', 'CGLContextObj', 'OpenGL/', 'GLuint')
failures = []

header = code(read('Horos/Sources/NavigatorView.h'))
if not re.search(r'@interface NavigatorView\s*:\s*NSView\b', header):
    failures.append('NavigatorView is not an NSView')
for token in OPENGL_TOKENS:
    if token in header:
        failures.append('NavigatorView.h still carries %s' % token)

sources = ['Horos/Sources/NavigatorView.m', 'Horos/Sources/CalciumScoringWindowController.m',
           'Horos/Sources/ITKSegmentation3DController.m', 'Nitrogen/Sources/N2OpenGLViewWithSplitsWindow.m',
           'Nitrogen/Sources/N2OpenGLViewWithSplitsWindow.h']
for path in sources:
    text = code(read(path))
    if not text:
        failures.append('%s is missing' % path)
        continue
    calls = sorted(set(GL_CALL.findall(text)))
    if calls:
        failures.append('%s still calls OpenGL: %s' % (path, ', '.join(calls[:6])))
    for token in OPENGL_TOKENS:
        if token in text:
            failures.append('%s still uses %s' % (path, token))
if read('DCM Framework/OpenGLView.m') or read('DCM Framework/OpenGLView.h'):
    failures.append('the DCM framework still has its OpenGL view')

navigator = code(read('Horos/Sources/NavigatorView.m'))
draw = block(navigator, '- (void)drawRect:')
if 'setModelview:' not in draw or 'beginFrameWidth:' not in draw:
    failures.append('the Navigator does not draw its frame on a canvas with its own transform')
if 'drawIntensity:' not in draw:
    failures.append('the thumbnails are not the canvas\'s intensity pictures')
if not re.search(r'roiColor4f \(0\.5f, 0\.5f, 0\.5f, 1\.0f\)', draw):
    failures.append('the thumbnails that are not highlighted are not modulated by grey')
if 'presentCanvasIn:' not in draw or 'CGContextDrawImage' not in block(navigator, '- (void)presentCanvasIn:'):
    failures.append('the canvas is not shown over the visible rect')
for name in ('Horos/Sources/CalciumScoringWindowController.m', 'Horos/Sources/ITKSegmentation3DController.m'):
    text = code(read(name))
    if 'HorosDrawObjectsCanvasNotification' not in text or 'OsirixDrawObjectsNotification' in text:
        failures.append('%s does not draw its seed on the canvas' % name)

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the Navigator is an NSView drawn on the canvas, and Calcium Scoring, the 3D segmentation '
      'and the window under OSIWindow use no OpenGL')
