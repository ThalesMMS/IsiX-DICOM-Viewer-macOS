#!/usr/bin/env python3
"""The DICOM listener keeps the AE title and port it was configured with.

Explicit settings survive, because `DefaultsOsiriX` supplies its dictionary to
-registerDefaults:, which never touches the user's own values. What did move was
the value nobody had set: `AETITLE`'s registered default is computed from the
computer's name at every launch, so renaming the Mac renamed the listener, and
the remote nodes configured with the old title could no longer send to it -
with nothing said anywhere.

It is now stored the first time the listeners are started, and only then, on
the main thread before their threads start (storeListenerTitles).
AppController is Swift: its part is read in the Swift spelling.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []
controller = source_text('AppController')
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
defaults = default_preferences.source()


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


start = body(controller, 'private func storeListenerTitles()')
title_rules = (root / 'Horos/Sources/ListenerAETitle.swift').read_text()
if not start:
    failures.append('storeListenerTitles is gone')
else:
    # Stored only when the user domain has none - reading with string(forKey:)
    # would see the registered default and never store anything.
    if 'persistentDomain(forName:' not in start:
        failures.append('the AE title is stored without asking whether the user set one')
    if not re.search(r'persistentDomain\(forName:.*\)\?\["AETITLE"\] == nil', start):
        failures.append('the check is not "the user domain has no AETITLE"')
    if 'defaults.set(derived, forKey: "AETITLE")' not in start:
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
if 'UserDefaults.standard.register(defaults: (DefaultPreferences.applicationDefaults()' not in controller:
    failures.append('the defaults are no longer registered; they may overwrite user values')
if re.search(r'UserDefaults\.standard\.set(Value)?\([^\n]*forKey:\s*"AEPORT"\)',
             controller):
    failures.append('the listener port is written at launch')

# The registered default is still derived from the host name only when absent,
# which is the mechanism this defends against.
window = defaults[defaults.find('// ** AETITLE'):]
window = window[:window.find('AEPORT') + 40]
if 'if values["AETITLE"] == nil {' not in window:
    failures.append('the AETITLE default is no longer conditional')
if 'hostName()' not in window or 'gethostname' not in defaults:
    failures.append('the AETITLE default no longer comes from the computer name')
# Without a computer name the default is ISIX, the application's own title, in
# the registered defaults and where the listener re-derives it; the example
# node carries it too. A stored title is never compared with it, so a stored
# ISIS from an earlier installation stays ISIS.
if default_preferences.registered(viewer=False).get('AETITLE') != 'ISIX':
    failures.append('the AETITLE fallback of the registered defaults is not ISIX')
if 'static let fallback = "ISIX"' not in title_rules:
    failures.append('the AETITLE fallback of setAETitleToHostname is not ISIX')
if default_preferences.registered()['SERVERS'][0].get('AETitle') != 'ISIX':
    failures.append('the example node does not use the ISIX title')
for source, text in (('AppController.swift', controller), ('IsiXPreferences', defaults),
                     ('ListenerAETitle.swift', title_rules)):
    if re.search(r'"ISIS"', text):
        failures.append('%s still names the ISIS title' % source)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a configured AE title and port are left alone, and one that was never configured is '
      'stored the first time the listener starts so it stops following the computer name')
