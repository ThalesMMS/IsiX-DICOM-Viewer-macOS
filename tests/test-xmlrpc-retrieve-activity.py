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

The interface is Swift (XMLRPCInterface.swift and its extensions); PACS
On-Demand's retrieve starts in one place, retrieveOnDemand, which DisplayStudy
and FindObject both call.

In the app, tools/exercise-native-thread-progress.py --scenario xmlrpc-retrieve
asks for a C-GET by XML-RPC and records the "Retrieving images..." thread.
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import class_text  # noqa: E402

source = class_text('XMLRPCInterface')
code = '\n'.join(line.split('//')[0] for line in source.split('\n'))
failures = []


def body(signature):
    """The body of the Swift function that starts with `signature`."""
    at = code.find(signature)
    if at < 0:
        return ''
    depth, index, opened = 0, at, False
    while index < len(code):
        if code[index] == '{':
            depth, opened = depth + 1, True
        elif code[index] == '}':
            depth -= 1
            if opened and depth == 0:
                return code[at:index + 1]
        index += 1
    return ''


for selector, function in (('_PACSOnDemandRetrieve:', 'pacsOnDemandRetrieve'), ('_threadRetrieve:', 'threadRetrieve')):
    if f'@objc({selector})' not in code:
        failures.append(f'{selector} is no longer the selector of {function}')
    if re.search(r'detachNewThread(Selector)?\([^\n]*%s' % function, code):
        failures.append(f'{selector} still runs on a detached thread')
    started = len(re.findall(r'startRetrieveThread\(\s*#selector\(\s*(self\.)?%s\(_:\)\s*\)' % function, code))
    if started != 1:
        failures.append(f'{selector} is started {started} times through startRetrieveThread, not 1')

# PACS On-Demand: both DisplayStudy and FindObject go through the one start.
on_demand = body('private func retrieveOnDemand(')
if 'startRetrieveThread(#selector(pacsOnDemandRetrieve(_:))' not in on_demand:
    failures.append('PACS On-Demand does not start its retrieve through startRetrieveThread')
for function in ('private func findStudies(', 'private func findObjects('):
    if 'retrieveOnDemand(' not in body(function):
        failures.append(f'{function} no longer retrieves on demand through retrieveOnDemand')
# Retrieve and CMove: both answer through the one query that starts the thread.
for function in ('public func retrieve(_ paramDict', 'public func cMove('):
    if 'retrieve(from: source, filters: filters' not in body(function):
        failures.append(f'{function} no longer goes through retrieve(from:filters:retrieveMode:)')

helper = body('func startRetrieveThread(')
if not helper:
    failures.append('startRetrieveThread(_:with:count:) is missing')
else:
    for needed in ('Thread(target: self, selector: selector, object: object)',
                   'thread.name = NSLocalizedString("Retrieving images...", comment: "")',
                   'thread.supportsCancel = true', 'ThreadsManager.default()?.addThreadAndStart(thread)'):
        if needed not in helper:
            failures.append(f'the helper does not do: {needed}')

loop = body('func threadRetrieve(')
if not loop or 'Thread.current.isCancelled' not in loop:
    failures.append('_threadRetrieve: does not stop when the Activity row is cancelled')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: Retrieve, CMove, DisplayStudy and FindObject retrieves run on ThreadsManager threads, named and cancellable')
