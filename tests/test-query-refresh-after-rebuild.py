#!/usr/bin/env python3
"""A refresh of the Query window asked for while the database is rebuilt does
not stop the later ones.

-refresh: schedules one refresh at a time: it sets a flag, ignores the calls that
arrive while the flag is on, and the read of the local study index, at the end of
the refresh, clears it. During a rebuild there is no database, and that read
returns at once. If it returned without clearing the flag, every later -refresh:
would be ignored, and the local-completeness column would stop following the
database until the app restarts.

This compiles the production -refresh:, -executeRefresh:, -applyNewStudyArray:,
-computeStudyArrayInstanceUID: and the shared index, taken from the Swift of the
Query window, with the browser, the database reader and the delayed perform
substituted, and runs: a refresh with no database, then one with a database,
then another.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/QueryController+Results.swift').read_text(encoding='utf-8')
failures = []

if not shutil.which('xcrun'):
    print('skipped: no xcrun here')
    sys.exit(2)


def body_end(at):
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return index + 1
    raise ValueError('unbalanced braces')


def member(signature):
    """The declaration of `signature`, with the attributes above it."""
    at = source.find(signature)
    if at < 0:
        failures.append('%s is gone' % signature)
        return ''
    line = source.rfind('\n', 0, at) + 1
    while line > 0:
        previous = source.rfind('\n', 0, line - 1) + 1
        if not source[previous:line].strip().startswith('@'):
            break
        line = previous
    return source[line:body_end(at)]


methods = '\n'.join(member(signature) for signature in (
    'public func refresh(_ sender: Any?)',
    'public func executeRefresh(_ sender: Any?)',
    'func applyNewStudyArray(_ d: NSDictionary?)',
    'nonisolated func computeStudyArrayInstanceUID(_ sender: NSNumber?)',
))
index_enum = member('enum LocalStudyIndex {')

HARNESS = r'''
import AppKit
import CoreData

// What the production methods use of the rest of the app. The browser's
// database is nil during a rebuild; the reader returns an empty index.
final class N2ManagedDatabase: NSObject {}
final class Browser: NSObject { var database: N2ManagedDatabase? }
enum BrowserController {
    nonisolated(unsafe) static var browser = Browser()
    static func currentBrowser() -> Browser? { browser }
}
final class StudyIndex { var objectIDs: [NSManagedObjectID] = []; var studyInstanceUIDs: [Any] = [] }
enum HorosLocalQueryReader {
    nonisolated(unsafe) static var reads = 0
    static func studyIndex(of database: N2ManagedDatabase) throws -> StudyIndex { reads += 1; return StudyIndex() }
}

@MainActor public final class QueryController: NSObject {
    nonisolated(unsafe) var DatabaseIsEdited = false
    nonisolated(unsafe) var reloads = 0
    /// The delayed refreshes -refresh: asked for.
    nonisolated(unsafe) var scheduled: [Selector] = []
    var window: NSWindow? { nil }
    nonisolated class func current() -> QueryController? { nil }
    nonisolated class func currentAuto() -> QueryController? { nil }
    func reloadResultsAfterLocalChange() { reloads += 1 }
    func readLocalSnapshot() {}
    override public func perform(_ aSelector: Selector, with anArgument: Any?, afterDelay delay: TimeInterval) {
        scheduled.append(aSelector)
    }
}

extension QueryController {
METHODS
}

INDEX
'''

DRIVER = r'''
import AppKit

func check(_ condition: Bool, _ what: String) { if !condition { print("FAIL: " + what); exit(1) } }

/// Runs the refresh -executeRefresh: starts on a worker thread, as the delayed
/// perform would, and waits until its read of the index is over.
@MainActor func runScheduledRefresh(_ c: QueryController) {
    c.executeRefresh(c)
    let deadline = Date().addingTimeInterval(5)
    while LocalStudyIndex.refreshScheduled && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

MainActor.assumeIsolated {
    let c = QueryController()

    // During a rebuild of the database.
    BrowserController.browser.database = nil
    c.refresh(nil)
    check(c.scheduled.count == 1, "the first refresh is not scheduled")
    c.refresh(nil)
    check(c.scheduled.count == 1, "a refresh already scheduled is scheduled again")
    runScheduledRefresh(c)
    check(!LocalStudyIndex.refreshScheduled, "a refresh read during a rebuild leaves the next ones ignored")

    // The database is back: the next refresh happens and reads it.
    BrowserController.browser.database = N2ManagedDatabase()
    c.refresh(nil)
    check(c.scheduled.count == 2, "the refresh after a rebuild is ignored")
    runScheduledRefresh(c)
    check(HorosLocalQueryReader.reads == 1, "the refresh after a rebuild does not read the database")
    check(!LocalStudyIndex.refreshScheduled, "a refresh that read the database leaves the next ones ignored")
    check(LocalStudyIndex.get() != nil, "the index read is not kept")

    c.refresh(nil)
    check(c.scheduled.count == 3, "the refresh after a successful one is ignored")
    print("PASS: the refresh after one asked for during a rebuild still happens")
}
'''

harness = HARNESS.replace('METHODS', methods).replace('INDEX', index_enum)
if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-query-refresh-') as directory:
        path = Path(directory)
        (path / 'Harness.swift').write_text(harness)
        (path / 'main.swift').write_text(DRIVER)
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '6',
                                str(path / 'Harness.swift'), str(path / 'main.swift'), '-o', str(path / 'test')],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            failures.append('the Swift refresh methods do not compile in the harness:\n' + built.stderr[-4000:])
        else:
            try:
                run = subprocess.run([str(path / 'test')], capture_output=True, text=True, timeout=60)
                if run.returncode:
                    failures.append('the harness says: ' + (run.stdout + run.stderr).strip()[-2000:])
                else:
                    print(run.stdout.strip())
            except subprocess.TimeoutExpired:
                failures.append('the refresh harness did not finish within 60 s')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the read of the local study index ends the scheduled refresh even with no database')
