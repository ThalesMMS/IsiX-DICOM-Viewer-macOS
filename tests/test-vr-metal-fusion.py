#!/usr/bin/env python3
"""A fused series ray-casts in Metal in the 3D viewer.

The 3D viewer draws a fused series as a second vtkVolume with its own
vtkHorosFixedPointVolumeRayCastMapper, after the image's; each mapper casts
its rays into its own ray-cast image, and VTK draws the images one over the
other with GL_ONE, GL_ONE_MINUS_SRC_ALPHA. The Metal hook now fills the fused
mapper's image too, from a snapshot of the fused series, and VTK keeps the
composition. Checked here:

* the wiring: the fusion refusal is gone from the snapshot and the hook; the
  hook takes the fused mapper and volume, and renders the fused volume from
  its own snapshot with its own renderer; setBlendingEngine: hands the fused
  mapper the hook; setMode: sets the fused mapper's mode, as the MPR and CPR
  controllers already do; each volume has its own renderer and upload, and a
  series fused and then closed leaves the GPU;
* the fused snapshot reads the fused window, CLUT, opacity table, shading,
  crop planes, step and background, under the view's camera;
The host is Swift over the VTK adapter (VRView+VolumeHost.swift,
VRController+VolumeMetal.swift), its rules in IsiXVolumeRendering; a revision
that still has VRHostBridge.mm is read as it was.

* the opacity: compiled from the source, the points the fused snapshot hands
  the renderer, expanded the renderer's way (entry i at x = 256 i / 255,
  linear between points), give VTK's BuildFunctionFromTable over the fused
  window - 255 table entries spread over it, clamped outside - converted to
  opacity per millimetre; projections get the table itself;
* the picture, compiled from the source: Metal's BGRA and opacity turned into
  VTK's premultiplied RGBA in 15 bits. VTK itself draws the fused picture over
  the image's; the pilot's comparison window, which composed them in BGRA, is
  gone.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


def braced(text, start):
    """The text from `start` to the brace that closes the first one after it."""
    depth, index = 0, text.index('{', start)
    while True:
        if text[index] == '{': depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0: return text[start:index + 1]
        index += 1


failures = []
try:
    view = read('Horos/Sources/VRView.m')
    objc_view = True
except (OSError, subprocess.CalledProcessError):
    # The class is Swift (VRView.swift); what the Metal host reads of it is in
    # VRView+VolumeHost.swift.
    view = read('Horos/Sources/VRView.swift')
    objc_view = False
# The view's VTK objects are the adapter's: its hook compares the mappers and
# volumes, and its scenes hand them to the host.
volume_view = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeView.mm')
pipeline = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm')
try:
    bridge = read('Horos/Sources/VRHostBridge.mm')
except (FileNotFoundError, subprocess.CalledProcessError):
    bridge = None

# The engines and modes are Swift (VRView+Engine.swift), an extension of the
# view; a revision that still has them in VRView.m is read there.
if '- (void) setMode: (long) modeID' in view:
    engine = braced(view, view.index('- (void) setBlendingEngine: (long) engineID showWait:(BOOL) showWait'))
    mode = braced(view, view.index('- (void) setMode: (long) modeID'))
    attach_call, blending_mode, blending_factor = '[vtk attachBlendingMapper];', '[self setBlendingMode: modeID];', '[self setBlendingFactor: blendingFactor];'
else:
    engine_source = read('Horos/Sources/VRView+Engine.swift')
    engine = braced(engine_source, engine_source.index('func setBlendingEngine(_ engineID: Int, showWait: Bool)'))
    mode = braced(engine_source, engine_source.index('func setMode(_ modeID: Int)'))
    attach_call, blending_mode, blending_factor = 'vtk.attachBlendingMapper()', 'setBlendingMode(modeID)', 'setBlendingFactor(horos_blendingFactor)'
attach = pipeline[pipeline.find('- (void)attachBlendingMapper'):]
attach = braced(attach, 0) if attach else ''
if attach_call not in engine or \
        'o->blendingVolumeMapper->SetImageRenderer(IsiXVTKVolumeViewRenderMetal, (__bridge void *)self);' not in attach:
    failures.append('setBlendingEngine: does not hand the fused mapper the Metal hook')
if blending_mode not in mode or blending_factor not in mode or mode.find(blending_mode) > mode.find(blending_factor):
    failures.append('setMode: leaves the fused mapper in the mode it was fused in')

if bridge is None:
    # The wiring, in the view's hook (Objective-C++, it compares VTK's
    # pointers) and the Swift host.
    host = read('Horos/Sources/VRView+VolumeHost.swift')
    metal = read('Horos/Sources/VRController+VolumeMetal.swift')
    state = view[view.index('@implementation VRView (HorosVolumeHostState)'):] if objc_view else \
        host[host.index('// MARK: - What the Metal host reads of the view'):]
    adapter_state = braced(volume_view, volume_view.index('- (IsiXVTKVolumeScene *)volumeSceneFused:(BOOL)fused'))
    entry = braced(volume_view, volume_view.index('bool IsiXVTKVolumeViewRenderMetal(')) + \
        braced(volume_view, volume_view.index('- (IsiXVTKVolumeScene *)renderingScene'))
    # The hook is Swift (VRView+Render.swift), an extension of VRView: to the
    # line that closes the method at the extension's indentation.
    view_render = read('Horos/Sources/VRView+Render.swift')
    hook_entry = view_render[view_render.index('func horosRenderMetalImageFused('):]
    hook_entry = hook_entry[:hook_entry.index('\n    }\n')]
    if ('[vtk setMetalImageRenderer:' if objc_view else 'horos_vtk.setMetalImageRenderer {') not in view or \
            'return horosRenderMetalImage(in: scene, fused: fused, mprPlane: mprPlane)' not in hook_entry:
        failures.append('the view does not hand its hook to the adapter')
    if 'Fusion keeps the original renderer' in host:
        failures.append('the snapshot still refuses fusion')
    hook = host[host.index('private func renderMetalImage(in scene: IsiXVTKVolumeScene, fused: Bool) -> Bool {'):
                host.index('private static func geometryRefusalReason(')]
    for needle, where, why in [
            ('BOOL fused = o->blendingVolume && volume == o->blendingVolume && mapper == o->blendingVolumeMapper;', entry, 'the hook does not know the fused mapper'),
            ('(volume != o->volume && !fused)', entry, 'the hook still turns the fused volume away'),
            ('o->renderingMapper = mapper;', entry, 'the hook does not render on the calling mapper\'s own grid'),
            ('objects.mapper = o->renderingMapper;', entry, 'the hook does not render on the calling mapper\'s own grid'),
            ('if !fused && !horosHasBlendingVolume { controller.horosFusedVolumeMetalRelease() }', hook, 'a series fused and then closed stays on the GPU'),
            ('let fusedSnapshot = horosFusedVolumeSnapshot()', hook, 'the fused volume does not take its own snapshot'),
            ('controller.horosVolumeMetalRender(snapshot ?? [:], fused: fused,', hook, 'the fused volume is not rendered with its own renderer'),
            ('try? scene.readRayCastImage(&image)', hook, 'the hook does not render on the calling mapper\'s own grid')]:
        if needle not in where:
            failures.append(why)
    if 'horosHasBlendingVolume ||' in hook or 'blendingController' in hook:
        failures.append('the hook still refuses fusion')
    # The image's snapshot replaces the fused one only when the hook draws the
    # image: taken anywhere else, the fused volume would be ray-cast with the
    # image's window, tables and planes.
    for found in re.finditer(re.escape('snapshot = horosVolumeSnapshot()'), hook):
        guards = [guard.start() for guard in re.finditer(re.escape('if !fused {'), hook[:found.start()])]
        if not any(found.start() < guard + len(braced(hook, guard)) for guard in guards):
            failures.append('the fused volume is rendered from the image\'s snapshot')
    fused_start = host.find('@objc func horosFusedVolumeSnapshot() -> NSDictionary {')
    fused = braced(host, fused_start) if fused_start >= 0 else ''
    for needle, where, why in [('let fused = horosMPRFusedVolume()', fused, 'the fused voxels and placement'),
                               ('try horosVolumeCameraSnapshot()', fused, 'the view\'s camera'),
                               ('var level = Double(blendingWl), windowWidth = blendingWw > 0 ? Double(blendingWw) : 1', fused,
                                'the fused window level and width'),
                               ('getBlendingWLWW(&blendingWl, &blendingWw)', fused, 'the fused window'),
                               ('VolumeColourTable.rgba(colours: horosBlendingColourTable, count: 256)', fused, 'the fused CLUT'),
                               ('return &blendingtable[0][0];' if objc_view else 'UnsafePointer(horos_blendingtable)', state,
                                'the fused CLUT'),
                               ('VolumeOpacityCurve.fusedPoints(table: horosBlendingOpacityTable,', fused, 'the fused opacity table'),
                               ('- (const double *) horosBlendingOpacityTable { return alpha; }' if objc_view else
                                'var horosBlendingOpacityTable: UnsafePointer<Double> { UnsafePointer(horos_alpha) }', state,
                                'the fused opacity table'),
                               ('let shading = try Self.shading(scene, sampling: sampling)', fused, 'the fused shading, with the renderer\'s lights'),
                               ('objects.property = o->blendingVolumeProperty;', adapter_state, 'the fused shading'),
                               ('try Self.cuttingPlanes(scene, sampling: sampling, width: width, height: height, depth: depth)', fused,
                                'the fused mapper\'s crop planes'),
                               ('objects.mapper = o->blendingVolumeMapper;', adapter_state, 'the fused mapper\'s crop planes and step'),
                               ('? Double(Float(sampling.sampleDistance) / factor())', fused, 'the fused mapper\'s step'),
                               ('"scalarBackground": horosIsBlendingRGB ? NSNumber(value: Int32(-1)) : fused["background"]', fused,
                                'the value a missed ray reads back'),
                               ('"mode": NSNumber(value: renderingMode)', fused, 'the view\'s mode')]:
        if needle not in where:
            failures.append('the fused snapshot does not carry ' + why)
    for needle, why in [('let rendererSlot = fused ? VolumeMetalSlots.key(&VolumeMetalSlots.fusedRenderer) : VolumeMetalSlots.key(&VolumeMetalSlots.renderer)',
                         'the volumes share one renderer'),
                        ('let uploadedSlot = fused ? VolumeMetalSlots.key(&VolumeMetalSlots.fusedUploaded) : VolumeMetalSlots.key(&VolumeMetalSlots.uploaded)',
                         'the volumes share one upload'),
                        ('return (renderer?.volumeBytes ?? 0) + (fused?.volumeBytes ?? 0)', 'the GPU bytes miss the fused volume')]:
        if needle not in metal:
            failures.append(why)
else:
    # The wiring.
    if 'Fusion keeps the original renderer' in bridge:
        failures.append('the snapshot still refuses fusion')
    hook_start = bridge.find('- (BOOL)horosRenderMetalImageForMapper:')
    hook = braced(bridge, hook_start) if hook_start >= 0 else ''
    for needle, why in [('BOOL fused = blendingVolume && renderVolume == blendingVolume && mapper == blendingVolumeMapper;', 'the hook does not know the fused mapper'),
                        ('(renderVolume != self.volume && !fused)', 'the hook still turns the fused volume away'),
                        ('if (!fused && !blendingVolume) [controller horosFusedVolumeMetalRelease];', 'a series fused and then closed stays on the GPU'),
                        ('(snapshot = [self horosFusedVolumeSnapshot])', 'the fused volume does not take its own snapshot'),
                        ('horosVolumeMetalRender:snapshot fused:fused ', 'the fused volume is not rendered with its own renderer'),
                        ('HorosRayCastImageRegion(mapper)', 'the hook does not render on the calling mapper\'s own grid')]:
        if needle not in hook:
            failures.append(why)
    if 'blendingVolume || blendingController' in hook:
        failures.append('the hook still refuses fusion')
    for found in re.finditer(re.escape('snapshot = [self horosVolumeSnapshot]'), hook):
        guards = [guard.start() for guard in re.finditer(re.escape('if (!fused) {'), hook[:found.start()])]
        if not any(found.start() < guard + len(braced(hook, guard)) for guard in guards):
            failures.append('the fused volume is rendered from the image\'s snapshot')
    fused_start = bridge.find('- (NSDictionary *)horosFusedVolumeSnapshot {')
    fused = braced(bridge, fused_start) if fused_start >= 0 else ''
    for needle, why in [('[self horosMPRFusedVolume]', 'the fused voxels and placement'),
                        ('[self horosVolumeCameraSnapshot]', 'the view\'s camera'),
                        ('double level = blendingWl, windowWidth = blendingWw > 0 ? blendingWw : 1;', 'the fused window level'),
                        ('blendingWw > 0 ? blendingWw : 1', 'the fused window width'),
                        ('blendingtable[i][0] * 255', 'the fused CLUT'),
                        ('HorosFusedOpacityPoints(alpha,', 'the fused opacity table'),
                        ('HorosShading(aRenderer, blendingVolumeProperty)', 'the fused shading, with the renderer\'s lights'),
                        ('HorosCuttingPlanes(blendingVolumeMapper,', 'the fused mapper\'s crop planes'),
                        ('blendingVolumeMapper->GetSampleDistance() / factor', 'the fused mapper\'s step'),
                        ('@"scalarBackground": isBlendingRGB ? @(-1) : fused[@"background"]', 'the value a missed ray reads back'),
                        ('@"mode": @(renderingMode)', 'the view\'s mode')]:
        if needle not in fused:
            failures.append('the fused snapshot does not carry ' + why)
    for needle, why in [('fused ? &fusedRendererKey : &rendererKey', 'the volumes share one renderer'),
                        ('fused ? &fusedUploadedKey : &uploadedKey', 'the volumes share one upload'),
                        ('return renderer.volumeBytes + fused.volumeBytes;', 'the GPU bytes miss the fused volume')]:
        if needle not in bridge:
            failures.append(why)

# The opacity and the picture, compiled from the source.
names = ('static void HorosFusedOpacityPoints(', 'static NSData *HorosVolumePicture(')
missing = [name for name in names if bridge is not None and name not in bridge]
if missing:
    failures.append('missing from the bridge: ' + ', '.join(missing))
elif bridge is None:
    # The module's rules, as the host calls them.
    sys.path.insert(0, str(root / 'tests'))
    import isix_modules
    if 'Self.volumePicture(bgra: pixels, scalar: opacity, projection: renderingMode == 0 ? nil : snapshot)' not in host or \
            'return RayCastPicture.composite(bgra: bgra as Data, opacity: scalar as Data) as NSData?' not in host:
        failures.append('the hook does not paint a composite picture with the module\'s conversion')
    program = r'''
import Foundation
import IsiXVolumeRendering
var composite = [Double](repeating: 0, count: 257), projection = composite
for i in 0..<256 {
    composite[i] = fmin(255, fmax(0, (200 / 3.0) * Double(i) / 256.0 - 8)) / 255.0
    projection[i] = fmin(255, fmax(0, 2 * 200.0 * Double(i) / 256.0)) / 255.0
}
let first = composite.withUnsafeBufferPointer { VolumeOpacityCurve.fusedPoints(table: $0.baseAddress!, samplesPerMillimetre: 2.19) }
let second = projection.withUnsafeBufferPointer { VolumeOpacityCurve.fusedPoints(table: $0.baseAddress!, samplesPerMillimetre: 1.0) }
var alpha: [Float] = [0.75, 0]
let under = RayCastPicture.composite(bgra: Data([40, 80, 160, 255, 0, 0, 0, 255]), opacity: Data(bytes: &alpha, count: 8))!
let words = under.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
let out: [String: Any] = ["composite": ["opacity": first.opacity, "projection": first.projection],
                          "mip": ["opacity": second.opacity, "projection": second.projection], "underPicture": words.map { Int($0) }]
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
'''
    with tempfile.TemporaryDirectory() as work:
        (Path(work) / 'fusion.swift').write_text(program)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *isix_modules.module_flags('IsiXVolumeRendering', Path(work) / 'module'),
                                str(Path(work) / 'fusion.swift'), '-o', str(Path(work) / 'fusion')], capture_output=True, text=True)
        if built.returncode:
            sys.exit('FAIL: the harness does not build:\n' + built.stderr[-3000:])
        result = json.loads(subprocess.run([str(Path(work) / 'fusion')], capture_output=True, text=True, check=True, timeout=60).stdout)
else:
    helpers = '\n'.join(braced(bridge, bridge.index(name)) for name in names)
    harness = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#include <cmath>
@interface HorosVolumeRenderer : NSObject
+ (NSData *)projectionPictureWithScalar:(NSData *)scalar level:(double)level width:(double)width clut:(NSData *)clut
                          opacityPoints:(NSArray *)points background:(double)background;
+ (NSData *)projectionPictureWithScalar:(NSData *)scalar level:(double)level width:(double)width colourTable:(NSData *)colour
                           opacityTable:(NSData *)opacity background:(double)background;
@end
@implementation HorosVolumeRenderer
+ (NSData *)projectionPictureWithScalar:(NSData *)scalar level:(double)level width:(double)width clut:(NSData *)clut
                          opacityPoints:(NSArray *)points background:(double)background { return nil; }
+ (NSData *)projectionPictureWithScalar:(NSData *)scalar level:(double)level width:(double)width colourTable:(NSData *)colour
                           opacityTable:(NSData *)opacity background:(double)background { return nil; }
@end
// The colour paths are not what this harness measures.
@interface HorosMPRColourPlane : NSObject
+ (NSData *)pictureWithComponents:(NSData *)values count:(NSInteger)count tables:(NSArray *)tables;
@end
@implementation HorosMPRColourPlane
+ (NSData *)pictureWithComponents:(NSData *)values count:(NSInteger)count tables:(NSArray *)tables { return nil; }
@end
HELPERS
int main() { @autoreleasepool {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    // Two tables as setBlendingFactor: builds them: composite (a/3 i/256 - 8) and MIP (2a i/256), then /255.
    double composite[257], projection[257];
    for (int i = 0; i < 256; ++i) {
        composite[i] = fmin(255, fmax(0, (200 / 3.0) * i / 256.0 - 8)) / 255.0;
        projection[i] = fmin(255, fmax(0, 2 * 200.0 * i / 256.0)) / 255.0;
    }
    composite[256] = projection[256] = 0;
    NSMutableArray *o1 = [NSMutableArray array], *p1 = [NSMutableArray array], *o2 = [NSMutableArray array], *p2 = [NSMutableArray array];
    HorosFusedOpacityPoints(composite, 2.19, o1, p1);
    HorosFusedOpacityPoints(projection, 1.0, o2, p2);
    out[@"composite"] = @{@"opacity": o1, @"projection": p1};
    out[@"mip"] = @{@"opacity": o2, @"projection": p2};
    // Two pixels: BGRA from Metal with its accumulated opacity.
    unsigned char imageBGRA[8] = {40, 80, 160, 255, 0, 0, 0, 255};
    float imageAlpha[2] = {0.75f, 0.0f};
    NSData *under = HorosVolumePicture([NSData dataWithBytes:imageBGRA length:8], [NSData dataWithBytes:imageAlpha length:8], nil);
    NSMutableArray *u = [NSMutableArray array];
    for (NSUInteger i = 0; i < under.length / 2; ++i) [u addObject:@(((const unsigned short *)under.bytes)[i])];
    out[@"underPicture"] = u;
    printf("%s\n", [[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:out options:0 error:nil] encoding:NSUTF8StringEncoding] UTF8String]);
} return 0; }
'''.replace('HELPERS', helpers)
    with tempfile.TemporaryDirectory() as work:
        program = Path(work) / 'fusion.mm'
        program.write_text(harness)
        binary = Path(work) / 'fusion'
        built = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-x', 'objective-c++', str(program),
                                '-framework', 'Foundation', '-framework', 'Accelerate', '-o', str(binary)], capture_output=True, text=True)
        if built.returncode:
            sys.exit('FAIL: the harness does not build:\n' + built.stderr[-3000:])
        result = json.loads(subprocess.run([str(binary)], capture_output=True, text=True, check=True).stdout)

if not missing:
    def vtk_table(table, x):
        # BuildFunctionFromTable(x1, x2, 255, table): entry i at x1 + i (x2 - x1) / 254, linear between, clamped outside.
        position = min(254.0, max(0.0, x / 256.0 * 254.0))
        lower = int(position); upper = min(254, lower + 1)
        return table[lower] + (table[upper] - table[lower]) * (position - lower)

    def renderer_table(flat):
        # VolumeTransferFunction.opacityTable: entry i is the curve at 256 i / 255.
        curve = sorted(zip(flat[0::2], flat[1::2]))
        if curve[0][0] > 0: curve.insert(0, (0.0, 0.0))
        if curve[-1][0] < 256: curve.append((256.0, 1.0))
        table = []
        for index in range(256):
            x = index * 256 / 255
            previous = curve[0]; value = min(1, max(0, curve[-1][1]))
            for point in curve[1:]:
                if x <= point[0]:
                    span = point[0] - previous[0]
                    t = (x - previous[0]) / span if span > 0 else 1
                    value = min(1, max(0, previous[1] + (point[1] - previous[1]) * t)); break
                previous = point
            table.append(value)
        return table

    for name, spm, formula in (('composite', 2.19, lambda i: min(255, max(0, (200 / 3) * i / 256 - 8)) / 255),
                               ('mip', 1.0, lambda i: min(255, max(0, 2 * 200 * i / 256)) / 255)):
        table = [formula(i) for i in range(256)]
        opacity = renderer_table(result[name]['opacity'])
        worst = max(abs(opacity[i] - (1 - (1 - vtk_table(table, i * 256 / 255)) ** spm)) for i in range(256))
        if worst > 1e-6:
            failures.append('%s: the fused opacity the renderer expands differs from VTK\'s function by %.2e' % (name, worst))
        projection = result[name]['projection']
        if [round(v, 12) for v in projection[1::2]] != [round(table[i], 12) for i in range(255)] or \
           any(abs(x - i * 256 / 254) > 1e-9 for i, x in enumerate(projection[0::2])):
            failures.append('%s: a projection does not get the fused table itself over the window' % name)

    # The image's picture: RGBA in VTK's 15 bits, premultiplied, from Metal's BGRA.
    expected_under = [(160 * 32767 + 127) // 255, (80 * 32767 + 127) // 255, (40 * 32767 + 127) // 255, int(0.75 * 32767 + 0.5), 0, 0, 0, 0]
    if result['underPicture'] != expected_under:
        failures.append('the picture does not turn Metal\'s BGRA into VTK\'s RGBA: %s' % result['underPicture'])

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('ok: the fused series ray-casts in Metal with its own window, CLUT, opacity and crop, and VTK composes it')
