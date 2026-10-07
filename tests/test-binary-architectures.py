#!/usr/bin/env python3
"""Every prebuilt binary the app ships is audited against the slice of each package.

Config.xcconfig builds arm64 by default, and a release build may choose x86_64
instead (script/build_release.sh, HOROS_RELEASE_ARCH); each package carries a
single slice. A prebuilt dependency that lacks it either fails to load, or, for
a helper launched as a process, needs Rosetta on Apple Silicon. Both are silent
at build time. A helper that exists once per slice, dciodvfy, is pinned once per
slice: Binaries/dciodvfy.zip is arm64 and Binaries/dciodvfy-x86_64.zip x86_64.
"""
import re, subprocess, sys, zipfile, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
config = (root / 'Config.xcconfig').read_text()
match = re.search(r'^\s*ARCHS\s*=\s*(.+?)\s*$', config, re.M)
if not match:
    print('FAIL: Config.xcconfig no longer declares ARCHS'); sys.exit(1)
default = match.group(1).split()
if default != ['arm64']:
    print('FAIL: the default build must stay arm64, not %s' % ' '.join(default)); sys.exit(1)
excluded = re.search(r'^\s*EXCLUDED_ARCHS\[sdk=macosx\*\]\s*=\s*(.+?)\s*$', config, re.M)
if not excluded or 'x86_64' in excluded.group(1).split():
    print('FAIL: Config.xcconfig must not exclude x86_64; a release build chooses it'); sys.exit(1)
packages = ['arm64', 'x86_64']
print('project builds for: %s by default; packages: %s' % (' '.join(default), ', '.join(packages)))

MACHO = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')

def archs(path):
    result = subprocess.run(['lipo', '-archs', str(path)], capture_output=True, text=True)
    return result.stdout.split()

def audit(label, path):
    with open(path, 'rb') as handle:
        if handle.read(4) not in MACHO:
            return None
    return (label, archs(path))

found = []
for path in sorted((root / 'Binaries').rglob('*')):
    if path.is_file() and not path.is_symlink() and path.suffix != '.zip':
        entry = audit(str(path.relative_to(root)), path)
        if entry:
            found.append(entry)
# Archived dependencies are unpacked into the bundle at build time, or copied
# into it as archives, at any depth of Binaries/.
for archive in sorted((root / 'Binaries').rglob('*.zip')):
    with zipfile.ZipFile(archive) as z, tempfile.TemporaryDirectory(prefix='horos-arch-') as folder:
        for name in z.namelist():
            if name.endswith('/'):
                continue
            extracted = Path(z.extract(name, folder))
            if extracted.is_file() and extracted.stat().st_size > 4:
                entry = audit('%s!%s' % (archive.relative_to(root / 'Binaries'), name), extracted)
                if entry:
                    found.append(entry)

if not found:
    print('FAIL: no prebuilt binaries were inspected'); sys.exit(1)

# The portable Weasis viewer is not code of the application: the web portal
# serves it and disc burning copies it, for a Java runtime on the recipient's
# computer. Its native OpenCV libraries sit compressed inside .jar.xz bundles,
# out of reach of the Mach-O checks above, and 3.6.0 has no macOS arm64 one
# (Weasis 4 ships no portable edition). Pin the platforms it carries, so
# that a new version is noticed and the bundle policy revisited.
weasis_natives = set()
for archive in sorted((root / 'Binaries').glob('weasis-portable-*.zip')):
    with zipfile.ZipFile(archive) as z:
        for name in z.namelist():
            native = re.search(r'weasis-opencv-core-(.+)-\d+\.\d+\.\d+[^/]*\.jar\.xz$', name)
            if native:
                weasis_natives.add(native.group(1))
expected_weasis = {'windows-x86', 'windows-x86-64', 'linux-x86', 'linux-x86-64', 'macosx-x86-64'}
if weasis_natives and weasis_natives != expected_weasis:
    print('FAIL: the portable Weasis now carries OpenCV for %s, not %s; update the bundle policy'
          % (sorted(weasis_natives), sorted(expected_weasis)))
    sys.exit(1)
if weasis_natives:
    print('portable Weasis natives (run by the recipient\'s Java, not by the app): %s'
          % ', '.join(sorted(weasis_natives)))

# Pinned per slice: each archive carries exactly the slice of its package.
per_slice = {'dciodvfy.zip!dciodvfy': 'arm64', 'dciodvfy-x86_64.zip!dciodvfy': 'x86_64'}
for label, slice_ in per_slice.items():
    entry = next((a for found_label, a in found if found_label == label), None)
    if entry != [slice_]:
        print('FAIL: %s must be %s only, got %s' % (label, slice_, entry)); sys.exit(1)
# Binaries/dciodvfy is what the last build staged from one of them.
staged = next((a for found_label, a in found if found_label == 'Binaries/dciodvfy'), None)
if staged is not None and len(staged) != 1:
    print('FAIL: the staged dciodvfy must carry one slice, got %s' % staged); sys.exit(1)
shared = [(label, a) for label, a in found if label not in per_slice and label != 'Binaries/dciodvfy']
missing = [(label, a) for label, a in shared if not set(packages) <= set(a)]
print('inspected %d prebuilt binaries, %d pinned per slice; %d shared by both packages lack a slice'
      % (len(found), len(per_slice), len(missing)))
for label, a in missing:
    print('   %-58s %s' % (label, ' '.join(a) or '(none)'))

# Known and accounted for. Anything else is a new problem.
# 3DconnexionClient, homephone and the HorosCloud plugin archive, all without
# arm64, used to be accepted here although the bundle carried them; they left
# the project and Binaries/ and must not come back as exceptions.
accepted = {}
for name in ('3DconnexionClient', 'homephone', 'HorosCloud'):
    if any(name in label for label, _ in found):
        print('FAIL: %s is back in Binaries/; it has no arm64 and cannot load in the bundle' % name)
        sys.exit(1)

unexpected = [m for m in missing if not any(name in m[0] for name in accepted)]
if unexpected:
    print('FAIL: prebuilt binaries shared by both packages without both slices and without a documented reason:')
    for label, a in unexpected:
        print(' ', label, a)
    sys.exit(1)

# Each accepted name has to still be present; a rename should fail this test
# rather than silently widen the exemption.
for name in accepted:
    if not any(name in label for label, _ in found):
        print('FAIL: %s is no longer shipped; drop it from the accepted list' % name)
        sys.exit(1)

print('PASS: dciodvfy pinned once per slice; every other prebuilt binary carries both slices or is one of the '
      '%d documented exceptions' % len(accepted))
for name, reason in sorted(accepted.items()):
    print('   %-20s %s' % (name, reason))
