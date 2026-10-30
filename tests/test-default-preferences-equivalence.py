#!/usr/bin/env python3
"""The factory settings are the ones +[DefaultsOsiriX getDefaults] registered.

The defaults the application registers beneath the user's preferences, and the
ones the Decompress helper starts from, moved from DefaultsOsiriX.m to the
IsiXPreferences module (DefaultPreferences). This builds both and compares the
dictionaries they return as XML property lists, so a string, an integer, a
float and a boolean are told apart and every nested table is compared:

* the application (OSIRIX_VIEWER), direct and Mac App Store (MACAPPSTORE);
* the helper (OSIRIX_LIGHT and DECOMPRESS_APP, as Decompress/prefix.pch).

The reference is DefaultsOsiriX.m of the last revision that has it, compiled
with clang as Xcode compiled it (manual retain and release), with stand-ins for
the headers it imports: the constants it read from them are taken from the same
revision. Both probes run beside copies of the application's colour tables and
default annotations, which they look up in their main bundle, and with a
super-sampling above the default in their argument domain, so that neither
writes one into its preferences.

    python3 tests/test-default-preferences-equivalence.py [--reference REV]
"""
import argparse
import difflib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'Horos/Sources/DefaultsOsiriX.m'
VARIANTS = [('application', ['-DOSIRIX_VIEWER'], 'true', 'false'),
            ('application, App Store', ['-DOSIRIX_VIEWER', '-DMACAPPSTORE'], 'true', 'true'),
            ('Decompress helper', ['-DOSIRIX_LIGHT', '-DDECOMPRESS_APP'], 'false', 'false')]
ARGUMENTS = ['-superSampling', '9']

parser = argparse.ArgumentParser()
parser.add_argument('--reference', help='revision whose DefaultsOsiriX.m is the reference')
arguments = parser.parse_args()


def exists(revision, path):
    return subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', f'{revision}:{path}'],
                          capture_output=True).returncode == 0


reference = arguments.reference or history_reference.before_removal(SOURCE) or ('HEAD' if exists('HEAD', SOURCE) else None)
if reference is None:
    print('skipped: no revision of this history has DefaultsOsiriX.m', file=sys.stderr)
    raise SystemExit(2)


def text(path):
    return history_reference.show(reference, path).decode('latin1')


def constant(path, name):
    match = re.search(r'\b%s\s*=\s*@"([^"]*)"' % re.escape(name), text(path))
    if not match:
        raise SystemExit(f'FAIL: {name} not found in {path} at {reference}')
    return match.group(1)


KEYS = ['OsirixWebPortalEnabledDefaultsKey', 'OsirixWebPortalPortNumberDefaultsKey', 'OsirixWadoServiceEnabledDefaultsKey',
        'OsirixWebPortalUsesWeasisDefaultsKey', 'OsirixWebPortalPrefersFlashDefaultsKey']
syncro = re.search(r'syncroRatio\s*=\s*(\d+)', text('Horos/Sources/DCMView.h')).group(1)
STUBS = {
    'PluginManager.h': f'enum {{ syncroRatio = {syncro} }};\n',
    'DCMNetServiceDelegate.h': '',
    'NSUserDefaults+OsiriX.h': '#import <Foundation/Foundation.h>\n'
                               + ''.join(f'extern NSString* const {key};\n' for key in KEYS),
    'DCMAbstractSyntaxUID.h': '#import <Foundation/Foundation.h>\n'
                              '@interface DCMAbstractSyntaxUID : NSObject\n+ (NSString*) MRSpectroscopyStorage;\n@end\n',
}
STANDINS = ('#import "NSUserDefaults+OsiriX.h"\n#import "DCMAbstractSyntaxUID.h"\n'
            + ''.join(f'NSString* const {key} = @"{constant("Horos/Sources/NSUserDefaults+OsiriX.mm", key)}";\n' for key in KEYS)
            + '@implementation DCMAbstractSyntaxUID\n+ (NSString*) MRSpectroscopyStorage { return @"%s"; }\n@end\n'
            % constant('DCM Framework/DCMAbstractSyntaxUID.m', 'MRSpectroscopyStorage'))
OBJC_DUMP = r'''
#import <Foundation/Foundation.h>
#import "DefaultsOsiriX.h"
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSData *xml = [NSPropertyListSerialization dataWithPropertyList: [DefaultsOsiriX getDefaults]
                                                                 format: NSPropertyListXMLFormat_v1_0 options: 0 error: NULL];
        fwrite(xml.bytes, 1, xml.length, stdout);
    }
    return 0;
}
'''
SWIFT_DUMP = r'''
import Foundation
import IsiXPreferences
let values = DefaultPreferences.defaults(forViewer: CommandLine.arguments[1] == "true", appStore: CommandLine.arguments[2] == "true")
let xml = try! PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
FileHandle.standardOutput.write(xml)
'''


def run(command, cwd):
    result = subprocess.run(command, capture_output=True, text=True, cwd=cwd, timeout=60)
    if result.returncode:
        sys.stderr.write(result.stderr[-4000:])
        raise SystemExit(f'FAIL: {command[0]} exited {result.returncode}')
    return result.stdout


def compile_checked(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stderr[-6000:])
        raise SystemExit('FAIL: a probe does not compile')


with tempfile.TemporaryDirectory(prefix='horos-default-preferences-') as name:
    work = Path(name)
    old = work / 'old'
    old.mkdir()
    for path in (SOURCE, 'Horos/Sources/DefaultsOsiriX.h', 'Horos/Sources/options.h', 'Horos/Sources/url.h'):
        (old / Path(path).name).write_bytes(history_reference.show(reference, path))
    for header, content in STUBS.items():
        (old / header).write_text(content)
    (old / 'standins.m').write_text(STANDINS)
    (old / 'dump.m').write_text(OBJC_DUMP)

    # The resources the defaults look up in the main bundle: an unbundled
    # executable's is the folder it is in.
    bin = work / 'bin'
    bin.mkdir()
    for plist in (ROOT / 'Horos/Resources/CLUTs').glob('*.plist'):
        shutil.copy(plist, bin / plist.name)
    shutil.copy(ROOT / 'Horos/Resources/AnnotationsDefault.plist', bin / 'AnnotationsDefault.plist')

    frameworks = ['-framework', 'Foundation', '-framework', 'AppKit', '-framework', 'AVFoundation', '-framework', 'Metal',
                  '-framework', 'CoreGraphics', '-framework', 'IOKit']
    references = {}
    for label, flags, viewer, store in VARIANTS:
        probe = bin / ('reference-' + re.sub(r'\W+', '-', label))
        compile_checked(['xcrun', 'clang', '-fno-objc-arc', '-w', '-I', str(old), *flags, str(old / 'DefaultsOsiriX.m'),
                         str(old / 'standins.m'), str(old / 'dump.m'), *frameworks, '-o', str(probe)])
        references[label] = run([str(probe), *ARGUMENTS], bin)

    modules = work / 'modules'
    (work / 'dump.swift').write_text(SWIFT_DUMP)
    swift_probe = bin / 'current'
    compile_checked(['xcrun', 'swiftc', '-swift-version', '6', *isix_modules.module_flags('IsiXPreferences', modules),
                     str(work / 'dump.swift'), '-o', str(swift_probe)])

    failed = False
    for label, flags, viewer, store in VARIANTS:
        current = run([str(swift_probe), viewer, store, *ARGUMENTS], bin)
        expected = references[label]
        keys = expected.count('\n\t<key>')
        if current != expected:
            failed = True
            diff = difflib.unified_diff(expected.splitlines(), current.splitlines(), 'DefaultsOsiriX.m', 'IsiXPreferences',
                                        lineterm='', n=2)
            print('\n'.join(list(diff)[:80]))
            print(f'FAIL: the {label} defaults differ from DefaultsOsiriX.m at {reference[:12]}')
        else:
            print(f'PASS: the {label} defaults ({keys} keys, {len(expected)} bytes of property list) '
                  f'match DefaultsOsiriX.m at {reference[:12]}')
        if label == 'application' and ('<key>CLUT</key>' not in expected or '<key>NIH</key>' not in expected):
            failed = True
            print('FAIL: the colour tables were not found beside the probes; the comparison proves too little')

raise SystemExit(1 if failed else 0)
