#!/usr/bin/env python3
"""The 16-bit value map of VRView stays one affine transform, for every time.

The 3D MPR captures its planes through the CPU ray caster with a linear
opacity table, and decodes each pixel as `value = raw / valueFactor - OFFSET16`.
That only holds when the volume was encoded with the same pair. Two defects
broke it:

* `computeValueFactor` scaled narrow (< 50) and wide (> 32000) ranges but had
  its `OFFSET16` assignment commented out, so a positive narrow range such as
  50..70 was encoded as `50 * 1600`, saturated, and decoded as nothing.
* a 4D set fixed the pair when its first time was loaded; the other times were
  added afterwards and could widen the range without the pair being recomputed,
  and only the first time carried the two guard voxels that make VTK see the
  same scalar range for every time.

This compiles the real `computeValueFactor` and the real
`applyMovieRangeGuardTo16BitVolume` against stubs, and checks the wiring in
`VRController+Movie.swift` and the view textually. The two methods are Swift
(VRView+Volume.swift), an extension of VRView: they are compiled as an
extension of a stand-in view whose properties are the view's own; the
16-bit conversions are spread over the Swift class (VRView.swift) and its
extensions.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
vrview = (root / 'Horos/Sources/VRView.swift').read_text()
extensions = {path.name: path.read_text() for path in sorted((root / 'Horos/Sources').glob('VRView*.swift'))}
controller = (root / 'Horos/Sources/VRController+Movie.swift').read_text()
failures = []


def method(source, signature, terminator='\n}\n'):
    start = source.index(signature)
    return source[start:source.index(terminator, start) + len(terminator)]


swift_methods = '- (void) computeValueFactor\n' not in vrview
if swift_methods:
    volume = extensions['VRView+Volume.swift']
    compute = method(volume, '    @objc(computeValueFactor)\n', '\n    }\n')
    guard = method(volume, '    @objc(applyMovieRangeGuardTo16BitVolume)\n', '\n    }\n')
    constant = re.search(r'private let maxDynamicValue = [0-9.]+\n', volume).group(0)
    branch = r'horos_valueFactor = [^\n]+\n\s*horos_OFFSET16 = -minimum\b'
    commented = r'//\s*horos_OFFSET16 ='
else:
    compute = method(vrview, '- (void) computeValueFactor\n')
    guard = method(vrview, '- (void) applyMovieRangeGuardTo16BitVolume\n')
    branch = r'valueFactor = [^;]+;\s*\n\s*OFFSET16 = -\[controller minimumValue\];'
    commented = r'//\s*OFFSET16 ='

# --- textual wiring ---------------------------------------------------------
branches = re.findall(branch, compute)
if len(branches) != 2:
    failures.append('computeValueFactor must set OFFSET16 in both the scaled and the unit branch, found %d' % len(branches))
if re.search(commented, compute):
    failures.append('computeValueFactor still carries a commented-out OFFSET16 assignment')

# Each conversion of the main volume to 16 bits, in Objective-C or in Swift,
# is followed by the 4D range guard.
conversions = [(name, text, r'BrowserController\.multiThreadedImageConvert\("FTo16U", (?:horos_)?srcf, (?:horos_)?dst8, -horos_OFFSET16,',
                 'applyMovieRangeGuardTo16BitVolume()') for name, text in extensions.items()]
found = 0
for name, text, pattern, guarded in conversions:
    for match in re.finditer(pattern, text):
        found += 1
        if guarded not in text[match.end():match.end() + 200]:
            line = text.count('\n', 0, match.start()) + 1
            failures.append('FTo16U conversion at %s:%d is not followed by the 4D range guard' % (name, line))
if found < 4:
    failures.append('expected the main-volume FTo16U conversion at least four times, found %d' % found)

if any(re.search(r'horos_data\??\[[^\]\n]*pwidth[^\]\n]*\] = [^\n]*minimumValue\(\)', text) for text in extensions.values()):
    failures.append('the float volume shared with the 2D viewer is still patched with the 4D guard')

add_movie = method(controller, '    public final func addMoviePixList(', '\n    }\n')
if 'computeMinMax()' not in add_movie or 'vrView?.recomputeValueFactorAfterRangeChange()' not in add_movie:
    failures.append('addMoviePixList must recompute min/max and then the value factor')
elif add_movie.index('computeMinMax()') > add_movie.index('vrView?.recomputeValueFactorAfterRangeChange()'):
    failures.append('addMoviePixList recomputes the value factor before the new min/max')

# --- compiled behaviour -----------------------------------------------------
SWIFT_HEADER = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
NS_ASSUME_NONNULL_BEGIN
@interface Pix : NSObject
@property BOOL SUVConverted;
@property long pwidth;
@end
@interface Viewer2D : NSObject
- (long) maxMovieIndex;
@end
@interface Controller : NSObject
- (float) minimumValue;
- (float) maximumValue;
- (nullable Viewer2D *) viewer2D;
@end
@interface View : NSObject
@property (readonly, nullable) Pix *horos_firstObject;
@property (readonly, nullable) Controller *horos_controller;
@property float horos_valueFactor, horos_OFFSET16;
@property (readonly) BOOL horos_isRGB;
@property (readonly, nullable) char *horos_data8;
@property (readonly) vImage_Buffer *horos_dst8 NS_RETURNS_INNER_POINTER;
@end
NS_ASSUME_NONNULL_END
'''

DRIVER = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#define MAXDYNAMICVALUE 32000.

@interface Pix : NSObject
@property BOOL SUVConverted;
@property long pwidth;
@end
@implementation Pix
@end

@interface Viewer2D : NSObject
@property long maxMovieIndex;
@end
@implementation Viewer2D
@end

@interface Controller : NSObject
@property float minimumValue, maximumValue;
@property (strong) Viewer2D *viewer2D;
@end
@implementation Controller
@end

@interface View : NSObject
{
    Pix *firstObject;
    Controller *controller;
    float valueFactor, OFFSET16;
    BOOL isRGB;
    char *data8;
    vImage_Buffer dst8;
}
- (void) computeValueFactor;
- (void) applyMovieRangeGuardTo16BitVolume;
- (instancetype) initWithMin:(float) mn max:(float) mx times:(long) times width:(long) w voxels:(long) n;
- (float) valueFactor;
- (float) OFFSET16;
- (unsigned short*) volume16;
- (void) convert:(const float*) src count:(long) n;
@end

@implementation View
- (instancetype) initWithMin:(float) mn max:(float) mx times:(long) times width:(long) w voxels:(long) n
{
    self = [super init];
    firstObject = [Pix new]; firstObject.pwidth = w;
    controller = [Controller new]; controller.minimumValue = mn; controller.maximumValue = mx;
    controller.viewer2D = [Viewer2D new]; controller.viewer2D.maxMovieIndex = times;
    data8 = (char*) calloc(n, sizeof(unsigned short));
    dst8.data = data8; dst8.width = w; dst8.height = n / w; dst8.rowBytes = w * 2;
    valueFactor = 1; OFFSET16 = 0;
    return self;
}
- (float) valueFactor { return valueFactor; }
- (float) OFFSET16 { return OFFSET16; }
- (unsigned short*) volume16 { return (unsigned short*) data8; }
- (void) convert:(const float*) src count:(long) n
{
    unsigned short *out = (unsigned short*) data8;
    for (long i = 0; i < n; i++) {
        float v = (src[i] + OFFSET16) * valueFactor;
        out[i] = v < 0 ? 0 : (v > 65535 ? 65535 : (unsigned short) (v + 0.5f));
    }
}
''' + ('' if swift_methods else compute + guard) + r'''
@end

#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); return 1; } } while (0)

int main(void) { @autoreleasepool {
    // narrow positive range, the regression phantom: 50..70 on its own
    View *narrow = [[View alloc] initWithMin:50 max:70 times:1 width:4 voxels:16];
    [narrow computeValueFactor];
    CHECK(fabsf(narrow.OFFSET16 - (-50)) < 1e-6, "narrow range OFFSET16 = %f, expected -50", narrow.OFFSET16);
    CHECK(fabsf(narrow.valueFactor - 1600) < 1e-3, "narrow range valueFactor = %f, expected 1600", narrow.valueFactor);
    float samples[16]; for (int i = 0; i < 16; i++) samples[i] = 50;
    samples[3] = 70;
    [narrow convert:samples count:16];
    CHECK(narrow.volume16[0] == 0, "50 must encode to 0, got %u", narrow.volume16[0]);
    CHECK(narrow.volume16[3] == 32000, "70 must encode to 32000, got %u", narrow.volume16[3]);
    float decoded = narrow.volume16[3] / narrow.valueFactor - narrow.OFFSET16;
    CHECK(fabsf(decoded - 70) < 1e-3, "round trip of 70 gave %f", decoded);
    // single time: no guard voxels touched
    [narrow applyMovieRangeGuardTo16BitVolume];
    CHECK(narrow.volume16[4] == 0 && narrow.volume16[5] == 0, "a 3D volume must not receive guard voxels");

    // ordinary CT range keeps the unit factor with the negative offset
    View *ct = [[View alloc] initWithMin:-1000 max:1000 times:1 width:4 voxels:16];
    [ct computeValueFactor];
    CHECK(ct.valueFactor == 1 && ct.OFFSET16 == 1000, "CT range gave factor %f offset %f", ct.valueFactor, ct.OFFSET16);

    // 4D: the range of all times is 50..270, the second time is uniform 150
    View *four = [[View alloc] initWithMin:50 max:270 times:3 width:4 voxels:16];
    [four computeValueFactor];
    CHECK(four.valueFactor == 1 && four.OFFSET16 == -50, "4D range gave factor %f offset %f", four.valueFactor, four.OFFSET16);
    for (int i = 0; i < 16; i++) samples[i] = 150;
    [four convert:samples count:16];
    [four applyMovieRangeGuardTo16BitVolume];
    CHECK(four.volume16[4] == 0, "guard low voxel must be the encoded minimum (0), got %u", four.volume16[4]);
    CHECK(four.volume16[5] == 220, "guard high voxel must be the encoded maximum (220), got %u", four.volume16[5]);
    CHECK(four.volume16[6] == 100, "the data next to the guard must be untouched, got %u", four.volume16[6]);
    unsigned short lo = 65535, hi = 0;
    for (int i = 0; i < 16; i++) { if (four.volume16[i] < lo) lo = four.volume16[i]; if (four.volume16[i] > hi) hi = four.volume16[i]; }
    CHECK(lo == 0 && hi == 220, "every time must expose the 4D range 0..220 to VTK, got %u..%u", lo, hi);

    // a volume too small for the guard is left alone
    View *tiny = [[View alloc] initWithMin:50 max:270 times:3 width:4 voxels:4];
    [tiny computeValueFactor];
    [tiny applyMovieRangeGuardTo16BitVolume];
    CHECK(tiny.volume16[0] == 0 && tiny.volume16[3] == 0, "a one-row volume must not be written past its end");
    return 0;
} }
'''

if swift_methods:
    # The driver's view, with the Swift methods' properties over its ivars.
    DRIVER = DRIVER.replace('''@interface Pix : NSObject
@property BOOL SUVConverted;
@property long pwidth;
@end
@implementation Pix''', '''#import "harness.h"
@implementation Pix''').replace('''@interface Viewer2D : NSObject
@property long maxMovieIndex;
@end
@implementation Viewer2D''', '''@interface Viewer2D ()
@property long maxMovieIndex;
@end
@implementation Viewer2D''').replace('''@interface Controller : NSObject
@property float minimumValue, maximumValue;
@property (strong) Viewer2D *viewer2D;
@end
@implementation Controller''', '''@interface Controller ()
@property float minimumValue, maximumValue;
@property (strong) Viewer2D *viewer2D;
@end
@implementation Controller''').replace('''@interface View : NSObject
{''', '''@interface View ()
{''').replace('''@implementation View
''', '''@implementation View
- (Pix *) horos_firstObject { return firstObject; }
- (Controller *) horos_controller { return controller; }
- (float) horos_valueFactor { return valueFactor; }
- (void) setHoros_valueFactor:(float) value { valueFactor = value; }
- (float) horos_OFFSET16 { return OFFSET16; }
- (void) setHoros_OFFSET16:(float) value { OFFSET16 = value; }
- (BOOL) horos_isRGB { return isRGB; }
- (char *) horos_data8 { return data8; }
- (vImage_Buffer *) horos_dst8 { return &dst8; }
''')
    assert DRIVER.count('#import "harness.h"') == 1 and DRIVER.count('- (vImage_Buffer *) horos_dst8') == 1
    SWIFT = 'import Foundation\n' + constant + 'extension View {\n' + compute + guard + '}\n'

if not failures:
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / 'driver.mm'
        source.write_text(DRIVER)
        binary = Path(tmp) / 'driver'
        if swift_methods:
            (Path(tmp) / 'harness.h').write_text(SWIFT_HEADER)
            (Path(tmp) / 'methods.swift').write_text(SWIFT)
            build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-import-objc-header',
                                    str(Path(tmp) / 'harness.h'), '-c', str(Path(tmp) / 'methods.swift'),
                                    '-o', str(Path(tmp) / 'methods.o')], capture_output=True, text=True)
            if build.returncode == 0:
                build = subprocess.run(['xcrun', 'clang++', '-fobjc-arc', '-I', tmp, '-c', str(source),
                                        '-o', str(Path(tmp) / 'driver.o')], capture_output=True, text=True)
            if build.returncode == 0:
                build = subprocess.run(['xcrun', 'swiftc', str(Path(tmp) / 'driver.o'), str(Path(tmp) / 'methods.o'), '-lc++',
                                        '-framework', 'Foundation', '-framework', 'Accelerate', '-o', str(binary)],
                                       capture_output=True, text=True)
        else:
            build = subprocess.run(['xcrun', 'clang++', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'Accelerate',
                                    str(source), '-o', str(binary)], capture_output=True, text=True)
        if build.returncode != 0:
            failures.append('driver did not compile:\n' + build.stderr[-3000:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append(run.stderr.strip() or 'driver failed without output')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: VRView keeps one affine value map and guards the 4D range on every time')
