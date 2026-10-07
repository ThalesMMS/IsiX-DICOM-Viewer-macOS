#!/usr/bin/env python3
"""Validator stage verifies identity before replacing a product, including offline recovery.

Each package slice has its own pin: dciodvfy.lock.json/dciodvfy.zip for arm64 and
dciodvfy-x86_64.lock.json/dciodvfy-x86_64.zip for x86_64. The stage takes the
slice of the build's ARCHS (arm64 outside a build), and the release record
names the pin of the helper the package ships.

Optional positional CACHE_DIR exercises the supplied pinned source/artifact cache.
Optional --bundle APP checks the record, notice and executable after app signing.
"""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
lock = json.loads((root / 'Binaries/dciodvfy.lock.json').read_text())
locks = {'arm64': lock, 'x86_64': json.loads((root / 'Binaries/dciodvfy-x86_64.lock.json').read_text())}
script = root / 'Horos/Scripts/Horos/stage-dciodvfy.py'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cache', nargs='?', type=Path)
parser.add_argument('--bundle', type=Path)
args = parser.parse_args()


def run(output, *options, succeeds=True, archs=None):
    environment = {key: value for key, value in os.environ.items() if key != 'ARCHS'}
    if archs is not None:
        environment['ARCHS'] = archs
    result = subprocess.run([sys.executable, str(script), '--output', str(output), *map(str, options)],
                            capture_output=True, text=True, timeout=60, env=environment)
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

    # One pin per slice, chosen by the build's ARCHS or by --arch.
    for name, pin in locks.items():
        assert pin['architecture'] == name and pin['snapshot'] == lock['snapshot']
        assert pin['source'] == lock['source'] and pin['license'] == lock['license'] and pin['build'] == lock['build']
        assert name in pin['artifact']['url'] and pin['helperSHA256'] != ('' if name == 'arm64' else lock['helperSHA256'])
        archive = root / 'Binaries' / ('dciodvfy.zip' if name == 'arm64' else 'dciodvfy-x86_64.zip')
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == pin['shippedArchiveSHA256'], name
    intel = folder / 'x86_64/dciodvfy'
    assert 'staged verified x86_64 helper' in run(intel, archs='x86_64').stdout
    assert hashlib.sha256(intel.read_bytes()).hexdigest() == locks['x86_64']['helperSHA256']
    assert subprocess.check_output(['lipo', '-archs', str(intel)], text=True).split() == ['x86_64']
    assert 'verified existing x86_64 helper' in run(intel, '--arch', 'x86_64').stdout
    assert 'staged verified arm64 helper' in run(intel, archs='arm64').stdout
    assert hashlib.sha256(intel.read_bytes()).hexdigest() == lock['helperSHA256']
    refused = run(intel, archs='arm64 x86_64', succeeds=False)
    assert 'one package slice per build' in refused.stderr
    # The arm64 archive offered as the x86_64 pin fails its digest, before any replacement.
    mismatch = run(intel, '--arch', 'x86_64', '--zip', root / 'Binaries/dciodvfy.zip', succeeds=False)
    assert 'SHA-256 mismatch' in mismatch.stderr and hashlib.sha256(intel.read_bytes()).hexdigest() == lock['helperSHA256']

# Exercise release metadata on a synthetic staging tree; the signed bundle
# checksum is explicitly separate from the acquired helper pin.
with tempfile.TemporaryDirectory(prefix='horos-validator-record-') as directory:
    staging = Path(directory)
    app = staging / 'IsiX DICOM Viewer.app'
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True)
    executable = app / 'Contents/MacOS/IsiX DICOM Viewer'
    executable.parent.mkdir()
    executable.write_bytes(b'synthetic executable')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'IsiX DICOM Viewer'}))
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

# The x86_64 package records the x86_64 pin, chosen by the helper it ships.
with tempfile.TemporaryDirectory(prefix='horos-validator-record-x86_64-') as directory:
    staging = Path(directory)
    app = staging / 'IsiX DICOM Viewer.app'
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True)
    (app / 'Contents/MacOS').mkdir()
    (app / 'Contents/MacOS/IsiX DICOM Viewer').write_bytes(b'synthetic executable')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'IsiX DICOM Viewer'}))
    for name in ('dciodvfy.lock.json', 'dciodvfy-x86_64.lock.json'):
        (resources / name).write_text((root / 'Binaries' / name).read_text())
    subprocess.run([sys.executable, str(script), '--arch', 'x86_64', '--output', str(resources / 'dciodvfy')],
                   check=True, capture_output=True, timeout=60)
    checkout = staging / 'checkout'
    (checkout / 'Horos.xcodeproj').mkdir(parents=True)
    (checkout / 'Horos.xcodeproj/project.pbxproj').write_bytes(plistlib.dumps({'objects': {}}))
    subprocess.run([sys.executable, str(root / 'script/release-metadata.py'),
                    str(checkout), str(staging / 'temp'), str(staging), str(staging / 'audit.json'),
                    str(staging / 'SourcePackages')], check=True, capture_output=True)
    record = (staging / 'BUILD-INFO.txt').read_text()
    assert 'architecture: x86_64' in record and locks['x86_64']['artifact']['sha256'] in record
    assert locks['x86_64']['helperSHA256'] in record and lock['artifact']['sha256'] not in record

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
assert 'dciodvfy.lock.json in Resources' in project
assert 'dciodvfy-x86_64.lock.json in Resources' in project
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
    shipped = subprocess.check_output(['lipo', '-archs', str(resources / 'dciodvfy')], text=True).split()
    assert len(shipped) == 1 and shipped[0] in locks, shipped
    lock = locks[shipped[0]]
    assert json.loads((resources / 'dciodvfy.lock.json').read_text()) == locks['arm64']
    assert json.loads((resources / 'dciodvfy-x86_64.lock.json').read_text()) == locks['x86_64']
    copyright_path = resources / lock['license']['path']
    assert hashlib.sha256(copyright_path.read_bytes()).hexdigest() == lock['license']['sha256']
    # Xcode signing changes Mach-O bytes; the pin records the acquired helper,
    # and the release SHA256SUMS records the actual signed bundle separately.
    helper = resources / 'dciodvfy'
    subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
    dependencies = subprocess.check_output(['otool', '-L', str(helper)], text=True)
    for line in dependencies.splitlines()[1:]:
        assert line.strip().startswith(('/usr/lib/', '/System/Library/')), line
    subprocess.run([sys.executable, str(root / 'tests/test-dciodvfy-native.py'),
                    '--helper', str(helper), '--arch', lock['architecture']], check=True, timeout=60)
print('PASS: pinned native staging per slice (arm64, x86_64), atomic failures, packaging/caller wiring' +
      (', supplied offline cache' if args.cache else '') +
      (', signed app record/license/helper' if args.bundle else ''))
