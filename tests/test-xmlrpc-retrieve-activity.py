#!/usr/bin/env python3
"""Retrieves asked for from outside run on threads the Activity panel lists.

A RIS asks IsiX for a study by a horos:// link, XML-RPC or AppleScript:
`Retrieve`, `CMove`, `DisplayStudy` and `FindObject` with PACS On-Demand. Those
retrieves ran on threads started with detachNewThreadSelector, which never
reach ThreadsManager, and the Activity panel and the Dock progress list only
ThreadsManager's threads: the study downloaded with no row and no Dock
progress. They now start through one helper that names the thread, gives it a
count and a Stop button, and hands it to ThreadsManager, as the Query window
does.

In the app, tools/exercise-native-thread-progress.py --scenario xmlrpc-retrieve
asks for a C-GET by XML-RPC and records the "Retrieving images..." thread.
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/XMLRPCMethods.mm').read_text(encoding='utf-8')
code = '\n'.join(line.split('//')[0] for line in source.split('\n'))
failures = []

for selector in ('_PACSOnDemandRetrieve:', '_threadRetrieve:'):
    if re.search(r'detachNewThreadSelector:\s*@selector\(\s*%s\s*\)' % re.escape(selector), code):
        failures.append(f'{selector} still runs on a detached thread')
    started = len(re.findall(r'_startRetrieveThread:\s*@selector\(\s*%s\s*\)' % re.escape(selector), code))
    expected = 2 if selector == '_PACSOnDemandRetrieve:' else 1
    if started != expected:
        failures.append(f'{selector} is started {started} times through _startRetrieveThread:, not {expected}')

helper = re.search(r'- \(void\) _startRetrieveThread:.*?\n\}', code, re.S)
if not helper:
    failures.append('_startRetrieveThread:withObject:count: is missing')
else:
    body = helper.group(0)
    for needed in ('initWithTarget:self selector:selector object:object', 't.name = NSLocalizedString(@"Retrieving images...", nil)',
                   't.supportsCancel = YES', '[[ThreadsManager defaultManager] addThreadAndStart:t]'):
        if needed not in body:
            failures.append(f'the helper does not do: {needed}')

loop = re.search(r'-\(void\)_threadRetrieve:.*?\n\}', code, re.S)
if not loop or 'NSThread.currentThread.isCancelled' not in loop.group(0):
    failures.append('_threadRetrieve: does not stop when the Activity row is cancelled')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: Retrieve, CMove, DisplayStudy and FindObject retrieves run on ThreadsManager threads, named and cancellable')
