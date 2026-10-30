#!/usr/bin/env python3
"""Import batches refresh the study list and the albums at a bounded rate.

Every indexed batch posts OsirixAddToDBNotification, and the browser answered
each one by refetching every study on the main thread and starting an album
count. Compile the production coalescing methods with short intervals and a
recording outline, post a burst of arrivals, and count the refreshes. Also check
that the album count is marked as running before its thread starts, so a burst
cannot start several counts at once.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []

# The coalescing is Swift (BrowserController+DatabaseSwitching.swift) on the
# IsiXDatabase schedule.
switching = (root / 'Horos/Sources/BrowserController+DatabaseSwitching.swift').read_text()
schedule = root / 'Modules/IsiXDatabase/Sources/ImportRules.swift'


def swift_methods(first, last):
    """From the attribute of `first` to the closing brace of `last`."""
    at = switching.find('@objc(%s)' % first)
    end = switching.find('func %s()' % last)
    if at < 0 or end < 0:
        failures.append('%s ... %s is gone' % (first, last))
        return ''
    opening = switching.index('{', end)
    depth = 0
    for index in range(opening, len(switching)):
        if switching[index] == '{':
            depth += 1
        elif switching[index] == '}':
            depth -= 1
            if depth == 0:
                return switching[at:index + 1]
    return ''


methods = swift_methods('_refreshDatabaseDisplayAfterImport', '_importAlbumsRefreshFire')
schedule_text = schedule.read_text()
if 'listInterval: TimeInterval = 5' not in schedule_text or 'albumsInterval: TimeInterval = 20' not in schedule_text:
    failures.append('the import refresh intervals are no longer 5 s for the list and 20 s for the albums')
# Short intervals for the run; the schedule's own arithmetic stays.
methods = methods.replace('ImportRefreshSchedule.listInterval', 'Harness.listInterval') \
                 .replace('ImportRefreshSchedule.albumsInterval', 'Harness.albumsInterval')

# -refreshAlbums and its thread are Swift too (BrowserController+StudyList.swift).
study_list = (root / 'Horos/Sources/BrowserController+StudyList.swift').read_text()


def swift_body(signature):
    at = study_list.find(signature)
    if at < 0:
        failures.append('%s is gone' % signature)
        return ''
    opening = study_list.index('{', at)
    depth = 0
    for index in range(opening, len(study_list)):
        if study_list[index] == '{':
            depth += 1
        elif study_list[index] == '}':
            depth -= 1
            if depth == 0:
                return study_list[at:index + 1]
    return ''


albums = swift_body('func refreshAlbums()')
thread = swift_body('func _computeNumberOfStudiesForAlbumsThread()') + swift_body('private func computeNumberOfStudiesForAlbums()')
if not re.search(r'horos_computingNumberOfStudiesForAlbums = true\s*Thread\.detachNewThreadSelector\(#selector\(BrowserController\._computeNumberOfStudiesForAlbumsThread\)', albums):
    failures.append('the album count is not marked as running before its thread starts')
if re.search(r'if horos_computingNumberOfStudiesForAlbums', thread):
    failures.append('the album thread checks the mark its caller has just set, and would never count')

NATIVE = r'''
import AppKit
enum Harness { static let listInterval: TimeInterval = 0.3, albumsInterval: TimeInterval = 1.0 }
final class Outline { var editedRow = -1 }
@MainActor final class Browser: NSObject {
    var horos_databaseOutline: Outline? = Outline()
    var horos_refreshDeferredWhileEditing = false
    var horos_lastImportListRefresh: TimeInterval = 0, horos_lastImportAlbumsRefresh: TimeInterval = 0
    var horos_importListRefreshPending = false, horos_importAlbumsRefreshPending = false
    var lists = 0, albums = 0
    func outlineViewRefresh() { lists += 1 }
    func refreshAlbums() { albums += 1 }
}
extension Browser {
METHODS
}
@MainActor func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
MainActor.assumeIsolated {
    let b = Browser()
    b._refreshDatabaseDisplayAfterImport()
    precondition(b.lists == 1 && b.albums == 1, "the first batch of a quiet period is shown at once")
    for _ in 0..<20 { b._refreshDatabaseDisplayAfterImport(); spin(0.075) }
    spin(1.2)
    print("20 batches over 1.5 s: \(b.lists) list refreshes, \(b.albums) album refreshes")
    precondition(b.lists >= 5 && b.lists <= 8, "list refreshed about every 0.3 s: \(b.lists)")
    precondition(b.albums >= 2 && b.albums <= 3, "albums refreshed about every 1 s: \(b.albums)")
    let lists = b.lists
    b.horos_databaseOutline?.editedRow = 3
    b._refreshDatabaseDisplayAfterImport()
    spin(0.5)
    precondition(b.lists == lists && b.horos_refreshDeferredWhileEditing, "an edit keeps its field editor; the refresh is deferred")
    print("PASS: a burst of 21 import batches refreshed the list and the albums at bounded rates")
}
'''.replace('METHODS', methods)

if methods.strip():
    with tempfile.TemporaryDirectory(prefix='horos-import-refresh-') as directory:
        path = Path(directory)
        (path / 'main.swift').write_text(NATIVE)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(schedule), str(path / 'main.swift'),
                                '-o', str(path / 'test')], capture_output=True, text=True)
        if built.returncode:
            failures.append('the refresh methods do not compile: ' + built.stderr[-3000:])
        else:
            run = subprocess.run([str(path / 'test')], capture_output=True, text=True, timeout=60)
            print(run.stdout.strip())
            if run.returncode:
                failures.append('coalescing regression: ' + run.stderr[-1500:])

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: import batches refresh the list at most every interval, the albums less often, one count at a time')
