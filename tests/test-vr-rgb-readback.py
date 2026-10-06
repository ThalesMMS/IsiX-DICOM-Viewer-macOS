#!/usr/bin/env python3
"""The colour full-depth readback takes each pixel's own colour.

-[VRView imageInFullDepthWidth:height:isRGB:blendingView:] reads VTK's
ray-cast image back as ARGB bytes whenever the result is colour: an RGB
volume's planes in the MPR and the CPR, and the VR's full-depth capture, for
ROIs and for export, a scalar volume in composite included. The image is
RGBA, four unsigned shorts per pixel with R first, and the colour branch
started on the alpha and skipped it: every pixel took the R, G and B of its
right-hand neighbour, and the last of each row read past the width in use.

The colour branch is compiled here from the source and run on a synthetic
ray-cast image whose memory rows are wider than the width in use, with a
distinct colour in every pixel: each output pixel, rows top first, must be
255 and its own R, G and B shifted by 7.

A projection read in full depth takes the value from the fourth word:
`-prepareFullDepthCapture` installs a linear opacity table so that VTK's caster
wrote the projected value there, and Metal, which draws the view,
painted its opacity curve instead, so the 16-bit MIP export held the curve.
The Metal hook now writes the value itself in full-depth mode. Its writer,
from VRHostBridge.mm, fills a synthetic ray-cast image here, and the
projection branch of the readback, from VRView.mm, must give each pixel's own
value back, to the 16-bit step.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
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
    depth, index = 0, text.index('{', start)
    while True:
        if text[index] == '{': depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0: return text[start:index + 1]
        index += 1


def colour_branch(source):
    method = source[source.index('- (float*) imageInFullDepthWidth: (long*) w height:(long*) h isRGB:(BOOL*) rgb blendingView:(BOOL) blendingView'):]
    start = method.index('unsigned char *destPtr, *destFixedPtr;')
    allocation = method.index('if( destFixedPtr)', start)
    return method[start:allocation] + braced(method, allocation)


failures = []
branch = colour_branch(read('Horos/Sources/VRView.mm'))

WIDTH, HEIGHT, MEMORY_WIDTH, MEMORY_HEIGHT = 7, 5, 10, 7
harness = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
static unsigned char *readback(unsigned short *im, int fullSize[2], long *w, long *h, BOOL *rgb) {
    float *returnedPtr = nil;
    BRANCH
    return (unsigned char *)returnedPtr;
}
int main() { @autoreleasepool {
    int fullSize[2] = {MEMORY_WIDTH, MEMORY_HEIGHT};
    long w = WIDTH, h = HEIGHT; BOOL rgb = NO;
    unsigned short *im = calloc(fullSize[0] * fullSize[1] * 4, sizeof(unsigned short));
    for (int y = 0; y < fullSize[1]; ++y)
        for (int x = 0; x < fullSize[0]; ++x) {
            unsigned short *pixel = im + 4 * (y * fullSize[0] + x);
            pixel[0] = (unsigned short)(128 * (10 * x + y + 1));
            pixel[1] = (unsigned short)(128 * (20 + 7 * x + 3 * y));
            pixel[2] = (unsigned short)(128 * (200 - 9 * x - 5 * y));
            pixel[3] = 32767;
        }
    unsigned char *out = readback(im, fullSize, &w, &h, &rgb);
    NSMutableArray *bytes = [NSMutableArray array];
    for (long k = 0; k < w * h * 4; ++k) [bytes addObject:@(out[k])];
    printf("%s\n", [[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@{@"rgb": @(rgb), @"bytes": bytes} options:0 error:nil]
                                             encoding:NSUTF8StringEncoding] UTF8String]);
} return 0; }
'''.replace('BRANCH', branch).replace('MEMORY_WIDTH', str(MEMORY_WIDTH)).replace('MEMORY_HEIGHT', str(MEMORY_HEIGHT)) \
   .replace('WIDTH', str(WIDTH)).replace('HEIGHT', str(HEIGHT))

with tempfile.TemporaryDirectory() as work:
    program = Path(work) / 'readback.m'
    program.write_text(harness)
    binary = Path(work) / 'readback'
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-x', 'objective-c', str(program),
                            '-framework', 'Foundation', '-framework', 'Accelerate', '-o', str(binary)], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the harness does not build:\n' + built.stderr[-3000:])
    result = json.loads(subprocess.run([str(binary)], capture_output=True, text=True, check=True).stdout)

if not result['rgb']:
    failures.append('the colour branch does not report a colour image')
wrong = []
for row in range(HEIGHT):
    y = HEIGHT - 1 - row                      # VTK keeps the bottom row first
    for x in range(WIDTH):
        expected = [255, (10 * x + y + 1), (20 + 7 * x + 3 * y), (200 - 9 * x - 5 * y)]
        got = result['bytes'][4 * (row * WIDTH + x):4 * (row * WIDTH + x) + 4]
        if got != expected:
            wrong.append((x, row, got, expected))
if wrong:
    x, row, got, expected = wrong[0]
    failures.append('%d of %d pixels take another pixel\'s colour; pixel (%d, %d) is %s, its own colour is %s'
                    % (len(wrong), WIDTH * HEIGHT, x, row, got, expected))


# The projection in full depth.
bridge = read('Horos/Sources/VRHostBridge.mm')
view = read('Horos/Sources/VRView.mm')
writer_start = bridge.find('static void HorosWriteFullDepthProjection(')
hook = bridge[bridge.index('- (BOOL)horosRenderMetalImageForMapper:'):]
hook = braced(hook, 0)
if writer_start < 0 or not re.search(r'if \(fullDepthMode && renderingMode != 0 && !colourProjection\)\s*HorosWriteFullDepthProjection\(', hook):
    failures.append('the Metal hook does not write the projected values of a full-depth capture')
else:
    writer = braced(bridge, writer_start)
    method = view[view.index('- (float*) imageInFullDepthWidth: (long*) w height:(long*) h isRGB:(BOOL*) rgb blendingView:(BOOL) blendingView'):]
    projection = braced(method, method.index('if( firstObject.isRGB == NO && ( renderingMode == 1'))
    projection = projection[projection.index('{'):]
    VALUES = [[-1024.0 + 97.3 * (x + 1) * (y + 2) if (x + y) % 5 else float('nan') for x in range(WIDTH)] for y in range(HEIGHT)]
    VALUES[0][0], VALUES[1][1] = 3071.0, -1024.0
    OFFSET, FACTOR = 1024.0, 2.0
    projection_harness = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
WRITER
static float *readback(unsigned short *im, int fullSize[2], long *w, long *h, BOOL *rgb) {
    float *returnedPtr = nil;
    BOOL blendingView = NO;
    float valueFactor = HARNESS_FACTOR, OFFSET16 = HARNESS_OFFSET, blendingValueFactor = 1, blendingOFFSET16 = 0;
    PROJECTION
    return returnedPtr;
}
int main() { @autoreleasepool {
    int fullSize[2] = {MEMORY_WIDTH, MEMORY_HEIGHT};
    long w = WIDTH, h = HEIGHT; BOOL rgb = YES;
    unsigned short *im = (unsigned short *)calloc(fullSize[0] * fullSize[1] * 4, sizeof(unsigned short));
    const float values[] = {VALUES};
    HorosWriteFullDepthProjection(im, fullSize[0] * 4, WIDTH, HEIGHT, values, HARNESS_OFFSET, HARNESS_FACTOR);
    float *out = readback(im, fullSize, &w, &h, &rgb);
    NSMutableArray *read = [NSMutableArray array];
    for (long k = 0; k < w * h; ++k) [read addObject:@(out[k])];
    printf("%s\n", [[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@{@"rgb": @(rgb), @"values": read} options:0 error:nil]
                                             encoding:NSUTF8StringEncoding] UTF8String]);
} return 0; }
'''.replace('WRITER', writer).replace('PROJECTION', projection) \
       .replace('VALUES', ', '.join('NAN' if v != v else repr(v) for row in VALUES for v in row)) \
       .replace('MEMORY_WIDTH', str(MEMORY_WIDTH)).replace('MEMORY_HEIGHT', str(MEMORY_HEIGHT)) \
       .replace('WIDTH', str(WIDTH)).replace('HEIGHT', str(HEIGHT)).replace('HARNESS_FACTOR', repr(FACTOR)).replace('HARNESS_OFFSET', repr(OFFSET))
    with tempfile.TemporaryDirectory() as work:
        program = Path(work) / 'projection.mm'
        program.write_text(projection_harness)
        binary = Path(work) / 'projection'
        built = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-x', 'objective-c++', str(program),
                                '-framework', 'Foundation', '-framework', 'Accelerate', '-o', str(binary)], capture_output=True, text=True)
        if built.returncode:
            sys.exit('FAIL: the projection harness does not build:\n' + built.stderr[-3000:])
        projected = json.loads(subprocess.run([str(binary)], capture_output=True, text=True, check=True).stdout)
    if projected['rgb']:
        failures.append('the projection branch reports a colour image')
    wrong = []
    for y in range(HEIGHT):
        for x in range(WIDTH):
            value = VALUES[y][x]
            expected = -OFFSET if value != value else round((value + OFFSET) * FACTOR) / FACTOR - OFFSET
            got = projected['values'][y * WIDTH + x]
            if abs(got - expected) > 1e-3:
                wrong.append((x, y, got, expected))
    if wrong:
        x, y, got, expected = wrong[0]
        failures.append('%d of %d projected values do not come back; pixel (%d, %d) reads %s, its value is %s'
                        % (len(wrong), WIDTH * HEIGHT, x, y, got, expected))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('ok: the colour full-depth readback takes each pixel\'s own colour, '
      'and a projection in full depth reads back each pixel\'s value')
