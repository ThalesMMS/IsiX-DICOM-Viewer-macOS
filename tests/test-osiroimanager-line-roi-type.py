#!/usr/bin/env python3
"""A plugin that names OSILineROIType links.

OSIROIManager.h, a header of the plugin API, declares
`extern const NSString *OSILineROIType`, and nothing defined it: a plugin
that used it failed to link with an undefined _OSILineROIType. Since the move to Swift the
plugin API's exported names live in OSIROIManager+CAPI.m, which now defines
it too.

The harness compiles OSIROIManager+CAPI.m as it is, with the real
OSIROIManager.h and a stand-in for the generated interface that declares the
class, and links it with a stand-in OSIROIManager and a "plugin" that reads
OSILineROIType and the notification name beside it. The link must succeed,
and the constant must be the string "OSILineROIType".

`<git revision>` as an optional argument reads the sources from that
revision, the negative control (one that has OSIROIManager+CAPI.m).
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang)', file=sys.stderr)
    sys.exit(SKIPPED)

# The generated interface, reduced to what OSIROIManager+CAPI.m implements a category of.
SWIFT_HEADER = '''#import <Cocoa/Cocoa.h>
@interface OSIROIManager : NSObject
@end
'''

CLASS = '''#import "OSIROIManager.h"
@implementation OSIROIManager
@end
'''

PLUGIN = r'''#import "OSIROIManager.h"
#include <stdio.h>

int main(void)
{
    @autoreleasepool {
        NSString *type = (NSString *)OSILineROIType;
        if (![type isKindOfClass:[NSString class]] || ![type isEqualToString:@"OSILineROIType"]) {
            printf("FAIL: OSILineROIType is %s, not \"OSILineROIType\"\n", type.description.UTF8String);
            return 1;
        }
        printf("OSILineROIType is \"%s\"; the notification beside it is \"%s\"\n",
               type.UTF8String, OSIROIManagerROIsDidUpdateNotification.UTF8String);
    }
    return 0;
}
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-line-roi-type-857-') as tmp:
    tmp = Path(tmp)
    try:
        for path in ['Horos/Sources/OSIROIManager.h', 'Horos/Sources/OSIROIManager+CAPI.m']:
            (tmp / Path(path).name).write_bytes(source(path))
    except subprocess.CalledProcessError:
        print(f'FAIL: OSIROIManager+CAPI.m is not at {revision}; give a revision that has it')
        sys.exit(1)
    (tmp / 'Horos-Swift.h').write_text(SWIFT_HEADER)
    (tmp / 'Class.m').write_text(CLASS)
    (tmp / 'Plugin.m').write_text(PLUGIN)
    objects = []
    try:
        for name in ['OSIROIManager+CAPI.m', 'Class.m', 'Plugin.m']:
            obj = tmp / (Path(name).stem + '.o')
            subprocess.run(['xcrun', 'clang', '-x', 'objective-c', '-include', 'Cocoa/Cocoa.h', '-fno-objc-arc',
                            '-I', str(tmp), '-c', str(tmp / name), '-o', str(obj)], check=True, capture_output=True)
            objects.append(str(obj))
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not compile:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)
    link = subprocess.run(['xcrun', 'clang', *objects, '-framework', 'Cocoa', '-o', str(tmp / 'plugin')],
                          capture_output=True, text=True)
    if link.returncode != 0:
        undefined = [line.strip() for line in link.stderr.splitlines() if '_OSI' in line]
        failures.append('a plugin naming OSILineROIType does not link: ' + ('; '.join(undefined) or link.stderr[-500:]))
    else:
        result = subprocess.run([str(tmp / 'plugin')], capture_output=True, text=True, timeout=30)
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        if result.returncode != 0:
            failures.append('; '.join(line[len('FAIL: '):] for line in lines if line.startswith('FAIL:'))
                            or f'the plugin exited {result.returncode}')
        else:
            print('ok: a plugin naming OSILineROIType links -', lines[-1] if lines else 'exit 0')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: OSILineROIType is defined, and a plugin that names it links')
