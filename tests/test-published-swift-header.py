#!/usr/bin/env python3
"""A plugin builds against Horos.framework away from the build machine's checkout (#754).

swiftc writes the bridging header's absolute path into Horos-Swift.h, and every
compatibility header of a migrated class imports Horos-Swift.h, so a plugin built
on another machine failed with "file not found". API.sh now publishes the header
with that import pointing at a Horos-Bridging-Header.h beside it.

This checks, on the built framework, that no published header names this
checkout, and compiles a plugin source against a copy of the framework in a
temporary folder while the sandbox denies every read of the checkout: a header
that still reached into it would fail to open.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
products = root / 'build/Build/Products'
framework = next((products / c / 'Horos.framework' for c in ('Release', 'Debug')
                  if (products / c / 'Horos.framework/Headers/Horos-Swift.h').is_file()), None)
if framework is None:
    print('skipped: needs a built Horos.framework with Horos-Swift.h', file=sys.stderr)
    raise SystemExit(2)

failures = []
headers = framework / 'Headers'
checkout = str(root)
for header in sorted(headers.glob('*.h')):
    if checkout.encode() in header.read_bytes():
        failures.append(f'{header.name} names the checkout {checkout}')
if not (headers / 'Horos-Bridging-Header.h').is_file():
    failures.append('Horos-Bridging-Header.h is not published beside Horos-Swift.h')

plugin = r'''
#import <Cocoa/Cocoa.h>
#import <Horos/DCMPix.h>
#import <Horos/ViewerController.h>
#import <Horos/BrowserController.h>
#import <Horos/PluginFilter.h>
#import <Horos/Horos-Swift.h>
#import <Horos/MyPoint.h>
#import <Horos/Point3D.h>
#import <Horos/ThreadsManager.h>
#import <Horos/PluginManager.h>
#import <Horos/N2Button.h>

@interface QAPublishedHeaderFilter : PluginFilter
@end
@implementation QAPublishedHeaderFilter
- (long)filterImage:(NSString *)menuName
{
    MyPoint *point = [MyPoint point:NSMakePoint(1, 2)];
    Point3D *point3D = [Point3D pointWithX:1 y:2 z:3];
    [[ThreadsManager defaultManager] threads];
    return (long)([point x] + [point3D z]) + (long)[[PluginManager plugins] count];
}
@end
'''

with tempfile.TemporaryDirectory(prefix='horos-published-header-') as directory:
    work = Path(directory)
    shutil.copytree(framework, work / 'Frameworks/Horos.framework', symlinks=True)
    (work / 'plugin.m').write_text(plugin)
    profile = '(version 1)(allow default)(deny file-read* (subpath "%s"))' % checkout
    result = subprocess.run(
        ['sandbox-exec', '-p', profile, 'xcrun', 'clang', '-fsyntax-only', '-x', 'objective-c',
         '-F', str(work / 'Frameworks'), '-Wno-deprecated-declarations', str(work / 'plugin.m')],
        cwd=work, capture_output=True, text=True)
    if result.returncode != 0:
        errors = [line for line in result.stderr.splitlines() if 'error' in line][:8]
        failures.append('a plugin does not compile against a copy of the framework:\n  ' + '\n  '.join(errors))

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print(f'PASS: {framework.parent.name} Horos.framework names no checkout path, and a plugin compiles against a copy of it with the checkout unreadable')
