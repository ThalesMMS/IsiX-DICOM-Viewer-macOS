#!/usr/bin/env python3
"""Mounting a DICOM disc asks what to do with it instead of hanging.

With the factory setting (MOUNT -1, ask), a disc scan holds the queue of its
private-queue database while it waits for the main thread to show "Copy,
Browse or Ignore". Before it asks, indexing the disc posts the independent
database's notifications, which the main database bounces to the main thread.
There, reading the IDs of the notified objects entered the scan's queue: the
main thread waited for the scan, the scan waited for the main thread, and the
application hung on every DICOM disc, with no dialog and nothing imported.

The IDs are now read on the posting thread, where the queue is the scan's own,
and the main thread receives IDs. What must stay true:

- the bounce to the main thread hands over the notification with its objects
  replaced by their IDs;
- the IDs are read on the posting database's context;
- the main thread does not resolve the posted objects through their context.

Measured in the Debug app, arm64, with a synthetic ISO 9660 disc of 8 CT images
and a DICOMDIR: before the change the scan stopped after "8 instance(s) to take"
and the main thread waited in -objectsWithIDs:; after it the dialog came up, and
Copy put the 8 images in the database and ejected the disc.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

failures = []
instance = source_text('DicomDatabase+Instance')
scan = source_text('DicomDatabase+Scan')
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


# The conditions of the hang: the scan runs on its database's queue and asks
# the main thread, waiting for the answer.
scan_thread = body(sources, 'func volumeScanThread()')
check('N2ManagedObjectContextPerformAndWait(database?.managedObjectContext)' in scan_thread
      and 'database?.scan(atPath:' in scan_thread,
      'the disc scan no longer runs on its database\'s queue: revisit this test')
check('#selector(MediaScanQuestions.askUserDiscDataCopyOrBrowse(_:))' in scan and 'waitUntilDone: true' in scan,
      'the disc scan no longer waits for the main thread to ask: revisit this test')

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
print('ok: a disc scan that asks the main thread is not waited for by it')
