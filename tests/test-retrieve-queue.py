#!/usr/bin/env python3
"""Query & Retrieve download queue: the rule, the threads, and the wiring.

Compiles RetrieveQueue.swift and checks Parallel without a limit (clicks at
once, Command behind every retrieve under way, one at a time), Parallel with a
limit (beyond it, in line), Sequential (one at a time), a cancelled or failed
retrieve making room, and a raised limit starting those waiting. Then real
threads wait their turn and one cancelled while waiting leaves the line.
Activity moves a waiting retrieve to the top, up or down without touching
those under way, a moved retrieve keeps its place as the others end, a waiting
thread hears its place each time it changes, and a name given to a retrieve
lasts until it ends. Finally checks that the Q&R window sends its retrieves
through the queue, that Command turns the arrows and queues the clicked row,
that Activity offers the moves and the name on a queued line, and that
Settings › Locations installs the two rows.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

from sources import class_text, source_text

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

// Reordering, in Sequential: one under way, three waiting.
var m = RetrieveQueue.State()
_ = (1...4).map { m.submit($0, explicitlyQueued: false, policy: sequential) }
check(m.waiting.map { $0.id } == [2, 3, 4] && m.position(4) == 3 && m.position(1) == nil, "positions")
check(m.move(4, to: 0) && m.waiting.map { $0.id } == [4, 2, 3], "move to top")
check(!m.move(1, to: 0), "a retrieve under way does not move")
check(!m.move(4, to: -1) && m.move(2, to: 5) && m.waiting.map { $0.id } == [4, 3, 2], "moves stay within the line")
check(m.remove(1, policy: sequential) == [4], "the one moved to the top starts next")
check(m.remove(3, policy: sequential).isEmpty && m.waiting.map { $0.id } == [2], "removing a waiting one keeps the order")
check(m.remove(4, policy: sequential) == [2], "and the last one is promoted")

// The shared queue in Sequential: Move to Top on the third, names, and the
// place a waiting thread hears.
// In the argument domain: nothing is written to the preferences.
UserDefaults.standard.setVolatileDomain([RetrieveQueue.modeKey: 1], forName: UserDefaults.argumentDomain)
let first = shared.ticket(explicitlyQueued: false)
let second = shared.ticket(explicitlyQueued: false)
let third = shared.ticket(explicitlyQueued: false)
let fourth = shared.ticket(explicitlyQueued: false)
check(shared.isRunning(first) && [second, third, fourth].map { shared.position(of: $0) } == [1, 2, 3] && shared.waitingCount == 3, "three waiting behind one")
var heard: [Int] = []
let heardLock = NSLock()
let fourthDone = DispatchGroup()
fourthDone.enter()
Thread {
    _ = shared.waitForTurn(fourth) { position in heardLock.lock(); heard.append(position); heardLock.unlock() }
    shared.finish(fourth)
    fourthDone.leave()
}.start()
Thread.sleep(forTimeInterval: 0.4)
check(shared.move(.top, third) && [third, second, fourth].map { shared.position(of: $0) } == [1, 2, 3], "Move to Top")
check(!shared.move(.up, third) && !shared.move(.top, first), "nothing above the first in line, nothing to move under way")
check(shared.move(.down, third) && shared.move(.up, third) && shared.position(of: third) == 1, "Move Down and Move Up")
check(shared.move(.top, fourth) && shared.position(of: fourth) == 1, "the waiting thread moves too")
Thread.sleep(forTimeInterval: 0.4)
shared.setLabel("  Chest CT  ", of: second)
check(shared.label(of: second) == "Chest CT", "a name, trimmed")
shared.setLabel("", of: third)
check(shared.label(of: third) == nil, "an empty name gives back the usual one")
shared.finish(first)
check(fourthDone.wait(timeout: .now() + 5) == .success, "the moved thread ran next")
heardLock.lock(); check(heard == [3, 1], "the waiting thread heard its places: \(heard)"); heardLock.unlock()
check(shared.isRunning(third) && shared.position(of: second) == 1, "then the one moved to the top before")
shared.finish(third)
check(shared.isRunning(second), "then the last")
shared.finish(second)
check(shared.label(of: second) == nil, "the name ends with the retrieve")
UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)

if failures > 0 { exit(1) }
print("PASS: Parallel, limit, Sequential and Command follow the rule; waiting threads run in turn or leave when cancelled; Activity reorders and names the waiting ones")
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

controller = class_text('QueryController')
for needle, what in [
    ('if showGUI && !forViewing && !onlyIfNotAvailable {', 'only the retrieves asked for in the window are queued'),
    ('RetrieveQueue.shared.ticket(explicitlyQueued: explicitlyQueued)', 'a ticket per retrieve'),
    ('#selector(performQueuedRetrieve(_:))', 'the thread waits for its turn'),
    ('RetrieveQueue.shared.waitForTurn(ticket, whileWaiting:', 'performQueuedRetrieve: waits'),
    ('RetrieveQueue.shared.finish(ticket)', 'performQueuedRetrieve: makes room'),
    ('RetrieveQueueArrows.install(on: outlineView, column: "Button")', 'the arrows follow Command'),
    ('@objc(queueRetrieveOfItem:)\n    func queueRetrieveOfItem(_ item: Any?) {', 'Command queues the clicked row'),
]:
    if needle not in controller:
        failures.append(f'QueryController: {what}')
queued = controller[controller.index('nonisolated func performQueuedRetrieve('):controller.index('public nonisolated func performRetrieve(_ array: [Any]!)')]
if queued.index('finish(ticket)') < queued.index('performRetrieve(items)'):
    failures.append('performQueuedRetrieve: makes room before its retrieve ends')

for needle, what in [
    ('thread.threadDictionary[RetrieveQueue.threadKey] = ticket', 'Activity finds the ticket of a queued line'),
    ('waitForTurn(ticket, whileWaiting: { position in', 'a waiting line shows its place'),
    ('RetrieveQueueActivity.waitingStatus(status, position: position)', 'the waiting status gives the place'),
    ('Thread.current.name = (label ?? "").isEmpty ? NSLocalizedString("Retrieving images...", comment: "") : label', 'a renamed retrieve keeps its name once it runs'),
]:
    if needle not in controller:
        failures.append(f'QueryController: {what}')
activity = source_text('BrowserController+Activity')
if 'RetrieveQueueActivity.menu(for: thread)' not in activity or 'NSMenu.popUpContextMenu(menu, with: evt, for: self)' not in activity:
    failures.append('the Activity list does not offer the queue menu on a line')
menu = source_text('RetrieveQueueActivity')
for title in ['"Move to Top"', '"Move Up"', '"Move Down"', '"Rename…"']:
    if title not in menu:
        failures.append(f'the Activity menu lacks {title}')

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
