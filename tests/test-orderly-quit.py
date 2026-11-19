#!/usr/bin/env python3
"""Every orderly end of the application makes the same stops before exit().

A quit that arrives as an Apple event (the Dock, a script, a log out, a
restart, a shut down) goes to -[NSApplication terminate:] without passing the
Quit command. The stops of quitting were in the Quit command only: on the
other routes exit() destroyed DCMTK's static loggers while the DICOM listener
thread was still in its loop, reading them, and the application crashed while
quitting.

What must stay true:

- AppKit's question before every orderly end, -applicationShouldTerminate:,
  reaches OrderlyQuit, which answers "later", stops the incoming import, the
  listeners and the background threads, waits for the import, and only then
  replies;
- the stops are the same, in the same order and made once, whether the Quit
  command, an Apple event of a person or the end of the session asked; the end
  of the session puts no question;
- the waits are not on the main thread, which goes on serving its run loop;
- a second request while the questions are on screen or the stops under way
  adds nothing and is answered "cancel"; a refusal leaves the application as
  it was, able to quit later;
- the Quit command keeps its questions where they were and has no stops of its
  own: it goes on through the same question of AppKit.

OrderlyQuit is compiled and run against stops that record their order.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []


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


def statements(block):
    return [line.strip() for line in block.splitlines()[1:-1] if line.strip() and not line.strip().startswith('//')]


controller = source_text('AppController')
lifecycle = source_text('ApplicationLifecycle')
order = source_text('OrderlyQuit')

asked = body(controller, '@objc(applicationShouldTerminate:) func applicationShouldTerminate(_ sender: NSApplication!) -> NSApplication.TerminateReply')
check(statements(asked) == ['lifecycle.shouldTerminate()'],
      "the application delegate does not hand AppKit's question to the lifecycle")
check(statements(body(controller, '@IBAction @objc(terminate:) public func terminate(_ sender: Any!)')) == ['lifecycle.terminate(sender)'],
      '-[AppController terminate:] no longer is the Quit command of the lifecycle')

answer = body(lifecycle, 'func shouldTerminate() -> NSApplication.TerminateReply')
check('quit.request(QuitRoute.current(notice: sessionEndNotice))' in answer, "AppKit's question does not reach OrderlyQuit with its route")
for case, reply in (('.now', '.terminateNow'), ('.later', '.terminateLater'), ('.cancel', '.terminateCancel')):
    check(re.search(r'case \%s: return \%s\b' % (case, reply), answer), 'the answer %s is not %s' % (case, reply))

command = statements(body(lifecycle, 'func terminate(_ sender: Any?)'))
check(command == ['guard quit.agreeNow() else { return }', 'finishTermination(sender)'],
      'the Quit command does not put its questions once and go on to the rest of quitting')
rest = statements(body(lifecycle, 'func finishTermination(_ sender: Any?)'))
check(rest == ['quit.agree()', 'NSApp.terminate(sender)', 'quit.withdrawAgreement()'],
      "the rest of quitting has something other than AppKit's own termination, agreed beforehand")
# One copy of each stop, in what OrderlyQuit is given.
work = body(lifecycle, 'private func makeQuit() -> OrderlyQuit')
for stop in ('databaseIngest.stop()', '.stopListeners(before:', 'cleanupFinishedThreads(nil)', 'waitUntilIdle(before:',
             'NSApp.reply(toApplicationShouldTerminate:'):
    check(lifecycle.count(stop) == 1 and stop in work, '%s is not made in one place, the stops given to OrderlyQuit' % stop)
check('agrees: { [unowned self] asking in BrowserQuitAgreement(browser: self.browser).given(asking: asking) }' in work,
      'the questions of quitting are not those of the database window')
check('fromMainRunLoop: { body in onMainRunLoop(body) }' in work,
      'the questions and the reply do not come from the main run loop')
# What belongs to the termination itself stays there.
will = body(lifecycle, 'func willTerminate()')
check('controller.destroyDCMTK()' in will and 'browser?.browserPrepareForClose()' in will and 'stopListeners' not in will,
      '-applicationWillTerminate: no longer does what is its own')

request = body(order, 'func request(_ route: QuitRoute) -> Answer')
check('work.agrees' not in request and 'work.begin' not in request,
      "something is done inside AppKit's question, where a modal loop may hold the main queue")
window = (root / 'Horos/Sources/BrowserController+Window.swift').read_text()
agreement = body(source_text('BrowserQuitAgreement'), 'func given(asking: Bool) -> Bool')
check(statements(body(window, 'func shouldTerminate(_ sender: Any!) -> Bool')) == ['BrowserQuitAgreement(browser: self).given(asking: true)'],
      '-[BrowserController shouldTerminate:] no longer asks as before')
check(len(re.findall(r'\bif asking && ', agreement)) == 2 and agreement.count('runModal()') + agreement.count('runInformational(') == 2,
      'a question of quitting is put when nobody is asked, or a new one is not')
# Before the database window exists there is nothing to ask, on any route: the
# Quit command agrees as an Apple event does.
check(statements(agreement)[:1] == ['guard let browser else { return true }'],
      'the agreement refuses, or asks, when there is no database window')
check(0 <= agreement.find('DatabaseRebuildService.waitForRebuildsBeforeQuitting()') < agreement.find('if asking && '),
      'the wait for a rebuild of the index depends on someone being asked')

# Nothing terminates the application behind the path: a direct termination that
# follows a question of its own would ask the database window a second time.
# What quits goes through the Quit command (-[AppController terminate:]) or,
# once the database window has agreed, through the rest of quitting.
DIRECT = re.compile(r'\bNSApp\s*\.\s*terminate\s*\(|\bNSApplication\s*\.\s*shared\s*\.\s*terminate\s*\('
                    r'|\[\s*(?:NSApp|\[\s*NSApplication\s+sharedApplication\s*\]|NSApplication\s*\.\s*sharedApplication)\s+terminate\s*:')
# Each exception with its reason.
DIRECT_ALLOWED = {
    # The one place that hands the agreed quit to AppKit, which then asks
    # -applicationShouldTerminate: and gets the stops.
    'Horos/Sources/ApplicationLifecycle.swift': 1,
    # The Quit button of the alert about a database of an unknown model, while
    # a database is being opened: that may be during the launch, before the
    # application has its delegate, so there is no Quit command to send. Nothing
    # was asked of the database window before it: AppKit's question asks it
    # once and makes the stops once.
    'Horos/Sources/DatabaseModelUpgrade.swift': 1,
}
from sources import FOLDERS  # noqa: E402
found = {}
for folder in FOLDERS:
    for path in sorted((root / folder).rglob('*')):
        if path.suffix not in ('.swift', '.m', '.mm') or not path.is_file():
            continue
        lines = [line for line in path.read_bytes().decode('utf-8', 'replace').splitlines()
                 if not line.lstrip().startswith('//')]
        count = sum(len(DIRECT.findall(line)) for line in lines)
        if count:
            found[str(path.relative_to(root))] = count
check(found == DIRECT_ALLOWED,
      'the application is terminated outside the one path of quitting (expected %s, found %s)' % (DIRECT_ALLOWED, found))
check(DIRECT.search('NSApp.terminate(nil)') and DIRECT.search('NSApplication.shared.terminate(self)')
      and DIRECT.search('[NSApp terminate: self]') and DIRECT.search('[[NSApplication sharedApplication] terminate:nil]')
      and not DIRECT.search('controller.terminate(controller)') and not DIRECT.search('#selector(NSApplication.terminate(_:))'),
      'the search for direct terminations no longer finds them')
check('processGraph.appController?.lifecycle.finishTermination(self)' in body(source_text('ICloudDriveDetector'), 'private func relaunch()'),
      'the relaunch after the database window agreed does not go on to the rest of quitting')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='latin1')
for name in ('OrderlyQuit', 'BrowserQuitAgreement'):
    check('%s.swift in Sources' % name in project, '%s.swift is not in the application target' % name)

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

driver = r'''
import AppKit

func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message) }
}

final class Record: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

/// What one scenario is given and what it saw.
@MainActor final class Scenario {
    let record = Record()
    var quit: OrderlyQuit!
    var agreement = true
    /// How many threads each count finds: two, then one, then none.
    nonisolated(unsafe) var threadCounts = [2, 1, 0]
    /// Answers of requests made while the stops were under way.
    nonisolated(unsafe) var answersWhileStopping: [OrderlyQuit.Answer] = []
    nonisolated(unsafe) var agreedWhileStopping = true
    nonisolated(unsafe) var waitsOnMain = false
    nonisolated(unsafe) var mainServedDuringWait = false
    nonisolated(unsafe) var listenerDeadline = Date.distantPast
    nonisolated(unsafe) var replies = 0

    init() {
        let record = record
        quit = OrderlyQuit(work: OrderlyQuit.Work(
            agrees: { [unowned self] asking in record.add(asking ? "ask" : "agree without asking"); return agreement },
            begin: { record.add("begin") },
            stopImports: { record.add("stop imports") },
            stopListeners: { [unowned self] deadline in
                record.add("stop listeners")
                listenerDeadline = deadline
                if Thread.isMainThread { waitsOnMain = true }
                // The main thread is not held by the wait: it answers this
                // thread, and a second request made meanwhile changes nothing.
                let served = DispatchSemaphore(value: 0)
                onMainRunLoop { [unowned self] in
                    answersWhileStopping.append(quit.request(.person))
                    answersWhileStopping.append(quit.request(.sessionEnd))
                    agreedWhileStopping = quit.agreeNow()
                    served.signal()
                }
                mainServedDuringWait = served.wait(timeout: .now() + 5) == .success
                Thread.sleep(forTimeInterval: 0.1)
                return true
            },
            cancelThreads: { [unowned self] in
                record.add("cancel threads")
                if Thread.isMainThread { waitsOnMain = true }
                return threadCounts.removeFirst()
            },
            waitForImports: { [unowned self] _ in
                record.add("wait for imports")
                if Thread.isMainThread { waitsOnMain = true }
                return true
            },
            end: { record.add("end") },
            reply: { [unowned self] terminate in
                record.add(terminate ? "reply yes" : "reply no")
                replies += 1
                CFRunLoopStop(CFRunLoopGetMain())
            },
            fromMainRunLoop: { body in onMainRunLoop(body) },
            log: { message in record.add("log: " + message) }))
    }

    /// Serves the main run loop until the reply, as AppKit does after "later".
    func serveUntilReply() {
        let before = replies
        let limit = Date(timeIntervalSinceNow: 20)
        while replies == before, Date() < limit {
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        expect(replies == before + 1, "no reply, or more than one: \(replies - before)")
    }
}

let stops = ["begin", "stop imports", "stop listeners", "cancel threads", "cancel threads", "cancel threads",
             "wait for imports", "end", "reply yes"]

do { // a quit Apple event of a person: the Dock, a script
    let scenario = Scenario()
    let start = Date()
    expect(scenario.quit.request(.person) == .later, "an Apple event quit is not answered later")
    expect(scenario.record.all.isEmpty, "something is done inside AppKit's question: \(scenario.record.all)")
    expect(scenario.quit.request(.person) == .cancel, "a second request before the questions is not cancelled")
    scenario.serveUntilReply()
    expect(scenario.record.all == ["ask"] + stops, "Apple event route: \(scenario.record.all)")
    expect(!scenario.waitsOnMain, "a wait ran on the main thread")
    expect(scenario.mainServedDuringWait, "the main thread was held while the listeners were stopped")
    expect(scenario.answersWhileStopping == [.cancel, .cancel], "a request while stopping was not cancelled: \(scenario.answersWhileStopping)")
    expect(!scenario.agreedWhileStopping, "the Quit command asked again while stopping")
    expect(scenario.quit.phase == .stopped, "not stopped after the reply")
    expect(scenario.quit.request(.person) == .now, "once stopped, AppKit is not told to terminate now")
    expect(scenario.listenerDeadline.timeIntervalSince(start) > 9 && scenario.listenerDeadline.timeIntervalSince(start) < 11,
           "the listeners do not get ten seconds on a person's quit")
    let entries = scenario.record.all.count
    CFRunLoopRunInMode(.defaultMode, 0.3, false)
    expect(scenario.record.all.count == entries, "something ran again after the reply")
}

do { // the end of the session: the same stops, no question
    let scenario = Scenario()
    expect(scenario.quit.request(.sessionEnd) == .later, "the end of the session is not answered later")
    scenario.serveUntilReply()
    expect(scenario.record.all == ["agree without asking"] + stops, "end of session route: \(scenario.record.all)")
    expect(!scenario.waitsOnMain, "a wait ran on the main thread at the end of the session")
}

do { // the Quit command: asked from the menu, then the same stops, not asked again
    let scenario = Scenario()
    expect(scenario.quit.agreeNow(), "the Quit command was refused")
    expect(scenario.record.all == ["ask"], "the Quit command did not ask at once")
    expect(!scenario.quit.agreeNow(), "the Quit command asked twice")
    expect(scenario.quit.request(.person) == .later, "the Quit command is not answered later")
    scenario.serveUntilReply()
    expect(scenario.record.all == ["ask"] + stops, "Quit command route: \(scenario.record.all)")
}

do { // asked elsewhere (the installation of an update), and an agreement AppKit never used
    let scenario = Scenario()
    scenario.quit.agree()
    scenario.quit.withdrawAgreement()
    expect(scenario.quit.phase == .idle, "an agreement AppKit did not use stays")
    scenario.quit.agree()
    expect(scenario.quit.request(.person) == .later, "an agreed quit is not answered later")
    scenario.quit.withdrawAgreement()
    scenario.serveUntilReply()
    expect(scenario.record.all == stops, "agreed route: \(scenario.record.all)")
}

do { // a refusal: no stop, and quitting stays possible
    let scenario = Scenario()
    scenario.agreement = false
    expect(scenario.quit.request(.person) == .later, "a request to be refused is not answered later")
    scenario.serveUntilReply()
    expect(scenario.record.all == ["ask", "reply no"], "refusal: \(scenario.record.all)")
    expect(scenario.quit.phase == .idle, "a refusal does not leave the application as it was")
    expect(!scenario.quit.agreeNow(), "the Quit command went on after a refusal")
    scenario.agreement = true
    expect(scenario.quit.request(.person) == .later, "no quit after a refusal")
    scenario.serveUntilReply()
    expect(scenario.record.all == ["ask", "reply no", "ask", "ask"] + stops, "quit after refusals: \(scenario.record.all)")
}

do { // the time the stops get
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let person = QuitTimeLimits.limits(for: .person), session = QuitTimeLimits.limits(for: .sessionEnd)
    expect(person.deadline(since: start, now: start) == start.addingTimeInterval(10), "a stop of a person's quit does not get 10 s")
    expect(person.deadline(since: start, now: start.addingTimeInterval(25)) == start.addingTimeInterval(30),
           "a person's quit may wait more than 30 s in all")
    expect(session.deadline(since: start, now: start) == start.addingTimeInterval(10), "a stop at the end of the session does not get 10 s")
    expect(session.deadline(since: start, now: start.addingTimeInterval(10)) == start.addingTimeInterval(15),
           "the end of the session may wait more than 15 s in all")
    expect(session.total < 30, "the end of the session waits as long as the system does")
}

print("done")
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(root / 'Horos/Sources/OrderlyQuit.swift'),
                            str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                            str(folder / 'main.swift'), '-o', str(folder / 'check')], capture_output=True, text=True)
    check(build.returncode == 0, 'OrderlyQuit.swift and its driver compile\n' + build.stderr[-3000:])
    if build.returncode == 0:
        run = subprocess.run([str(folder / 'check')], capture_output=True, text=True, timeout=120)
        check(run.returncode == 0 and run.stdout.strip().endswith('done'), 'the driver runs\n' + run.stdout + run.stderr[-2000:])
        failures.extend(line[len('FAIL: '):] for line in run.stdout.splitlines() if line.startswith('FAIL: '))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the Quit command, an Apple event and the end of the session make the same stops once, off the main thread, '
      'and reply after them')
