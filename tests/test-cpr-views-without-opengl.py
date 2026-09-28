#!/usr/bin/env python3
"""The CPR views letter their sections on the text overlay, not with OpenGL (#729).

The four CPR views are DCMView subclasses: since #728 their picture goes to the
view's Metal layer and their curves, handles and plane lines to the canvas. The
straightened, stretched and transverse views still lettered their transverse
sections A, B and C with StringTexture, an OpenGL texture that draws nothing
without an OpenGL context. Checked in the sources:
- no CPR view refers to StringTexture, enables an OpenGL texture target or
  holds an OpenGL context, and StringTexture is gone from the tree and project;
- each of the three views letters its sections through the DCMView label, and
  that label is a picture on the text overlay placed by the canvas transform.
The overlay's pictures are checked by test-annotation-overlay.py.

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


failures = []
views = ['CPRMPRDCMView', 'CPRStraightenedView', 'CPRStretchedView', 'CPRTransverseView']
for name in views:
    for suffix in ('.h', '.m'):
        text = code(read('Horos/Sources/' + name + suffix))
        if not text:
            failures.append('%s%s is missing' % (name, suffix))
            continue
        for token in ('StringTexture', 'GL_TEXTURE_RECTANGLE_EXT', 'NSOpenGLContext', 'CGLContextObj cgl_ctx'):
            if token in text:
                failures.append('%s%s still uses %s' % (name, suffix, token))

for path in ('Horos/Sources/StringTexture.h', 'Horos/Sources/StringTexture.m'):
    if read(path):
        failures.append('%s is still in the tree' % path)
if 'StringTexture' in read('Horos.xcodeproj/project.pbxproj'):
    failures.append('the project still builds StringTexture')

labels = {'CPRStraightenedView': 3, 'CPRStretchedView': 3, 'CPRTransverseView': 1}
for name, count in labels.items():
    drawing = block(code(read('Horos/Sources/%s.m' % name)), '- (void)subDrawRect:')
    found = len(re.findall(r'\[self horosDrawLabel: *\w+ at:', drawing))
    if found != count:
        failures.append('%s letters %d of its %d sections through the overlay label' % (name, found, count))
    if 'horosLabelText:' not in drawing:
        failures.append('%s does not make its letters as overlay text' % name)

view = code(read('Horos/Sources/DCMView.m'))
label = block(view, '- (void) horosDrawLabel:')
if 'horosAnnotationRect:' not in label or 'addText:' not in label:
    failures.append('the DCMView label is not a picture on the text overlay placed by the canvas transform')
if 'HorosAnnotationText textForString:' not in block(view, '- (HorosAnnotationText*) horosLabelText:'):
    failures.append('the DCMView label text is not an overlay text')
if 'horosDrawLabel:' not in read('Horos/Sources/DCMView.h'):
    failures.append('DCMView.h does not declare the label its subclasses draw')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the CPR views letter their sections on the text overlay, with no OpenGL texture or context')
