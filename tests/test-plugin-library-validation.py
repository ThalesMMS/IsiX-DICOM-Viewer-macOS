#!/usr/bin/env python3
"""Library validation exception for third-party plugins, per distribution channel.

Under the hardened runtime, dyld refuses to map code signed by another team
("mapping process and mapped file (non-platform) have different Team IDs").
Third-party plugins are signed by their own developers and load into the app's
process, so the entitlements of the GitHub channel, which the Developer ID
signature uses, must carry com.apple.security.cs.disable-library-validation.
The App Store channel loads no third-party plugins and must not carry it.

The release script and the build metadata it writes must say the same: the
exception is part of the app entitlements for plugins, not something only the
local ad hoc signature needs.

`<git revision>` as an optional argument checks that revision instead of the
working tree, which serves as a negative control on an earlier revision.
"""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
KEY = 'com.apple.security.cs.disable-library-validation'
failures = []


def read(relative):
    if revision:
        return subprocess.run(['git', '-C', str(root), 'show', '%s:%s' % (revision, relative)],
                              check=True, capture_output=True).stdout
    return (root / relative).read_bytes()


def require(condition, message):
    if not condition:
        failures.append(message)


def app_entitlements(xcconfig):
    text = read(xcconfig).decode()
    match = re.search(r'^HOROS_APP_ENTITLEMENTS\s*=\s*(\S+)\s*$', text, re.M)
    if not match:
        failures.append(xcconfig + ' does not set HOROS_APP_ENTITLEMENTS')
        return None, {}
    return match.group(1), plistlib.loads(read(match.group(1)))


for xcconfig in ('Horos/Configuration/GitHub.xcconfig', 'Horos/Horos.xcconfig'):
    path, entitlements = app_entitlements(xcconfig)
    if path:
        require(entitlements.get(KEY) is True,
                '%s (from %s) does not allow third-party plugins signed by another team' % (path, xcconfig))
        require(not entitlements.get('com.apple.security.get-task-allow')
                and not entitlements.get('com.apple.security.cs.allow-dyld-environment-variables'),
                '%s carries a local debugging exception' % path)

store_config = 'Horos/Configuration/AppStore.xcconfig'
store_path, store = app_entitlements(store_config)
if store_path:
    require(store_path != 'Horos/Horos.entitlements', 'the App Store channel shares the GitHub entitlements')
    require(KEY not in store, '%s disables library validation' % store_path)
    require(store.get('com.apple.security.app-sandbox') is True, '%s is not sandboxed' % store_path)
require(re.search(r'^RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION\s*=\s*NO\s*$',
                  read(store_config).decode(), re.M) is not None,
        store_config + ' does not turn off the Xcode library validation exception')

release = read('script/build_release.sh').decode()
block = release[:release.index('APP_ENTITLEMENTS=')]
block = block[block.rfind('\n\n') + 2:]
comment = ' '.join(line.lstrip('# ') for line in block.splitlines() if line.startswith('#'))
require('would not need it' not in comment and 'it is not in Horos.entitlements' not in comment,
        'build_release.sh still says a Developer ID signature does not need the exception')
require('third-party plugins' in comment.lower() and 'Horos.entitlements carries' in comment,
        'build_release.sh does not explain that third-party plugins need the exception in Horos.entitlements')

metadata = read('script/release-metadata.py').decode()
require('not of Horos.entitlements' not in metadata,
        'BUILD-INFO.txt still says the exception is not in Horos.entitlements')

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print('ok: GitHub entitlements disable library validation for third-party plugins; App Store entitlements do not'
      + (' (%s)' % revision if revision else ''))
