#!/usr/bin/env python3
"""The ZIP of an application package carries nothing of the machine it was made on.

The application ZIPs of a release were made by hand, with `ditto -c -k
--keepParent`: each extended attribute the build machine had left on a file
(provenance, quarantine) became an AppleDouble file, `._name`, beside it
inside the bundle. An extractor that does not fold those back into attributes
leaves them in the bundle, the seal of the signature breaks, and Gatekeeper
refuses the application as one it cannot verify.

A small application is built and signed here, with extended attributes on its
files as a build machine leaves them, and zipped three ways:

- as the releases were, and with --sequesterRsrc: the ZIP holds `._` or
  `__MACOSX` entries, what unzip extracts from the first does not pass
  `codesign --verify --deep --strict` (the fixture reproduces the failure),
  and both `script/release_archive.py --check` and `script/release-metadata.py
  --update-feed` refuse them;
- by `script/release_archive.py`: the ZIP has the name people download it by,
  from the application's version and slice, no foreign entry, the symbolic
  link and the executable bit as they were; what unzip extracts passes
  codesign, with no `._` file and no extended attribute; the script says the
  signature is ad hoc, refuses it with --require-notarized, and does not
  replace a ZIP already there;
- a ZIP with two top-level items, and an application of two slices, are
  refused.

The Developer ID signature, Gatekeeper and the stapled ticket are checked by
the script on a published package; they are not in this test, which has no
such signature to work with.
"""
import private_tmpdir  # noqa: F401
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'script/release_archive.py'
METADATA = ROOT / 'script/release-metadata.py'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def run(*command, **options):
    return subprocess.run([str(part) for part in command], capture_output=True, text=True, **options)


def build_application(folder, archs=('arm64',)):
    app = folder / 'IsiX DICOM Viewer.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Resources/en.lproj').mkdir(parents=True)
    (folder / 'main.c').write_text('int main(void) { return 0; }\n')
    flags = [flag for arch in archs for flag in ('-arch', arch)]
    done = run('xcrun', 'clang', *flags, '-o', contents / 'MacOS/IsiX DICOM Viewer', folder / 'main.c')
    if done.returncode:
        print(done.stderr)
        sys.exit(1)
    (folder / 'main.c').unlink()
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'IsiX DICOM Viewer', 'CFBundleIdentifier': 'org.horos.qa.release-archive', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '9.8.7', 'CFBundleVersion': '2026010100', 'LSMinimumSystemVersion': '15.0'}))
    (contents / 'Resources/notes.txt').write_text('a resource\n')
    (contents / 'Resources/en.lproj/Localizable.strings').write_text('"a" = "b";\n')
    os.symlink('notes.txt', contents / 'Resources/link.txt')
    done = run('codesign', '--force', '--sign', '-', app)
    if done.returncode:
        print(done.stderr)
        sys.exit(1)
    # What a build machine leaves on the files.
    for path in (contents / 'Info.plist', contents / 'Resources/notes.txt', contents / 'MacOS/IsiX DICOM Viewer', contents / '_CodeSignature/CodeResources'):
        run('xattr', '-w', 'com.apple.quarantine', '0086;00000000;test;', path)
        run('xattr', '-w', 'org.horos.qa.build-machine', 'left by the build', path)
    return app


def unzipped(archive, folder):
    folder.mkdir()
    done = run('unzip', '-q', archive, '-d', folder)
    check(done.returncode == 0, f'unzip failed on {archive.name}: {done.stderr}')
    return folder / 'IsiX DICOM Viewer.app'


with tempfile.TemporaryDirectory(prefix='horos-release-zip-') as directory:
    work = Path(directory)
    (work / 'app').mkdir()
    app = build_application(work / 'app')
    check(run('codesign', '--verify', '--deep', '--strict', app).returncode == 0, 'the fixture application is not signed')

    # As the releases were zipped, and with the attributes set aside.
    (work / 'hand').mkdir()
    inline = work / 'hand/IsiX-DICOM-Viewer-9.8.7-Apple-Silicon-Macs.zip'
    run('ditto', '-c', '-k', '--keepParent', app, inline)
    names = zipfile.ZipFile(inline).namelist()
    check(any('/._' in name for name in names), 'ditto --keepParent wrote no AppleDouble entry: the fixture does not reproduce the release ZIPs')
    extracted = unzipped(inline, work / 'hand-unzipped')
    check(any(extracted.rglob('._*')), 'unzip left no ._ file in the bundle')
    check(run('codesign', '--verify', '--deep', '--strict', extracted).returncode != 0, 'the bundle with ._ files still passes codesign')
    refused = run(sys.executable, ARCHIVE, '--check', inline)
    check(refused.returncode != 0 and 'AppleDouble' in refused.stderr, f'the hand-made ZIP is accepted: {refused.stdout}{refused.stderr}')
    feed = run(sys.executable, METADATA, '--update-feed', 'v9.8.7', ROOT, inline)
    check(feed.returncode != 0 and 'AppleDouble' in feed.stdout + feed.stderr and not (work / 'hand/stable.plist').exists(),
          f'release-metadata.py writes a feed for the hand-made ZIP: {feed.stdout}{feed.stderr}')
    (work / 'sequestered').mkdir()
    sequestered = work / 'sequestered/IsiX-DICOM-Viewer-9.8.7-Apple-Silicon-Macs.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, sequestered)
    check(any(name.startswith('__MACOSX/') for name in zipfile.ZipFile(sequestered).namelist()), '--sequesterRsrc wrote no __MACOSX entry')
    refused = run(sys.executable, ARCHIVE, '--check', sequestered)
    check(refused.returncode != 0 and '__MACOSX' in refused.stderr, 'a ZIP with __MACOSX is accepted')
    check(run(sys.executable, METADATA, '--update-feed', 'v9.8.7', ROOT, sequestered).returncode != 0, 'release-metadata.py accepts a ZIP with __MACOSX')

    # By the script.
    made = run(sys.executable, ARCHIVE, app, '--output', work / 'out')
    archive = work / 'out/IsiX-DICOM-Viewer-9.8.7-Apple-Silicon-Macs.zip'
    check(made.returncode == 0 and archive.is_file(), f'the script wrote no ZIP: {made.stdout}{made.stderr}')
    if archive.is_file():
        check('signed ad hoc' in made.stdout and 'Gatekeeper not asked' in made.stdout, f'the script does not say the signature is ad hoc: {made.stdout}')
        with zipfile.ZipFile(archive) as bundle:
            names = bundle.namelist()
            link = bundle.getinfo('IsiX DICOM Viewer.app/Contents/Resources/link.txt')
            executable = bundle.getinfo('IsiX DICOM Viewer.app/Contents/MacOS/IsiX DICOM Viewer')
        check(not [name for name in names if '/._' in name or name.startswith('__MACOSX') or name.endswith('.DS_Store')], 'the ZIP holds foreign entries')
        check(all(name.startswith('IsiX DICOM Viewer.app/') for name in names), 'the ZIP holds something beside the application')
        check((link.external_attr >> 16) & 0o170000 == 0o120000, 'the symbolic link is not stored as a link')
        check((executable.external_attr >> 16) & 0o111 == 0o111, 'the executable lost its executable bit')
        extracted = unzipped(archive, work / 'out-unzipped')
        check(not any(extracted.rglob('._*')), 'unzip left ._ files in the bundle')
        check(run('codesign', '--verify', '--deep', '--strict', extracted).returncode == 0, 'what unzip extracts does not pass codesign')
        check((extracted / 'Contents/Resources/link.txt').is_symlink(), 'the link came out as a file')
        attributes = run('xattr', '-r', extracted).stdout
        check('org.horos.qa.build-machine' not in attributes and 'com.apple.quarantine' not in attributes, f'the build machine\'s attributes came out: {attributes}')
        by_ditto = work / 'out-ditto'
        run('ditto', '-x', '-k', archive, by_ditto)
        check(run('codesign', '--verify', '--deep', '--strict', by_ditto / 'IsiX DICOM Viewer.app').returncode == 0, 'what ditto extracts does not pass codesign')
        check(run(sys.executable, ARCHIVE, '--check', archive).returncode == 0, 'the script refuses its own ZIP')
        strict = run(sys.executable, ARCHIVE, '--check', archive, '--require-notarized')
        check(strict.returncode != 0 and 'ad hoc' in strict.stderr, 'an ad hoc signature passes --require-notarized')
        size = archive.stat().st_size
        again = run(sys.executable, ARCHIVE, app, '--output', work / 'out')
        check(again.returncode != 0 and 'not replaced' in again.stderr and archive.stat().st_size == size, 'the script replaced a ZIP that was there')
        feed = run(sys.executable, METADATA, '--update-feed', 'v9.8.7', ROOT, archive)
        check(feed.returncode == 0 and (work / 'out/stable.plist').is_file(), f'release-metadata.py refuses the script\'s ZIP: {feed.stdout}{feed.stderr}')
    notarized = run(sys.executable, ARCHIVE, app, '--output', work / 'strict', '--require-notarized')
    check(notarized.returncode != 0 and not any((work / 'strict').glob('*.zip')) if (work / 'strict').exists() else notarized.returncode != 0,
          'a ZIP of an ad hoc application is left behind with --require-notarized')

    # Two top-level items, and two slices.
    two = work / 'two.zip'
    shutil.copy(archive, two)
    with zipfile.ZipFile(two, 'a') as bundle:
        bundle.writestr('README.txt', 'beside the application\n')
    refused = run(sys.executable, ARCHIVE, '--check', two)
    check(refused.returncode != 0 and 'one application' in refused.stderr, 'a ZIP with something beside the application is accepted')
    (work / 'fat').mkdir()
    fat = build_application(work / 'fat', archs=('arm64', 'x86_64'))
    refused = run(sys.executable, ARCHIVE, fat, '--output', work / 'fat-out')
    check(refused.returncode != 0 and 'single slice' in refused.stderr, f'an application of two slices is zipped: {refused.stdout}{refused.stderr}')
    (work / 'intel').mkdir()
    intel = build_application(work / 'intel', archs=('x86_64',))
    made = run(sys.executable, ARCHIVE, intel, '--output', work / 'intel-out')
    check((work / 'intel-out/IsiX-DICOM-Viewer-9.8.7-Intel-Macs.zip').is_file(), f'the Intel package is not named for Intel Macs: {made.stdout}{made.stderr}')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print('PASS: a ZIP made as the releases were holds AppleDouble entries, breaks the signature under unzip and is refused; '
      'the one script/release_archive.py writes has none, keeps links and modes, and what unzip extracts passes codesign')
