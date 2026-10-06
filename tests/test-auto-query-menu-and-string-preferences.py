#!/usr/bin/env python3
"""Two small checks of AppController that could not do what they said.

`-validateMenuItem:` enables "Auto Query / Retrieve Refresh" only while there is
an auto query window. The test sat inside the branch for the fixed tiling
items, whose condition admits only `setFixedTilingRows:` and
`setFixedTilingColumns:`, so it never ran and the item fell through to the
final `return true`. It is now a branch of its own.

`-runPreferencesUpdateCheck:` compares each string preference with its
previous value, and logged "*** isKindOfClass NSString" whenever the previous
value was not a string, including when there was none, as for a key seen for
the first time. Only a value of another type is logged now.

Both need the menus and defaults of a running app, so the source is read.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

application = sources.source_text('AppController')
failures = []


def method(signature):
    start = application.find(signature)
    if start < 0:
        sys.exit('FAIL: %s is gone from AppController.swift' % signature)
    return application[start:application.index('\n    }\n', start)]


def block(text, opening):
    """The text between the brace at `opening` and the brace that closes it."""
    depth = 0
    for i in range(opening, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[opening + 1:i]
    return text[opening + 1:]


# 1. The refresh item is validated where its action can arrive.
validate = method('@objc(validateMenuItem:) public func validateMenuItem(_ item: NSMenuItem!) -> Bool {')
tiling = re.search(r'if item\?\.action == #selector\(AppController\.setFixedTilingRows\(_:\)\) \|\| '
                   r'item\?\.action == #selector\(AppController\.setFixedTilingColumns\(_:\)\) \{', validate)
if not tiling:
    failures.append('the branch of the fixed tiling items is no longer where the test looks')
else:
    admitted = {'setFixedTilingRows', 'setFixedTilingColumns'}
    inner = block(validate, tiling.end() - 1)
    for name in re.findall(r'item\?\.action == #selector\(AppController\.(\w+)\(', inner):
        if name not in admitted:
            failures.append('the tiling branch tests %s:, which its condition never lets in' % name)

refresh = re.search(r'if item\?\.action == #selector\(AppController\.autoQueryRefresh\(_:\)\) \{', validate)
if not refresh:
    failures.append('-validateMenuItem: no longer looks at autoQueryRefresh:')
else:
    body = block(validate, refresh.end() - 1)
    if not re.search(r'if QueryController\.currentAuto\(\) != nil \{\s*return true\s*\} else \{\s*return false\s*\}', body):
        failures.append('the refresh item does not follow the auto query window')
    # It must be a branch of the outer chain, reachable before the final return.
    line = validate[validate.rfind('\n', 0, refresh.start()) + 1:refresh.start()]
    if line.strip() not in ('', '} else'):
        failures.append('the refresh test is not a branch of its own')
    if refresh.start() > (tiling.start() if tiling else len(validate)):
        failures.append('the refresh test comes after the tiling branch')

# 2. A missing previous value is not reported as a value of the wrong type.
check = method('@objc(runPreferencesUpdateCheck:) public func runPreferencesUpdateCheck(_ timer: Timer!) {')
string_keys = re.findall(r'if let previous = previousDefaults\?\.value\(forKey: ("[^"]+")\) as\? NSString \{', check)
logs = re.findall(r'else(.*)\{ NSLog\("\*\*\* isKindOfClass NSString"\) \}', check)
if len(string_keys) < 6:
    failures.append('only %d string preferences are compared' % len(string_keys))
if len(logs) != len(string_keys):
    failures.append('%d string preferences, %d logs' % (len(string_keys), len(logs)))
for key, guard in zip(string_keys, logs):
    if guard.strip() != 'if previousDefaults?.value(forKey: %s) != nil' % key:
        failures.append('%s logs "isKindOfClass NSString" when it had no previous value' % key)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the refresh item follows the auto query window, and only a wrong type is logged')
