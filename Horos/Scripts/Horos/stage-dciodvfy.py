#!/usr/bin/env python3
"""Verify and atomically stage the pinned native DICOM validator of one slice.

Each package carries the validator of its slice: Binaries/dciodvfy.zip and
dciodvfy.lock.json for arm64, dciodvfy-x86_64.zip and dciodvfy-x86_64.lock.json
for x86_64. --arch chooses; by default the single slice of the build's ARCHS,
and arm64 outside a build.

Default: use the tracked ZIP, without network access.
--from-upstream: obtain the identified source and the slice's archive into --cache-dir.
--offline: require those exact cached archives, with no network fallback.
All hashes, version, license, architecture and runtime dependencies are checked
before replacing the destination. Only the validator member is extracted.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[3]
PINS = {'arm64': ('dciodvfy.lock.json', 'dciodvfy.zip'),
        'x86_64': ('dciodvfy-x86_64.lock.json', 'dciodvfy-x86_64.zip')}


def build_architecture():
    """The slice Xcode builds, or arm64 when run by hand."""
    slices = os.environ.get('ARCHS', '').split()
    if not slices:
        return 'arm64'
    if len(slices) != 1 or slices[0] not in PINS:
        raise ValueError('one package slice per build, arm64 or x86_64; ARCHS is ' + ' '.join(slices))
    return slices[0]


def verify(data, digest, label):
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError('SHA-256 mismatch: ' + label)
    return data


def acquire(record, cache, offline):
    path = cache / record['filename']
    if path.exists():
        return verify(path.read_bytes(), record['sha256'], record['filename'])
    if offline:
        raise ValueError('Offline cache missing: ' + record['filename'])
    with urllib.request.urlopen(record['url'], timeout=60) as response:
        data = verify(response.read(), record['sha256'], record['filename'])
    atomic_write(path, data, 0o644)
    return data


def atomic_write(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    name = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.' + path.name + '-', delete=False) as f:
            name = f.name
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if name and os.path.exists(name):
            os.unlink(name)


def member(archive, name):
    info = archive.getmember(name)
    if not info.isfile():
        raise ValueError('Archive member must be a regular file: ' + name)
    return archive.extractfile(info).read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=sorted(PINS))
    parser.add_argument('--output', type=Path, default=ROOT / 'Binaries/dciodvfy')
    parser.add_argument('--zip', type=Path)
    parser.add_argument('--from-upstream', action='store_true')
    parser.add_argument('--cache-dir', type=Path, default=ROOT / 'build/dciodvfy-cache')
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    architecture = args.arch or build_architecture()
    lock_name, zip_name = PINS[architecture]
    lock = json.loads((ROOT / 'Binaries' / lock_name).read_text())
    if lock['architecture'] != architecture:
        raise ValueError('%s pins %s, not %s' % (lock_name, lock['architecture'], architecture))
    args.zip = args.zip or ROOT / 'Binaries' / zip_name
    license_data = verify((ROOT / 'Binaries' / lock['license']['path']).read_bytes(),
                          lock['license']['sha256'], 'bundled COPYRIGHT')
    if args.from_upstream:
        import io
        source = acquire(lock['source'], args.cache_dir, args.offline)
        artifact = acquire(lock['artifact'], args.cache_dir, args.offline)
        with tarfile.open(fileobj=io.BytesIO(source), mode='r:bz2') as tar:
            source_root = lock['source']['filename'].removesuffix('.tar.bz2')
            if member(tar, source_root + '/COPYRIGHT') != license_data:
                raise ValueError('Source COPYRIGHT differs from bundled license')
        with tarfile.open(fileobj=io.BytesIO(artifact), mode='r:gz') as tar:
            if member(tar, './COPYRIGHT') != license_data:
                raise ValueError('Artifact COPYRIGHT differs from source license')
            if member(tar, './VERSION.txt').decode().strip() != lock['source']['filename']:
                raise ValueError('Artifact VERSION.txt differs from pinned source')
            data = member(tar, lock['artifact']['member'])
    else:
        verify(args.zip.read_bytes(), lock['shippedArchiveSHA256'], 'shipped ZIP')
        with zipfile.ZipFile(args.zip) as archive:
            data = archive.read('dciodvfy')
    verify(data, lock['helperSHA256'], 'dciodvfy member')
    # Validate a private temporary copy before touching an existing staged helper.
    with tempfile.TemporaryDirectory(prefix='dciodvfy-check-') as directory:
        candidate = Path(directory) / 'dciodvfy'
        candidate.write_bytes(data)
        candidate.chmod(0o755)
        archs = subprocess.check_output(['/usr/bin/lipo', '-archs', str(candidate)], text=True).split()
        if archs != [architecture]:
            raise ValueError('Validator must be %s-only, not %s' % (architecture, ' '.join(archs) or 'unreadable'))
        libraries = subprocess.check_output(['/usr/bin/otool', '-L', str(candidate)], text=True)
        for line in libraries.splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if not dependency.startswith(('/usr/lib/', '/System/Library/')):
                raise ValueError('Validator loads a non-system library: ' + dependency)
    if args.output.is_file() and args.output.read_bytes() == data and os.access(args.output, os.X_OK):
        print('dciodvfy: verified existing %s helper, snapshot %s' % (architecture, lock['snapshot']))
    else:
        atomic_write(args.output, data, 0o755)
        print('dciodvfy: staged verified %s helper, snapshot %s' % (architecture, lock['snapshot']))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, tarfile.TarError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        sys.exit('error: stage dciodvfy: ' + str(error))
