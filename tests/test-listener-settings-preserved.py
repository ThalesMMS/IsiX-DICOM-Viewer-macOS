#!/usr/bin/env python3
"""The DICOM listener keeps the AE title and port it was configured with.

Explicit settings survive, because `DefaultsOsiriX` supplies its dictionary to
-registerDefaults:, which never touches the user's own values. What did move was
the value nobody had set: `AETITLE`'s registered default is computed from the
computer's name at every launch, so renaming the Mac renamed the listener, and
the remote nodes configured with the old title could no longer send to it -
with nothing said anywhere.

It is now stored the first time the listener starts, and only then.
AppController is Swift since #830: its part is read in the Swift spelling.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []
controller = source_text('AppController')
defaults = (root / 'Horos/Sources/DefaultsOsiriX.m').read_bytes().decode('latin1')


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth, index = 0, opening
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
        index += 1
    return ''


start = body(controller, 'public func startSTORESCP(_ sender: Any!)')
if not start:
    failures.append('-startSTORESCP: is gone')
else:
    # Stored only when the user domain has none - reading with string(forKey:)
    # would see the registered default and never store anything.
    if 'persistentDomain(forName:' not in start:
        failures.append('the AE title is stored without asking whether the user set one')
    if not re.search(r'persistentDomain\(forName:.*\)\?\["AETITLE"\] == nil', start):
        failures.append('the check is not "the user domain has no AETITLE"')
    if 'UserDefaults.standard.set(derived, forKey: "AETITLE")' not in start:
        failures.append('the derived AE title is not stored')
    # And the explicit opt-in still wins: it runs first and writes its own value.
    hostname = start.find('setAETitleToHostname')
    stored = start.find('persistentDomain(forName:')
    if hostname < 0 or stored < 0 or hostname > stored:
        failures.append('UseHostNameForAETitle no longer takes precedence')
    # The user is told, once, what the listener will answer to.
    if 'listener AE title was not stored' not in start:
        failures.append('storing the AE title is not reported')

# The defaults are registered, so nothing in them overwrites a configured value.
if 'UserDefaults.standard.register(defaults: (DefaultsOsiriX.getDefaults()' not in controller:
    failures.append('the defaults are no longer registered; they may overwrite user values')
if re.search(r'UserDefaults\.standard\.set(Value)?\([^\n]*forKey:\s*"AEPORT"\)',
             controller):
    failures.append('the listener port is written at launch')

# The registered default is still derived from the host name only when absent,
# which is the mechanism this defends against.
window = defaults[defaults.find('// ** AETITLE'):]
window = window[:window.find('AEPORT') + 40]
if 'objectForKey:@"AETITLE"] == nil' not in window:
    failures.append('the AETITLE default is no longer conditional')
if 'gethostname' not in window:
    failures.append('the AETITLE default no longer comes from the computer name')
# Without a computer name the default is ISIX, the application's own title, in
# the registered defaults and where the listener re-derives it; the example
# node carries it too. A stored title is never compared with it, so a stored
# ISIS from an earlier installation stays ISIS.
if '[defaultValues setObject:@"ISIX" forKey:@"AETITLE"];' not in window:
    failures.append('the AETITLE fallback of the registered defaults is not ISIX')
if 'c = "ISIX"' not in controller:
    failures.append('the AETITLE fallback of setAETitleToHostname is not ISIX')
if '[aServer setObject:@"ISIX" forKey: @"AETitle"];' not in defaults:
    failures.append('the example node does not use the ISIX title')
for source, text in (('AppController.swift', controller), ('DefaultsOsiriX.m', defaults)):
    if re.search(r'"ISIS"', text):
        failures.append('%s still names the ISIS title' % source)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a configured AE title and port are left alone, and one that was never configured is '
      'stored the first time the listener starts so it stops following the computer name')
