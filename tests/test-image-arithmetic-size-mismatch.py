#!/usr/bin/env python3
"""Image subtraction and multiplication leave an image of another size alone.

-[DCMPix imageArithmeticSubtraction:absolute:] and
-[DCMPix imageArithmeticMultiplication:], the fusion types 2 and 3, read the
other series' image through arithmeticSubtractImages::absolute: and
multiplyImages:: with this image's width and height. The fusion sheet compares
only the images on screen, so a series of mixed sizes, or a plugin calling
-blendWithViewer:blendingType:, read past the end of a smaller image and
combined a larger one with the wrong row stride. An image whose other image
has another size, or has none, is now left without the operation, as in the
RGB composition.

The four methods are compiled here from the source into a stand-in DCMPix,
with the app's own altivecFunctions.c. Every image buffer ends on a page that
is neither readable nor writable, so a read past its end stops the harness.
Each case runs in a process of its own: a smaller image, a larger one and none
at all, with and without a pixel shift, must leave this image as it was; an
image of the same size must still be subtracted and multiplied.

The XA mask subtraction had the same flaw: -[ViewerController
subCtrlOnOff:] handed the mask's fImage to every image of the series, and
-subCtrlNewMask: and -computeSubCtrlMinMax had -[DCMPix subMinMax::] read it,
all with each image's own width and height. In a series of mixed sizes a mask
smaller than an image was read past its end. An image of another size than the
mask is now left without the subtraction and out of the subtraction range.
The two Objective-C actions, from ViewerController.m, and the Swift
-computeSubCtrlMinMax, taken as it stands, run here over stand-ins of the viewer
and its DCMView, with the three DCMPix methods from DCMPix.m and buffers again
ending on a page nobody may touch. Each case, in a process of its own, switches
the subtraction on with the default mask and then picks a new mask, smaller,
larger or of the most common size: every image of the mask's size must be
subtracted, and displayed, as before; every other one must have no mask; the
range must come from the images of the mask's size only.

Such a series, like a series of a single image, never had the subtraction:
the viewer computes enableSubtraction when it loads, and
-subCtrlOnOff: answered that "Subtraction works only for XA modality." even
for an XA series. The check read only the first movie list, while the
subtraction works on the list of curMovieIndex. The Swift
-subtractionUnavailableReason now checks every list and says why, and
-finishLoadImageData: takes enableSubtraction from it. The harness sets
enableSubtraction the same way over one or several movie lists, sends
-subCtrlOnOff: from the menu and reads the alert: it must name the real reason
(not XA, a list of one image, a list of mixed sizes), and a series that passes
must be subtracted without an alert.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import json
import re
import signal
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import sources

root = Path(__file__).resolve().parents[1]


def read(path):
    """The file at `path` in the checkout, or in the revision given as argument."""
    return (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]) if len(sys.argv) > 1
            else (root / path).read_bytes()).decode('utf-8' if path.endswith('.swift') else 'latin1')


source = read('Horos/Sources/DCMPix.m')
viewer = read('Horos/Sources/ViewerController.m')
swift = read(str(sources.source_path('ViewerController+RetrieveAndView').relative_to(root)))


def braced(text, start):
    depth, index = 0, text.index('{', start)
    while True:
        if text[index] == '{': depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0: return text[start:index + 1]
        index += 1


methods = '\n'.join(braced(source, source.index(signature)) for signature in (
    '-(void) imageArithmeticMultiplication:(DCMPix*) sub',
    '-(float*) multiplyImages :(float*) input :(float*) subfImage',
    '-(void) imageArithmeticSubtraction:(DCMPix*) sub absolute:(BOOL) abs',
    '-(float*) arithmeticSubtractImages :(float*) input :(float*) subfImage absolute:(BOOL) abs'))
WIDTH, HEIGHT = 23, 17
OPERATIONS = ('subtract', 'absolute', 'multiply')
# (width, height) of the other image, or None for no image at all.
OTHERS = {'smaller': (8, 6), 'narrower': (WIDTH - 1, HEIGHT), 'shorter': (WIDTH, HEIGHT - 1),
          'larger': (40, 30), 'missing': None, 'same': (WIDTH, HEIGHT)}
SHIFTS = ((0, 0), (2, -1))

harness = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#include <sys/mman.h>
#include <unistd.h>
#include "altivecFunctions.h"
#define DCMPix Pix
@interface Pix : NSObject {
@public
    long height, width;
    NSPoint subPixOffset;
    float *fImage;
}
- (long) pwidth;
- (long) pheight;
- (float*) fImage;
@end
@implementation Pix
- (long) pwidth { return width; }
- (long) pheight { return height; }
- (float*) fImage { return fImage; }
METHODS
@end
// A buffer of count floats that ends where a page nobody may touch begins.
static float *guarded(long count)
{
    long page = sysconf(_SC_PAGESIZE), bytes = count * sizeof(float);
    long span = (bytes + page - 1) / page * page;
    char *base = mmap(NULL, span + page, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (base == MAP_FAILED || mprotect(base + span, page, PROT_NONE)) { perror("guard"); exit(3); }
    return (float *)(base + span - bytes);
}
static Pix *image(long width, long height, int seed)
{
    Pix *pix = [Pix new];
    pix->width = width; pix->height = height;
    pix->fImage = guarded(width * height);
    for (long k = 0; k < width * height; ++k) { long x = k % width, y = k / width; pix->fImage[k] = seed == 0 ? 3 * x + 5 * y + 1 : 2 * x - y + 7 + (x * y % 5); }
    return pix;
}
int main(int argc, char **argv) { @autoreleasepool {
    // operation, other width (0 for no image), other height, shift x, shift y
    const char *operation = argv[1];
    long otherWidth = atol(argv[2]), otherHeight = atol(argv[3]);
    Pix *pix = image(WIDTH, HEIGHT, 0), *other = otherWidth ? image(otherWidth, otherHeight, 1) : nil;
    pix->subPixOffset = NSMakePoint(atof(argv[4]), atof(argv[5]));
    if (!strcmp(operation, "multiply")) [pix imageArithmeticMultiplication:other];
    else [pix imageArithmeticSubtraction:other absolute:!strcmp(operation, "absolute")];
    for (long k = 0; k < WIDTH * HEIGHT; ++k) printf("%.3f\n", pix->fImage[k]);
} return 0; }
'''.replace('METHODS', methods).replace('WIDTH', str(WIDTH)).replace('HEIGHT', str(HEIGHT))


def this(x, y): return 3 * x + 5 * y + 1
def other(x, y): return 2 * x - y + 7 + (x * y % 5)


apply = {'subtract': lambda a, b: a - b, 'absolute': lambda a, b: abs(a - b), 'multiply': lambda a, b: a * b}
failures = []
with tempfile.TemporaryDirectory() as work:
    program = Path(work) / 'size.m'
    program.write_text(harness)
    binary = Path(work) / 'size'
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-x', 'objective-c', str(program),
                            '-x', 'c', str(root / 'Horos/Sources/altivecFunctions.c'),
                            '-I', str(root / 'Horos/Sources'),
                            '-framework', 'Foundation', '-framework', 'Accelerate', '-o', str(binary)],
                           capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the harness does not build:\n' + built.stderr[-3000:])

    for name, size in OTHERS.items():
        for dx, dy in SHIFTS:
            for operation in OPERATIONS:
                case = '%s, %s image, shift (%d, %d)' % (operation, name, dx, dy)
                w, h = size or (0, 0)
                run = subprocess.run([str(binary), operation, str(w), str(h), str(dx), str(dy)],
                                     capture_output=True, text=True)
                if run.returncode:
                    reason = ('signal %s: read outside the images' % signal.Signals(-run.returncode).name
                              if run.returncode < 0 else 'exit %d %s' % (run.returncode, run.stderr[-500:]))
                    failures.append('%s: the harness stopped (%s)' % (case, reason))
                    continue
                values = [float(line) for line in run.stdout.split()]
                for k, value in enumerate(values):
                    x, y = k % WIDTH, k // WIDTH
                    if name != 'same':
                        expected = this(x, y)
                    else:
                        mx, my = x - dx, y + dy
                        covered = 0 <= mx < WIDTH and 0 <= my < HEIGHT
                        expected = apply[operation](this(x, y), other(mx, my)) if covered else 0.0
                    if abs(value - expected) > 1e-3:
                        failures.append('%s: pixel (%d, %d) is %.3f, expected %.3f%s' % (
                            case, x, y, value, expected, ' (the image as it was)' if name != 'same' else ''))
                        break

# The XA mask subtraction: -subCtrlOnOff:, -subCtrlNewMask: and the Swift
# -computeSubCtrlMinMax over a series of mixed sizes.
def swift_method(selector):
    at = swift.index('    @objc(' + selector + ')\n')
    return swift[at:swift.index('    @objc(', at + 1)]


subtraction = '\n'.join(braced(source, source.index(signature)) for signature in (
    '-(NSPoint) subMinMax:(float*)input :(float*)subfImage',
    '- (void) setSubtractedfImage:(float*)mask :(NSPoint)smm',
    '-(float*) subtractImages:(float*)input :(float*)subfImage'))
actions = '\n'.join(braced(viewer, viewer.index(signature)) for signature in (
    '- (IBAction) subCtrlOnOff:(id) sender', '- (IBAction) subCtrlNewMask:(id) sender'))
c_long = re.search(r'fileprivate func cLong\(_ x: Double\) -> Int \{.*?\n\}\n', swift, re.S).group(0)
is_equal = re.search(r'fileprivate func objcIsEqualToString\(_ string: Any\?, _ other: Any\?\) -> Bool \{.*?\n\}\n', swift, re.S).group(0)
if '    @objc(subtractionUnavailableReason)\n' in swift:
    reason_method = swift_method('subtractionUnavailableReason')
else:
    # A revision without it: the alert and the gate are checked all the same.
    failures.append('the Swift -subtractionUnavailableReason is missing')
    reason_method = '    @objc(subtractionUnavailableReason)\n    func subtractionUnavailableReason() -> String? { return nil }\n'
extension = ('import AppKit\n\n' + c_long + is_equal + '\nextension ViewerController {\n' + swift_method('computeSubCtrlMinMax')
             + reason_method + '}\n')

# -finishLoadImageData: takes enableSubtraction from it, and from nothing else.
at = swift.index('    @objc(finishLoadImageData:)\n')
loading = swift[at:swift.index('\n    }\n', at)]
if (loading.count('horos_enableSubtraction =') != 1
        or 'self.horos_enableSubtraction = self.subtractionUnavailableReason() == nil' not in loading):
    failures.append('-finishLoadImageData: does not take enableSubtraction from -subtractionUnavailableReason')

# What Swift reads is spelled as in DCMPix.h, DCMView.h and ViewerController+SwiftIvars.h.
header = r'''
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Cocoa/Cocoa.h>
@interface DCMPix : NSObject {
@public
    long height, width, maskID;
    NSPoint subPixOffset, subMinMax;
    float subtractedfPercent, subtractedfZero, maskTime, fImageTime;
    float *fImage, *subtractedfImage;
    BOOL updateToBeApplied;
}
@property (nonatomic) long pwidth, pheight;
@property(setter=setfImage:) float* fImage;
@property(retain) NSString* modalityString;
- (NSPoint) subMinMax:(float*)input :(float*)subfImage;
- (void) setSubtractedfImage:(float*)mask :(NSPoint)smm;
- (float*) subtractImages:(float*)input :(float*)subfImage;
- (float) fImageTime;
- (void) maskID:(long)newID;
- (void) maskTime:(float)newMaskTime;
@end
@interface DCMView : NSObject {
@public
    NSMutableArray *dcmPixList;
    BOOL flippedData;
    short curImage;
}
@property(readonly) NSMutableArray *dcmPixList;
@property BOOL flippedData;
@property(readonly) short curImage;
- (void) setWLWW:(float) wl :(float) ww;
- (void) setIndex:(short) index;
@end
// The on/off button and the mask number field.
@interface Control : NSObject {
@public
    NSInteger state, tag;
}
- (NSInteger) state;
- (void) setState:(NSInteger) value;
- (NSInteger) tag;
- (void) setEnabled:(BOOL) value;
- (void) setStringValue:(NSString *) value;
@end
@interface ViewerController : NSObject {
@public
    DCMView *imageView;
    NSView *subCtrlView;
    BOOL enableSubtraction, subCtrlMinMaxComputed;
    Control *subCtrlOnOff, *subCtrlMaskText;
    long subCtrlMaskID;
    NSPoint subCtrlMinMax;
    NSMutableArray *pixList[4];
    short curMovieIndex, maxMovieIndex;
}
@property(retain, nullable) DCMView* horos_imageView;
@property(assign) short horos_maxMovieIndex;
- (nullable NSMutableArray<DCMPix *>*) horos_pixListAt:(NSInteger)index;
@property(assign) long horos_subCtrlMaskID;
@property(assign) NSPoint horos_subCtrlMinMax;
@property(assign) BOOL horos_subCtrlMinMaxComputed;
- (void) checkEverythingLoaded;
- (void) checkView:(NSView *)aView :(BOOL) OnOff;
- (IBAction) subSumSlider:(id) sender;
- (IBAction) subCtrlOnOff:(id) sender;
- (IBAction) subCtrlNewMask:(id) sender;
@end
'''

check = r'''
#import "Harness.h"
#import "HorosAlertPanel.h"
#import <objc/runtime.h>
#import <Accelerate/Accelerate.h>
#include <sys/mman.h>
#include <unistd.h>
@interface ViewerController (Swift)
- (void) computeSubCtrlMinMax;
- (NSString *) subtractionUnavailableReason;
@end
// What -subCtrlOnOff: would show in an alert panel.
static NSString *alertMessage;
static NSModalResponse recordAlert(NSAlert *alert, SEL selector)
{
    alertMessage = [alert.informativeText copy];
    return NSAlertFirstButtonReturn;
}
// Historical source controls retain their arithmetic/gate body and use the
// same production bridge; only the obsolete SDK function spelling is adapted.
#define NSRunAlertPanel HorosRunAlertPanel
@implementation DCMPix
@synthesize fImage, modalityString;
- (long) pwidth { return width; }
- (void) setPwidth:(long) value { width = value; }
- (long) pheight { return height; }
- (void) setPheight:(long) value { height = value; }
- (float) fImageTime { return fImageTime; }
- (void) maskID:(long) newID { maskID = newID; }
- (void) maskTime:(float) newMaskTime { maskTime = newMaskTime; }
SUBTRACTION
@end
@implementation DCMView
@synthesize dcmPixList, flippedData, curImage;
- (void) setWLWW:(float) wl :(float) ww {}
- (void) setIndex:(short) index {}
@end
@implementation Control
- (NSInteger) state { return state; }
- (void) setState:(NSInteger) value { state = value; }
- (NSInteger) tag { return tag; }
- (void) setEnabled:(BOOL) value {}
- (void) setStringValue:(NSString *) value {}
@end
@implementation ViewerController
@synthesize horos_imageView = imageView, horos_subCtrlMaskID = subCtrlMaskID, horos_subCtrlMinMax = subCtrlMinMax,
    horos_subCtrlMinMaxComputed = subCtrlMinMaxComputed, horos_maxMovieIndex = maxMovieIndex;
- (NSMutableArray *) horos_pixListAt:(NSInteger)index { return pixList[index]; }
- (void) checkEverythingLoaded {}
- (void) checkView:(NSView *)aView :(BOOL) OnOff {}
- (IBAction) subSumSlider:(id) sender {}
ACTIONS
@end
// A buffer of count floats that ends where a page nobody may touch begins.
static float *guarded(long count)
{
    long page = sysconf(_SC_PAGESIZE), bytes = count * sizeof(float);
    long span = (bytes + page - 1) / page * page;
    char *base = mmap(NULL, span + page, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (base == MAP_FAILED || mprotect(base + span, page, PROT_NONE)) { perror("guard"); exit(3); }
    return (float *)(base + span - bytes);
}
// Which image's pixels each image is subtracted from (-1: none), the range,
// and the sum of what each subtracted image displays.
static NSDictionary *state(ViewerController *viewer)
{
    NSArray *list = viewer->imageView->dcmPixList;
    NSMutableArray *masks = [NSMutableArray array], *sums = [NSMutableArray array];
    for (DCMPix *pix in list) {
        long owner = -1;
        for (long k = 0; k < (long)list.count; ++k) if (pix->subtractedfImage && pix->subtractedfImage == ((DCMPix *)list[k])->fImage) owner = k;
        if (pix->subtractedfImage && owner < 0) owner = -2;
        [masks addObject:@(owner)];
        double sum = 0;
        if (pix->subtractedfImage) {
            float *shown = [pix subtractImages:pix->fImage :pix->subtractedfImage];
            for (long k = 0; k < pix->width * pix->height; ++k) sum += shown[k];
            free(shown);
        }
        [sums addObject:@(sum)];
    }
    return @{@"masks": masks, @"range": @[@(viewer->subCtrlMinMax.x), @(viewer->subCtrlMinMax.y)], @"sums": sums};
}
// A movie list of the sizes given as "w x h" separated by commas.
static NSMutableArray *series(NSString *sizes, NSString *modality)
{
    NSMutableArray *list = [NSMutableArray array];
    long index = 0;
    for (NSString *size in [sizes componentsSeparatedByString:@","]) {
        NSArray *wh = [size componentsSeparatedByString:@"x"];
        DCMPix *pix = [DCMPix new];
        pix->width = [wh[0] intValue]; pix->height = [wh[1] intValue];
        pix->fImage = guarded(pix->width * pix->height);
        for (long k = 0; k < pix->width * pix->height; ++k) { long x = k % pix->width, y = k / pix->width; pix->fImage[k] = (3 * x + 5 * y + 1 + 11 * index) % 97; }
        pix->subtractedfPercent = 1; pix->subtractedfZero = 0.8; pix->fImageTime = index;
        pix.modalityString = modality;
        [list addObject:pix];
        index++;
    }
    return list;
}
int main(int argc, char **argv) { @autoreleasepool {
    method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)recordAlert);
    if (!strcmp(argv[1], "gate")) {
        // gate, the modality, the movie lists (separated by ";"), curMovieIndex
        NSArray *lists = [@(argv[3]) componentsSeparatedByString:@";"];
        ViewerController *viewer = [ViewerController new];
        viewer->maxMovieIndex = lists.count;
        for (long k = 0; k < (long)lists.count; ++k) viewer->pixList[k] = series(lists[k], @(argv[2]));
        viewer->curMovieIndex = atol(argv[4]);
        DCMView *view = [DCMView new];
        view->dcmPixList = viewer->pixList[viewer->curMovieIndex];
        viewer->imageView = view;
        viewer->subCtrlOnOff = [Control new]; viewer->subCtrlMaskText = [Control new];
        // What -finishLoadImageData: and -enableSubtraction do.
        viewer->enableSubtraction = [viewer subtractionUnavailableReason] == nil;
        viewer->subCtrlMaskID = 1;
        [viewer subCtrlOnOff:viewer->subCtrlOnOff]; // from the menu: tag 0
        NSDictionary *result = @{@"enabled": @(viewer->enableSubtraction), @"alert": alertMessage ?: [NSNull null],
                                 @"on": @(viewer->subCtrlOnOff->state), @"masks": state(viewer)[@"masks"]};
        printf("%s\n", [[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil] encoding:NSUTF8StringEncoding] UTF8String]);
        return 0;
    }
    // sizes (w x h, comma separated), the default mask, the new mask (-1: none)
    NSMutableArray *list = series(@(argv[1]), nil);
    DCMView *view = [DCMView new];
    view->dcmPixList = list;
    ViewerController *viewer = [ViewerController new];
    viewer->imageView = view; viewer->pixList[0] = list; viewer->maxMovieIndex = 1;
    viewer->subCtrlOnOff = [Control new]; viewer->subCtrlOnOff->tag = 15; viewer->subCtrlOnOff->state = 1;
    viewer->subCtrlMaskText = [Control new];
    viewer->enableSubtraction = YES; viewer->subCtrlMaskID = atol(argv[2]);
    [viewer subCtrlOnOff:viewer->subCtrlOnOff];
    NSMutableDictionary *steps = [NSMutableDictionary dictionaryWithObject:state(viewer) forKey:@"on"];
    if (atol(argv[3]) >= 0) {
        view->curImage = atol(argv[3]);
        [viewer subCtrlNewMask:nil];
        steps[@"new"] = state(viewer);
    }
    printf("%s\n", [[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:steps options:0 error:nil] encoding:NSUTF8StringEncoding] UTF8String]);
} return 0; }
'''.replace('SUBTRACTION', subtraction).replace('ACTIONS', actions)

R, S, L, N, H = (23, 17), (8, 6), (40, 30), (22, 17), (23, 16)
MIXED = [R, R, S, R, L, N, H]
# (series, default mask, new mask or -1)
CASES = [(MIXED, 1, -1), (MIXED, 1, 0), (MIXED, 1, 2), (MIXED, 1, 4), (MIXED, 1, 5), (MIXED, 1, 6),
         ([R, S, R, L], 1, -1), ([R, S, R, L], 1, 3), ([R, S, R, L], 1, 0), ([R, R, R], 1, 0)]


def pixels(size, index):
    w, h = size
    return [(3 * (k % w) + 5 * (k // w) + 1 + 11 * index) % 97 for k in range(w * h)]


def expected(series, mask):
    """The masks, the range and the displayed sums with the mask `mask`."""
    low, high = 1024, 0
    same = [k for k, size in enumerate(series) if size == series[mask]]
    for k in same:
        difference = [a - b for a, b in zip(pixels(series[k], k), pixels(series[mask], mask))]
        if min(difference) < low: low = int(min(difference))
        if max(difference) > high: high = int(max(difference))
    ratio = abs(high - low) or 1
    sums = [sum((a - b) / ratio + 0.8 for a, b in zip(pixels(size, k), pixels(series[mask], mask))) if k in same else 0.0
            for k, size in enumerate(series)]
    return [mask if k in same else -1 for k in range(len(series))], [low, high], sums


with tempfile.TemporaryDirectory() as work:
    folder = Path(work)
    (folder / 'Harness.h').write_text(header)
    (folder / 'Check.m').write_text(check)
    (folder / 'Mask.swift').write_text(extension)
    for command in (['xcrun', 'clang', '-c', '-fno-objc-arc', '-fblocks', '-Werror=deprecated-declarations', '-I', str(folder),
                     '-I', str(root / 'Horos/Sources'), str(folder / 'Check.m'), '-o', str(folder / 'Check.o')],
                    ['xcrun', 'clang', '-c', '-fno-objc-arc', '-fblocks', '-Werror=deprecated-declarations',
                     str(root / 'Horos/Sources/HorosAlertPanel.m'), '-o', str(folder / 'HorosAlertPanel.o')],
                    ['xcrun', 'swiftc', '-parse-as-library', '-I', str(folder), '-import-objc-header', str(folder / 'Harness.h'),
                     str(folder / 'Mask.swift'), str(folder / 'Check.o'), str(folder / 'HorosAlertPanel.o'), '-framework', 'Cocoa', '-framework', 'Accelerate',
                     '-o', str(folder / 'mask')]):
        built = subprocess.run(command, capture_output=True, text=True)
        if built.returncode:
            sys.exit('FAIL: the subtraction harness does not build:\n' + (built.stdout + built.stderr)[-3000:])

    for series, default, new in CASES:
        case = 'mask subtraction, sizes %s, mask %d%s' % (
            ' '.join('%dx%d' % size for size in series), default, ' then %d' % new if new >= 0 else '')
        run = subprocess.run([str(folder / 'mask'), ','.join('%dx%d' % size for size in series), str(default), str(new)],
                             capture_output=True, text=True)
        if run.returncode:
            reason = ('signal %s: read outside the images' % signal.Signals(-run.returncode).name
                      if run.returncode < 0 else 'exit %d %s' % (run.returncode, run.stderr[-500:]))
            failures.append('%s: the harness stopped (%s)' % (case, reason))
            continue
        steps = json.loads(run.stdout)
        # -subCtrlOnOff: takes its range from -computeSubCtrlMinMax, with the
        # default mask; -subCtrlNewMask: from the new mask.
        for step, mask in (('on', default), ('new', new)):
            if step not in steps: continue
            masks, range_, sums = expected(series, mask)
            got = steps[step]
            if got['masks'] != masks:
                failures.append('%s, %s: the images are subtracted from %s, expected %s' % (case, step, got['masks'], masks))
            if got['range'] != range_:
                failures.append('%s, %s: the range is %s, expected %s' % (case, step, got['range'], range_))
            for k, (value, want) in enumerate(zip(got['sums'], sums)):
                if abs(value - want) > 1e-3 * max(1.0, abs(want)):
                    failures.append('%s, %s: image %d displays a sum of %.4f, expected %.4f' % (case, step, k, value, want))

# Why the subtraction is off, over one or several movie lists.
    XA_ONLY = 'Subtraction works only for XA modality.'
    TWO = 'Subtraction needs a series of at least two images.'
    SIZE = 'Subtraction needs all the images of the series to have the same size.'
    # (modality, movie lists, curMovieIndex, the alert or None for a subtraction)
    GATES = [('CT', [[R, R, R]], 0, XA_ONLY), ('XA', [[R]], 0, TWO), ('XA', [[R, S, R]], 0, SIZE),
             ('XA', [MIXED], 0, SIZE), ('XA', [[R, R, R]], 0, None),
             ('XA', [[R, R], [R, S]], 1, SIZE), ('XA', [[R, R], [R, S]], 0, SIZE),
             ('XA', [[R, R], [R]], 1, TWO), ('XA', [[R, R], [S, S, S]], 1, None)]
    for modality, lists, current, alert in GATES:
        case = 'subtraction gate, %s %s, movie %d' % (
            modality, ' / '.join(' '.join('%dx%d' % size for size in sizes) for sizes in lists), current)
        run = subprocess.run([str(folder / 'mask'), 'gate', modality,
                              ';'.join(','.join('%dx%d' % size for size in sizes) for sizes in lists), str(current)],
                             capture_output=True, text=True)
        if run.returncode:
            reason = ('signal %s' % signal.Signals(-run.returncode).name if run.returncode < 0
                      else 'exit %d %s' % (run.returncode, run.stderr[-500:]))
            failures.append('%s: the harness stopped (%s)' % (case, reason))
            continue
        got = json.loads(run.stdout)
        if got['alert'] != alert:
            failures.append('%s: the alert says %r, expected %r' % (case, got['alert'], alert))
        if got['enabled'] != (alert is None) or got['on'] != (alert is None):
            failures.append('%s: the subtraction is %s, expected %s' % (
                case, 'on' if got['on'] else 'off', 'off' if alert else 'on'))
        if alert is None and got['masks'] != [1] * len(lists[current]):
            failures.append('%s: the images are subtracted from %s' % (case, got['masks']))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('ok: image subtraction and multiplication, and the XA mask subtraction, leave an image of another size, or none, as it was; the XA subtraction says why it is off')

