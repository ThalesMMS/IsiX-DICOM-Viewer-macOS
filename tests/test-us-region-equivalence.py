#!/usr/bin/env python3
"""An ultrasound region answers what DCMUSRegion answered.

DCMUSRegion.m, the value the image keeps for each item of the Sequence of
Ultrasound Regions, became USRegion of the IsiXImaging module (IsiXUSRegion in
Objective-C). The image fills it by key and the ROI labels read it by key, so
this sets the same values by key on both, the integers at their limits and
doubles of every magnitude, and compares what each answers by key and its
-toString, which prints them through NSNumber.

The reference is DCMUSRegion.m of the last revision that has it, compiled with
clang as Xcode compiled it (manual retain and release).

    python3 tests/test-us-region-equivalence.py
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'Horos/Sources/DCMUSRegion.m'

reference = history_reference.before_removal(SOURCE)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', f'HEAD:{SOURCE}'],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: no revision of this history has DCMUSRegion.m', file=sys.stderr)
    raise SystemExit(2)

DRIVER = r'''
#import <Foundation/Foundation.h>
#include <float.h>
#include <limits.h>
CLASS_IMPORT
int main(void) { @autoreleasepool {
    NSArray *integers = @[@"regionSpatialFormat", @"regionDataType", @"regionFlags", @"regionLocationMinX0", @"regionLocationMinY0",
                          @"regionLocationMaxX1", @"regionLocationMaxY1", @"referencePixelX0", @"referencePixelY0",
                          @"physicalUnitsXDirection", @"physicalUnitsYDirection"];
    NSArray *reals = @[@"refPixelPhysicalValueX", @"refPixelPhysicalValueY", @"physicalDeltaX", @"physicalDeltaY",
                       @"dopplerCorrectionAngle"];
    NSArray *flags = @[@"isReferencePixelX0Present", @"isReferencePixelY0Present"];
    NSArray *intValues = @[@0, @1, @-1, @3, @12, @(INT_MAX), @(INT_MIN), @65535];
    NSArray *realValues = @[@0.0, @-0.0, @1.0, @0.1, @-0.0025, @1e-300, @(DBL_MAX), @(1.0 / 3.0), @12345.678901234567, @-90.5];
    for (int round = 0; round < 40; round++) {
        id region = [[[REGION alloc] init] autorelease];
        if (round > 0) {
            for (NSUInteger i = 0; i < integers.count; i++)
                [region setValue: intValues[(round * 3 + i) % intValues.count] forKey: integers[i]];
            for (NSUInteger i = 0; i < reals.count; i++)
                [region setValue: realValues[(round * 7 + i) % realValues.count] forKey: reals[i]];
            for (NSUInteger i = 0; i < flags.count; i++)
                [region setValue: @((round + i) % 2) forKey: flags[i]];
        }
        NSArray *keys = [[integers arrayByAddingObjectsFromArray: reals] arrayByAddingObjectsFromArray: flags];
        NSDictionary *values = [region dictionaryWithValuesForKeys: keys];
        NSMutableString *line = [NSMutableString string];
        for (NSString *key in keys)
            [line appendFormat: @"%@=%@(%s) ", key, values[key], [values[key] objCType]];
        printf("%s\n%s\n", line.UTF8String, [[region toString] UTF8String]);
    }
    return 0;
} }
'''


def build(work, name, flags, class_import, region):
    (work / f'{name}.m').write_text(DRIVER.replace('CLASS_IMPORT', class_import).replace('REGION', region))
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-w', *flags[0], str(work / f'{name}.m'), *flags[1],
                            '-framework', 'Foundation', '-o', str(work / name)], capture_output=True, text=True)
    if built.returncode:
        sys.stderr.write(built.stderr[-3000:])
        raise SystemExit(f'FAIL: the {name} probe does not compile')
    return subprocess.run([str(work / name)], capture_output=True, text=True, check=True, timeout=60).stdout


with tempfile.TemporaryDirectory(prefix='horos-us-region-') as name:
    work = Path(name)
    old = work / 'old'
    old.mkdir()
    for file in ('DCMUSRegion.h', 'DCMUSRegion.m'):
        (old / file).write_bytes(history_reference.show(reference, 'Horos/Sources/' + file))
    former = build(work, 'former', (['-I', str(old)], [str(old / 'DCMUSRegion.m')]), '#import "DCMUSRegion.h"', 'DCMUSRegion')
    module = work / 'IsiXImaging'
    current = build(work, 'current', (isix_modules.clang_module_flags('IsiXImaging', module),
                                      isix_modules.link_flags('IsiXImaging', module)),
                    '@import IsiXImaging;', 'IsiXUSRegion')

if current != former:
    for a, b in zip(former.splitlines(), current.splitlines()):
        if a != b:
            print('DCMUSRegion.m:', a)
            print('USRegion:     ', b)
            break
    print(f'FAIL: USRegion does not answer what DCMUSRegion.m at {reference[:12]} answered')
    raise SystemExit(1)
print(f'PASS: 40 regions answer by key and in -toString what DCMUSRegion.m at {reference[:12]} answered '
      f'({len(former.splitlines())} lines)')
