#!/usr/bin/env python3
"""The DICOM listener takes its settings while the application runs.

Ticking or unticking the listener in Settings stored the value and showed, once
per session, "Restart IsiX DICOM Viewer to apply these changes": the listener
went on, or stayed off, until the next launch.

The preferences check now compares the listener's own settings with those the
running listeners were started with, and stops and starts them when they
differ. What it must keep true:

- the listener's keys no longer ask for a restart of the application;
- the stop is awaited on a thread of its own, on the locks the listener threads
  hold while they run, and only then are the listeners started again;
- a stop asked for while a listener is still setting up its network is kept.

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
scp = (root / 'Horos/Sources/DCMTKQueryRetrieveSCP.mm').read_bytes().decode('latin1')


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


keys = re.search(r'listenerSettingKeys = \[(.*?)\]', controller, re.S)
listed = set(re.findall(r'"([^"]+)"', keys.group(1))) if keys else set()
for key in ('STORESCP', 'STORESCPTLS', 'AETITLE', 'AEPORT', 'TLSStoreSCPAEPORT', 'DICOMTimeout',
            'preferredSyntaxForIncoming'):
    check(key in listed, f'{key} is not among the settings the listeners are restarted for')

update = body(controller, 'func runPreferencesUpdateCheck(')
check(update, 'runPreferencesUpdateCheck not found')
check('listenerSettings().isEqual(appliedListenerSettings) == false' in update and 'applyListenerSettings()' in update,
      'the preferences check does not apply changed listener settings')
# What still sets restartListener asks the user to restart the application.
for key in sorted(listed):
    asks = re.search(r'forKey: "%s"\)[^\n]*\{\s*restartListener = true' % re.escape(key), update)
    check(not asks, f'{key} still asks for a restart of the application')

apply = body(controller, 'func applyListenerSettings(')
check(apply, 'applyListenerSettings not found')
check('Thread.detachNewThread' in apply, 'the listeners are not stopped on a thread of their own')
stop = apply[:apply.find('DispatchQueue.main.async')] if 'DispatchQueue.main.async' in apply else ''
check('STORESCP?.lock(before:' in stop and 'STORESCPTLS?.lock(before:' in stop,
      'the stop is not awaited on the locks the listener threads hold')
check('pendingListenerStarts' in stop, 'a listener thread not yet holding its lock is not waited for')
check('.abort()' in stop, 'the running listeners are not asked to stop')
check('restartSTORESCP()' in apply[len(stop):], 'the listeners are not started again once stopped')
check('applyingListenerSettings' in apply and 'listenerSettingsChangedMeanwhile' in apply,
      'a change made while the listeners stop is not applied afterwards')

restart = body(controller, 'func restartSTORESCP(')
check(restart.count('pendingListenerStarts += 1') == 2, 'each detached listener thread is not counted as starting')
for signature in ('func startSTORESCP(', 'func startSTORESCPTLS('):
    check('pendingListenerStarts -= 1' in body(controller, signature), f'{signature} does not end its start')

run = body(scp, '- (void)run')
check(run, '-[DCMTKQueryRetrieveSCP run] not found')
check(not re.search(r'^\s*_abort\s*=\s*NO\s*;', run, re.M),
      '-run clears a stop asked for while it was setting up the network')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print('ok: listener settings are applied while the application runs')
