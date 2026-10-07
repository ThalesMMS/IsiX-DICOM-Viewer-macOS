#!/usr/bin/env python3
"""Native validator, per package slice, and metadata caller contract on synthetic DICOMs.

Binaries/dciodvfy.zip holds the arm64 validator and Binaries/dciodvfy-x86_64.zip
the x86_64 one. Each must carry only its slice and load only macOS libraries.
Both are run on the synthetic files when this Mac can run their slice; an
x86_64 helper needs Rosetta on Apple Silicon, and without it that run is
reported as not done rather than passed.

Optional --fixtures-dir preserves only generated valid/invalid files for app QA.
--helper tests the validator in a built app instead of the tracked archives;
--arch names the slice it must have (by default, the single slice it carries).
"""
from pathlib import Path
import argparse
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
archives = {'arm64': root / 'Binaries/dciodvfy.zip', 'x86_64': root / 'Binaries/dciodvfy-x86_64.zip'}
for path in archives.values():
    if not path.is_file():
        print('FAIL: %s is missing' % path.relative_to(root), file=sys.stderr)
        sys.exit(1)


def element(group, number, vr, payload):
    if vr in (b'OB', b'OW'):
        if len(payload) % 2:
            payload += b'\x00'
        return struct.pack('<HH2sHI', group, number, vr, 0, len(payload)) + payload
    if len(payload) % 2:
        payload += b'\x00' if vr == b'UI' else b' '
    return struct.pack('<HH2sH', group, number, vr, len(payload)) + payload


CLASS_UID = b'1.2.840.10008.5.1.4.1.1.7'
INSTANCE_UID = b'1.2.826.0.1.3680043.8.498.37001'
EXPLICIT_LITTLE = b'1.2.840.10008.1.2.1'
meta = (element(0x0002, 0x0001, b'OB', b'\x00\x01')
        + element(0x0002, 0x0002, b'UI', CLASS_UID)
        + element(0x0002, 0x0003, b'UI', INSTANCE_UID)
        + element(0x0002, 0x0010, b'UI', EXPLICIT_LITTLE)
        + element(0x0002, 0x0012, b'UI', b'1.2.826.0.1.3680043.8.498.1'))
meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(meta))) + meta
# Complete single-frame Secondary Capture; all data is synthetic.
attributes = [
    (0x0008, 0x0016, b'UI', CLASS_UID), (0x0008, 0x0018, b'UI', INSTANCE_UID),
    (0x0008, 0x0020, b'DA', b'20261001'), (0x0008, 0x0030, b'TM', b'120000'),
    (0x0008, 0x0050, b'SH', b''), (0x0008, 0x0060, b'CS', b'OT'),
    (0x0008, 0x0064, b'CS', b'WSD'), (0x0008, 0x0090, b'PN', b''),
    (0x0010, 0x0010, b'PN', b'QA^DCIODVFY'), (0x0010, 0x0020, b'LO', b'LOCAL-DCIODVFY'),
    (0x0010, 0x0030, b'DA', b''), (0x0010, 0x0040, b'CS', b''),
    (0x0020, 0x000D, b'UI', b'1.2.826.0.1.3680043.8.498.37002'),
    (0x0020, 0x000E, b'UI', b'1.2.826.0.1.3680043.8.498.37003'),
    (0x0020, 0x0010, b'SH', b'DCIOD'), (0x0020, 0x0011, b'IS', b'1'),
    (0x0020, 0x0013, b'IS', b'1'), (0x0020, 0x0020, b'CS', b''), (0x0020, 0x0060, b'CS', b''),
    (0x0028, 0x0002, b'US', struct.pack('<H', 1)),
    (0x0028, 0x0004, b'CS', b'MONOCHROME2'),
    (0x0028, 0x0010, b'US', struct.pack('<H', 4)),
    (0x0028, 0x0011, b'US', struct.pack('<H', 5)),
    (0x0028, 0x0100, b'US', struct.pack('<H', 16)),
    (0x0028, 0x0101, b'US', struct.pack('<H', 16)),
    (0x0028, 0x0102, b'US', struct.pack('<H', 15)),
    (0x0028, 0x0103, b'US', struct.pack('<H', 0)),
    (0x7fe0, 0x0010, b'OW', bytes(40)),
]
valid_fixture = b'\x00' * 128 + b'DICM' + meta + b''.join(element(*x) for x in attributes)
# Keep pixels and a distinct SOP instance for independent imports in the app;
# removing the required PatientSex element makes this an invalid IOD.
invalid_fixture = (b'\x00' * 128 + b'DICM' + meta +
                   b''.join(element(*x) for x in attributes if x[:2] != (0x0010, 0x0040)))
invalid_fixture = invalid_fixture.replace(INSTANCE_UID, b'1.2.826.0.1.3680043.8.498.37004')

# Compile the bounded task implementation used by XMLController, with its actual
# capture-stderr / allow-failure options. This is execution, not a source scanner.
driver = r'''
#import <Foundation/Foundation.h>
#import "HorosBoundedTask.h"
#define check(x) do { if (!(x)) { NSLog(@"FAIL: %s", #x); return 1; } } while (0)
int main(int argc, char **argv) { @autoreleasepool {
 NSString *helper = @(argv[1]), *valid = @(argv[2]), *invalid = @(argv[3]);
 HorosBoundedTaskOptions options = {.timeout=5, .capturesStandardError=YES, .allowsFailureStatus=YES};
 NSError *error = nil;
 NSData *out = HorosRunBoundedTaskWithOptions(helper, @[valid], options, &error);
 check(out && !error);
 NSString *report = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
 check([report containsString:@"SCImage"] && ![report containsString:@"Error"]);
 out = HorosRunBoundedTaskWithOptions(helper, @[invalid], options, &error);
 check(out && !error);
 report = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
 check([report containsString:@"Missing attribute"]);
 options.allowsFailureStatus = NO;
 out = HorosRunBoundedTaskWithOptions(helper, @[invalid], options, &error);
 check(!out && error);
 options.allowsFailureStatus = YES;
 error = nil;
 out = HorosRunBoundedTaskWithOptions(@"/there-is-no-validator", @[], options, &error);
 check(!out && error);
 error = nil;
 out = HorosRunBoundedTaskWithOptions(valid, @[], options, &error);
 check(!out && error); // existing, non-executable file
 error = nil;
 options.timeout = 0.1;
 double before = NSProcessInfo.processInfo.systemUptime;
 out = HorosRunBoundedTaskWithOptions(@"/bin/sh", @[@"-c", @"printf partial >&2; exec sleep 60"], options, &error);
 check(!out && error && NSProcessInfo.processInfo.systemUptime - before < 3);
 NSLog(@"PASS: metadata validator options preserve findings, stderr, launch failures and deadline");
}}
'''

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fixtures-dir', type=Path)
parser.add_argument('--helper', type=Path)
parser.add_argument('--arch', choices=sorted(archives))
args = parser.parse_args()


def runnable(architecture):
    """Whether this Mac runs code of that slice (x86_64 on Apple Silicon needs Rosetta)."""
    return subprocess.run(['/usr/bin/arch', '-' + architecture, '/usr/bin/true'], capture_output=True).returncode == 0


def minimum_macos(helper):
    listing = subprocess.check_output(['otool', '-l', str(helper)], text=True)
    found = re.search(r'cmd LC_BUILD_VERSION.*?minos (\S+)', listing, re.S) or \
        re.search(r'cmd LC_VERSION_MIN_MACOSX.*?version (\S+)', listing, re.S)
    return tuple(int(part) for part in found.group(1).split('.')) if found else None


def check_identity(helper, architecture):
    slices = subprocess.check_output(['lipo', '-archs', str(helper)], text=True).split()
    assert slices == [architecture], (helper, slices)
    for line in subprocess.check_output(['otool', '-L', str(helper)], text=True).splitlines()[1:]:
        assert line.strip().startswith(('/usr/lib/', '/System/Library/')), line
    minimum = minimum_macos(helper)
    assert minimum is not None and minimum <= (26, 0), (helper, minimum)


def check_findings(helper, data_folder):
    valid = data_folder / 'válido 空間.dcm'
    invalid = data_folder / 'inválido 空間.dcm'
    valid.write_bytes(valid_fixture)
    invalid.write_bytes(invalid_fixture)
    for path, status in ((valid, 0), (invalid, 1)):
        result = subprocess.run([str(helper), str(path)], capture_output=True, text=True, timeout=30)
        assert result.returncode == status, result.stderr
        assert result.stdout == '' and 'SCImage' in result.stderr, result
        if status:
            assert 'Missing attribute' in result.stderr, result.stderr
        else:
            assert 'Error' not in result.stderr, result.stderr
    return valid, invalid


with tempfile.TemporaryDirectory(prefix='horos-dciodvfy-') as directory:
    folder = Path(directory)
    if args.helper:
        helper = args.helper.resolve()
        architecture = args.arch or subprocess.check_output(['lipo', '-archs', str(helper)], text=True).strip()
        helpers = {architecture: helper}
    else:
        helpers = {}
        for architecture, archive in archives.items():
            (folder / architecture).mkdir()
            with zipfile.ZipFile(archive) as zipped:
                zipped.extract('dciodvfy', folder / architecture)
            helpers[architecture] = folder / architecture / 'dciodvfy'
            helpers[architecture].chmod(0o755)
    ran, not_run = [], []
    data_folder = args.fixtures_dir or folder
    data_folder.mkdir(parents=True, exist_ok=True)
    driver_helper = None
    for architecture, helper in helpers.items():
        check_identity(helper, architecture)
        if runnable(architecture):
            valid, invalid = check_findings(helper, data_folder)
            ran.append(architecture)
            driver_helper = driver_helper or helper
        else:
            not_run.append(architecture)
    assert ran, 'no validator of a slice this Mac runs was exercised'
    (folder / 'driver.m').write_text(driver)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fsanitize=address,undefined',
                    '-fno-sanitize-recover=all', '-framework', 'Foundation',
                    '-I', str(root / 'Horos/Sources'), str(folder / 'driver.m'), '-o', str(folder / 'driver')], check=True)
    subprocess.run([str(folder / 'driver'), str(driver_helper), str(valid), str(invalid)], check=True, timeout=30)
    print('PASS: %s validator(s) single-slice with macOS-only libraries; %s validated complete SCImage, '
          'reported the invalid IOD, Unicode paths and bounded task failures'
          % ('/'.join(helpers), '/'.join(ran)))
    for architecture in not_run:
        print('note: the %s validator was checked by slice, libraries and minimum macOS, but not run: '
              'this Mac cannot run %s code' % (architecture, architecture))
