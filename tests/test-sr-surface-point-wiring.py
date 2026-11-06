#!/usr/bin/env python3
"""Surface Rendering 3D points pick the iso actor, not the camera focal plane."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def strip(text):
    text = re.sub(r'//[^\n]*', '', text)
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


def method(source, name):
    at = source.find(name)
    if at < 0:
        return ''
    return source[at:source.index('\n}', at) + 2]


def swift_method(source, name):
    at = source.find(name)
    if at < 0:
        return ''
    return source[at:source.index('\n    }\n', at) + 6]


# SRView is Swift, split by responsibility (SRView+Points.swift picks and
# places the points, SRView+Mouse.swift takes the click); the pick itself is
# the VTK adapter's (IsiXVTKScene, IsiXVTKSceneActors.mm builds the surfaces).
sys.path.insert(0, str(root / 'tests'))
import sources  # noqa: E402
view = strip(sources.class_text('SRView'))
scene = strip((root / 'Horos/Sources/Adapters/VTK/IsiXVTKScene.mm').read_text())
actors = strip((root / 'Horos/Sources/Adapters/VTK/IsiXVTKSceneActors.mm').read_text())
project = (root / 'Horos.xcodeproj/project.pbxproj').read_bytes().decode('latin1')
helper = root / 'Horos/Sources/SRSurfacePointGeometry.swift'

if not helper.is_file():
    failures.append('Horos/Sources/SRSurfacePointGeometry.swift is missing')
if 'SRSurfacePointGeometry.swift' not in project:
    failures.append('project.pbxproj does not compile SRSurfacePointGeometry.swift')

throw = swift_method(view, 'func throw3DPointOnSurface(')
if not throw:
    failures.append('throw3DPointOnSurface is gone')
else:
    if 'WorldPointPicker' in throw:
        failures.append('throw3DPointOnSurface still uses vtkWorldPointPicker, which lands on the focal plane')
    if 'pickSurface(atDisplayX:' not in throw:
        failures.append('throw3DPointOnSurface does not pick the iso surface')
    if 'add3DPoint' not in throw or 'add2DPoint' not in throw:
        failures.append('a hit no longer writes both the 3D actor and the exported 2D point')

pick = swift_method(view, 'func pickSurface(atDisplayX x: Double, y: Double, world: inout IsiXVTKPoint)')
picker = scene[scene.find('- (BOOL)pickActors:'):scene.find('\n}\n', scene.find('- (BOOL)pickActors:')) + 3]
if 'scene.pick(surfaces' not in pick:
    failures.append('the surface pick does not go through the scene with the surfaces')
if 'vtkCellPicker' not in picker:
    failures.append('the surface pick does not use vtkCellPicker')
if 'PickableOn()' not in picker:
    failures.append('iso actors stay PickableOff during the pick, so CellPicker cannot hit them')
if 'SetPickable(wasPickable' not in picker:
    failures.append('iso actors are left pickable, so the 3D-point tool would select the surface instead of a sphere')

convert = swift_method(view, 'func convert3Dto2Dpoint(')
if 'SRSurfacePointGeometry.voxel(' not in convert:
    failures.append('convert3Dto2Dpoint no longer uses SRSurfacePointGeometry for the exported voxel')

surface = actors[actors.find('- (IsiXVTKActor *)surfaceAtValue:'):]
if 'actor->PickableOff();' not in surface[:surface.find('\n}\n')]:
    failures.append('the surfaces are no longer built unpickable')

at = view.find('throw3DPointOnSurface(pick.x, pick.y)')
if at < 0:
    failures.append('SRView no longer places a 3D point at the click')
else:
    if 'VRInteractionGeometry.backingPoint' not in view[max(0, at - 500):at]:
        failures.append('SRView throws a 3D point from view points, not VTK backing pixels')
if 'WorldPointPicker' in swift_method(view, 'override func mouseDown('):
    failures.append('mouseDown still uses vtkWorldPointPicker for the surface click')

if failures:
    print('FAIL:', *failures, sep='\n', file=sys.stderr)
    sys.exit(1)
print('PASS: SR 3D points pick the iso surface in backing pixels and export through SRSurfacePointGeometry')
