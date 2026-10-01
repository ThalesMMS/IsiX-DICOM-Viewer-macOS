#!/usr/bin/env python3
"""Every prebuilt binary the app ships is audited against the architecture it builds for.

The project builds a single architecture (Config.xcconfig ARCHS). A prebuilt
dependency that lacks it either fails to load, or — for a helper launched as a
process — needs Rosetta on Apple Silicon. Both are silent at build time.
"""
import re, subprocess, sys, zipfile, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
config = (root / 'Config.xcconfig').read_text()
match = re.search(r'^\s*ARCHS\s*=\s*(.+?)\s*$', config, re.M)
if not match:
    print('FAIL: Config.xcconfig no longer declares ARCHS'); sys.exit(1)
target = match.group(1).split()
print('project builds for: %s' % ' '.join(target))

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
# (#1021; Weasis 4 ships no portable edition). Pin the platforms it carries, so
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

missing = [(label, a) for label, a in found if not set(target) & set(a)]
print('inspected %d prebuilt binaries, %d lack every target architecture' % (len(found), len(missing)))
for label, a in missing:
    print('   %-58s %s' % (label, ' '.join(a) or '(none)'))

# Known and accounted for. Anything else is a new problem.
# 3DconnexionClient, homephone and the HorosCloud plugin archive, all without
# arm64, used to be accepted here although the bundle carried them; they left
# the project and Binaries/ (#979) and must not come back as exceptions.
accepted = {}
for name in ('3DconnexionClient', 'homephone', 'HorosCloud'):
    if any(name in label for label, _ in found):
        print('FAIL: %s is back in Binaries/; it has no arm64 and cannot load in the bundle' % name)
        sys.exit(1)
dciodvfy = [(label, a) for label, a in found if 'dciodvfy' in label]
if not dciodvfy:
    print('FAIL: dciodvfy is no longer shipped in Binaries/')
    sys.exit(1)
if any('arm64' not in a for _, a in dciodvfy):
    print('FAIL: shipped dciodvfy must be arm64, got', dciodvfy)
    sys.exit(1)

unexpected = [m for m in missing if not any(name in m[0] for name in accepted)]
if unexpected:
    print('FAIL: prebuilt binaries without a target architecture and without a documented reason:')
    for label, a in unexpected:
        print(' ', label, a)
    sys.exit(1)

# Each accepted name has to still be present; a rename should fail this test
# rather than silently widen the exemption.
for name in accepted:
    if not any(name in label for label, _ in found):
        print('FAIL: %s is no longer shipped; drop it from the accepted list' % name)
        sys.exit(1)

print('PASS: every prebuilt binary either carries a target architecture or is one of the '
      '%d documented exceptions' % len(accepted))
for name, reason in sorted(accepted.items()):
    print('   %-20s %s' % (name, reason))
