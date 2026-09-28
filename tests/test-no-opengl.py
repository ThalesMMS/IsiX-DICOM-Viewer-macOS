#!/usr/bin/env python3
"""The application builds and links without OpenGL (#735).

Checked in the sources:
- the OpenGL classes are gone from the tree and the project: GLString,
  StringTexture, NSFont_OpenGL, OpenGLScreenReader, VTKView and the former
  stereo views;
- OpenGL.framework is not linked, and no source includes OpenGL's headers,
  uses its contexts or calls a gl* or CGL* function;
- VTK is configured with no rendering backend and without its OpenGL modules;
- the classes VTK makes only through a backend's object factory get their
  implementation from the application's factories (SceneFactory.cxx and
  VRPresentation.mm), so that
  vtkActor::New() and the others do not return nullptr;
- the plugin SDK does not publish ROICanvasGL.h, and no header it publishes
  names an OpenGL type.

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
        out = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision])
        return [f for f in out.decode().split('\n') if f]
    out = subprocess.check_output(['git', '-C', str(root), 'ls-files'])
    return [f for f in out.decode().split('\n') if f]


def code(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


failures = []
tree = files()
project = read('Horos.xcodeproj/project.pbxproj')

GONE = ('GLString', 'StringTexture', 'NSFont_OpenGL', 'OpenGLScreenReader', 'VTKView', 'VTKStereo', 'StereoVision')
for name in GONE:
    left = [f for f in tree if f.split('/')[0] in ('Horos', 'Nitrogen', 'NSFont_OpenGL') and re.search(r'(^|/)%s[^/]*\.(h|m|mm|swift)$' % name, f)]
    if left:
        failures.append('%s is still in the tree: %s' % (name, ', '.join(left[:3])))
    if re.search(r'\b%s\w*\.(h|m|mm)\b' % name, project):
        failures.append('the project still lists %s' % name)
if 'OpenGL.framework' in project:
    failures.append('OpenGL.framework is still linked')

sources = [f for f in tree if f.startswith('Horos/') and re.search(r'\.(h|m|mm|swift|pch)$', f)
           and not f.startswith('Horos/ThirdParty/')]
opengl = re.compile(r'<OpenGL/|import OpenGL\b|\bNSOpenGL\w+|\bCGL[A-Z]\w*\s*\(|\bCGLContextObj\b|\bgl[A-Z]\w*\s*\(')
using = sorted(f for f in sources if opengl.search(code(read(f))))
if using:
    failures.append('OpenGL is still used in %s' % ', '.join(using[:6]))

cmake = code(read('Horos/Scripts/VTK/CMake.sh').replace('#', '//'))
if '-DVTK_RENDERING_BACKEND=None' not in cmake:
    failures.append('VTK is still built with a rendering backend')
for module in ('vtkRenderingOpenGL2', 'vtkRenderingVolumeOpenGL2', 'vtkRenderingContextOpenGL2', 'vtkIOExportOpenGL2'):
    if re.search(r'-DModule_%s=ON' % module, cmake):
        failures.append('VTK still builds %s' % module)

presentation = code(read('Horos/Sources/VRPresentation.mm') + read('Horos/Sources/SceneFactory.cxx'))
if 'vtkObjectFactory::RegisterFactory' not in presentation:
    failures.append('the application does not register its VTK object factory')
for base in ('vtkActor', 'vtkProperty', 'vtkCamera', 'vtkLight', 'vtkTexture', 'vtkPolyDataMapper',
             'vtkPolyDataMapper2D', 'vtkImageMapper', 'vtkRayCastImageDisplayHelper', 'vtkRenderer',
             'vtkRenderWindow'):
    if not re.search(r'(Add<\w+>|RegisterOverride)\s*\(\s*"%s"' % base, presentation):
        failures.append('the application\'s factory does not make %s' % base)
for module in ('vtkRenderingFreeType', 'vtkInteractionStyle'):
    if 'VTK_MODULE_INIT(%s)' % module not in presentation:
        failures.append('the application does not initialise %s, which a backend pulled in' % module)

publisher = read('Horos/Scripts/Horos/API-Headers.pl')
if 'ROICanvasGL.h' not in publisher:
    failures.append('the plugin SDK publishes ROICanvasGL.h')
gl_type = re.compile(r'\bGL(enum|bitfield|uint|int|float|double|ubyte|ushort|boolean|sizei)\b|\bCGLContextObj\b|\bNSOpenGL\w+')
published = [f for f in tree if re.match(r'(Horos|Nitrogen)/Sources/(JSON/)?[^/]+\.h$', f)
             and not f.endswith('+SwiftIvars.h') and not f.endswith('/ROICanvasGL.h')]
typed = sorted(f for f in published if gl_type.search(code(read(f))))
if typed:
    failures.append('SDK headers still name OpenGL types: %s' % ', '.join(typed[:6]))

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: no OpenGL class, header, call or framework is left; VTK is built without a backend and the '
      'application makes the classes a backend made; the plugin SDK names no OpenGL type')
