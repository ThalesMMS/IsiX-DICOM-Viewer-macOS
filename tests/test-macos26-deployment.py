#!/usr/bin/env python3
"""Checkout policy for macOS 26: signing isolation, encoded target vs SDK, full-screen button swizzle, plist.

The product minimum is macOS 26, revised down from 27 when that number put the
target beyond every SDK and every machine available to build it. 26 is both
expressible by the toolchain here and runnable, so the encoded target is no
longer allowed to lag behind the policy.
"""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []


def fail(message):
    failures.append(message)


config = (root / 'Config.xcconfig').read_text()
match = re.search(r'^\s*MACOSX_DEPLOYMENT_TARGET\s*=\s*(\S+)', config, re.M)
if not match:
    fail('Config.xcconfig no longer declares MACOSX_DEPLOYMENT_TARGET')
    encoded = '0.0'
else:
    encoded = match.group(1)

sdk = subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip()
sdk_major = int(sdk.split('.')[0])
encoded_major = int(encoded.split('.')[0])
if encoded_major > sdk_major:
    fail(f'encoded MACOSX_DEPLOYMENT_TARGET {encoded} exceeds SDK {sdk}')

# Product minimum is 26. Encode it whenever the SDK can express it, which is
# the case for every toolchain that can build this checkout at all.
PRODUCT_MINIMUM_MAJOR = 26
if sdk_major >= PRODUCT_MINIMUM_MAJOR and encoded_major != PRODUCT_MINIMUM_MAJOR:
    fail(f'SDK {sdk} can encode macOS {PRODUCT_MINIMUM_MAJOR} but Config has {encoded}')
if sdk_major < PRODUCT_MINIMUM_MAJOR and encoded_major >= PRODUCT_MINIMUM_MAJOR:
    fail(f'SDK {sdk} cannot encode MACOSX_DEPLOYMENT_TARGET {encoded}')

if 'DEVELOPMENT_TEAM = TPT6TVH8UY' in config or 'HOROS_DEVELOPMENT_TEAM = TPT6TVH8UY' in config:
    fail('the donor DEVELOPMENT_TEAM TPT6TVH8UY must not be copied into Config.xcconfig')
if 'DEVELOPMENT_TEAM = $(HOROS_DEVELOPMENT_TEAM)' not in config:
    fail('tracked DEVELOPMENT_TEAM must stay $(HOROS_DEVELOPMENT_TEAM)')
if '#include? "Config.local.xcconfig"' not in config:
    fail('Config.xcconfig must keep the untracked local include')

example = root / 'Config.local.xcconfig.example'
if not example.is_file():
    fail('Config.local.xcconfig.example is missing')
ignore = (root / '.gitignore').read_text()
if 'Config.local.xcconfig' not in ignore:
    fail('Config.local.xcconfig must remain gitignored')

plist = (root / 'Horos/Info.plist').read_text()
if '$(MACOSX_DEPLOYMENT_TARGET)' not in plist and '${MACOSX_DEPLOYMENT_TARGET}' not in plist:
    fail('Horos Info.plist LSMinimumSystemVersion must follow MACOSX_DEPLOYMENT_TARGET')
if re.search(r'<string>\d+\.\d+</string>\s*<!-- LSMinimumSystemVersion', plist):
    fail('Info.plist must not hard-code a minimum beside LSMinimumSystemVersion')

# AppController is Swift; what stayed in Objective-C is in +CAPI.m.
app = source_text('AppController') + source_text('AppController+CAPI')
if 'showsFullScreenButton' in app and 'jr_swizzleMethod' in app:
    fail('the private showsFullScreenButton swizzle must not return')

entitlements = (root / 'Horos/Horos.entitlements').read_text()
expected_keys = {'com.apple.security.automation.apple-events', 'com.apple.security.cs.disable-library-validation'}
if set(re.findall(r'<key>([^<]+)</key>', entitlements)) != expected_keys or entitlements.count('<key>') != 2:
    fail('Horos.entitlements must hold only Apple Events and the third-party plugin library exception')

readme = (root / 'README.md').read_text()
if 'macOS 26' not in readme:
    fail('README must state the product minimum macOS 26')
if 'SDK' not in readme:
    fail('README must distinguish the compile SDK from the product minimum')

if 'HorosPlatformPolicy.swift in Sources' not in (root / 'Horos.xcodeproj/project.pbxproj').read_text():
    fail('HorosPlatformPolicy.swift must be in the Horos target')

if failures:
    print('FAIL:')
    for item in failures:
        print(' ', item)
    raise SystemExit(1)

gap = sdk_major < PRODUCT_MINIMUM_MAJOR
print(f'PASS: encoded target {encoded} is legal for SDK {sdk}; '
      f'product minimum {PRODUCT_MINIMUM_MAJOR}.0 '
      f'{"is a toolchain gap" if gap else "is encoded"}')
