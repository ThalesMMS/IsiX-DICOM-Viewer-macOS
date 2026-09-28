#!/usr/bin/env python3
"""The 3D views' stereo, ported to the Metal presentation (#734).

The former stereo mode (nine Objective-C files behind _STEREO_VISION_, never
compiled) is gone; the Stereo menu of VR.xib and SR.xib drives the new one.
Checked in the sources:
- no _STEREO_VISION_ block and none of the former files, in the tree or the project;
- every Stereo menu item of the nibs has a mode of HorosStereoMode for its tag
  and an action the views implement; the geometry window's buttons have one
  the controllers implement, and the outlets the nibs connect are declared;
- each eye is rendered as VTK asks for it: the renderer turns the camera's
  stereo on, surfaces are drawn with the projection that carries the eye's
  shear, and the Metal ray cast receives that shear with the camera;
- two-buffer stereo shows the right eye in a picture of its own, which the
  window's right buffer reads and captures put beside the left eye.

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


def files():
    if revision:
        out = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision, 'Horos'])
        return out.decode().split('\n')
    return [str(p.relative_to(root)) for p in (root / 'Horos').rglob('*') if p.is_file()]


def code(text):
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
tree = files()
FORMER = ('StereoVision', 'VTKStereoVRView', 'VTKStereoSRView')
former = sorted(f for f in tree if any(name in f for name in FORMER))
if former:
    failures.append('the former stereo files are still there: %s' % ', '.join(former[:4]))
project = read('Horos.xcodeproj/project.pbxproj')
if any(name in project for name in FORMER):
    failures.append('the project still lists the former stereo files')
sources = [f for f in tree if re.search(r'\.(h|m|mm|swift|pch)$', f)]
guarded = sorted(f for f in sources if '_STEREO_VISION_' in code(read(f)))
if guarded:
    failures.append('_STEREO_VISION_ is still used in %s' % ', '.join(guarded[:4]))

stereo = code(read('Horos/Sources/StereoPresentation.swift'))
if 'StereoPresentation.swift' not in project:
    failures.append('StereoPresentation.swift is not in the project')
modes = dict((name, int(value)) for name, value in re.findall(r'(\w+) = (\d)', block(stereo, 'public enum StereoMode')))
if modes != {'off': 0, 'anaglyph': 1, 'redBlue': 2, 'interlaced': 3, 'twoScreens': 4, 'oneScreen': 5}:
    failures.append('the stereo modes do not follow the menu tags: %s' % modes)

vr, scene = code(read('Horos/Sources/VRView.mm')), code(read('Horos/Sources/SceneView.mm'))
controllers = {'VR': code(read('Horos/Sources/VRController.mm')), 'SR': code(read('Horos/Sources/SRController.mm'))}
headers = {'VR': code(read('Horos/Sources/VRController.h')), 'SR': code(read('Horos/Sources/SRController.h'))}
views = {'VR': vr, 'SR': scene}
for nib in ('en.lproj', 'ja-JP.lproj'):
    for kind in ('VR', 'SR'):
        xib = read('Horos/Resources/%s/%s.xib' % (nib, kind))
        items = re.findall(r'<menuItem ([^>]*)>\s*(?:<modifierMask[^>]*/>\s*)?<connections>\s*<action selector="SwitchStereoMode:"', xib)
        tags = sorted(int((re.search(r'tag="(\d+)"', item) or [0, 0])[1]) for item in items)
        if tags != [0, 1, 2, 3, 4, 5]:
            failures.append('%s/%s.xib: the Stereo menu items are %s' % (nib, kind, tags))
        for selector in set(re.findall(r'<action selector="([^"]+)"', xib)) & {'SwitchStereoMode:', 'invertedSides:'}:
            name = selector.rstrip(':')
            if not re.search(r'-\s*\(IBAction\)\s*%s\s*:' % name, views[kind]):
                failures.append('%s/%s.xib sends %s, which the view does not implement' % (nib, kind, selector))
        if 'ApplyGeometrieSettings:' in xib and not re.search(r'-\s*\(IBAction\)\s*ApplyGeometrieSettings\s*:', controllers[kind]):
            failures.append('%s/%s.xib sends ApplyGeometrieSettings:, which the controller does not implement' % (nib, kind))
        for outlet in ('stereoIconView', 'distanceValue', 'heightValue', 'eyeDistance', kind + 'GeometrieSettingsWindow'):
            if 'property="%s"' % outlet in xib and not re.search(r'\*\s*%s\b' % outlet, headers[kind]):
                failures.append('%s/%s.xib connects %s, which the controller does not declare' % (nib, kind, outlet))
for kind, source in views.items():
    if 'horosSetStereoScreenHeight' not in source or 'HorosSetStereoMode(' not in source:
        failures.append('the %s view does not apply the Stereo menu and its geometry' % kind)
    if 'stereoIconView' not in block(controllers[kind], 'StereoIdentifier]'):
        failures.append('the %s toolbar does not show the Stereo menu' % kind)

presentation = code(read('Horos/Sources/VRPresentation.mm'))
device = block(presentation, 'void HorosVRRenderer::DeviceRender()')
if 'GetStereoRender()' not in device:
    failures.append('the renderer does not turn the camera\'s stereo on as VTK\'s OpenGL camera did')
draw = block(presentation, 'bool HorosVRRenderer::DrawActor(')
if 'GetCompositeProjectionTransformMatrix' in draw or 'GetProjectionTransformMatrix' not in draw:
    failures.append('surfaces are not drawn with the projection that carries the eye')
for method in ('void HorosVRRenderWindow::StereoMidpoint()', 'void HorosVRRenderWindow::StereoRenderComplete()'):
    if 'EyePresenter' not in block(presentation, method):
        failures.append('%s does not keep the other eye' % method)
if 'EyePresenter' not in block(presentation, 'NSData *HorosVRRenderWindow::Read('):
    failures.append('the window\'s right buffer is not the right eye')
if 'HorosCopyVRStereoFramebuffer' not in vr or 'HorosCopyVRStereoFramebuffer' not in code(read('Horos/Sources/SRView.mm')):
    failures.append('captures do not put the two eyes side by side')

renderer = code(read('Horos/Sources/VolumeMetalRenderer.swift'))
if 'eyeShear' not in renderer or 'p.eye.w' not in renderer:
    failures.append('the Metal ray cast does not take the eye\'s shear')
snapshot = block(code(read('Horos/Sources/VRHostBridge.mm')), '- (NSDictionary *)horosVolumeCameraSnapshot {')
if 'GetLeftEye()' not in snapshot or 'GetEyeAngle()' not in snapshot:
    failures.append('the volume camera does not carry the eye VTK renders')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the Stereo menu drives the Metal presentation; each eye is rendered and shown as VTK asks, '
      'and the former stereo files are gone')
