#!/usr/bin/env python3
"""A partial list of a C-FIND never replaces the complete list of its query.

While a C-FIND of the Query window runs, each match is reported on the C-FIND's
own thread, and what has come is listed at most once a second: that partial
list crosses the main queue. The thread that asked waits for the C-FIND in
steps of 50 ms without serving the queue in between, and shows the complete
list itself as soon as the C-FIND ends. A node that takes more than 50 ms to
send its first match and sends the rest right after has both in one step: the
complete list is shown first, the main queue then hands over the list of the
first match, and the window lists one study of a query that found a dozen.

Static checks, everywhere:
- the worker state of the window keeps the lists in a LiveQueryAnswers of
  IsiXDICOMNetwork, which hands out each partial list with a turn;
- the window shows a partial list through -showPartialResults only, which asks
  for the turn on the main thread right before it replaces the list;
- a query opens the lists as it starts and closes them after its complete list
  is shown.

Runtime, where xcrun is present (skipped otherwise, exit 2): the real
QueryWindowWorkerState.swift, compiled with IsiXDICOMNetwork, in the order the
window meets:
- a partial list handed to the main queue by another thread, the complete list
  shown by the main thread before the queue is served: the window keeps the
  complete list;
- the same with the complete list of a node shown as a partial list of a later
  turn (a query of several nodes, and the automatic query's window);
- a partial list of the query before, arriving during the next one, is not
  shown;
- a partial list that arrives while its query still runs is shown;
- and, as the negative control, the same order without asking for the turn
  leaves the window with the first match only.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
from sources import source_text
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
failures = []


def body(text, signature, what):
    """The text of the function that starts with `signature`, up to the next
    declaration at its level."""
    start = text.find(signature)
    if start < 0:
        failures.append(f'{what}: {signature!r} is gone')
        return ''
    end = text.find('\n    }\n', start)
    return text[start:end if end >= 0 else len(text)]


workers = source_text('QueryWindowWorkerState')
for needle, what in [
    ('private var liveAnswers = LiveQueryAnswers<AnyObject>()', 'the lists shown while a C-FIND runs are not a LiveQueryAnswers'),
    ('locked { liveAnswers.begin(showing: showing) }', 'a query does not open the lists'),
    ('locked { liveAnswers.end() }', 'a query does not close the lists'),
    ('locked { liveAnswers.add(answers, now: now, merge: merge) }', 'a partial list is not handed out with its turn'),
    ('locked { liveAnswers.takeTurn(turn) }', 'the turn of a partial list is not asked for'),
]:
    if needle not in workers:
        failures.append(f'QueryWindowWorkerState: {what}')

query = source_text('QueryController+Query')
realtime = body(query, 'nonisolated func realtimeCFindResults(_ notification: Notification) {', 'the answers of a C-FIND under way')
if 'showPartialResults(shown.answers, turn: shown.turn)' not in realtime:
    failures.append('-realtimeCFindResults: does not show its list with the turn it was handed out with')
if 'showResults(' in realtime or 'refreshList(' in realtime:
    failures.append('-realtimeCFindResults: shows a partial list without its turn')

partial = body(query, 'nonisolated func showPartialResults(', 'showing a partial list')
turn, replaced = partial.find('guard controller.workers.takeRealtimeTurn(turn) else { return }'), partial.find('controller.refreshList(')
if not 0 <= turn < replaced:
    failures.append('-showPartialResults: the list is replaced without asking for the turn first')
if 'onMainActor {' not in partial or not partial.find('onMainActor {') < turn:
    failures.append('-showPartialResults: the turn is not asked for on the main thread, right before the list is replaced')

answers = query[query.find('nonisolated func queryAnswers('):query.find('nonisolated func addFilters(')]
opened, complete, closed = (answers.find('workers.beginRealtimeAnswers(showing: onMain)'),
                            answers.find('showResults(tempResultArray.map { $0 as AnyObject })'),
                            answers.find('workers.endRealtimeAnswers()'))
if not 0 <= opened < complete < closed:
    failures.append('-queryAnswers: the lists are not opened as the query starts and closed after its complete list is shown')

# Nothing else replaces the list with what a C-FIND under way has answered.
for name in ('QueryController', 'QueryController+Results', 'QueryController+Retrieve', 'QueryController+AutoQuery',
             'QueryController+Network', 'QueryController+Filters'):
    if 'realtimeAnswers(adding:' in source_text(name):
        failures.append(f'{name}: lists the answers of a C-FIND under way outside -realtimeCFindResults')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS (static): a partial list is shown only with its turn, asked for on the main thread, and a query closes '
      'the lists after its complete list')

if shutil.which('xcrun') is None:
    print('skipped: the runtime part needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

DRIVER = r'''
import Foundation
import IsiXDICOMNetwork

// What the worker state names of the application, and does not use here.
final class QueryArrayController {}
final class HorosLocalQuerySnapshot {}
extension Thread { func setIsCancelled(_ cancelled: Bool) {} }

/// The window's list, written on the main thread only.
nonisolated(unsafe) var listed: [String] = []

func join(_ answers: [AnyObject], _ list: inout [AnyObject]) {
    for answer in answers where !list.contains(where: { $0.isEqual(answer) }) { list.append(answer) }
}

func names(_ answers: [AnyObject]) -> [String] { answers.map { $0 as? String ?? "?" } }
func objects(_ names: [String]) -> [AnyObject] { names.map { $0 as NSString } }

let whole = (1...12).map { "study \($0)" }

/// A match reported on the C-FIND's thread: listed there, and handed to the
/// main queue as the window hands it; `asking` false is the window that shows
/// whatever arrives. Returns once the list is on the queue, not served.
func reportOnAnotherThread(_ answers: [String], _ workers: QueryWindowWorkerState, now: TimeInterval, asking: Bool) {
    let handedOver = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        if let partial = workers.realtimeAnswers(adding: objects(answers), now: now, merge: join) {
            let list = names(partial.answers), turn = partial.turn
            DispatchQueue.main.async {
                guard !asking || workers.takeRealtimeTurn(turn) else { return }
                listed = list
            }
        }
        handedOver.signal()
    }
    handedOver.wait()
}

/// The main queue, served as the run loop serves it once the query returns.
func serveMainQueue() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
}

func begin(_ workers: QueryWindowWorkerState) {
    listed = []
    workers.beginRealtimeAnswers(showing: true)
    workers.isFirstNode = true
}

/// The first match, then the end of the C-FIND before the queue is served.
func lateFirstMatch(asking: Bool) -> [String] {
    let workers = QueryWindowWorkerState()
    begin(workers)
    reportOnAnotherThread(["study 1"], workers, now: 100, asking: asking)
    listed = whole              // the complete list, shown by the thread that asked
    workers.endRealtimeAnswers()
    serveMainQueue()
    return listed
}

var failed = false
func check(_ condition: Bool, _ message: String) {
    print((condition ? "PASS: " : "FAIL: ") + message)
    if !condition { failed = true }
}

if CommandLine.arguments.dropFirst().first == "unasked" {
    let shown = lateFirstMatch(asking: false)
    print("without the turn the window lists \(shown.count) of \(whole.count)")
    exit(shown == ["study 1"] ? 0 : 1)
}

check(lateFirstMatch(asking: true) == whole,
      "the complete list stays when the list of the first match arrives after it")

do {
    // The node's C-FIND ends: the thread that asked lists all of its answers
    // as a list of a later turn, and goes on to the next node.
    let workers = QueryWindowWorkerState()
    begin(workers)
    reportOnAnotherThread(["study 1"], workers, now: 100, asking: true)
    workers.resetRealtimeUpdate()
    if let all = workers.realtimeAnswers(adding: objects(whole), now: 100.2, merge: join), workers.takeRealtimeTurn(all.turn) {
        listed = names(all.answers)
    }
    serveMainQueue()
    check(listed == whole, "the answers of a node, listed at its end, stay when its first match arrives after them")
    workers.endRealtimeAnswers()
}

do {
    // The first match of one query is still on the queue when the next query
    // starts and lists its own.
    let workers = QueryWindowWorkerState()
    begin(workers)
    reportOnAnotherThread(["earlier patient"], workers, now: 100, asking: true)
    workers.endRealtimeAnswers()
    begin(workers)
    serveMainQueue()
    check(listed == [], "the first match of the query before is not listed during the next one")
    reportOnAnotherThread(["this patient"], workers, now: 102, asking: true)
    serveMainQueue()
    check(listed == ["this patient"], "a match of the query under way is listed while it runs")
    workers.endRealtimeAnswers()
}

do {
    // A query off the main thread lists nothing while it runs.
    let workers = QueryWindowWorkerState()
    listed = ["what the window listed"]
    workers.beginRealtimeAnswers(showing: false)
    workers.isFirstNode = true
    reportOnAnotherThread(["study 1"], workers, now: 100, asking: true)
    serveMainQueue()
    check(listed == ["what the window listed"], "a query that shows its answers at its end lists nothing before")
}

exit(failed ? 1 : 0)
'''

with tempfile.TemporaryDirectory(prefix='horos-query-partial-list-') as temporary:
    work = Path(temporary)
    (work / 'main.swift').write_text(DRIVER)
    binary = work / 'partial-list'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(root / 'Horos/Sources/QueryWindowWorkerState.swift'),
                    str(work / 'main.swift'), *isix_modules.module_flags('IsiXDICOMNetwork', work / 'modules'),
                    '-o', str(binary)], check=True)
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
    sys.stdout.write(run.stdout)
    if run.returncode != 0:
        sys.stderr.write(run.stderr)
        print(f'FAIL: the driver ended with {run.returncode}')
        sys.exit(1)
    # Negative control: shown without its turn, the first match replaces the complete list.
    unasked = subprocess.run([str(binary), 'unasked'], capture_output=True, text=True, timeout=120)
    if unasked.returncode != 0:
        print('FAIL: a partial list shown without its turn no longer replaces the complete one, so this test proves '
              'nothing: ' + (unasked.stdout + unasked.stderr).strip()[:300])
        sys.exit(1)
    print('PASS (control): ' + unasked.stdout.strip())
