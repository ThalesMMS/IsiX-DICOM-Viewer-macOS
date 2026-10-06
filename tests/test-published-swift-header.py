#!/usr/bin/env python3
"""A plugin builds against Horos.framework away from the build machine's checkout.

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

# Exercise the publisher directly before relying on any previous host build.
# Inactive Android implementation headers must not enter the macOS SDK, while
# a genuinely absent quoted dependency must still produce its diagnostic.
with tempfile.TemporaryDirectory(prefix='horos-sdk-publisher-') as directory:
    work = Path(directory)
    sources = work / 'Horos/Sources'
    sources.mkdir(parents=True)
    vendor = root / 'Horos/Sources/ThirdParty/Libarchive'
    originals = {}
    for name in ('archive.h', 'archive_entry.h'):
        originals[name] = (vendor / name).read_bytes()
        (sources / name).write_bytes(originals[name])
    bridge = sources / 'Horos-Bridging-Header.h'
    bridge.write_text('#include "archive.h"\n#include "archive_entry.h"\n')
    generated = work / 'Horos-Swift.h'
    generated.write_text('#include "' + str(bridge) + '"\n')
    headers = work / 'Headers'
    headers.mkdir()
    publisher = root / 'Horos/Scripts/Horos/publish-swift-header.py'
    args = [sys.executable, str(publisher), str(work), str(generated), str(headers)]
    result = subprocess.run(args, capture_output=True, text=True, check=True)
    assert 'warning:' not in result.stdout + result.stderr, result.stdout + result.stderr
    for name, original in originals.items():
        assert (sources / name).read_bytes() == original
        assert 'android_lf.h' not in (headers / name).read_text()
    (work / 'consumer.c').write_text('#include "Horos-Swift.h"\nint main(void) { return ARCHIVE_OK; }\n')
    subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                    '-I', str(headers), str(work / 'consumer.c')], check=True)
    bridge.write_text(bridge.read_text() + '#include "AbsentRequiredHeader.h"\n')
    result = subprocess.run(args, capture_output=True, text=True, check=True)
    assert 'warning:' in result.stdout and 'AbsentRequiredHeader.h' in result.stdout
    print('PASS: publisher retains vendor headers and reports real missing dependencies; macOS copies omit Android internals')
# Public Objective-C++ imports may already forward-declare the DCMTK file
# type through HorosDCMTKObject. The export header must agree in either order,
# without requiring the host-only DCMTK includes or changing pointer layout.
with tempfile.TemporaryDirectory(prefix='horos-sdk-cpp-type-') as directory:
    source = Path(directory) / 'consumer.mm'
    header = root / 'Horos/Sources/DICOMExport.h'
    for before in (True, False):
        declaration = 'class DcmFileFormat;\n'
        include = '#import "' + str(header) + '"\n'
        source.write_text((declaration + include if before else include + declaration)
                          + 'static_assert(sizeof(DcmFileFormat *) == sizeof(void *));\n')
        subprocess.run(['xcrun', 'clang', '-std=c++17', '-fsyntax-only', str(source)], check=True)
    source = source.with_suffix('.m')
    source.write_text('#import "' + str(header) + '"\n')
    subprocess.run(['xcrun', 'clang', '-fsyntax-only', str(source)], check=True)
    print('PASS: public DICOM export imports preserve opaque pointer types in ObjC and ObjC++')
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
