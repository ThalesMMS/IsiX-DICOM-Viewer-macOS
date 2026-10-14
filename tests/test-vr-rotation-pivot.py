#!/usr/bin/env python3
"""A 3D rotation drag turns about the surface under the pointer, not the focal point.

With a wide view angle the camera's focal point can sit far to the side of
what the user looks at, and turning about it swings that region out of the
view. VRView takes the visible surface under the pointer where a rotation drag
starts as its pivot, and the interactor, after each turn about the focal
point, moves the camera back so the pivot keeps its place in the camera's own
frame (HorosKeepPointInCameraFrame). Here a 110 degree camera turns about an
off-axis pivot: the pivot stays on the same display pixel and depth, at the
same distance from the eye, and the camera's direction and view angle are
those of the turn.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vtk_pattern_window

root = Path(__file__).resolve().parents[1]
interaction = (root / 'Horos/Sources/VRInteraction.mm').read_text(encoding='utf-8')
view = (root / 'Horos/Sources/VRView.mm').read_bytes().decode('latin1')
try:
    function = interaction[interaction.index('void HorosKeepPointInCameraFrame'):interaction.index('// MARK: - Interactor')]
except ValueError:
    print('FAIL: HorosKeepPointInCameraFrame is missing from VRInteraction.mm', file=sys.stderr)
    sys.exit(1)

rotate = interaction[interaction.index('void HorosVRInteractor::Rotate()'):interaction.index('void HorosVRInteractor::Spin()')]
assert re.search(r'if\( this->HasRotationPivot\)\s*HorosKeepPointInCameraFrame\( camera, this->RotationPivot, pivotInCamera\);', rotate), \
    'Rotate() no longer turns about the pivot'
assert 'this->HasRotationPivot = false;' in interaction[interaction.index('void HorosVRInteractor::Stop()'):], \
    'the pivot outlives the drag'
assert re.search(r'get3DPixelUnder2DPositionX: mouseLoc\.x Y: mouseLoc\.y pixel: pix position: surface value: &value\]\)'
                 r'\s*\{\s*double pivot\[ 3\] = \{ surface\[ 0\] \* factor', view), \
    'VRView no longer takes the surface under the pointer as the pivot'

install = root / 'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install'
if not (install / 'wlib/libVTK.a').is_file():
    print('needs built VTK libraries in', install, file=sys.stderr)
    sys.exit(2)

code = r'''
#include "vtk_pattern_scene.h"
#include <vtkRenderer.h>
#include <vtkRenderWindow.h>
#include <vtkCamera.h>
#include <vtkMatrix4x4.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
FUNCTION
static void check(bool condition, const char *message) { if (!condition) { std::printf("FAIL: %s\n", message); std::exit(1); } }
int main() {
    auto window = vtkRenderWindow::New();
    auto renderer = vtkRenderer::New();
    window->AddRenderer(renderer);
    window->SetSize(800, 600);
    auto camera = renderer->GetActiveCamera();
    camera->SetPosition(0, -300, 0);
    camera->SetFocalPoint(0, 0, 0);
    camera->SetViewUp(0, 0, 1);
    camera->SetViewAngle(110);
    const double pivot[3] = {120, 40, -60};
    auto display = [&](double out[3]) {
        renderer->SetWorldPoint(pivot[0], pivot[1], pivot[2], 1);
        renderer->WorldToDisplay();
        renderer->GetDisplayPoint(out);
    };
    auto distance = [&]() {
        double eye[3]; camera->GetPosition(eye);
        return std::sqrt(std::pow(eye[0] - pivot[0], 2) + std::pow(eye[1] - pivot[1], 2) + std::pow(eye[2] - pivot[2], 2));
    };
    double before[3], inCamera[4], world[4] = {pivot[0], pivot[1], pivot[2], 1};
    display(before);
    const double reach = distance();
    camera->GetViewTransformMatrix()->MultiplyPoint(world, inCamera);
    double focus[3]; camera->GetFocalPoint(focus);

    // What the interactor does for one step of a drag: turn about the focal point.
    camera->Azimuth(35);
    camera->Elevation(-20);
    camera->OrthogonalizeViewUp();
    double drifted[3], turned[3];
    display(drifted);
    camera->GetDirectionOfProjection(turned);
    check(std::hypot(drifted[0] - before[0], drifted[1] - before[1]) > 20, "turning about the focal point should move the pivot");

    HorosKeepPointInCameraFrame(camera, pivot, inCamera);
    double after[3], direction[3], moved[3];
    display(after);
    camera->GetDirectionOfProjection(direction);
    camera->GetFocalPoint(moved);
    check(std::abs(after[0] - before[0]) < 1e-6 && std::abs(after[1] - before[1]) < 1e-6, "the pivot left its pixel");
    check(std::abs(after[2] - before[2]) < 1e-9, "the pivot changed depth");
    check(std::abs(distance() - reach) < 1e-6, "the eye changed its distance to the pivot");
    for (int i = 0; i < 3; ++i)
        check(std::abs(direction[i] - turned[i]) < 1e-12, "the camera's direction is not the turn's");
    check(camera->GetViewAngle() == 110, "the view angle changed");
    check(std::hypot(moved[0] - focus[0], moved[1] - focus[1]) > 1, "the focal point should move with the camera");
    renderer->Delete();
    window->Delete();
    std::puts("PASS: a 110 degree camera turns about an off-axis pivot, which keeps its pixel, depth and distance");
}
'''.replace('FUNCTION', function)

with tempfile.TemporaryDirectory(prefix='horos-vr-rotation-pivot-') as folder:
    folder = Path(folder)
    (folder / 'test.cxx').write_text(code)
    (folder / 'vtk_pattern_scene.h').write_text(vtk_pattern_window.WINDOW + vtk_pattern_window.SCENE)
    vtk_pattern_window.compile(install, root, folder / 'test.cxx', folder / 'test', scene=True, frameworks=('Cocoa',))
    subprocess.run([str(folder / 'test')], check=True)
