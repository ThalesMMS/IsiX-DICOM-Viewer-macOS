#!/usr/bin/env python3
"""Query & Retrieve download queue: the rule, the threads, and the wiring.

Compiles RetrieveQueue.swift and checks Parallel without a limit (clicks at
once, Command behind every retrieve under way, one at a time), Parallel with a
limit (beyond it, in line), Sequential (one at a time), a cancelled or failed
retrieve making room, and a raised limit starting those waiting. Then real
threads wait their turn and one cancelled while waiting leaves the line.
Finally checks that the Q&R window sends its retrieves through the queue,
that Command turns the arrows and queues the clicked row, and that Settings ›
Locations installs the two rows.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

from sources import source_text

root = Path(__file__).resolve().parents[1]
queue = source_text('RetrieveQueue')

driver = r'''
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failures += 1 }
}
typealias P = RetrieveQueue.Policy
let unlimited = P(sequential: false, limit: nil)
let limit2 = P(sequential: false, limit: 2)
let sequential = P(sequential: true, limit: 4)

// Parallel without a limit: clicks start at once.
var s = RetrieveQueue.State()
check((1...3).allSatisfy { s.submit($0, explicitlyQueued: false, policy: unlimited) }, "clicks run in parallel")
// Command: behind every retrieve under way, then one at a time.
check(!s.submit(4, explicitlyQueued: true, policy: unlimited), "Command waits while retrieves run")
check(!s.submit(5, explicitlyQueued: true, policy: unlimited), "second Command waits too")
check(s.submit(6, explicitlyQueued: false, policy: unlimited), "a click still starts at once")
check(s.remove(1, policy: unlimited).isEmpty && s.remove(2, policy: unlimited).isEmpty && s.remove(3, policy: unlimited).isEmpty, "Command waits for all")
check(s.remove(6, policy: unlimited) == [4], "first Command starts when nothing runs")
check(s.remove(4, policy: unlimited) == [5], "then the second")
check(s.remove(5, policy: unlimited).isEmpty && s.running.isEmpty && s.waiting.isEmpty, "queue empties")
var e = RetrieveQueue.State()
check(e.submit(1, explicitlyQueued: true, policy: unlimited), "Command with nothing running starts at once")

// Parallel with a limit of 2: four clicks, two run, two wait, in order.
var l = RetrieveQueue.State()
let started = (1...4).map { l.submit($0, explicitlyQueued: false, policy: limit2) }
check(started == [true, true, false, false], "limit 2: \(started)")
check(!l.submit(5, explicitlyQueued: true, policy: limit2), "Command behind them")
check(l.remove(2, policy: limit2) == [3], "a finished retrieve makes room for the first in line")
check(l.remove(4, policy: limit2).isEmpty && l.waiting.map { $0.id } == [5], "a cancelled waiting retrieve leaves the line")
check(l.remove(1, policy: limit2) == [5], "Command follows the limit rule")
// A raised limit starts those waiting.
var r = RetrieveQueue.State()
_ = (1...5).map { r.submit($0, explicitlyQueued: false, policy: limit2) }
check(r.promote(policy: P(sequential: false, limit: 4)) == [3, 4], "raised limit")

// Sequential: one at a time, whatever the limit says.
var q = RetrieveQueue.State()
check((1...3).map { q.submit($0, explicitlyQueued: false, policy: sequential) } == [true, false, false], "sequential")
check(q.remove(1, policy: sequential) == [2], "next one")

// Preferences: the defaults reproduce today's behaviour.
let defaults = UserDefaults(suiteName: "horos-retrieve-queue-test-\(getpid())")!
check(P.current(defaults) == unlimited, "default is Parallel without a limit")
defaults.set(true, forKey: RetrieveQueue.limitEnabledKey)
check(P.current(defaults) == P(sequential: false, limit: 4), "limit defaults to 4")
defaults.set(1, forKey: RetrieveQueue.modeKey)
check(P.current(defaults).capacity(explicitlyQueued: false) == 1, "Sequential")
defaults.removePersistentDomain(forName: "horos-retrieve-queue-test-\(getpid())")

// Real threads, on the shared queue with the standard defaults (Parallel,
// no limit): one click running, two Command retrieves, the second cancelled
// while it waits.
let shared = RetrieveQueue.shared
let running = shared.ticket(explicitlyQueued: false)
let queued = shared.ticket(explicitlyQueued: true)
let cancelled = shared.ticket(explicitlyQueued: true)
check(shared.isRunning(running) && !shared.isRunning(queued) && !shared.isRunning(cancelled), "tickets")
var log: [String] = []
let lock = NSLock()
let done = DispatchGroup()
func start(_ name: String, _ ticket: RetrieveQueue.Ticket) -> Thread {
    done.enter()
    let thread = Thread {
        let turn = shared.waitForTurn(ticket)
        lock.lock(); log.append("\(name) \(turn ? "ran" : "left")"); lock.unlock()
        if turn { Thread.sleep(forTimeInterval: 0.1) }
        shared.finish(ticket)
        done.leave()
    }
    thread.start()
    return thread
}
_ = start("queued", queued)
let toCancel = start("cancelled", cancelled)
Thread.sleep(forTimeInterval: 0.4)
lock.lock(); check(log.isEmpty, "nothing ran while a retrieve is under way: \(log)"); lock.unlock()
toCancel.cancel()
Thread.sleep(forTimeInterval: 0.6)
lock.lock(); check(log == ["cancelled left"], "the cancelled one left the line: \(log)"); lock.unlock()
shared.finish(running)
check(done.wait(timeout: .now() + 5) == .success, "threads ended")
check(log == ["cancelled left", "queued ran"], "order: \(log)")

if failures > 0 { exit(1) }
print("PASS: Parallel, limit, Sequential and Command follow the rule; waiting threads run in turn or leave when cancelled")
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-retrieve-queue-') as directory:
    work = Path(directory)
    (work / 'RetrieveQueue.swift').write_text(queue)
    (work / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                            str(work / 'RetrieveQueue.swift'), str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True, timeout=300)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(1)
    run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=60)
    print(run.stdout.strip())
    if run.returncode:
        failures.append('queue rule or threads')

controller = source_text('QueryController')
for needle, what in [
    ('if( showGUI && forViewing == NO && onlyIfNotAvailable == NO)', 'only the retrieves asked for in the window are queued'),
    ('[[HorosRetrieveQueue sharedQueue] ticketExplicitlyQueued: explicitlyQueued]', 'a ticket per retrieve'),
    ('@selector(performQueuedRetrieve:)', 'the thread waits for its turn'),
    ('[[HorosRetrieveQueue sharedQueue] waitForTurn: ticket]', 'performQueuedRetrieve: waits'),
    ('[[HorosRetrieveQueue sharedQueue] finish: ticket];', 'performQueuedRetrieve: makes room'),
    ('[HorosRetrieveQueueArrows installOnOutlineView: outlineView column: @"Button"];', 'the arrows follow Command'),
    ('- (void) queueRetrieveOfItem:(id) item', 'Command queues the clicked row'),
]:
    if needle not in controller:
        failures.append(f'QueryController: {what}')
queued = controller[controller.index('- (void) performQueuedRetrieve:'):controller.index('- (void) performRetrieve:(NSArray*) array')]
if queued.index('finish: ticket') < queued.index('performRetrieve: items'):
    failures.append('performQueuedRetrieve: makes room before its retrieve ends')

outline = source_text('QueryOutlineView')
if 'Selector(("queueRetrieveOfItem:"))' not in outline or 'tableColumns[clickedColumn].identifier.rawValue == "Button"' not in outline:
    failures.append('QueryOutlineView does not send a Command-click on a download arrow to the queue')

pane = source_text('OSILocationsPreferencePanePref')
if 'QueryRetrieveDownloadSettings.install(below: characterSetPopup, in: mainView)' not in pane:
    failures.append('Settings > Locations does not install the Q&R download rows')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the Q&R window queues its retrieves and Settings > Locations sets the queue')
