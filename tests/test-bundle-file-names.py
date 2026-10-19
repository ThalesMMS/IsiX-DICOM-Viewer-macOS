#!/usr/bin/env python3
"""No file of the application has a name that unzip does not extract intact.

The Finder keeps a folder's custom icon in a file named Icon followed by a
carriage return. Copied into the bundle, it is sealed by the signature under
that name; unzip writes it as Icon, and codesign then reports the sealed
resource as missing. Checked three ways:

- no tracked file has a control character in its name;
- .gitignore keeps a new Icon\\r out, and still accepts Icon and Icons;
- tools/audit-release-bundle.py reports such a name in a bundle, and only then.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import json
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
failures = []


def control(name):
    return any(ord(character) < 32 or ord(character) == 127 for character in name)


tracked = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], capture_output=True, check=True).stdout
for name in tracked.decode('utf-8', 'surrogateescape').split('\0'):
    if control(name):
        failures.append('tracked file with a control character in its name: %r' % name)


def ignored(name):
    return subprocess.run(['git', '-C', str(root), 'check-ignore', '-q', '--no-index', name]).returncode == 0


for name in ('Icon\r', 'Binaries/Splash/images/Icon\r'):
    if not ignored(name):
        failures.append('.gitignore does not ignore %r' % name)
for name in ('Binaries/Splash/images/Icon', 'Binaries/Splash/images/Icons'):
    if ignored(name):
        failures.append('.gitignore also ignores %r' % name)


def audit_problems(bundle):
    report = bundle.parent / 'audit.json'
    subprocess.run([sys.executable, str(root / 'tools/audit-release-bundle.py'), str(bundle), '--json', str(report)],
                   capture_output=True)
    return json.loads(report.read_text())['problems']


with tempfile.TemporaryDirectory(prefix='bundle-file-names-') as temporary:
    bundle = Path(temporary) / 'Test.app'
    images = bundle / 'Contents/Resources/Splash/images'
    images.mkdir(parents=True)
    (bundle / 'Contents/Info.plist').write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
        '<key>CFBundleIdentifier</key><string>test.bundle.names</string></dict></plist>\n')
    (images / 'logo.png').write_bytes(b'')
    named = [problem for problem in audit_problems(bundle) if 'control character' in problem]
    if named:
        failures.append('the audit reports a name problem in a clean bundle: %s' % named)
    (images / 'Icon\r').write_bytes(b'')
    named = [problem for problem in audit_problems(bundle) if 'control character' in problem]
    if len(named) != 1 or 'Splash/images/Icon\\r' not in named[0]:
        failures.append('the audit does not report Icon\\r: %s' % named)

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('ok: no control characters in tracked names, Icon\\r ignored, the audit reports it')
