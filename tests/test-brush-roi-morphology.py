#!/usr/bin/env python3
"""Erode/Dilate/Open/Close of a brush ROI with radius 1 change the mask.

ITKBrushROIFilter (Swift) runs vImage's erosion and dilation with the elements
of IsiXSegmentation's MorphologyKernel; it is compiled here with the module and
run, as the app runs it, on a ROI reduced to its texture buffer, and the
module's disc is reached as draw_filled_circle. The mask is the wall-3 tube of
tools/generate-seg-surface-fixture.py as one slice holds it: a 10 x 10 square
ring with a 4 x 4 hole, 84 pixels.

Radius 1 used to draw only the centre of its 3 x 3 element, and vImage returns
the mask unchanged with that. It is now the disc of radius 1 (the cross), and
each operation is compared with a direct computation of the same operation by
the cross: erosion 32 pixels, dilation 136. Radius 2 stays the 3 x 3 square
(28 and 140 per slice). The elements of radii 2 to 20 are compared byte by
byte with the Objective-C++ implementation from before that change, taken from
history, which is also run to show that radius 1 changed nothing.
(tests/test-itk-segmentation-equivalence.py compares the filter with the last
Objective-C++ one.)

The filter is shared by the concurrent operations of -applyMorphology: and
builds an element on first use. The source must draw the element before it is
published, under the filter's lock, and many operations at once on fresh
filters must each give the result of the operation alone. (The race itself
was never caught by running the former code.)
"""
import private_tmpdir  # noqa: F401  (a TMPDIR of the test's own)
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

path = 'Horos/Sources/ITKBrushROIFilter.mm'
swift = root / 'Horos/Sources/ITKBrushROIFilter.swift'


def region(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin) + len(end)]


def circle(text):
    return region(text, 'void draw_filled_circle(unsigned char *buf, int width, unsigned char val)\n{', '\n}\n')


def implementation(text):
    return region(text, '@implementation ITKBrushROIFilter', '\n@end')


source = swift.read_text()


def revision_containing(marker):
    listed = subprocess.run(['git', 'log', '--format=%H', '--', path], cwd=str(root), capture_output=True, text=True)
    for revision in listed.stdout.split():
        shown = subprocess.run(['git', 'show', '%s:%s' % (revision, path)], cwd=str(root), capture_output=True)
        if shown.returncode == 0:
            content = shown.stdout.decode('latin1')
            if marker in content and 'if( width == 3)' not in circle(content):
                return content
    return None


# Each element is drawn before it is published, under the filter's lock (the
# concurrent run below cannot force the interleaving).
body = region(source, 'private func element(side: Int, erosion: Bool) -> [UInt8] {', '\n        return element\n    }')
assert 'lock.lock()' in body and 'defer { lock.unlock() }' in body, 'the elements are built without the lock'
drawn = body.index('MorphologyKernel.erosion(side: side) : MorphologyKernel.dilation(side: side)')
assert drawn < body.index('erosionElements[side] = element') and drawn < body.index('dilationElements[side] = element'), \
    'an element is published before it is drawn'
for operation in ('erode', 'dilate'):
    method = region(source, 'public func %s(_ aROI: ROI?' % operation, '\n    }')
    assert 'filter(aROI, side:' in method, '-%s: reads the element without the accessor' % operation

old = revision_containing('void draw_filled_circle(unsigned char *buf, int width, unsigned char val)')
old_circle = circle(old).replace('draw_filled_circle', 'draw_filled_circle_before') if old else ''
old_implementation = (implementation(old).replace('@implementation ITKBrushROIFilter', '@implementation ITKBrushROIFilterBefore')
                      .replace('draw_filled_circle', 'draw_filled_circle_before')) if old else ''

ROI_HEADER = r'''
#import <Cocoa/Cocoa.h>
// A brush ROI, reduced to its texture buffer.
@interface ROI : NSObject {
@public
    unsigned char *buffer;
    int width, height;
}
@property (readonly) unsigned char *textureBuffer;
@property (readonly) int textureWidth, textureHeight;
- (void)textureBufferHasChanged;
- (BOOL)reduceTextureIfPossible;
- (void)addMarginToBuffer:(int)margin;
@end
'''

# The module's disc, under the name the harness and the former code use.
SHIM = r'''
import IsiXSegmentation
@_cdecl("draw_filled_circle")
public func drawFilledCircle(_ buffer: UnsafeMutablePointer<UInt8>, _ width: Int32, _ value: UInt8) {
    let count = Int(width) * Int(width)
    var element = Array(UnsafeBufferPointer(start: buffer, count: count))
    MorphologyKernel.drawDisc(&element, side: Int(width), value: value)
    buffer.update(from: element, count: count)
}
'''

code = r'''
#include <Accelerate/Accelerate.h>
#import <Cocoa/Cocoa.h>
#import "ROI.h"
#include <string.h>

static int failures;
#define check(c, ...) do { if (!(c)) { printf("FAIL line %d: %s: ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)
#define CURRENT_FILTER NSClassFromString(@"ITKBrushROIFilter")

extern "C" void draw_filled_circle(unsigned char *buf, int width, unsigned char val);

@implementation ROI
- (unsigned char *)textureBuffer { return buffer; }
- (int)textureWidth { return width; }
- (int)textureHeight { return height; }
- (void)textureBufferHasChanged {}
- (BOOL)reduceTextureIfPossible { return NO; }
- (void)addMarginToBuffer:(int)margin {
    int w = width + 2 * margin, h = height + 2 * margin;
    unsigned char *grown = (unsigned char *)calloc(w * h, 1);
    for (int y = 0; y < height; y++) memcpy(grown + (y + margin) * w + margin, buffer + y * width, width);
    free(buffer);
    buffer = grown; width = w; height = h;
}
- (void)dealloc { free(buffer); [super dealloc]; }
@end

#if HAVE_BEFORE
@interface ITKBrushROIFilterBefore : NSObject { unsigned char *kernelDilate, *kernelErode; } @end
@@OLD_CIRCLE@@
@@OLD_IMPLEMENTATION@@
#endif

// The tube of the fixture in one slice: a 10 x 10 square ring, wall 3, placed
// `margin` pixels inside a texture of (10 + 2 margin)^2.
static ROI *ring(int margin) {
    ROI *roi = [[[ROI alloc] init] autorelease];
    roi->width = roi->height = 10 + 2 * margin;
    roi->buffer = (unsigned char *)calloc(roi->width * roi->height, 1);
    for (int y = 0; y < 10; y++)
        for (int x = 0; x < 10; x++)
            if (!(x >= 3 && x <= 6 && y >= 3 && y <= 6)) roi->buffer[(y + margin) * roi->width + x + margin] = 0xFF;
    return roi;
}

static long count(ROI *roi) {
    long n = 0;
    for (int i = 0; i < roi->width * roi->height; i++) n += roi->buffer[i] != 0;
    return n;
}

// Erosion or dilation by an element given as offsets, computed directly; outside the texture is empty.
static void direct(ROI *roi, bool erode, int radius, bool cross) {
    unsigned char *out = (unsigned char *)calloc(roi->width * roi->height, 1);
    for (int y = 0; y < roi->height; y++)
        for (int x = 0; x < roi->width; x++) {
            bool all = true, any = false;
            for (int dy = -radius; dy <= radius; dy++)
                for (int dx = -radius; dx <= radius; dx++) {
                    if (cross && dx * dx + dy * dy > radius * radius) continue;
                    int u = x + dx, v = y + dy;
                    bool on = u >= 0 && v >= 0 && u < roi->width && v < roi->height && roi->buffer[v * roi->width + u];
                    all = all && on; any = any || on;
                }
            out[y * roi->width + x] = (erode ? all : any) ? 0xFF : 0;
        }
    free(roi->buffer);
    roi->buffer = out;
}

// The operation by the radius-1 cross (radius 1) or the 3 x 3 square (radius 2), directly.
static long expect(NSString *operation, int radius, int margin) {
    ROI *roi = ring(margin);
    bool cross = radius == 1;
    if ([operation isEqualToString:@"erode"] || [operation isEqualToString:@"open"]) direct(roi, true, 1, cross);
    if (![operation isEqualToString:@"erode"]) direct(roi, false, 1, cross);
    if ([operation isEqualToString:@"close"]) direct(roi, true, 1, cross);
    return count(roi);
}

static ROI *apply(Class filterClass, NSString *operation, int radius, int margin) {
    ROI *roi = ring(margin);
    id filter = [[filterClass alloc] init];
    SEL selector = NSSelectorFromString([operation stringByAppendingString:@":withStructuringElementRadius:"]);
    ((void (*)(id, SEL, ROI *, int))objc_msgSend)(filter, selector, roi, radius);
    [filter release];
    return roi;
}

int main() {
    @autoreleasepool {
        // Radius 1: the cross, 0xFF on it for the erosion and 0 on it for the dilation.
        unsigned char element[9] = {0};
        draw_filled_circle(element, 3, 0xFF);
        const unsigned char cross[9] = {0, 0xFF, 0, 0xFF, 0xFF, 0xFF, 0, 0xFF, 0};
        check(memcmp(element, cross, 9) == 0, "radius 1 is not the cross");

#if HAVE_BEFORE
        // Radii 2 to 20: the elements are those of before, byte by byte.
        for (int radius = 2; radius <= 20; radius++) {
            int w = 2 * radius + 1;
            unsigned char *now = (unsigned char *)calloc(w * w, 1), *then = (unsigned char *)calloc(w * w, 1);
            draw_filled_circle(now, w, 0xFF);
            draw_filled_circle_before(then, w, 0xFF);
            check(memcmp(now, then, w * w) == 0, "radius %d element changed", radius);
            memset(now, 0xFF, w * w); memset(then, 0xFF, w * w);
            draw_filled_circle(now, w, 0);
            draw_filled_circle_before(then, w, 0);
            check(memcmp(now, then, w * w) == 0, "radius %d dilation element changed", radius);
            free(now); free(then);
        }
#endif

        const int margin = 6;
        long original = count(ring(margin));
        check(original == 84, "the ring has %ld pixels", original);

        struct { int radius; long erode, dilate; } expected[] = {
            {1, 32, 136},   // the cross
            {2, 28, 140},   // the 3 x 3 square (448 and 2240 over 16 slices)
        };
        for (auto &e : expected)
            for (NSString *operation in @[@"erode", @"dilate", @"open", @"close"]) {
                long got = count(apply(CURRENT_FILTER, operation, e.radius, margin));
                long want = expect(operation, e.radius, margin);
                printf("radius %d %-6s %3ld pixels (direct %3ld)\n", e.radius, operation.UTF8String, got, want);
                check(got == want, "radius %d %s: %ld, direct %ld", e.radius, operation.UTF8String, got, want);
                if ([operation isEqualToString:@"erode"]) check(got == e.erode && got != original, "radius %d erosion %ld", e.radius, got);
                if ([operation isEqualToString:@"dilate"]) check(got == e.dilate && got != original, "radius %d dilation %ld", e.radius, got);
            }
        // Radius 1 and 2 differ: the slider's first step is a step.
        check(count(apply(CURRENT_FILTER, @"erode", 1, margin)) != count(apply(CURRENT_FILTER, @"erode", 2, margin)),
              "radius 1 and 2 erode alike");

#if HAVE_BEFORE
        long before1 = count(apply([ITKBrushROIFilterBefore class], @"erode", 1, margin));
        long before1d = count(apply([ITKBrushROIFilterBefore class], @"dilate", 1, margin));
        printf("former filter, radius 1: erode %ld, dilate %ld\n", before1, before1d);
        check(before1 == original && before1d == original, "radius 1 in the former filter should change nothing");
        for (int radius = 2; radius <= 5; radius++)
            for (NSString *operation in @[@"erode", @"dilate", @"open", @"close"]) {
                ROI *now = apply(CURRENT_FILTER, operation, radius, margin);
                ROI *then = apply([ITKBrushROIFilterBefore class], operation, radius, margin);
                check(now->width == then->width && now->height == then->height
                      && memcmp(now->buffer, then->buffer, now->width * now->height) == 0,
                      "radius %d %s differs from before", radius, operation.UTF8String);
            }
#endif

        // -applyMorphology: runs one operation per ROI on a concurrent queue, all
        // with one filter, which builds its element on first use. Many ROIs at once on a
        // fresh filter must each come out as the same operation run alone.
        long mismatches = 0, beforeMismatches = 0, runs = 0;
        for (int radius = 1; radius <= 3; radius++)
            for (NSString *operation in @[@"erode", @"dilate"]) {
                ROI *alone = apply(CURRENT_FILTER, operation, radius, margin);
                SEL selector = NSSelectorFromString([operation stringByAppendingString:@":withStructuringElementRadius:"]);
                for (int trial = 0; trial < 300; trial++) {
                    for (int version = 0; version < (HAVE_BEFORE ? 2 : 1); version++) {
                        Class filterClass = version ? NSClassFromString(@"ITKBrushROIFilterBefore") : CURRENT_FILTER;
                        if (version && radius == 1) continue;   // radius 1 of the former filter is the identity
                        ROI *reference = version ? apply(filterClass, operation, radius, margin) : alone;
                        id filter = [[filterClass alloc] init];
                        const int count = 16;
                        NSMutableArray *rois = [NSMutableArray array];
                        for (int i = 0; i < count; i++) [rois addObject:ring(margin)];
                        dispatch_apply(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
                            ((void (*)(id, SEL, ROI *, int))objc_msgSend)(filter, selector, rois[i], radius);
                        });
                        [filter release];
                        for (ROI *roi in rois) {
                            bool same = roi->width == reference->width && roi->height == reference->height
                                && memcmp(roi->buffer, reference->buffer, roi->width * roi->height) == 0;
                            if (!same) { if (version) beforeMismatches++; else mismatches++; }
                            if (!version) runs++;
                        }
                    }
                }
            }
        printf("concurrent: %ld operations on shared fresh filters, %ld differ from the operation alone"
               " (former filter: %ld)\n", runs, mismatches, beforeMismatches);
        check(mismatches == 0, "%ld concurrent operations differ from the operation alone", mismatches);
    }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("ok\n");
    return 0;
}
'''

code = code.replace('@@OLD_CIRCLE@@', old_circle).replace('@@OLD_IMPLEMENTATION@@', old_implementation)
code = code.replace('#import <Cocoa/Cocoa.h>', '#import <Cocoa/Cocoa.h>\n#import <objc/message.h>\n#define HAVE_BEFORE %d' % (1 if old else 0), 1)


def run(command):
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode:
        print(done.stderr[-4000:])
        sys.exit(1)


with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'ROI.h').write_text(ROI_HEADER)
    (folder / 'Shim.swift').write_text(SHIM)
    (folder / 'harness.mm').write_text(code, encoding='latin1')
    modules = isix_modules.module_flags('IsiXSegmentation', folder / 'modules')
    run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'Harness', '-wmo',
         '-import-objc-header', str(folder / 'ROI.h'), *modules, '-c', '-o', str(folder / 'swift.o'),
         str(swift), str(folder / 'Shim.swift')])
    run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-w', '-x', 'objective-c++', '-I', str(folder), '-c',
         str(folder / 'harness.mm'), '-o', str(folder / 'harness.o')])
    run(['xcrun', 'swiftc', '-o', str(folder / 'harness'), str(folder / 'swift.o'), str(folder / 'harness.o'), *modules,
         '-lc++', '-framework', 'Cocoa', '-framework', 'Accelerate'])
    try:
        result = subprocess.run([str(folder / 'harness')], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        print('FAIL: the harness did not finish within 120 s')
        sys.exit(1)
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr[-2000:])
        sys.exit(1)
if not old:
    print("note: the former filter is not in this checkout's history; only the current one was run")
