#!/usr/bin/env python3
"""Mounting a DICOM disc asks what to do with it instead of hanging.

With the factory setting (MOUNT -1, ask), a disc scan holds the queue of its
private-queue database while it waits for the main thread to show "Copy,
Browse or Ignore". Before it asks, indexing the disc posts the independent
database's notifications, which the main database bounces to the main thread.
There, reading the IDs of the notified objects entered the scan's queue: the
main thread waited for the scan, the scan waited for the main thread, and the
application hung on every DICOM disc, with no dialog and nothing imported.

The IDs are read on the posting thread, where the queue is the scan's own, and
the main thread receives IDs. And the scan no longer holds its queue while it
asks: nothing that waits for the main thread runs on a context's queue, in the
scan or in the copy it starts. What must stay true:

- the bounce to the main thread hands over the notification with its objects
  replaced by their IDs;
- the IDs are read on the posting database's context;
- the main thread does not resolve the posted objects through their context;
- the disc scan runs outside its database's queue, which it enters only to
  index, to read its objects and to make thumbnails;
- none of those blocks, and no function they call in the scan or the copy, waits
  for the main thread or for a person;
- the questions come from the main run loop, not from inside the main queue;
- the album and the selection of a copy are read on the main thread, without
  the copy waiting for it, and the first batch waits on a thread of its own,
  outside every context.

Measured in the Debug app, arm64, with a synthetic ISO 9660 disc of 8 CT images
and a DICOMDIR: before the change the scan stopped after "8 instance(s) to take"
and the main thread waited in -objectsWithIDs:; after it the dialog came up, and
Copy put the 8 images in the database and ejected the disc.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

failures = []
instance = source_text('DicomDatabase+Instance')
scan = source_text('MediaVolumeScan')
job = source_text('MediaImportJob')
ingest = source_text('DatabaseIngest')
sources = source_text('BrowserController+Sources')


def check(condition, message):
    if not condition:
        failures.append(message)


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


def code_of(text):
    return re.sub(r'//[^\n]*', '', text)


def blocks(source, *openers):
    """The closures passed to each of `openers`, with their nested calls in place."""
    found = []
    for opener in openers:
        at = source.find(opener)
        while at >= 0:
            found.append(body(source[at:], opener))
            at = source.find(opener, at + 1)
    return found


# What waits for the main thread, or for a person through it.
WAITS = ('onMainRunLoopSync', 'onMainActorSync', 'DispatchQueue.main.sync', 'waitUntilDone: true', 'questions.',
         'runModal', 'destination.value()', '.value()', 'currentBrowser', 'whatToDo', 'commandIsDown')

scan_thread = body(sources, 'func volumeScanThread()')
check('database?.scan(atPath: self.devicePath)' in scan_thread,
      'the disc scan no longer starts in volumeScanThread: revisit this test')
at = scan_thread.find('N2ManagedObjectContextPerformAndWait')
held = body(scan_thread[at:], 'N2ManagedObjectContextPerformAndWait') if at >= 0 else ''
check('scan(atPath' not in held, 'the disc scan holds the queue of its database')

code = code_of(scan)
for number, block in enumerate(blocks(code, 'onDatabaseQueue {')):
    for wait in WAITS:
        check(wait not in block, f'block {number} on the database queue of the scan reaches {wait}')
check(len(blocks(code, 'onDatabaseQueue {')) >= 4, 'the scan no longer enters its database\'s queue as this test reads it')
run = code[code.find('private func scanned() -> Bool {'):code.find('private func onDatabaseQueue(')]
check('onDatabaseQueue' not in run and 'N2ManagedObjectContextPerformAndWait' not in run and 'performBlockAndWait' not in run,
      'the body of the scan enters the queue itself, where the questions are')
check('questions.whatToDo(withMedium:' in run and 'questions.commandIsDown()' in run,
      'the disc scan no longer asks: revisit this test')
questions = code[code.find('struct MediaScanQuestions'):code.find('struct MediaVolumeScan')]
check(questions.count('onMainRunLoopSync {') == 3, 'a question of the scan does not come from the main run loop')
for old_way in ('performSelector(onMainThread', 'waitUntilDone', 'DispatchQueue.main', 'onMainActorSync', 'currentBrowser()'):
    check(old_way not in code, f'the scan still reaches {old_way}')

code = code_of(job)
check('currentBrowser()' not in code and 'DispatchQueue.main' not in code and 'onMainActorSync' not in code and 'onMainRunLoopSync' not in code,
      'the copy waits for the main thread, or reads the browser, on its own')
indexing = code[code.find('func indexRaising('):code.find('private func add(')]
own = indexing[indexing.find('ingest.indexOnOwnContext('):]
own = body(own, 'ingest.indexOnOwnContext(')
for wait in WAITS:
    check(wait not in own, f'the block on the context of a batch reaches {wait}')
check(indexing.find('destination.value()') < indexing.find('ingest.indexOnOwnContext('),
      'a batch reads the destination inside its context')
check('let shown = destination.value()' in indexing, 'a batch does not wait for the destination outside the context')
reading = code[code.find('private final class MediaImportDestinationReading'):code.find('private struct MediaImportBatch')]
check('onMainRunLoop(finish)' in reading and 'Thread.isMainThread' in reading,
      'the destination is not read on the main thread')
run = code[code.find('private func importing() -> MediaImportOutcome'):code.find('lane.finishAndWait()')]
check('.value()' not in run, 'the copy itself waits for the main thread')

adapter = body(code_of(ingest)[code_of(ingest).find('func indexOnOwnContext('):], 'func indexOnOwnContext(')
check('worker.performBlockAndWait' in adapter, 'a batch is not indexed on its own context')

observe = body(instance, 'func observeIndependentDatabaseNotification(')
check(observe, 'observeIndependentDatabaseNotification not found')
bounce = observe[:observe.find('} else {')] if '} else {' in observe else ''
check('with: DicomDatabase.replacingObjectsWithIDs(notification), waitUntilDone: false' in bounce,
      'the main thread receives the independent database\'s objects, and enters its queue to read their IDs')

replace = body(instance, 'func replacingObjectsWithIDs(')
check(replace, 'replacingObjectsWithIDs not found')
check('(notification.object as? N2ManagedDatabase)?.managedObjectContext' in replace
      and 'N2ManagedObjectContextPerformAndWait(context)' in replace,
      'the IDs are not read on the posting database\'s context')
check('.objectID' in replace and 'OsirixAddToDBNotificationImagesArray' in replace
      and 'OsirixAddToDBNotificationImagesPerAETDictionary' in replace,
      'the image array and the per-AET dictionary are not both turned into IDs')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print('ok: a disc scan asks the user with no context queue held, and the main thread does not wait for it')
