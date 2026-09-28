#!/usr/bin/env python3
"""The Metal volume renderer shades a composite as VTK's ray caster does (#784).

With shading on, the Metal composite came out brighter than the CPU ray cast
it stands in for (issue: about 20 % on the lit pixels). Reading the two
lighting models side by side, the differences were formulas, not the light:

* ambient: `vtkEncodedGradientShader` multiplies the material's ambient by
  each light's ambient colour, and the headlight VTK creates - the only light
  of the host's 3D views - has a black one, so VTK adds no ambient at all;
  the kernel added the preset's 0.15 of the colour everywhere;
* two-sided lighting (`vtkRenderer`'s default): VTK turns a normal that faces
  away towards the viewer; the kernel left those surfaces unlit;
* the normal: VTK's central differences stay inside the voxel centres
  (one-sided at a face of the volume) and reach two and then three voxels out
  where one finds no change; the kernel differenced against a zero outside
  the volume, which lit every cut face, and left samples a voxel into a
  homogeneous region without a normal, dark;
* the headlight and view are the camera's direction, not each ray's.

The kernel now follows each of them; `VolumeShading` folds the renderer's
lights into the terms (their ambient colour and intensity, VTK's headlight by
default), and the host hands it its renderer's lights. Searching two and three
voxels out as VTK does doubled the shaded render of a volume with large
uniform regions, so the kernel does not search: behind a surface, where one
voxel finds no change, a ray keeps the surface's normal, whole for one voxel
of depth and faded out by the third, as VTK's interpolated shading fades.

What is left is how the normal is estimated: VTK encodes a normal per voxel
and interpolates the shaded result of the eight corners, the kernel shades
with the gradient at the sample and the carried normal. Emulated in the
kernel, VTK's scheme brought the shaded difference down to the unshaded one
but tripled the shaded kernel's time (19 against 6 ms, 256 x 256 x 200 at
1024^2 on an M4), so the difference is kept and bounded: shaded composites are
held to a mean channel difference of 14/255 instead of the 8/255 unshaded ones
are (measured up to 13.3/255, on the soft-tissue surface; with VTK's search it
was 11.2/255), with the same lit/unlit agreement and 32/255 bounds, and a mean
brightness within 8/255 of VTK's.

Checked here, on a synthetic CT phantom in Hounsfield units (air, fat, soft
tissue, a contrast vessel, bone; 64 x 64 x 80, 1 mm), two transfer
functions and three parallel views, each shaded and not: VTK's own mapper,
compiled from the app's source against the built VTK and driven through the
renderer the app's HorosVRRenderer mirrors (its automatic headlight), against
the Metal renderer compiled from the sources, with the metrics of
`tools/compare-native-volume-metal.py`. The unshaded composites must keep
their parity, so a change that only moved the shading cannot hide behind a
looser bound. The sources are also checked for the bridge handing the
renderer's lights to Metal.

Needs the built Release VTK libraries (`build/`) and a Metal device; exits 2
without them. `<git revision>` as an optional argument takes the Metal
renderer and the bridge from that revision, the negative control.
"""
from pathlib import Path
import math
import struct
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


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('utf-8')
    return (root / path).read_text()


failures = []
bridge = read('Horos/Sources/VRHostBridge.mm')
if 'static NSArray *HorosShading(vtkRenderer *renderer, vtkVolumeProperty *property)' not in bridge or \
        'light->GetAmbientColor(colour);' not in bridge:
    failures.append('the bridge does not read the renderer\'s lights for the Metal shading')
for use in ('HorosShading(aRenderer, volumeProperty)', 'HorosShading(aRenderer, blendingVolumeProperty)'):
    if use not in bridge:
        failures.append('a snapshot does not hand its renderer\'s lights to Metal: ' + use)
# The shaded kernel must not search for a normal (its cost doubled the render
# of uniform volumes); it carries the surface's instead.
kernel = read('Horos/Sources/VolumeMetalRenderer.swift')
if 'for (int d = 1; d <= 3' in kernel:
    failures.append('the kernel searches two and three voxels out for a normal, which doubles the shaded render of uniform regions')
if 'carried = gradient / magnitude; carriedAt = t;' not in kernel:
    failures.append('the kernel does not carry a surface\'s normal behind it')

# The phantom of tools/generate-ct-phantom-fixture.py, 64 x 64 x 80, in HU.
W, H, D = 64, 64, 80
AIR, FAT, SOFT, VESSEL, BONE = -1000.0, -100.0, 40.0, 300.0, 1000.0
voxels = []
for k in range(D):
    drift = 0.18 * math.sin(2 * math.pi * k / (D - 1))
    ribs = 0.15 * D < k < 0.85 * D
    for j in range(H):
        y = -1 + 2 * j / (H - 1)
        for i in range(W):
            x = -1 + 2 * i / (W - 1)
            r = math.hypot(x, y)
            hu = SOFT if r < 0.8 else AIR
            if 0.72 < r < 0.8: hu = FAT
            if abs(x) < 0.10 and 0.42 < y < 0.60: hu = BONE
            if ribs and any((x - 0.62 * math.cos(a)) ** 2 + (y - 0.62 * math.sin(a)) ** 2 < 0.0036
                            for a in (2 * math.pi * n / 8 for n in range(8))):
                hu = BONE
            if (x - drift) ** 2 + (y + 0.15) ** 2 < 0.0049: hu = VESSEL
            voxels.append(hu)

# Two transfer functions over the window 300/1500: 256 colours and opacities
# per millimetre, one a soft-tissue surface over vessel and bone, one bone.
LEVEL, WINDOW, SIZE = 300.0, 1500.0, 128


def table(points, i):
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x0 <= i <= x1:
            t = (i - x0) / (x1 - x0)
            return [a + (b - a) * t for a, b in zip(y0, y1)]
    return list(points[-1][1])


PRESETS = {
    'soft': ([(0, (0, 0, 0)), (70, (0.55, 0.25, 0.15)), (90, (0.85, 0.55, 0.45)), (130, (0.9, 0.2, 0.2)), (255, (1, 1, 0.9))],
             [(0, (0,)), (75, (0,)), (85, (0.35,)), (120, (0.5,)), (200, (0.9,)), (255, (0.95,))]),
    'bone': ([(0, (0, 0, 0)), (100, (0.6, 0.3, 0.2)), (160, (0.95, 0.85, 0.7)), (255, (1, 1, 1))],
             [(0, (0,)), (110, (0,)), (140, (0.15,)), (200, (0.85,)), (255, (0.95,))]),
}
turn = math.radians(40)
VIEWS = {
    'front': ((31.5, -120, 39.5), (0, 0, 1)),
    'turned': ((31.5 + 120 * math.sin(turn), 31.5 - 120 * math.cos(turn), 69.5), (0, 0, 1)),
    'axial': ((31.5, 31.5, -120), (0, -1, 0)),   # onto the first slice: a cut face of the volume
}
cases = []
for preset, (colour, opacity) in PRESETS.items():
    colours = [round(255 * c) for i in range(256) for c in table(colour, i)]
    opacities = [table(opacity, i)[0] for i in range(256)]
    for view, (position, up) in VIEWS.items():
        for shaded in (0, 1):
            cases.append(('%s-%s-%s' % (preset, view, 'shaded' if shaded else 'plain'),
                          [*position, 31.5, 31.5, 39.5, *up, 45.0, shaded, 0.15, 0.9, 0.3, 15], colours, opacities))
description = '%d\n' % len(cases) + ''.join(
    '%s\n%s\n%s\n%s\n' % (name, ' '.join(map(str, numbers)), ' '.join(map(str, colours)), ' '.join('%.6f' % o for o in opacities))
    for name, numbers, colours, opacities in cases)

VTK_SIDE = r'''
#import <Cocoa/Cocoa.h>
#include "vtk_pattern_scene.h"
#include "vtkHorosFixedPointVolumeRayCastMapper.h"
#include <vtkCamera.h>
#include <vtkVolumeProperty.h>
#include <vtkImageData.h>
#include <vtkFixedPointRayCastImage.h>
#include <vtkPiecewiseFunction.h>
#include <vtkColorTransferFunction.h>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

// VRView's volume: the mapper at a fixed sample distance, one ray a pixel,
// linear interpolation, the window's colour and opacity per millimetre.
int main(int argc, char **argv) { @autoreleasepool {
  const int W = %(W)d, H = %(H)d, D = %(D)d, S = %(SIZE)d;
  const double level = %(LEVEL)f, window = %(WINDOW)f;
  vtkNew<vtkImageData> data; data->SetDimensions(W, H, D); data->SetSpacing(1, 1, 1);
  data->AllocateScalars(VTK_FLOAT, 1);
  FILE *f = fopen(argv[1], "rb");
  if (!f || fread(data->GetScalarPointer(), 4, size_t(W) * H * D, f) != size_t(W) * H * D) return 3;
  fclose(f);
  std::ifstream cases(argv[2]);
  std::string directory = argv[3];
  vtkNew<PatternWindow> renderWindow; vtkNew<PatternRenderer> renderer;
  renderWindow->SetSize(S, S); renderWindow->AddRenderer(renderer);
  int count; cases >> count;
  for (int n = 0; n < count; ++n) {
    std::string name; cases >> name;
    double v[15]; for (double &x : v) cases >> x;
    std::vector<int> colour(768); for (int &c : colour) cases >> c;
    std::vector<double> opacity(256); for (double &o : opacity) cases >> o;
    vtkNew<vtkHorosFixedPointVolumeRayCastMapper> mapper;
    mapper->SetInputData(data); mapper->AutoAdjustSampleDistancesOff(); mapper->SetSampleDistance(0.5);
    mapper->SetImageSampleDistance(1); mapper->SetMinimumImageSampleDistance(1); mapper->SetMaximumImageSampleDistance(1);
    vtkNew<vtkColorTransferFunction> colours; vtkNew<vtkPiecewiseFunction> opacities;
    for (int i = 0; i < 256; ++i) {
      double x = level - window / 2 + i * window / 255;
      colours->AddRGBPoint(x, colour[3 * i] / 255.0, colour[3 * i + 1] / 255.0, colour[3 * i + 2] / 255.0);
      opacities->AddPoint(x, opacity[i]);
    }
    vtkNew<vtkVolume> volume; volume->SetMapper(mapper);
    vtkVolumeProperty *property = volume->GetProperty();
    property->SetColor(colours); property->SetScalarOpacity(opacities); property->SetInterpolationTypeToLinear();
    property->SetShade(int(v[10])); property->SetAmbient(v[11]); property->SetDiffuse(v[12]);
    property->SetSpecular(v[13]); property->SetSpecularPower(v[14]);
    renderer->RemoveAllViewProps(); renderer->AddVolume(volume);
    vtkCamera *camera = renderer->GetActiveCamera();
    camera->ParallelProjectionOn(); camera->SetParallelScale(v[9]);
    camera->SetPosition(v[0], v[1], v[2]); camera->SetFocalPoint(v[3], v[4], v[5]); camera->SetViewUp(v[6], v[7], v[8]);
    renderer->ResetCameraClippingRange();
    renderWindow->Render();
    // The lights the ray cast shaded with, summed as the bridge sums them.
    double ambient = 0, intensity = 0;
    vtkCollectionSimpleIterator it; vtkLight *light = nullptr;
    for (renderer->GetLights()->InitTraversal(it); (light = renderer->GetLights()->GetNextLight(it)); ) {
      if (!light->GetSwitch()) continue;
      double c[3]; light->GetAmbientColor(c);
      ambient += light->GetIntensity() * (c[0] + c[1] + c[2]) / 3; intensity += light->GetIntensity();
    }
    if (ambient != 0 || intensity != 1) { printf("FAIL: the scene's lights are not VTK's headlight (ambient %%g, intensity %%g)\n", ambient, intensity); return 1; }
    // The ray cast image, 15-bit premultiplied RGBA over black, placed in the view, top row first.
    vtkFixedPointRayCastImage *image = mapper->GetRayCastImage();
    int *used = image->GetImageInUseSize(), *memory = image->GetImageMemorySize(), *origin = image->GetImageOrigin();
    std::vector<unsigned char> rgb(size_t(S) * S * 3, 0);
    for (int y = 0; y < used[1]; ++y) for (int x = 0; x < used[0]; ++x) {
      int X = x + origin[0], Y = y + origin[1];
      if (X < 0 || Y < 0 || X >= S || Y >= S) continue;
      unsigned short *p = image->GetImage() + 4 * (size_t(y) * memory[0] + x);
      for (int c = 0; c < 3; ++c) { int b = (p[c] * 255 + 16383) / 32767; rgb[3 * (size_t(S - 1 - Y) * S + X) + c] = b > 255 ? 255 : b; }
    }
    std::ofstream out(directory + "/" + name + ".vtk.rgb", std::ios::binary);
    out.write(reinterpret_cast<const char *>(rgb.data()), rgb.size());
  }
  return 0;
}}
''' % {'W': W, 'H': H, 'D': D, 'SIZE': SIZE, 'LEVEL': LEVEL, 'WINDOW': WINDOW}

METAL_SIDE = r'''
import Foundation
import Metal
import simd

@main struct Check {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard let device = MTLCreateSystemDefaultDevice() else { print("skipped: no Metal device"); exit(2) }
        let engine = try VolumeMetalRenderer(device: device)
        try engine.upload(try ResliceVolume(width: %(W)d, height: %(H)d, depth: %(D)d, voxels: try Data(contentsOf: URL(fileURLWithPath: arguments[1])),
                                            voxelToWorld: matrix_identity_float4x4))
        var lines = try String(contentsOfFile: arguments[2], encoding: .utf8).split(separator: "\n").map(String.init)
        let count = Int(lines.removeFirst())!
        for n in 0..<count {
            let v = lines[4 * n + 1].split(separator: " ").map { Float(String($0))! }
            let colour = lines[4 * n + 2].split(separator: " ").map { UInt8(String($0))! }
            let opacity = lines[4 * n + 3].split(separator: " ").map { Float(String($0))! }
            var rgba = [UInt8](); for i in 0..<256 { rgba += [colour[3 * i], colour[3 * i + 1], colour[3 * i + 2], 255] }
            let camera = try VolumeCamera(position: SIMD3(v[0], v[1], v[2]), focalPoint: SIMD3(v[3], v[4], v[5]), viewUp: SIMD3(v[6], v[7], v[8]),
                                          parallel: true, parallelScale: v[9], viewAngle: 30, clippingRange: nil)
            // The material alone, as the host's five numbers were: the lights are VolumeShading's default.
            let shading = VolumeShading(enabled: v[10] != 0, ambient: v[11], diffuse: v[12], specular: v[13], specularPower: v[14])
            let request = try VolumeRenderRequest(camera: camera, transfer: try VolumeTransferFunction(level: %(LEVEL)f, width: %(WINDOW)f, colour: Data(rgba), opacity: opacity),
                                                  mode: .composite, shading: shading, crop: nil, width: %(SIZE)d, height: %(SIZE)d, sampleStep: 0.5)
            let bgra = [UInt8](try engine.render(request).bgra)
            var rgb = [UInt8](); for p in 0..<(%(SIZE)d * %(SIZE)d) { rgb += [bgra[4 * p + 2], bgra[4 * p + 1], bgra[4 * p]] }
            try Data(rgb).write(to: URL(fileURLWithPath: arguments[3] + "/" + lines[4 * n] + ".metal.rgb"))
        }
    }
}
''' % {'W': W, 'H': H, 'D': D, 'SIZE': SIZE, 'LEVEL': LEVEL, 'WINDOW': WINDOW}

# compare-native-volume-metal.py's composite metrics, and the brightness of the lit pixels.
PLAIN = {'mean': 8 / 255, 'agree': 0.95, 'within32': 0.90}
SHADED = {'mean': 14 / 255, 'agree': 0.95, 'within32': 0.90, 'brightness': 8 / 255}


def compare(vtk, metal):
    lit_metal = lit_vtk = both = within = 0; channel = signed = 0.0
    for p in range(SIZE * SIZE):
        mr, mg, mb = metal[3 * p:3 * p + 3]; vr, vg, vb = vtk[3 * p:3 * p + 3]
        lm = mr + mg + mb > 6; lv = vr + vg + vb > 6
        lit_metal += lm; lit_vtk += lv
        if lm or lv:
            channel += (abs(mr - vr) + abs(mg - vg) + abs(mb - vb)) / 3
        if lm and lv:
            both += 1; signed += (mr + mg + mb - vr - vg - vb) / 3
            within += max(abs(mr - vr), abs(mg - vg), abs(mb - vb)) <= 32
    either = lit_metal + lit_vtk - both
    return {'mean': channel / either / 255 if either else 0, 'agree': 1 - (either - both) / (SIZE * SIZE),
            'within32': within / both if both else 0, 'brightness': signed / both / 255 if both else 0}


with tempfile.TemporaryDirectory(prefix='horos-volume-shading-') as name:
    work = Path(name)
    (work / 'phantom.f32').write_bytes(struct.pack('<%df' % len(voxels), *voxels))
    (work / 'cases.txt').write_text(description)
    (work / 'vtk_pattern_scene.h').write_text(vtk_pattern_window.WINDOW + vtk_pattern_window.SCENE)
    (work / 'vtk.mm').write_text(VTK_SIDE)
    libs = sorted((install / 'lib').glob('libvtkCommon*.a'))
    for library in ['vtkRenderingVolume', 'vtkRenderingCore', 'vtkRenderingFreeType', 'vtkfreetype', 'vtkInteractionStyle',
                    'vtkFiltersCore', 'vtkFiltersGeneral', 'vtkFiltersSources', 'vtkImagingCore', 'vtkFiltersGeometry',
                    'vtksys', 'vtkdoubleconversion']:
        libs += list((install / 'lib').glob('lib' + library + '-*.a'))
    built = subprocess.run(['xcrun', 'clang++', '-std=c++14', '-O2', '-w', '-I' + str(install / 'include'), '-I' + str(work),
                            '-I' + str(root / 'Horos/Sources'), str(work / 'vtk.mm'),
                            str(root / 'Horos/Sources/vtkHorosFixedPointVolumeRayCastMapper.cxx'),
                            str(root / 'Horos/Sources/vtkHorosFixedPointVolumeRayCastMIPHelper.cxx'),
                            str(root / 'Horos/Sources/SceneFactory.cxx'), *map(str, libs), '-lz', '-framework', 'Cocoa',
                            '-o', str(work / 'vtk')])
    if built.returncode:
        print('FAIL: VTK\'s ray cast does not build with the check')
        raise SystemExit(1)
    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'MPRMetalReslicer.swift', 'VolumeMetalRenderer.swift',
               'MetalPerformanceTrace.swift', 'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift']
    for source in sources:
        (work / source).write_text(read('Horos/Sources/' + source))
    (work / 'Check.swift').write_text(METAL_SIDE)
    built = subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-suppress-warnings',
                            *[str(work / s) for s in sources], str(work / 'Check.swift'), '-o', str(work / 'metal')])
    if built.returncode:
        print('FAIL: the renderer does not build with the check')
        raise SystemExit(1)
    ran = subprocess.run([str(work / 'vtk'), str(work / 'phantom.f32'), str(work / 'cases.txt'), str(work)], timeout=600)
    if ran.returncode:
        print('FAIL: VTK\'s ray cast did not run (%d)' % ran.returncode)
        raise SystemExit(1)
    ran = subprocess.run([str(work / 'metal'), str(work / 'phantom.f32'), str(work / 'cases.txt'), str(work)], timeout=600)
    if ran.returncode:
        if ran.returncode == 2:
            raise SystemExit(2)
        print('FAIL: the Metal renderer did not run (%d)' % ran.returncode)
        raise SystemExit(1)
    print('%-20s %8s %8s %9s %11s' % ('case', 'mean', 'lit/unlit', 'within32', 'brightness'))
    for case, *_ in cases:
        m = compare((work / (case + '.vtk.rgb')).read_bytes(), (work / (case + '.metal.rgb')).read_bytes())
        print('%-20s %8.4f %9.4f %9.4f %+11.4f' % (case, m['mean'], m['agree'], m['within32'], m['brightness']))
        bounds = SHADED if case.endswith('shaded') else PLAIN
        if m['mean'] > bounds['mean'] or m['agree'] < bounds['agree'] or m['within32'] < bounds['within32'] or \
                abs(m['brightness']) > bounds.get('brightness', 1):
            failures.append('%s: mean channel %.4f (≤ %.4f), lit/unlit %.4f, within 32/255 %.4f, brightness %+.4f'
                            % (case, m['mean'], bounds['mean'], m['agree'], m['within32'], m['brightness']))

for failure in failures:
    print('FAIL:', failure)
if failures:
    raise SystemExit(1)
print('ok: shaded composites match VTK\'s ray cast within 14/255 and 8/255 of brightness, unshaded ones within 8/255 (#784)')
