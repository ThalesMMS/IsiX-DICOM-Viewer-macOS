#!/usr/bin/env python3
"""A fused series ray-casts in Metal in the 3D viewer.

The 3D viewer draws a fused series as a second vtkVolume with its own
vtkHorosFixedPointVolumeRayCastMapper, after the image's; each mapper casts
its rays into its own ray-cast image, and VTK draws the images one over the
other with GL_ONE, GL_ONE_MINUS_SRC_ALPHA. The Metal hook now fills the fused
mapper's image too, from a snapshot of the fused series, and VTK keeps the
composition. Checked here:

* the wiring: the fusion refusal is gone from the snapshot and the hook; the
  hook takes the fused mapper and volume; setBlendingEngine: hands the fused
  mapper the hook; setMode: sets the fused mapper's mode, as the MPR and CPR
  controllers already do; each volume has its own renderer and upload, and a
  series fused and then closed leaves the GPU;
* the fused snapshot reads the fused window, CLUT, opacity table, shading,
  crop planes, step and background, under the view's camera;
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
bridge = read('Horos/Sources/VRHostBridge.mm')
view = read('Horos/Sources/VRView.mm')

# The wiring.
if 'Fusion keeps the original renderer' in bridge:
    failures.append('the snapshot still refuses fusion')
hook_start = bridge.find('- (BOOL)horosRenderMetalImageForMapper:')
hook = braced(bridge, hook_start) if hook_start >= 0 else ''
for needle, why in [('BOOL fused = blendingVolume && renderVolume == blendingVolume && mapper == blendingVolumeMapper;', 'the hook does not know the fused mapper'),
                    ('(renderVolume != self.volume && !fused)', 'the hook still turns the fused volume away'),
                    ('if (!fused && !blendingVolume) [controller horosFusedVolumeMetalRelease];', 'a series fused and then closed stays on the GPU'),
                    ('horosFusedVolumeMetalRenderSnapshot:snapshot', 'the fused volume is not rendered from its own snapshot'),
                    ('HorosRayCastImageRegion(mapper)', 'the hook does not render on the calling mapper\'s own grid')]:
    if needle not in hook:
        failures.append(why)
if 'blendingVolume || blendingController' in hook:
    failures.append('the hook still refuses fusion')
engine = view[view.find('- (void) setBlendingEngine: (long) engineID showWait:(BOOL) showWait'):]
engine = braced(engine, 0) if engine else ''
if 'blendingVolumeMapper->SetImageRenderer(HorosRenderMetalVolume, self);' not in engine:
    failures.append('setBlendingEngine: does not hand the fused mapper the Metal hook')
mode = view[view.find('- (void) setMode: (long) modeID'):]
mode = braced(mode, 0) if mode else ''
if '[self setBlendingMode: modeID];' not in mode or mode.find('[self setBlendingMode: modeID];') > mode.find('[self setBlendingFactor: blendingFactor];'):
    failures.append('setMode: leaves the fused mapper in the mode it was fused in')
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
missing = [name for name in names if name not in bridge]
if missing:
    failures.append('missing from the bridge: ' + ', '.join(missing))
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
