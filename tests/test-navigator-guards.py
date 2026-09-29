#!/usr/bin/env python3
"""The 4D series navigator: no missing outlet, no dead branch, no WL/WW from a non-image, no division by zero (#858).

Four defects kept by the translation of the navigator to Swift (#828):

1. Navigator.xib (en and ja-JP) connected an outlet `scroller` that
   NavigatorWindowController does not have: loading the nib logged a failure
   to connect it. Every outlet of the File's Owner is now a property of the
   class, or the window NSWindowController has.
2. -displaySelectedViewInNewWindow:, inside the branch for a time line other
   than the viewer's, tested whether the time line was the viewer's: never.
3. -changeWLWW: took the notification's object for a DCMPix without checking
   it. The notification also comes with a blending DCMView, or with no image,
   and the navigator then set WL and WW 0 in every associated viewer. Now it
   leaves anything but a DCMPix alone.
4. -computeThumbnailSize divided the image's size by a factor that is zero
   without a viewer (or with an image of no size), and the offsets and the
   rotation are divided by it too. Now a zero factor leaves them as they are.

Checked in the sources and the nibs, since the navigator needs a 4D viewer
around it. `<git revision>` as an optional argument reads that revision, the
negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


def code(text):
    return '\n'.join(line.split('//')[0].rstrip() for line in text.split('\n'))


def block(text, at):
    """The braces that open at or after `at`."""
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


def method(text, selector):
    at = text.find('@objc(%s)' % selector)
    if at < 0:
        failures.append('NavigatorView no longer implements -%s; this test needs a new look' % selector)
        return ''
    return block(text, at)


# 1. The outlets of the nibs.
controller = code(read('Horos/Sources/NavigatorWindowController.swift'))
for language in ('en', 'ja-JP'):
    nib = read('Horos/Resources/%s.lproj/Navigator.xib' % language)
    owner = re.search(r'<customObject id="-2"[^>]*customClass="NavigatorWindowController">(.*?)</customObject>',
                      nib, re.S)
    if not owner:
        failures.append('%s Navigator.xib: no File\'s Owner of class NavigatorWindowController' % language)
        continue
    for outlet in re.findall(r'<outlet property="(\w+)"', owner.group(1)):
        if outlet != 'window' and not re.search(r'\bvar %s\b' % outlet, controller):
            failures.append('%s Navigator.xib connects the outlet %r, which NavigatorWindowController does not have'
                            % (language, outlet))

view = code(read('Horos/Sources/NavigatorView.swift'))

# 2. No branch that never runs.
display = method(view, 'displaySelectedViewInNewWindow:')
if display:
    other = display.find('if t != Int32(self.viewer()?.curMovieIndex() ?? 0)')
    if other < 0:
        failures.append('-displaySelectedViewInNewWindow: no longer tests the viewer\'s time line; '
                        'this test needs a new look')
    elif re.search(r'if t == Int32\(self\.viewer\(\)\?\.curMovieIndex\(\)', block(display, other)):
        failures.append('-displaySelectedViewInNewWindow: tests for the viewer\'s time line where it cannot be')

# 3. Only an image's WL and WW.
wlww = method(view, 'changeWLWW:')
if wlww:
    guard = re.search(r'guard let (\w+) = notif\?\.object as\? DCMPix else \{ return \}', wlww)
    if not guard or re.search(r'\?\.w[lw] \?\? 0', wlww):
        failures.append('-changeWLWW: takes WL and WW 0 from a notification whose object is not a DCMPix')

# 4. No division by a zero factor.
size = method(view, 'computeThumbnailSize')
if size:
    assigned = re.search(r'\bsizeFactor = (\w+)', size)
    divided = size.find('/ sizeFactor')
    guard = re.search(r'guard (\w+) > 0 else \{ return \}', size)
    if not assigned or not guard or guard.group(1) != assigned.group(1) or guard.start() > assigned.start() \
            or (divided >= 0 and divided < guard.start()):
        failures.append('-computeThumbnailSize sets or divides by a size factor it has not checked to be positive')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the navigator\'s nibs connect only its outlets, and it has no dead branch, '
      'no WL/WW from a non-image and no division by a zero factor')
