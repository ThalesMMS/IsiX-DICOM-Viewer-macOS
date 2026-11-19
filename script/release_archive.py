#!/usr/bin/env python3
"""Write and check the ZIP a release publishes for one application package.

    release_archive.py APP [--output FOLDER] [--require-notarized]

zips APP, the final signed (and, for a publication, notarized and stapled)
IsiX DICOM Viewer.app of one slice, into FOLDER (the application's folder when
not given) under the name people download it by,
IsiX-DICOM-Viewer-VERSION-Apple-Silicon-Macs.zip or
IsiX-DICOM-Viewer-VERSION-Intel-Macs.zip, VERSION and the slice read from the
application, and then checks the ZIP as below. An existing ZIP is not replaced.

    release_archive.py --check ZIP [--require-notarized]

checks a ZIP that already exists.

The ZIP carries no extended attribute of the machine it was made on
(provenance, quarantine, access lists): `ditto -c -k --norsrc --noextattr`.
Zipped without those options, each attribute becomes an AppleDouble file,
`._name`, beside its file inside the bundle, or under `__MACOSX/` with
`--sequesterRsrc`. An extractor that does not fold the `._` files back into
attributes leaves them in the bundle, the seal of the signature breaks, and
Gatekeeper refuses the application as one it cannot verify. Code signatures of
the bundle are in its Mach-O files and in `_CodeSignature`, not in extended
attributes, so nothing of them is lost.

The check:

- the ZIP holds one application at its top level and no AppleDouble,
  `__MACOSX` or `.DS_Store` entry;
- extracted with `unzip`, the plainest extractor, the bundle holds no `._`
  file and `codesign --verify --deep --strict` accepts it;
- unless the signature is ad hoc (a local build), Gatekeeper accepts the
  extracted application (`spctl -a -vv`) and its notarization ticket is
  stapled. --require-notarized refuses an ad hoc signature too: use it for the
  ZIPs of a publication.
"""
import argparse
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

SLICE_NAMES = {'arm64': 'Apple-Silicon', 'x86_64': 'Intel'}


class Refused(Exception):
    pass


def run(*command):
    done = subprocess.run([str(part) for part in command], capture_output=True, text=True)
    return done.returncode, (done.stdout + done.stderr).strip()


def foreign_entries(names):
    """The entries of a ZIP that are not files of the application: AppleDouble, __MACOSX, .DS_Store."""
    return [name for name in names
            if any(part.startswith('._') or part in ('__MACOSX', '.DS_Store') for part in name.rstrip('/').split('/'))]


def application_in(names):
    """The top-level application of a ZIP's entries, refused unless it is the only top-level item."""
    tops = {name.split('/', 1)[0] for name in names if name.strip('/')}
    apps = sorted(top for top in tops if top.endswith('.app'))
    if len(apps) != 1 or len(tops) != 1:
        raise Refused('the ZIP must hold one application at its top level and nothing else: %s' % ', '.join(sorted(tops)[:6]))
    return apps[0]


def archive_name(app):
    """IsiX-DICOM-Viewer-VERSION-SLICE-Macs.zip for the application at `app`."""
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = info.get('CFBundleShortVersionString', '')
    if not re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z.-]*', version):
        raise Refused('the application has no version a file name takes: %r' % version)
    code, archs = run('/usr/bin/lipo', '-archs', app / 'Contents/MacOS' / info['CFBundleExecutable'])
    if code or archs.split() not in ([arch] for arch in SLICE_NAMES):
        raise Refused('each release ZIP carries a single slice, arm64 or x86_64; the application holds: %s' % archs)
    return 'IsiX-DICOM-Viewer-%s-%s-Macs.zip' % (version, SLICE_NAMES[archs.split()[0]])


def check(archive, require_notarized=False):
    """Raises Refused unless `archive` is a ZIP people can extract with anything; returns what was found."""
    if not zipfile.is_zipfile(archive):
        raise Refused('%s is not a readable ZIP' % archive)
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
    foreign = foreign_entries(names)
    if foreign:
        raise Refused('the ZIP holds %d AppleDouble, __MACOSX or .DS_Store entries (%s ...): zip the application with '
                      'ditto -c -k --norsrc --noextattr --keepParent' % (len(foreign), foreign[0]))
    name = application_in(names)
    with tempfile.TemporaryDirectory(prefix='release-archive-') as directory:
        code, output = run('/usr/bin/unzip', '-q', archive, '-d', directory)
        if code:
            raise Refused('unzip could not extract the ZIP: %s' % output)
        app = Path(directory) / name
        left = sorted(str(path.relative_to(directory)) for path in app.rglob('._*'))
        if left:
            raise Refused('unzip left %d AppleDouble files in the bundle (%s ...)' % (len(left), left[0]))
        code, output = run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
        if code:
            raise Refused('the application unzip extracts does not pass codesign --verify --deep --strict: %s' % output)
        _, signature = run('/usr/bin/codesign', '-dvv', app)
        if 'Signature=adhoc' in signature:
            if require_notarized:
                raise Refused('the application is signed ad hoc: a publication needs the Developer ID signature and the notarization')
            return 'signed ad hoc (a local build): Gatekeeper not asked'
        code, output = run('/usr/sbin/spctl', '-a', '-vv', app)
        if code or 'accepted' not in output:
            raise Refused('Gatekeeper does not accept the application unzip extracts: %s' % output)
        code, stapled = run('/usr/bin/xcrun', 'stapler', 'validate', app)
        if code:
            raise Refused('the notarization ticket is not stapled to the application: %s' % stapled)
        source = next((line.split('=', 1)[1] for line in output.splitlines() if line.startswith('source=')), 'accepted')
        return 'Gatekeeper: %s; ticket stapled' % source


def write(app, folder, require_notarized=False):
    """Zips `app` into `folder` under its public name, checks the ZIP and returns its path and what was found."""
    if not (app / 'Contents/Info.plist').is_file():
        raise Refused('%s is not an application bundle' % app)
    archive = folder / archive_name(app)
    if archive.exists() or archive.is_symlink():
        raise Refused('%s is already there; it is not replaced' % archive)
    folder.mkdir(parents=True, exist_ok=True)
    code, output = run('/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, archive)
    if code:
        archive.unlink(missing_ok=True)
        raise Refused('ditto could not write the ZIP: %s' % output)
    try:
        found = check(archive, require_notarized)
    except Refused:
        archive.unlink(missing_ok=True)
        raise
    return archive, found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true', help='check an existing ZIP instead of writing one')
    parser.add_argument('--output', type=Path, metavar='FOLDER', help='where the ZIP is written; the application\'s folder by default')
    parser.add_argument('--require-notarized', action='store_true', help='refuse an application signed ad hoc')
    parser.add_argument('path', type=Path, help='the application to zip, or with --check the ZIP')
    arguments = parser.parse_args()
    try:
        if arguments.check:
            print('%s: no foreign entry; unzip extracts a bundle codesign accepts; %s'
                  % (arguments.path, check(arguments.path, arguments.require_notarized)))
        else:
            archive, found = write(arguments.path, arguments.output or arguments.path.resolve().parent, arguments.require_notarized)
            print('%s: %d bytes; no foreign entry; unzip extracts a bundle codesign accepts; %s'
                  % (archive, archive.stat().st_size, found))
    except Refused as refusal:
        sys.exit('release_archive.py: %s' % refusal)


if __name__ == '__main__':
    main()
