#!/usr/bin/env python3
"""The Listener preferences open the Network and Sharing panes of System Settings by their addresses.

The two buttons used to send a script to System Settings, which a sandbox
refuses, and dropped the error: nothing happened and nothing was said. An
address of the scheme System Settings registers is opened through the
workspace instead, which sends no Apple Event, and a failure to open it is
told to the user.

1. The pane has no script left; each button opens the address of its pane,
   and when the workspace does not open it an alert says where the pane is.
2. Every catalog has the two texts of that alert.
3. On this Mac, read without opening anything: System Settings registers the
   scheme, the workspace finds an application for each address, and each
   identifier is that of a settings extension the system has, which accepts
   addresses of the scheme. The extensions are not looked for where the system
   keeps none.
"""
from pathlib import Path
import json
import plistlib
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

SCHEME = 'x-apple.systempreferences'
PANES = {'editAddresses': ('com.apple.Network-Settings.extension', 'Network.appex'),
         'editHostname': ('com.apple.Sharing-Settings.extension', 'Sharing.appex')}
TEXTS = ['System Settings could not be opened.',
         'To change the network addresses or the name of this Mac, open System Settings and choose Network or General > Sharing.']

# --- 1. the pane --------------------------------------------------------------
pane = source_text('OSIListenerPreferencePanePref')
assert 'NSAppleScript' not in pane and 'tell application' not in pane and 'System Preferences' not in pane
for action, (identifier, _) in PANES.items():
    assert ('    @IBAction public func %s(_ sender: Any?) {\n        openSystemSettings(pane: "%s")\n    }\n' % (action, identifier)) in pane, action
opener = pane[pane.index('    private func openSystemSettings(pane: String) {'):pane.index('    @IBAction public func editAddresses')]
assert 'if let url = URL(string: "%s:" + pane), NSWorkspace.shared.open(url) { return }\n' % SCHEME in opener
# What follows the return runs only when the address was not opened.
failure = opener[opener.index('{ return }\n'):]
for text in TEXTS:
    assert 'NSLocalizedString(%s, comment: "")' % json.dumps(text) in failure, text
assert 'alert.runModal()' in failure

# --- 2. the catalogs ----------------------------------------------------------
catalogs = sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings'))
assert len(catalogs) == 12, catalogs
for catalog in catalogs:
    language = catalog.parent.name[:-len('.lproj')]
    if language == 'en':
        continue
    entries = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(catalog)]))
    for text in TEXTS:
        value = entries.get(text)
        assert value and value != text, '%s: no translation of %r' % (language, text)
        assert '%' not in value, (language, value)

# --- 3. this Mac --------------------------------------------------------------
settings = Path('/System/Applications/System Settings.app')
info = plistlib.loads((settings / 'Contents/Info.plist').read_bytes())
schemes = [scheme for kind in info.get('CFBundleURLTypes', []) for scheme in kind.get('CFBundleURLSchemes', [])]
assert SCHEME in schemes, schemes

PROBE = r'''import AppKit
for address in CommandLine.arguments.dropFirst() {
    // Asks which application would open the address, and opens nothing.
    print(URL(string: address).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }?.path ?? "none")
}
'''
addresses = ['%s:%s' % (SCHEME, identifier) for identifier, _ in PANES.values()]
with tempfile.TemporaryDirectory(prefix='horos-settings-panes-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(PROBE)
    subprocess.run(['xcrun', 'swiftc', str(folder / 'main.swift'), '-o', str(folder / 'probe')], check=True)
    openers = subprocess.check_output([str(folder / 'probe'), *addresses], text=True).split('\n')[:-1]
assert openers == [str(settings)] * len(addresses), openers

extensions = Path('/System/Library/ExtensionKit/Extensions')
checked = 'not looked for: this system keeps none in %s' % extensions
if extensions.is_dir():
    for identifier, bundle in PANES.values():
        about = plistlib.loads((extensions / bundle / 'Contents/Info.plist').read_bytes())
        assert about['CFBundleIdentifier'] == identifier, (bundle, about['CFBundleIdentifier'])
        attributes = about['EXAppExtensionAttributes']
        assert attributes['EXExtensionPointIdentifier'] == 'com.apple.Settings.extension.ui', bundle
        # Absent on a system that takes every extension's address; never false.
        assert attributes.get('SettingsExtensionAttributes', {}).get('allowsXAppleSystemPreferencesURLScheme', True) is True, bundle
    checked = 'those of %s' % ' and '.join(bundle for _, bundle in PANES.values())
version = subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip()
assert re.fullmatch(r'\d+(\.\d+)*', version), version
print('PASS: the Listener pane opens %s by address and tells a failure; on macOS %s System Settings takes the scheme, '
      'and the settings extensions are %s' % (' and '.join(identifier for identifier, _ in PANES.values()), version, checked))
