#!/usr/bin/env python3
"""The DICOM listeners' AE titles are stored on the main thread, never by the listener threads.

startSTORESCP: and startSTORESCPTLS: run on threads of their own. They used to
store AETITLE themselves: the host's name when "Use Host Name for AETitle" is
ticked, the title derived from the computer's name the first time, and a title
cut to 16 characters. The Listener preferences bind AETITLE, and a default
written on another thread notifies the bindings on that thread. With the pane
open, ticking "Use Host Name for AETitle" stopped the application (the
binding's enabled state asks PreferencesWindowController.isUnlocked(), which
is main-actor isolated), and a title of 20 characters left the listener
stopped on "Modifications to the layout engine must not be performed from a
background thread".

What must stay true:

- the listener threads read the defaults and write none;
- -restartSTORESCP, on the main thread, stores the titles before it detaches
  the threads that read them;
- the host's name becomes the title up to its first dot, at most 16
  characters, ISIX when there is none; a stored title longer than 16
  characters is cut to 16 without splitting a character; the title is written
  only when it changes, so a listener restarted with the same title notifies
  nothing.

AppController is Swift: its part is read in the Swift spelling.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []
controller = source_text('AppController')


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return ''


def check(condition, message):
    if not condition:
        failures.append(message)


writes = re.compile(r'\.set\(|setValue\(|removeObject\(forKey|setAETitleToHostname|storeListenerTitles')
for signature in ('@objc(startSTORESCP:) nonisolated public func startSTORESCP(',
                  '@objc(startSTORESCPTLS:) nonisolated public func startSTORESCPTLS('):
    thread = body(controller, signature)
    check(thread, f'{signature} not found')
    found = writes.findall(thread)
    check(not found, f'{signature.split(" func ")[1]}...) writes defaults on the listener thread: {found}')
    check('UserDefaults.standard.string(forKey: "' in thread, f'{signature} no longer reads its title from the defaults')

host = re.search(r'(@objc[^\n]*) func setAETitleToHostname\(\)', controller)
check(host is not None and 'nonisolated' not in host.group(1),
      'setAETitleToHostname is nonisolated: a listener thread could call it again')
hostname = body(controller, 'func setAETitleToHostname()')
check('ListenerAETitle.fromHostName(' in hostname, 'setAETitleToHostname does not take the title from ListenerAETitle')
check(re.search(r'if UserDefaults\.standard\.string\(forKey: "AETITLE"\) != title \{\s*UserDefaults\.standard\.set\(title, forKey: "AETITLE"\)', hostname),
      'setAETitleToHostname writes AETITLE even when it does not change')

store = body(controller, 'private func storeListenerTitles()')
check(store, 'storeListenerTitles not found')
check(re.search(r'if defaults\.bool\(forKey: "UseHostNameForAETitle"\) \{\s*setAETitleToHostname\(\)', store),
      'storeListenerTitles does not take the host name when asked to')
check('persistentDomain(forName:' in store and 'defaults.set(derived, forKey: "AETITLE")' in store,
      'storeListenerTitles no longer stores the derived title the first time')
check('for key in ["AETITLE", "TLSStoreSCPAETITLE"]' in store and 'ListenerAETitle.limited(title)' in store
      and 'limited != title' in store, 'storeListenerTitles does not cut both titles to 16 characters, only when they are longer')

restart = body(controller, '@objc public func restartSTORESCP()')
check(restart, 'restartSTORESCP not found')
stored = restart.find('storeListenerTitles()')
for selector in ('#selector(AppController.startSTORESCP(_:))', '#selector(AppController.startSTORESCPTLS(_:))'):
    detached = restart.find(selector)
    check(-1 < stored < detached, f'restartSTORESCP does not store the titles before it detaches {selector}')
check(restart.find('ProtectedMode.isActive') < stored, 'the titles are stored even in protected mode, where no listener starts')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
check('ListenerAETitle.swift in Sources' in project, 'ListenerAETitle.swift is not in the application target')

# The title rules, compiled and run.
if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)
cases = [
    ('host', 'Thaless-Mac-mini.local', 'Thaless-Mac-mini'),
    ('host', 'MacBook-Air-X', 'MacBook-Air-X'),
    ('host', 'a-very-long-host-name-indeed.example.org', 'a-very-long-host'),
    ('host', 'short.with-a-domain-longer-than-sixteen', 'short'),
    ('host', '', 'ISIX'),
    ('host', None, 'ISIX'),
    ('host', '.local', 'ISIX'),
    ('limit', None, None),
    ('limit', '', ''),
    ('limit', 'ISIX TEST', 'ISIX TEST'),
    ('limit', 'ABCDEFGHIJKLMNOP', 'ABCDEFGHIJKLMNOP'),
    ('limit', 'ABCDEFGHIJKLMNOPQ', 'ABCDEFGHIJKLMNOP'),
    ('limit', 'ABCDEFGHIJKLMNOPQRST', 'ABCDEFGHIJKLMNOP'),
    # A character of two UTF-16 units across the 16th unit is left out whole.
    ('limit', 'ABCDEFGHIJKLMNO\U0001F600Z', 'ABCDEFGHIJKLMNO'),
    ('limit', 'ABCDEFGHIJKLMN\U0001F600Z', 'ABCDEFGHIJKLMN\U0001F600'),
]
driver = '''
import Foundation
let cases = try! JSONSerialization.jsonObject(with: Data(CommandLine.arguments[1].utf8)) as! [[Any]]
var results: [Any] = []
for item in cases {
    let kind = item[0] as! String
    let input = item[1] as? String
    let output: String? = kind == "host" ? ListenerAETitle.fromHostName(input) : ListenerAETitle.limited(input)
    results.append(output ?? NSNull())
}
print(String(data: try! JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
'''
with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/ListenerAETitle.swift'), str(folder / 'main.swift'),
                            '-o', str(folder / 'check')], capture_output=True, text=True)
    check(build.returncode == 0, 'ListenerAETitle.swift and its driver compile\n' + build.stderr[-3000:])
    if build.returncode == 0:
        run = subprocess.run([str(folder / 'check'), json.dumps([[k, i] for k, i, _ in cases])], capture_output=True, text=True)
        check(run.returncode == 0, 'the driver runs\n' + run.stderr[-2000:])
        if run.returncode == 0:
            for (kind, given, expected), got in zip(cases, json.loads(run.stdout)):
                check(got == expected, f'{kind}({given!r}) = {got!r}, not {expected!r}')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the listener threads write no defaults; the main thread stores the titles before starting them')
