#!/usr/bin/env python3
"""An RGB volume's MIP, MinIP and mean on the CPU ray cast, channel by channel (#786).

The MPR draws an RGB volume's plane in Metal, each channel resliced as a
scalar volume (#724, `tests/test-mpr-rgb-plane.py`). When that plane is
refused - a series fused over the RGB volume, a geometry the plane refuses
(a crop plane that cuts the volume), no Metal device, or channels that cannot
be uploaded - and the view is in a projection mode, the 3D view's Metal hook
does not draw it either (it draws the MPR only in volume rendering mode), and
the plane comes from VTK's CPU ray cast: `vtkHorosFixedPointVolumeRayCastMIPHelper`,
whose independent-components loops reduce the red, green and blue components.

Two defects in those loops, measured on the real helper:
- **no mean:** the mean (mode 3, a minimum-intensity blend with the mapper's
  mean flag, #665) was only read by the one-component loop. An RGB volume in
  mean drew its MinIP;
- **nearest neighbour MIP and MinIP:** the space leap of the first min-max
  block was decided from an uninitialised maximum, before the ray had one, so
  the later samples of that block could be skipped. A MIP down a column whose
  blue maximum lay in that block came out as the value of a later block.

With linear interpolation the MIP and MinIP loops already kept each
component's maximum and minimum; the swap #786 recorded on the VTK path before
#735 does not reproduce on this helper, and is checked here all the same.

The loops now sum each component and divide by the samples in mean, as the
one-component loop does, and compare every sample of the first block once the
ray has its first value.

The reference is the same helper on scalar volumes: each channel of a
synthetic RGB volume whose per-channel maxima and minima lie in different
slices is ray cast as a one-component volume with that channel's colour
function and the shared opacity function, with the same camera and slab. The
RGB picture's red, green and blue must equal the three scalar pictures,
byte for byte in VTK's 15 bits, in MIP, MinIP and mean, with linear
interpolation (the app's), for an axis-aligned and an oblique plane and slabs
of 0.3, 2 and 6 mm. With nearest-neighbour interpolation (Option held while
the 3D view opens) MIP and MinIP must equal the scalar pictures; the scalar
loop has no nearest-neighbour mean, so the RGB mean down the stack must lie
within two samples of the slab's average, strictly between MinIP and MIP.

Needs the built Release VTK libraries (`build/`); exits 2 without them.
`<git revision>` as an optional argument takes the helper from that revision,
the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
sys.path.insert(0, str(root / 'tests'))
import vtk_pattern_window

install = root / 'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install'
if not (install / 'lib').is_dir():
    print('skipped: needs built Release VTK libraries in', install)
    raise SystemExit(2)

HELPER = 'Horos/Sources/vtkHorosFixedPointVolumeRayCastMIPHelper.cxx'


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path])
    return (root / path).read_bytes()


CODE = r'''
#import <Cocoa/Cocoa.h>
#include "vtk_pattern_scene.h"
#include "vtkHorosFixedPointVolumeRayCastMapper.h"
#include <vtkCamera.h>
#include <vtkVolumeProperty.h>
#include <vtkImageData.h>
#include <vtkFixedPointRayCastImage.h>
#include <vtkPiecewiseFunction.h>
#include <vtkColorTransferFunction.h>
#include <cmath>
#include <cstdio>
#include <vector>

// 12 x 10 x 12 voxels of 1 mm. Each channel is a profile along the stack,
// with an in-plane ramp so that rays differ; the maxima and minima of red,
// green and blue lie in different slices, each on a plateau of two slices so
// that a slab over them reaches it whatever the sampling.
static const int W = 12, H = 10, D = 12;
static const int profile[3][D] = {
  { 90, 100, 215, 215, 120,  95,  60,  45,  45,  80, 110, 100},   // red: max z 2-3, min z 7-8
  {100,  70,  35,  35,  90, 150, 190, 205, 205, 120,  95, 110},   // green: min z 2-3, max z 7-8
  {140, 130, 125, 150,  65,  65, 170, 230, 150, 235, 235, 120},   // blue: min z 4-5, max z 9-10
};
// Voxel (0, 0, 0) is 0 in every channel, off every ray below: VTK maps a
// component from its own minimum, and a channel whose minimum is 0 takes the
// one-component loop that has a mean (the host's scalar data starts at 0 too).
static int voxel(int c, int x, int y, int z) { return x + y + z == 0 ? 0 : profile[c][z] + (x + 2 * y) % 7; }

struct Scene {
  vtkNew<PatternWindow> window;
  vtkNew<PatternRenderer> renderer;
  Scene() { window->SetSize(96, 80); window->AddRenderer(renderer); }
};

// One volume, RGB (four independent components, the alpha weighted 0, as
// VRView holds an ARGB series) or one channel of it.
struct Volume {
  vtkNew<vtkImageData> data;
  vtkNew<vtkHorosFixedPointVolumeRayCastMapper> mapper;
  vtkNew<vtkVolume> volume;
  vtkNew<vtkPiecewiseFunction> opacity;
  vtkNew<vtkColorTransferFunction> colour[3];
  Volume(int channel) {  // -1: RGB
    data->SetDimensions(W, H, D); data->SetSpacing(1, 1, 1);
    data->AllocateScalars(VTK_UNSIGNED_CHAR, channel < 0 ? 4 : 1);
    unsigned char *v = static_cast<unsigned char *>(data->GetScalarPointer());
    for (int z = 0; z < D; ++z) for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
      size_t i = (size_t(z) * H + y) * W + x;
      if (channel < 0) { v[4 * i] = 255; for (int c = 0; c < 3; ++c) v[4 * i + 1 + c] = voxel(c, x, y, z); }
      else v[i] = voxel(channel, x, y, z);
    }
    mapper->SetInputData(data); mapper->AutoAdjustSampleDistancesOff(); mapper->SetSampleDistance(0.25);
    volume->SetMapper(mapper);
    opacity->AddPoint(0, 0); opacity->AddPoint(255, 1);
    for (int c = 0; c < 3; ++c) {
      colour[c]->AddRGBPoint(0, 0, 0, 0);
      colour[c]->AddRGBPoint(255, c == 0, c == 1, c == 2);
    }
    vtkVolumeProperty *property = volume->GetProperty();
    if (channel < 0) {
      property->IndependentComponentsOn();
      for (int c = 1; c <= 3; ++c) { property->SetColor(c, colour[c - 1]); property->SetScalarOpacity(c, opacity); }
      property->SetComponentWeight(0, 0);
    } else {
      property->SetColor(colour[channel]); property->SetScalarOpacity(opacity);
    }
  }
  // VRView's -setMode: for modes 1 to 3.
  std::vector<unsigned short> render(Scene &scene, int mode, bool nearest, int size[2]) {
    if (nearest) volume->GetProperty()->SetInterpolationTypeToNearest();
    else volume->GetProperty()->SetInterpolationTypeToLinear();
    if (mode == 1) mapper->SetBlendModeToMaximumIntensity(); else mapper->SetBlendModeToMinimumIntensity();
    mapper->SetMeanIntensity(mode == 3);
    scene.renderer->RemoveAllViewProps(); scene.renderer->AddVolume(volume);
    scene.window->Render();
    vtkFixedPointRayCastImage *image = mapper->GetRayCastImage();
    int *used = image->GetImageInUseSize(), *memory = image->GetImageMemorySize();
    size[0] = used[0]; size[1] = used[1];
    std::vector<unsigned short> pixels(size_t(used[0]) * used[1] * 4);
    for (int y = 0; y < used[1]; ++y)
      for (int x = 0; x < 4 * used[0]; ++x) pixels[size_t(y) * 4 * used[0] + x] = image->GetImage()[size_t(y) * 4 * memory[0] + x];
    return pixels;
  }
};

static int failures = 0;
static void fail(const char *what) { if (failures++ < 12) printf("FAIL: %s\n", what); }
// The channel value a 15-bit output stands for: colour x opacity, both the value / 255.
static double level(unsigned short v) { return 255 * std::sqrt(v / 32767.0); }

int main() { @autoreleasepool {
  Scene scene;
  Volume rgb(-1), red(0), green(1), blue(2);
  Volume *scalar[3] = {&red, &green, &blue};
  const char *modeName[4] = {"", "MIP", "MinIP", "mean"};
  vtkCamera *camera = scene.renderer->GetActiveCamera();
  camera->ParallelProjectionOn(); camera->SetParallelScale(8);
  int compared = 0, lit = 0, nearestMeans = 0;
  for (int nearest = 0; nearest < 2; ++nearest)
  for (int oblique = 0; oblique < 2; ++oblique)
  for (double centre : {3.0, 5.5, 8.0})
  for (double thickness : {0.3, 2.0, 6.0}) {
    // The slab is the camera's clipping range around the plane, as the MPR sets it.
    double focal[3] = {5.5, 4.5, centre}, direction[3] = {0, 0, 1};
    if (oblique) { direction[0] = 0.3; direction[1] = -0.2; }
    double length = std::sqrt(direction[0] * direction[0] + direction[1] * direction[1] + 1);
    camera->SetFocalPoint(focal);
    camera->SetPosition(focal[0] + 100 * direction[0] / length, focal[1] + 100 * direction[1] / length, focal[2] + 100 / length);
    camera->SetViewUp(0, 1, 0);
    camera->SetClippingRange(100 - thickness / 2, 100 + thickness / 2);
    std::vector<unsigned short> byMode[4];
    for (int mode = 1; mode <= 3; ++mode) {
      int size[2], channelSize[2];
      std::vector<unsigned short> picture = rgb.render(scene, mode, nearest, size);
      byMode[mode] = picture;
      char where[200];
      snprintf(where, sizeof where, "%s, %s, %s plane, slab %.1f mm at z %.1f", modeName[mode],
               nearest ? "nearest" : "linear", oblique ? "oblique" : "axial", thickness, centre);
      if (nearest && mode == 3) continue;  // no scalar reference: checked below
      for (int c = 0; c < 3; ++c) {
        std::vector<unsigned short> reference = scalar[c]->render(scene, mode, nearest, channelSize);
        if (channelSize[0] != size[0] || channelSize[1] != size[1]) { fail(where); continue; }
        int differing = 0, worst = 0;
        for (size_t p = 0; p < reference.size() / 4; ++p) {
          int d = std::abs(int(picture[4 * p + c]) - int(reference[4 * p + c]));
          differing += d != 0; worst = d > worst ? d : worst;
          lit += reference[4 * p + c] > 0;
        }
        compared += reference.size() / 4;
        if (differing) {
          char text[400];
          snprintf(text, sizeof text, "%s: channel %d differs from its scalar ray cast in %d of %zu pixels (up to %d of 32767)",
                   where, c, differing, reference.size() / 4, worst);
          fail(text);
        }
      }
    }
    // Nearest-neighbour mean down the stack: the rays run along z, so every
    // sample takes a slice's value. The central ray's column is one whose slab
    // maxima and minima are the MIP and MinIP drawn; its mean must be the
    // slab's average within two samples and, over 2 mm or more, lie strictly
    // between the two.
    if (nearest && !oblique) {
      int size[2];
      rgb.render(scene, 3, true, size);
      size_t p = size_t(size[1] / 2) * size[0] + size[0] / 2;
      double z0 = std::max(-0.5, centre - thickness / 2), z1 = std::min(D - 0.5, centre + thickness / 2);
      bool matched = false;
      char text[400] = "";
      for (int vy = 1; vy < H && !matched; ++vy) for (int vx = 1; vx < W && !matched; ++vx) {
        double average[3], low[3], high[3];
        bool column = true;
        for (int c = 0; c < 3; ++c) {
          double sum = 0; low[c] = 1e9; high[c] = -1e9;
          const int steps = 1000;
          for (int s = 0; s < steps; ++s) {
            // VTK's nearest neighbour is the voxel below the sample: its fixed-point shift truncates.
            int z = std::min(D - 1, std::max(0, int(std::floor(z0 + (z1 - z0) * (s + 0.5) / steps))));
            double v = voxel(c, vx, vy, z); sum += v; low[c] = std::min(low[c], v); high[c] = std::max(high[c], v);
          }
          average[c] = sum / steps;
          // The samples may miss a sliver of a slice at either end of the slab.
          column = column && level(byMode[1][4 * p + c]) <= high[c] + 1 && level(byMode[2][4 * p + c]) >= low[c] - 1;
        }
        if (!column) continue;
        bool good = true;
        for (int c = 0; c < 3; ++c) {
          double got = level(byMode[3][4 * p + c]), maximum = level(byMode[1][4 * p + c]), minimum = level(byMode[2][4 * p + c]);
          double tolerance = (high[c] - low[c]) * 2 / std::max(1.0, (z1 - z0) / 0.25) + 2;
          bool between = thickness < 2 || maximum - minimum < 2 || (got > minimum + 0.5 && got < maximum - 0.5);
          if (std::fabs(got - average[c]) > tolerance || !between) {
            good = false;
            snprintf(text, sizeof text, "mean, nearest, slab %.1f mm at z %.1f: channel %d is %.1f, not the slab's average %.1f (MinIP %.1f, MIP %.1f)",
                     thickness, centre, c, got, average[c], minimum, maximum);
          }
        }
        matched = good;
      }
      if (!matched) fail(text[0] ? text : "mean, nearest: no column of the volume has the central ray's MIP and MinIP");
      nearestMeans += 3;
    }
  }
  if (!lit) fail("no ray reached the volume");
  if (failures) { printf("FAIL: %d checks failed\n", failures); return 1; }
  printf("PASS: RGB MIP, MinIP and mean equal each channel's scalar ray cast in %d pixel channels "
         "(linear and nearest, axial and oblique, slabs of 0.3-6 mm); %d nearest-neighbour means match their slabs\n",
         compared, nearestMeans);
  return 0;
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-mpr-rgb-cpu-') as name:
    work = Path(name)
    (work / 'test.mm').write_text(CODE)
    (work / 'vtk_pattern_scene.h').write_text(vtk_pattern_window.WINDOW + vtk_pattern_window.SCENE)
    (work / 'helper.cxx').write_bytes(read(HELPER))
    # VTK as the app links it: the one archive Horos/Scripts/VTK/Make.sh wraps.
    libs = [install / 'wlib' / 'libVTK.a']
    build = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O1', '-w', '-I' + str(install / 'include'),
                            '-I' + str(root / 'Horos/Sources'), str(work / 'test.mm'),
                            str(root / 'Horos/Sources/vtkHorosFixedPointVolumeRayCastMapper.cxx'), str(work / 'helper.cxx'),
                            str(root / 'Horos/Sources/SceneFactory.cxx'), *map(str, libs), '-lz', '-framework', 'Cocoa',
                            '-o', str(work / 'test')])
    if build.returncode:
        print('FAIL: the ray cast helper does not build with the check')
        raise SystemExit(1)
    raise SystemExit(subprocess.run([str(work / 'test')], timeout=300).returncode)
