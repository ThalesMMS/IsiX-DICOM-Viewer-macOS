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
  hold while they run, and only then are the listeners started again (quitting
  awaits the same stop, with a deadline);
- a stop asked for while a listener is still setting up its network is kept.

The life cycle is DICOMListenerController's, the settings are IsiXDICOMNetwork's
ListenerSettings and the preferences check is AppController's; all are read in
the Swift spelling, with DCMTKQueryRetrieveSCP.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []
controller = source_text('DICOMListenerController')
settings = source_text('ListenerSettings')
scp = (root / 'Horos/Sources/DCMTKQueryRetrieveSCP.swift').read_text()


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


# The settings the listeners are restarted for: each key ListenerSettings reads,
# through the catalog of IsiXPreferences or its own ListenerPreferences.
catalog = source_text('NetworkPreferences') + settings
read = body(settings, 'public init(preferences: any PreferenceStore)')
names = {}
for constant, name in re.findall(r'static let (\w+) = PreferenceKey<[^>]+>\("([^"]+)"', catalog):
    names.setdefault(constant, name)
listed = {names[constant] for constant in re.findall(r'(?:NetworkPreferences|ListenerPreferences)\.(\w+)\]', read)
          if constant in names}
for key in ('STORESCP', 'STORESCPTLS', 'AETITLE', 'AEPORT', 'TLSStoreSCPAEPORT', 'DICOMTimeout',
            'preferredSyntaxForIncoming'):
    check(key in listed, f'{key} is not among the settings the listeners are restarted for')

update = body(source_text('PreferenceChangeResponder'), 'private func respond(to change: PreferenceChange')
check(update, 'the answer to a change of the preferences is not found')
check('listener.applySettingsIfChanged()' in update,
      'the preferences check does not apply changed listener settings')
changed = body(controller, 'func applySettingsIfChanged()')
check('ListenerSettings(preferences: preferences) != appliedSettings' in changed and 'applySettings()' in changed,
      'changed listener settings are not compared with those the listeners run with')
# What still marks listenerRestart asks the user to restart the application.
restart = body(source_text('PreferenceChange'), 'static var listenerKeys: [PreferenceKey<Int>]')
check(restart, 'the keys that ask for a restart are not found')
for constant in re.findall(r'NetworkPreferences\.(\w+)', restart):
    check(names.get(constant) not in listed, f'{names.get(constant)} still asks for a restart of the application')

apply = body(controller, 'private func applySettings()')
check(apply, 'applySettings not found')
check('Self.startThread(named:' in apply, 'the listeners are not stopped on a thread of their own')
stop = apply[:apply.find('onMainRunLoop')] if 'onMainRunLoop' in apply else ''
check('stopListeners(before: .distantFuture)' in stop,
      'the listeners are not stopped, and awaited without a deadline, before they start again')
stopping = body(controller, 'func stopListeners(before deadline: Date)')
check(stopping, 'stopListeners(before:) not found')
check('(STORESCP, {' in stopping and '(STORESCPTLS, {' in stopping and 'lock?.lock(before:' in stopping
      and 'lock?.unlock()' in stopping,
      'the stop is not awaited on the locks the listener threads hold')
check('pendingStarts' in stopping, 'a listener thread not yet holding its lock is not waited for')
check('.abort()' in stopping, 'the running listeners are not asked to stop')
check('restart()' in apply[len(stop):], 'the listeners are not started again once stopped')
check('applyingSettings' in apply and 'settingsChangedMeanwhile' in apply,
      'a change made while the listeners stop is not applied afterwards')
check('let thread = Thread(block: body)' in body(controller, 'private nonisolated static func startThread('),
      'a listener does not run on a thread of its own')

start = body(controller, 'private func start(tls: Bool, settings: ListenerSettings)')
check(start.count('pendingStarts += 1') == 1 and start.find('pendingStarts += 1') < start.find('Self.startThread('),
      'each listener thread is not counted as starting before it is started')
check(body(controller, 'func restart()').count('start(tls:') == 2, 'restart does not start both listeners')
check('pendingStarts -= 1' in body(controller, 'private nonisolated func serve(tls: Bool, settings: ListenerSettings)'),
      'a listener thread does not end its start')

run = body(scp, '@objc func run()')
check(run, '-[DCMTKQueryRetrieveSCP run] not found')
check(not re.search(r'aborted\s*=\s*false', run),
      '-run clears a stop asked for while it was setting up the network')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print('ok: listener settings are applied while the application runs')
