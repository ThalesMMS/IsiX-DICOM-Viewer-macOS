#!/usr/bin/env python3
"""Validator stage verifies identity before replacing a product, including offline recovery.

Optional positional CACHE_DIR exercises the supplied pinned source/artifact cache.
Optional --bundle APP checks the record, notice and executable after app signing.
"""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
lock = json.loads((root / 'Binaries/dciodvfy.lock.json').read_text())
script = root / 'Horos/Scripts/Horos/stage-dciodvfy.py'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cache', nargs='?', type=Path)
parser.add_argument('--bundle', type=Path)
args = parser.parse_args()


def run(output, *options, succeeds=True):
    result = subprocess.run([sys.executable, str(script), '--output', str(output), *map(str, options)],
                            capture_output=True, text=True, timeout=60)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
    return result


with tempfile.TemporaryDirectory(prefix='horos-validator-stage-') as directory:
    folder = Path(directory)
    output = folder / '空間 válido/dciodvfy'
    run(output)
    data = output.read_bytes()
    assert hashlib.sha256(data).hexdigest() == lock['helperSHA256']
    assert output.stat().st_mode & 0o111
    timestamp = output.stat().st_mtime_ns
    run(output)
    assert output.stat().st_mtime_ns == timestamp, 'no-op stage rewrote verified helper'
    corrupt = folder / 'corrupt.zip'
    corrupt.write_bytes(b'corrupt archive')
    result = run(output, '--zip', corrupt, succeeds=False)
    assert 'SHA-256 mismatch' in result.stderr
    run(output, '--zip', folder / 'missing.zip', succeeds=False)
    run(output, '--from-upstream', '--cache-dir', folder / 'empty-cache', '--offline', succeeds=False)
    assert output.read_bytes() == data and output.stat().st_mtime_ns == timestamp
    if args.cache:
        recovered = folder / 'offline/dciodvfy'
        run(recovered, '--from-upstream', '--cache-dir', args.cache, '--offline')
        assert recovered.read_bytes() == data
        bad_cache = folder / 'bad-cache'
        bad_cache.mkdir()
        # A cache with poisoned source is rejected without fallback or replacement.
        (bad_cache / lock['source']['filename']).write_bytes(b'poisoned source')
        run(output, '--from-upstream', '--cache-dir', bad_cache, '--offline', succeeds=False)
        assert output.read_bytes() == data
    assert list(output.parent.iterdir()) == [output], 'failed stage leaked temporary files'

# Exercise release metadata on a synthetic staging tree; the signed bundle
# checksum is explicitly separate from the acquired helper pin.
with tempfile.TemporaryDirectory(prefix='horos-validator-record-') as directory:
    staging = Path(directory)
    app = staging / 'Isis DICOM Viewer.app'
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True)
    executable = app / 'Contents/MacOS/Isis DICOM Viewer'
    executable.parent.mkdir()
    executable.write_bytes(b'synthetic executable')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Isis DICOM Viewer'}))
    (resources / 'dciodvfy.lock.json').write_text(json.dumps(lock))
    (resources / 'dciodvfy').write_bytes(b'synthetic signed helper')
    # The record of the validator does not depend on the Swift packages. A
    # scratch checkout whose project links none keeps this check off the
    # network, where the release metadata confirms each package's public tag.
    checkout = staging / 'checkout'
    (checkout / 'Horos.xcodeproj').mkdir(parents=True)
    (checkout / 'Horos.xcodeproj/project.pbxproj').write_bytes(plistlib.dumps({'objects': {}}))
    subprocess.run([sys.executable, str(root / 'script/release-metadata.py'),
                    str(checkout), str(staging / 'temp'), str(staging), str(staging / 'audit.json'),
                    str(staging / 'SourcePackages')],
                   check=True, capture_output=True)
    record = (staging / 'BUILD-INFO.txt').read_text()
    for expected in (lock['source']['sha256'], lock['artifact']['sha256'],
                     lock['build']['revision'], lock['helperSHA256'],
                     hashlib.sha256(b'synthetic signed helper').hexdigest()):
        assert expected in record
    assert '/Users/' not in record
    assert 'Contents/Resources/dciodvfy.lock.json' in (staging / 'SHA256SUMS.txt').read_text()

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
assert 'dciodvfy.lock.json in Resources' in project
unzip = (root / 'Horos/Scripts/Horos/Unzip.sh').read_text()
assert 'stage-dciodvfy.py" || exit $?' in unzip and 'unzip -uo dciodvfy.zip' not in unzip
controller = (root / 'Horos/Sources/XMLController.swift').read_text()
start = controller.index('public func verify(')
verify = controller[start:controller.index('@IBAction', start)]
for setting in ('options.timeout = 30.0', 'options.capturesStandardError = true',
                'options.allowsFailureStatus = true', 'HorosRunBoundedTaskWithOptions'):
    assert setting in verify

if args.bundle:
    resources = args.bundle / 'Contents/Resources'
    assert json.loads((resources / 'dciodvfy.lock.json').read_text()) == lock
    copyright_path = resources / lock['license']['path']
    assert hashlib.sha256(copyright_path.read_bytes()).hexdigest() == lock['license']['sha256']
    # Xcode signing changes Mach-O bytes; the pin records the acquired helper,
    # and the release SHA256SUMS records the actual signed bundle separately.
    helper = resources / 'dciodvfy'
    assert subprocess.check_output(['lipo', '-archs', str(helper)], text=True).split() == ['arm64']
    subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
    dependencies = subprocess.check_output(['otool', '-L', str(helper)], text=True)
    for line in dependencies.splitlines()[1:]:
        assert line.strip().startswith(('/usr/lib/', '/System/Library/')), line
    subprocess.run([sys.executable, str(root / 'tests/test-dciodvfy-native.py'),
                    '--helper', str(helper)], check=True, timeout=30)
print('PASS: pinned native staging, atomic failures, packaging/caller wiring' +
      (', supplied offline cache' if args.cache else '') +
      (', signed app record/license/helper' if args.bundle else ''))
