#!/usr/bin/env python3
"""The NSNotificationCenter (AllObservers) category stays gone; the plugin crash
guards stay declared and implemented (#766).

OsiriXNotificationCenter held an `NSNotificationCenter (AllObservers)` category
(`my_addObserver:selector:name:object:`, `my_removeObserver:name:object:`,
`my_postNotificationName:object:userInfo:`, `my_postNotification:`,
`my_observersForNotificationName:` and `postExtraNotification:`) meant to be
exchanged with NSNotificationCenter's own methods. The exchange in its +load
had been commented out since the original sources, and the Swift translation
of #716 dropped the +load: nothing ever installed or called it. The class is
removed.

The same issue said `+[PluginManager startProtectForCrashWithFilter:]`,
`startProtectForCrashWithPath:` and `endProtectForCrash` did not exist. They
do: PluginManager.h publishes them to plugins and PluginManager.swift writes
and removes the crash marker the plugin quarantine reads at the next launch.
DCMPix, DicomFile, ViewerController, DicomDatabase and BrowserController wrap
plugin calls in them, so those calls are kept.

Checked:

1. no source of the application, its frameworks, preference panes, plugins or
   API names the category or its selectors, no file is named
   OsiriXNotificationCenter, and Horos.xcodeproj does not list one;
2. PluginManager.h declares the three crash guard selectors, PluginManager.swift
   implements each under that @objc name, and every selector of that family
   sent anywhere in the sources is one of them;
3. Changelog.md, under Unreleased, records the removal of the category, which
   the generated Horos-Swift.h had published since #716.

`<git revision>` as an optional argument reads the sources from that revision.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []

FOLDERS = ('Horos/Sources', 'Nitrogen/Sources', 'DCM Framework', 'DICOMPrint', 'Preference Panes',
           'Plugins', 'API', 'Horos/Scripts')
EXTENSIONS = ('.swift', '.m', '.mm', '.h', '.c', '.cpp', '.pl', '.py', '.sh')


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', '%s:%s' % (revision, path)])
    else:
        data = (root / path).read_bytes()
    return data.decode('latin1')


def tracked():
    command = ['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision] if revision else \
        ['git', '-C', str(root), 'ls-files']
    return subprocess.check_output(command, text=True).splitlines()


def uncommented(text):
    text = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n') or ' ', text, flags=re.S)
    return re.sub(r'(?m)(^|[^:"])//.*$', r'\1', text)


files = [f for f in tracked() if f.startswith(tuple(folder + '/' for folder in FOLDERS))]
if revision is None:
    files = [f for f in files if (root / f).is_file()]
sources = {f: read(f) for f in files if f.endswith(EXTENSIONS)}
if not any(f.endswith('PluginManager.swift') for f in sources):
    print('FAIL: no PluginManager.swift among the sources; this test is stale')
    sys.exit(1)

# ------------------------------------------------------------ 1. category gone
CATEGORY = re.compile(r'\b(?:my_addObserver|my_removeObserver|my_postNotificationName|my_postNotification|'
                      r'my_observersForNotificationName|postExtraNotification)\b|\(\s*AllObservers\s*\)')
named = [f for f in files if Path(f).stem == 'OsiriXNotificationCenter']
if named:
    failures.append('OsiriXNotificationCenter is still in the tree: ' + ', '.join(named))
for path, text in sorted(sources.items()):
    for match in CATEGORY.finditer(text):
        line = text.count('\n', 0, match.start()) + 1
        failures.append('%s:%d names the notification center category (%s)' % (path, line, match.group(0)))
if 'OsiriXNotificationCenter' in read('Horos.xcodeproj/project.pbxproj'):
    failures.append('Horos.xcodeproj still lists OsiriXNotificationCenter')

# -------------------------------------------------------- 2. crash guards live
GUARDS = ('startProtectForCrashWithFilter:', 'startProtectForCrashWithPath:', 'endProtectForCrash')
header = uncommented(read('Horos/Sources/PluginManager.h'))
interface = re.search(r'@interface\s+PluginManager\b(.*?)@end', header, re.S)
declared = set()
if interface:
    for signature in re.findall(r'^\s*\+\s*\([^)]*\)\s*([^;]+);', interface.group(1), re.M):
        parts = re.findall(r'(\w+)\s*:', signature)
        declared.add(''.join(p + ':' for p in parts) if parts else signature.split()[0])
swift = uncommented(next(text for f, text in sources.items() if f.endswith('Horos/Sources/PluginManager.swift')))
for selector in GUARDS:
    if selector not in declared:
        failures.append('PluginManager.h does not declare +%s' % selector)
    if selector.endswith(':'):
        implemented = re.search(r'@objc\(%s\)\s*(?:public\s+)?class\s+func\b' % re.escape(selector), swift)
    else:
        implemented = re.search(r'@objc\s+(?:public\s+)?class\s+func\s+%s\s*\(\s*\)' % selector, swift)
    if not implemented:
        failures.append('PluginManager.swift does not implement +%s under that name' % selector)

SENT = re.compile(r'\b((?:start|end)ProtectForCrash\w*)')
senders = 0
for path, text in sorted(sources.items()):
    for match in SENT.finditer(uncommented(text)):
        word = match.group(1)
        known = any(word == g.rstrip(':') for g in GUARDS) or word in ('startProtectForCrash', 'endProtectForCrash')
        if not known:
            failures.append('%s sends %s, which PluginManager does not implement' % (path, word))
        senders += 1
if senders == 0:
    failures.append('no source sends the crash guards; this test is stale')

# ------------------------------------------------------------- 3. Changelog
changelog = read('Changelog.md')
unreleased = re.search(r'^## Unreleased\n(.*?)(?=^## )', changelog, re.S | re.M)
removed = re.search(r'^### Removed\n(.*?)(?=^##|\Z)', unreleased.group(1), re.S | re.M) if unreleased else None
if not removed or 'postExtraNotification:' not in removed.group(1):
    failures.append('Changelog.md does not record the removal of NSNotificationCenter (AllObservers) '
                    'under Unreleased / Removed')

label = revision or 'working tree'
if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: %s has no NSNotificationCenter (AllObservers); PluginManager declares and implements the '
      '%d crash guards, sent %d times in %d sources' % (label, len(GUARDS), senders, len(sources)))
