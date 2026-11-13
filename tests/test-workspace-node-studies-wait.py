#!/usr/bin/env python3
"""A study whose saved workspace needs studies of a node opens without holding the main thread.

With PACS On-Demand on, opening a study whose saved workspace names a study
that is not in the database asked the nodes for it and retrieved it on the
main thread, then waited there up to 20 seconds for its images: the windows
stopped answering for the whole transfer, the Abort button of "Connecting..."
included. The opening now hands those studies to a thread of their own that
Activity lists with its Cancel button, and goes on from the main run loop when
they arrived, when that thread is cancelled or when the time allowed runs out,
with what is in the database by then.

While such an opening waits, and while the opening of a study waits for the
comparatives its hanging protocol asks of the nodes, the status line of the
database window says so in front of the rest: which study is opening, what it
waits for and how to open it without them. The notice goes when the wait is
over, however it ends: the opening went on, its thread was cancelled, the time
ran out, another opening took its place, or the selection or the database
changed meanwhile.

Three parts, on the sources as they are:

- text: in ViewerOpener.swift, neither the opening of a study nor the restoring
  of its workspace asks a node, retrieves or sleeps; the only call of the
  retrieve is the work given to StudyOpeningWait. The notice of the workspace
  is shown and taken away by the wait; the notice of the comparatives is
  shown only when the nodes are asked and goes wherever their wait ends,
  before the opening looks at the selection and the database; a thread
  cancelled in Activity opens the study with the comparatives found so far.
  StudyListContent.swift writes the status line in one place, the notice
  first.
- wait: StudyOpeningWait.swift, with ActivityThread.swift and
  MainActorCallbacks.swift, compiled against a thread manager that only lists
  and starts the threads. The opening goes on once, on the main thread, from
  the run loop (a block given to the main queue runs while it is still going
  on, as it must while a sheet or an alert is up): when the work ends; when
  the time runs out, the work being left to end uncancelled; when the listed
  thread is cancelled. An opening given up does not go on, and its work is
  not cancelled either. In each of those, `waiting` is told once that the
  wait began and once that it is over, before the opening goes on.
- retrieve: ViewerOpener.retrieveWorkspaceStudies, taken as it is, around
  stand-ins of the query, the nodes and the retrieves. A node that answers
  more studies than it was asked for has only the study asked for retrieved;
  one that does not have it has nothing retrieved; no node, or another active
  database, asks nothing; a cancelled thread asks for nothing more; a study
  already being retrieved is waited for, not asked for twice.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

OPENER = 'Horos/Sources/ViewerOpener.swift'
WAIT = 'Horos/Sources/StudyOpeningWait.swift'
ACTIVITY = 'Horos/Sources/ActivityThread.swift'
CALLBACKS = 'Horos/Sources/MainActorCallbacks.swift'


def exists(path):
    if revision:
        return subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{revision}:{path}'],
                              capture_output=True).returncode == 0
    return (root / path).is_file()


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text(encoding='utf-8')


def fail(message):
    print('FAIL:', message)
    sys.exit(1)


def function(text, signature):
    """The text of the Swift method with that signature, up to the next method or mark."""
    start = text.find(signature)
    if start < 0:
        fail(f'{signature} not found in {OPENER}')
    following = re.search(r'\n    (?:///|// MARK:|(?:(?:private|nonisolated|static|@\w+) )*func )', text[start + len(signature):])
    return text[start:start + len(signature) + following.start() if following else len(text)]


def code(text):
    """The lines of `text` that are not comments."""
    return '\n'.join(line for line in text.splitlines() if not line.strip().startswith('//'))


# ---------------------------------------------------------------- text

opener = source(OPENER)
if 'private func retrieveIfMissing(' in opener:
    fail('the workspace still has its own retrieve of a missing study, run where the workspace is restored')
if not exists(WAIT):
    fail(f'{WAIT} is missing')

ASKS = ('QueryController.', 'retrieveNow(', 'retrieveStudies(', 'Thread.sleep', 'retrieveWorkspaceStudies(',
        'importQueueNow(', 'RunLoop.current.run')
for signature in ('    func openStudy(_ item: NSManagedObject?) {',
                  '    private func restoreWorkspace(of currentStudy: DicomStudy?) {',
                  '    private func openByHangingProtocol(_ currentStudy: DicomStudy?) {'):
    body = code(function(opener, signature))
    for ask in ASKS:
        if ask in body:
            fail(f'{signature.strip()} holds `{ask}`: it would ask a node, retrieve or wait on the main thread')

opening = code(function(opener, '    func openStudy(_ item: NSManagedObject?) {'))
gate = 'if let currentStudy, let database, waitForWorkspaceStudies(of: currentStudy, in: database) { return }'
if gate not in opening or opening.index(gate) > opening.index('restoreWorkspace(of: currentStudy)'):
    fail('the opening of a study does not wait for the studies of its workspace before restoring it')

waiting = code(function(opener, '    private func waitForWorkspaceStudies(of study: DicomStudy, in database: DicomDatabase) -> Bool {'))
if waiting.count('retrieveWorkspaceStudies(') != 1:
    fail('the studies of the workspace are not retrieved in exactly one place')
work = waiting[waiting.index('StudyOpeningWait('):]
if 'retrieveWorkspaceStudies(' not in work[:work.index('} waiting:')]:
    fail('the retrieve of the studies of the workspace is not the work given to StudyOpeningWait')
shown = work[work.index('} waiting:'):work.index('} then:')]
if 'self?.waitingNotice = waiting ? (text: notice, row: selected) : nil' not in shown:
    fail('the wait for the studies of the workspace does not show its notice while it waits and take it away after')
if 'Notice' in work[work.index('} then:'):]:
    fail('the notice of the workspace is also handled where the opening goes on: it is the wait that takes it away, however it ends')
for ask in ('QueryController.', 'retrieveNow(', 'Thread.sleep'):
    if ask in waiting:
        fail(f'waitForWorkspaceStudies holds `{ask}` on the main thread')
proceeding = work[work.index('} then:'):]
if not (proceeding.index('self.database === database') < proceeding.index('self.restoreWorkspace(of: current)')
        < proceeding.index('self.openByHangingProtocol(current)')):
    fail('once the wait is over the study is not opened by its workspace, then its hanging protocol, on the database it was asked on')

# The comparatives a hanging protocol asks of the nodes.
ending = code(function(opener, '    private func cancelComparativeOpening() {'))
if 'waitingNotice = nil' not in ending:
    fail('the end of the wait for the comparatives leaves its notice in the status line')
preparing = code(function(opener, '    private func prepareComparativeOpening(_ study: DicomStudy, in database: DicomDatabase, options: [AnyHashable: Any]) {'))
asked = 'if preferences[NetworkPreferences.searchesComparativeStudiesOnDICOMNodes], !database.isReadOnly, database.isLocal() {'
if asked not in preparing or 'waitingNotice = (text: notice(ofOpening: study), row: selected)' not in preparing[preparing.index(asked):preparing.index(asked) + 200]:
    fail('the wait for the comparatives shows no notice when the nodes are asked, or shows it when they are not')
if preparing.count('waitingNotice') != 1 or 'openingNotice' in preparing:
    fail('the notice of the comparatives is set in more than one place of their wait')
finishing = preparing[preparing.index('let finish: @MainActor @Sendable () -> Void = {'):]
finishing = finishing[:finishing.index('opening.work = Task')]
if not (finishing.index('self.cancelComparativeOpening()') < finishing.index('self.database === database')
        < finishing.index('self.openPrepared(current')):
    fail('when the wait for the comparatives is over its notice does not go before the selection and the database are looked at')
after = preparing[preparing.index('opening.work = Task'):]
tail = after[after.rindex('if !Task.isCancelled {') if 'if !Task.isCancelled {' in after else 0:]
if 'if !Task.isCancelled {' not in after or 'completed &&' in after or \
        not (tail.index('finish()') < tail.index('self?.cancelComparativeOpening()')):
    fail('a thread cancelled in Activity does not open the study with the comparatives found so far, '
         'or an opening that another replaced does not end its wait')
for signature in ('    func openStudy(_ item: NSManagedObject?) {',
                  '    func open(_ currentStudy: DicomStudy?, withProtocol currentHangingProtocol: [AnyHashable: Any]?) {'):
    body = code(function(opener, signature))
    if 'abandonWorkspaceOpening()' not in body or 'cancelComparativeOpening()' not in body:
        fail(f'{signature.strip()} does not end the wait of the opening it replaces')
if 'workspaceOpening?.wait.abandon()' not in code(function(opener, '    private func abandonWorkspaceOpening() {')):
    fail('an opening that another replaces does not give its wait up')
notice = code(function(opener, '    private func notice(ofOpening study: DicomStudy) -> String {'))
if 'NSLocalizedString("OPENING %@: waiting for studies from the PACS; cancel the retrieve in Activity to open without them. / "' not in notice \
        or 'study.name' not in notice:
    fail('the notice does not name the study that is opening, what it waits for and how to open without it')

# The status line of the database window.
LIST = 'Horos/Sources/StudyListContent.swift'
listing = code(source(LIST))
showing = listing[listing.index('    func showDescription() {'):]
showing = showing[:showing.index('\n    }\n')]
if 'let notice = browser.viewerOpener.openingNotice' not in showing \
        or 'let description = (notice ?? "") + listDescription' not in showing \
        or 'guard let line = browser.horos_databaseDescription else { return }' not in showing \
        or 'line.stringValue = description' not in showing:
    fail('the status line does not show the notice of an opening in front of what the list says')
if 'line.textColor = notice == nil ? listDescriptionColor : .labelColor' not in showing:
    fail('the status line keeps its dim colour while it shows a notice, or keeps the colour of the notice after it')
if listing.count('horos_databaseDescription') != 1:
    fail('the status line is written in more than one place: a refresh of the list would drop the notice')
if not re.search(r'listDescription = description\n\s*showDescription\(\)', listing):
    fail('a refresh of the list does not write the status line through showDescription')
if 'browser.studyList.showDescription()' not in code(opener[opener.index('private(set) var openingNotice: String? {'):][:300]):
    fail('the status line is not written again when the notice comes or goes')

# The notice shows while the row the opening was asked on is still the selected one.
noticing = code(function(opener, '    private func showWaitingNotice() {'))
if 'openingNotice = waitingNotice.row == selectedOpeningRowID ? waitingNotice.text : nil' not in noticing:
    fail('the notice of an opening still shows once another row is selected, although the study will not open')
if 'NSOutlineView.selectionDidChangeNotification' not in noticing or 'self?.showWaitingNotice()' not in noticing:
    fail('the notice is not looked at again when the selection of the list changes')
gone = noticing[noticing.index('guard let waitingNotice else {'):noticing.index('return')]
if 'removeObserver(waitingNoticeObserver)' not in gone or 'openingNotice = nil' not in gone:
    fail('a wait that is over leaves its notice, or goes on listening to the selection')
if len(re.findall(r'\bopeningNotice = ', code(opener))) != 2:
    fail('the notice of the status line is written outside showWaitingNotice')
print('ok: text - the opening and the workspace ask no node on the main thread; the retrieve is the work of the wait; '
      'the notice shows while an opening waits and goes however the wait ends')

if shutil.which('xcrun') is None:
    print('skipped: the wait and the retrieve need xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

# ---------------------------------------------------------------- wait

WAIT_STUBS = r'''
import Foundation

/// The thread manager of the application, here only listing and starting.
final class ThreadsManager: @unchecked Sendable {
    static let shared = ThreadsManager()
    private let lock = NSLock()
    private var listed: [Thread] = []
    class func `default`() -> ThreadsManager! { shared }
    func addThreadAndStart(_ thread: Thread!) {
        lock.withLock { listed.append(thread) }
        thread.start()
    }
    var threads: [Thread] { lock.withLock { listed } }
}

extension Thread {
    var supportsCancel: Bool {
        get { threadDictionary["supportsCancel"] as? Bool ?? false }
        set { threadDictionary["supportsCancel"] = newValue }
    }
}
'''

WAIT_MAIN = r'''
import Foundation

final class Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    func set(_ key: String, _ value: Double = 1) { lock.withLock { values[key] = value } }
    func add(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
    subscript(_ key: String) -> Double? { lock.withLock { values[key] } }
}

let flags = Flags()
let started = Date()
func elapsed() -> Double { Date().timeIntervalSince(started) }
nonisolated(unsafe) var failures: [String] = []
func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

/// Lets the main run loop turn for `seconds`, as the application's does.
@MainActor func turn(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// What `waiting` is told: how many times that the wait began and that it is
/// over, and which was said last.
@MainActor func signal(_ waiting: Bool) {
    flags.add(waiting ? "signalOn" : "signalOff")
    flags.set("signal", waiting ? 1 : 0)
}

/// The notice was shown once and is shown now, or was taken away once and for good.
func checkSignal(shown: Bool, _ when: String) {
    check(flags["signalOn"] == 1, "\(when), the wait was said to begin \(flags["signalOn"] ?? 0) times, not once")
    check((flags["signalOff"] ?? 0) == (shown ? 0 : 1), "\(when), the wait was said to be over \(flags["signalOff"] ?? 0) times")
    check(flags["signal"] == (shown ? 1 : 0), "\(when), the notice is \(flags["signal"] == 1 ? "shown" : "not shown")")
}

/// What the opening does when it goes on: recorded, with whether a block given
/// to the main queue runs before it returns.
@MainActor func proceeded() {
    flags.add("proceeded")
    flags.set("signalAtProceed", flags["signal"] ?? -1)
    flags.set("proceededAt", elapsed())
    flags.set("proceededOnMain", Thread.isMainThread ? 1 : 0)
    DispatchQueue.main.async { flags.set("queueServed") }
    turn(0.3)
    flags.set("queueServedInside", flags["queueServed"] ?? 0)
}

func work(seconds: Double, untilCancelled: Bool = false) -> @Sendable () -> Void {
    {
        flags.set("workOnMain", Thread.isMainThread ? 1 : 0)
        flags.set("cancellable", Thread.current.supportsCancel ? 1 : 0)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if untilCancelled && Thread.current.isCancelled { break }
            usleep(20_000)
        }
        flags.set("workCancelled", Thread.current.isCancelled ? 1 : 0)
        flags.set("workEndedAt", elapsed())
    }
}

@MainActor func run(_ which: String) {
    switch which {
    case "ends":
        let wait = StudyOpeningWait(activity: "Retrieving", limit: .seconds(6), work: work(seconds: 0.4), waiting: signal, then: proceeded)
        check(wait.isPending, "the opening does not wait while the work runs")
        checkSignal(shown: true, "as the wait begins")
        turn(0.2)
        check(flags["proceeded"] == nil, "the opening went on before the work ended")
        checkSignal(shown: true, "while the work runs")
        turn(2.3)
        checkSignal(shown: false, "once the opening went on")
        check(flags["signalAtProceed"] == 0, "the notice was still shown when the opening went on")
        wait.abandon()
        checkSignal(shown: false, "given up after it went on")
        check(flags["proceeded"] == 1, "the opening went on \(flags["proceeded"] ?? 0) times when the work ended, not once")
        check((flags["proceededAt"] ?? 9) < 2, "the opening went on \(flags["proceededAt"] ?? -1) s after it began, the work taking 0.4 s")
        check(flags["proceededOnMain"] == 1, "the opening went on away from the main thread")
        check(flags["workOnMain"] == 0, "the work ran on the main thread")
        check(flags["cancellable"] == 1, "the thread of the work has no Cancel button")
        check(ThreadsManager.shared.threads.count == 1, "the work is not on a listed thread")
        check(flags["queueServedInside"] == 1, "the main queue was not served while the opening went on: it runs from a block of that queue or a main-actor task")
        check(!wait.isPending, "the opening still waits after it went on")
    case "deadline":
        let wait = StudyOpeningWait(activity: "Retrieving", limit: .milliseconds(500), work: work(seconds: 2.5), waiting: signal, then: proceeded)
        turn(0.3)
        checkSignal(shown: true, "before the time runs out")
        turn(1.3)
        checkSignal(shown: false, "once the time ran out")
        check(flags["signalAtProceed"] == 0, "the notice was still shown when the opening went on after the time ran out")
        check(flags["proceeded"] == 1, "the opening did not go on when the time ran out")
        check((flags["proceededAt"] ?? 9) < 1.5 && (flags["proceededAt"] ?? 0) >= 0.45, "the opening went on at \(flags["proceededAt"] ?? -1) s, the time allowed being 0.5 s")
        check(flags["workEndedAt"] == nil, "the work ended before the time ran out: the case measures nothing")
        check(flags["queueServedInside"] == 1, "the main queue was not served while the opening went on")
        check(!wait.isPending, "the opening still waits after the time ran out")
        turn(2.0)
        check(flags["workEndedAt"] != nil, "the work did not end")
        check(flags["workCancelled"] == 0, "the work was cancelled when the time ran out")
        check(flags["proceeded"] == 1, "the opening went on again when the work ended after the time ran out")
        checkSignal(shown: false, "when the work ended after the time ran out")
    case "cancel":
        let wait = StudyOpeningWait(activity: "Retrieving", limit: .seconds(8), work: work(seconds: 6, untilCancelled: true), waiting: signal, then: proceeded)
        turn(0.4)
        check(flags["proceeded"] == nil, "the opening went on before the thread was cancelled")
        checkSignal(shown: true, "before the thread is cancelled")
        check(ThreadsManager.shared.threads.count == 1, "the work is not on a listed thread")
        ThreadsManager.shared.threads.first?.cancel()
        turn(1.6)
        check(flags["proceeded"] == 1, "the opening did not go on once the thread was cancelled")
        check((flags["proceededAt"] ?? 9) < 2, "the opening went on \(flags["proceededAt"] ?? -1) s after it began, the thread cancelled at 0.4 s")
        check(flags["workCancelled"] == 1, "the work did not see its thread cancelled")
        checkSignal(shown: false, "once the thread was cancelled")
        check(flags["signalAtProceed"] == 0, "the notice was still shown when the opening went on after the cancelling")
        check(!wait.isPending, "the opening still waits after it went on")
    case "abandon":
        let wait = StudyOpeningWait(activity: "Retrieving", limit: .milliseconds(900), work: work(seconds: 0.5), waiting: signal, then: proceeded)
        turn(0.1)
        checkSignal(shown: true, "before the opening is given up")
        wait.abandon()
        check(!wait.isPending, "an opening given up still waits")
        checkSignal(shown: false, "as soon as the opening is given up")
        wait.abandon()
        turn(1.6)
        checkSignal(shown: false, "after the work and the time of an opening given up")
        check(flags["proceeded"] == nil, "an opening given up went on")
        check(flags["workEndedAt"] != nil && flags["workCancelled"] == 0, "the work of an opening given up was cancelled or did not end")
    default:
        failures.append("unknown case \(which)")
    }
}

MainActor.assumeIsolated { run(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "") }
for failure in failures { print("FAIL: \(failure)") }
if failures.isEmpty { print("as expected") }
exit(failures.isEmpty ? 0 : 1)
'''

WAIT_CASES = [
    ('ends', 'the opening goes on once, from the main run loop, when the work of a listed, cancellable thread ends; its notice goes first'),
    ('deadline', 'the opening goes on when the time runs out, its notice gone, and the work is left to end uncancelled'),
    ('cancel', 'cancelling the listed thread lets the opening go on at once, its notice gone'),
    ('abandon', 'an opening given up does not go on, its notice goes at once, and its work is not cancelled'),
]

# ---------------------------------------------------------------- retrieve

RETRIEVE_STUBS = r'''
import Foundation

func sameString(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? String, let b = b as? String else { return false }
    return (a as NSString).isEqual(to: b)
}

final class DicomDatabase {}

final class DCMTKStudyQueryNode: NSObject {
    let uid: String?
    init(_ uid: String?) { self.uid = uid }
    func studyInstanceUID() -> String! { uid }
}

struct Nodes {
    var servers: [[String: Any]] = [["Description": "Node"]]
    func comparativeServers() -> [[String: Any]] { servers }
}

struct Search { var nodes = Nodes() }

final class ProcessGraph {
    var pacsOnDemand = Search()
    var activeLocalDatabase: DicomDatabase?
}

/// The retrieves of the history, here recording what is asked of them.
final class DistantStudyRetrieves {
    var retrieved: [String?] = []
    var databases: [DicomDatabase?] = []
    /// The UID being retrieved elsewhere, and how many more times it answers so.
    var busy: String?
    var busyAnswers = 0
    var busyAsked = 0
    var cancelsDuringRetrieve = false

    func isRetrieving(studyInstanceUID uid: String?) -> Bool {
        guard uid != nil, uid == busy else { return false }
        busyAsked += 1
        busyAnswers -= 1
        return busyAnswers >= 0
    }

    func retrieveNow(_ study: DCMTKStudyQueryNode?, in database: DicomDatabase? = nil) {
        retrieved.append(study?.studyInstanceUID())
        databases.append(database)
        if cancelsDuringRetrieve { Thread.current.cancel() }
    }
}

enum QueryController {
    static var answers: [String?] = []
    static var asked: [[AnyHashable: Any]] = []
    static var showedErrors = false
    static func queryStudies(forFilters filters: [AnyHashable: Any]!, servers: [Any]!, showErrors: Bool) -> NSMutableArray! {
        asked.append(filters ?? [:])
        showedErrors = showedErrors || showErrors
        return NSMutableArray(array: answers.map { DCMTKStudyQueryNode($0) })
    }
}

enum ViewerOpener {
RETRIEVE_FUNCTION
}
'''

RETRIEVE_MAIN = r'''
import Foundation

var failures: [String] = []
func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

/// Runs the retrieve on a thread of its own, as the application does, and waits for it.
func retrieve(_ uids: [String], _ database: DicomDatabase, _ retrieves: DistantStudyRetrieves, _ graph: ProcessGraph) -> Double {
    QueryController.asked = []
    let done = DispatchSemaphore(value: 0)
    let began = Date()
    let thread = Thread {
        ViewerOpener.retrieveWorkspaceStudies(uids, into: database, retrieves: retrieves, graph: graph)
        done.signal()
    }
    thread.start()
    if done.wait(timeout: .now() + 20) == .timedOut { failures.append("the retrieve did not return in 20 s"); return 20 }
    return Date().timeIntervalSince(began)
}

func asked() -> [String] { QueryController.asked.map { $0["StudyInstanceUID"] as? String ?? "?" } }

let database = DicomDatabase()
let graph = ProcessGraph()
graph.activeLocalDatabase = database

// A node that answers more than it was asked.
var retrieves = DistantStudyRetrieves()
QueryController.answers = ["1.2.9", "1.2.3", nil, "1.2.8"]
_ = retrieve(["1.2.3"], database, retrieves, graph)
check(asked() == ["1.2.3"], "the node was asked \(asked()), not the study of the workspace")
check(QueryController.asked.first?.count == 1, "the node was asked more than the study's UID")
check(retrieves.retrieved == ["1.2.3"], "a node that answered four studies had \(retrieves.retrieved) retrieved, not the one asked for")
check(retrieves.databases.count == 1 && retrieves.databases[0] === database, "the study was not retrieved into the database of the opening")
check(!QueryController.showedErrors, "a node that does not answer shows an alert")

// A node that does not have the study.
retrieves = DistantStudyRetrieves()
QueryController.answers = ["1.2.9", "1.2.8"]
_ = retrieve(["1.2.3"], database, retrieves, graph)
check(retrieves.retrieved.isEmpty, "a node without the study had \(retrieves.retrieved) retrieved")
QueryController.answers = []
_ = retrieve(["1.2.3"], database, retrieves, graph)
check(retrieves.retrieved.isEmpty, "a node that found nothing had \(retrieves.retrieved) retrieved")

// Two studies, each asked and retrieved in turn.
retrieves = DistantStudyRetrieves()
QueryController.answers = ["1.2.3", "1.2.4"]
_ = retrieve(["1.2.3", "1.2.4"], database, retrieves, graph)
check(asked() == ["1.2.3", "1.2.4"] && retrieves.retrieved == ["1.2.3", "1.2.4"], "two studies were asked \(asked()) and retrieved \(retrieves.retrieved)")

// A thread cancelled during the first retrieve asks for nothing more.
retrieves = DistantStudyRetrieves()
retrieves.cancelsDuringRetrieve = true
_ = retrieve(["1.2.3", "1.2.4"], database, retrieves, graph)
check(asked() == ["1.2.3"] && retrieves.retrieved == ["1.2.3"], "a cancelled thread went on: asked \(asked()), retrieved \(retrieves.retrieved)")

// A study already on its way is waited for, not asked for twice.
retrieves = DistantStudyRetrieves()
retrieves.busy = "1.2.3"
retrieves.busyAnswers = 3
let waited = retrieve(["1.2.3", "1.2.4"], database, retrieves, graph)
check(asked() == ["1.2.4"] && retrieves.retrieved == ["1.2.4"], "a study being retrieved already was asked for again: asked \(asked()), retrieved \(retrieves.retrieved)")
check(retrieves.busyAsked >= 4 && waited >= 0.3, "a study being retrieved already was not waited for (asked \(retrieves.busyAsked) times in \(waited) s)")

// No node, or another database active: nothing is asked.
retrieves = DistantStudyRetrieves()
let noNode = ProcessGraph()
noNode.activeLocalDatabase = database
noNode.pacsOnDemand.nodes.servers = []
_ = retrieve(["1.2.3"], database, retrieves, noNode)
check(asked().isEmpty && retrieves.retrieved.isEmpty, "with no comparative node the study was asked for")
let elsewhere = ProcessGraph()
elsewhere.activeLocalDatabase = DicomDatabase()
_ = retrieve(["1.2.3"], database, retrieves, elsewhere)
check(asked().isEmpty && retrieves.retrieved.isEmpty, "with another active database the study was asked for")

for failure in failures { print("FAIL: \(failure)") }
if failures.isEmpty { print("as expected") }
exit(failures.isEmpty ? 0 : 1)
'''


def build(tmp, name, inputs, version):
    try:
        subprocess.run(['xcrun', 'swiftc', '-swift-version', version, '-module-name', 'Horos', '-g', *[str(i) for i in inputs],
                        '-o', str(tmp / name)], check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        fail(f'the {name} harness did not build: ' + (e.stderr or b'').decode(errors='replace')[-3000:])
    return tmp / name


def outcome(command, claim, failures):
    try:
        result = subprocess.run([str(c) for c in command], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        failures.append(f'{claim}: timed out')
        return
    lines = [line for line in (result.stdout + result.stderr).splitlines() if line.strip()]
    if result.returncode == 0:
        print('ok:', claim)
    else:
        detail = '; '.join(line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')) or \
            (lines[-1] if lines else f'exit {result.returncode}')
        failures.append(f'{claim}: {detail}')


failures = []
with tempfile.TemporaryDirectory(prefix='horos-workspace-node-studies-') as tmp:
    tmp = Path(tmp)

    wait = tmp / 'wait'
    wait.mkdir()
    for path in (WAIT, ACTIVITY, CALLBACKS):
        (wait / Path(path).name).write_text(source(path))
    (wait / 'Stubs.swift').write_text(WAIT_STUBS)
    (wait / 'main.swift').write_text(WAIT_MAIN)
    harness = build(wait, 'wait', sorted(wait.glob('*.swift')), '6')
    for case, claim in WAIT_CASES:
        outcome([harness, case], 'wait - ' + claim, failures)

    retrieve = tmp / 'retrieve'
    retrieve.mkdir()
    body = function(opener, '    nonisolated static func retrieveWorkspaceStudies(')
    (retrieve / 'Stubs.swift').write_text(RETRIEVE_STUBS.replace('RETRIEVE_FUNCTION', body))
    (retrieve / 'main.swift').write_text(RETRIEVE_MAIN)
    harness = build(retrieve, 'retrieve', sorted(retrieve.glob('*.swift')), '5')
    outcome([harness], 'retrieve - only the study asked for is retrieved, once, into the database of the opening; '
            'a cancelled thread, no node or another database ask nothing more', failures)

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: a study whose workspace needs studies of a node waits for them away from the main thread, '
      'and opens when they arrive, when the retrieve is cancelled or when the time runs out')
