#!/usr/bin/env python3
"""A medium that was not written must not sound and look like one that was.

createDMG only logged when the *task* failed to finish, and HorosRunTaskUntilExit
answers YES for a task that finishes whatever its exit status - so hdiutil
reporting a full destination was ignored, and the window played the success sound
and closed with no disc image anywhere. The USB path was worse: it erases the
volume first and then discarded the copy error.

BurnerWindowController is Swift: its source is read through
tests/sources.py, and the checks are those of the Objective-C in Swift spelling.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

source = source_text('BurnerWindowController')
failures = []

if not re.search(r'@objc\(createDMG:withSource:\)\s+(?:public )?func createDMG\([^)]*\) -> Bool', source):
    failures.append('createDMG no longer reports whether it worked')
if 'makeImageTask.terminationStatus != 0' not in source:
    failures.append("the disc image task's exit status is ignored again")
# The former header declared -(BOOL)saveOnVolume: the Swift class exports it with that selector.
if not re.search(r'@objc\(saveOnVolume\)\s+public func saveOnVolume\(\) -> Bool', source):
    failures.append('saveOnVolume no longer reports whether it worked')
if 'byReplacingExisting: true, error: &copyError' not in source:
    failures.append('the copy to the volume discards its error again')

# The success sound and the close must be behind the failure check.
start = re.search(r'self\.buttonsDisabled = false\n\s*self\.runBurnAnimation = false\n\s*self\.burning = false\n\n\s*if self\.failed',
                  source)
tail = source[start.start():start.start() + 1800] if start else ''
if 'if self.failed {' not in tail:
    failures.append('the end of a burn no longer distinguishes a failure')
elif 'Glass.aiff' not in tail or tail.index('if self.failed {') > tail.index('Glass.aiff'):
    failures.append('the success sound plays before the failure is considered')
if 'The medium was not created' not in tail:
    failures.append('a failed burn no longer says so')

# Every diskutil wait has a deadline; the three unbounded polls are gone.
volume = source[source.index('public func saveOnVolume()'):source.index('public func burnCD(')]
if re.search(r'while\s*\(?\s*!?\s*[\w.]+\.isRunning\b', volume):
    failures.append('a diskutil task is polled with no deadline again')
if 'HorosRunTaskUntilExit(rename, 120' not in source:
    failures.append('renaming the volume is no longer bounded')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('PASS: both destinations report a failure, the success sound is behind that check, '
      'and no diskutil wait is unbounded')
