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
lasts until it ends. Move to Top starts a waiting retrieve ahead of those
under way: the one started last yields and resumes right after it, in
Sequential and in Parallel with a limit, nothing yields in Parallel without
one, and a request to yield that is no longer needed is withdrawn; a real
thread under way stops its transfer, waits in line again and resumes, and one
cancelled by the user ends. Finally checks that the Q&R window sends its retrieves
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

// Move to Top starts a retrieve ahead of the one under way, in Sequential:
// that one is asked to yield, counts as under way until its transfer has
// stopped, and then waits first in line to resume.
var p = RetrieveQueue.State()
_ = (1...3).map { p.submit($0, explicitlyQueued: false, policy: sequential) }
check(p.canStartAhead(2) && p.canStartAhead(3) && !p.canStartAhead(1) && !p.canStartAhead(9), "any waiting retrieve can start ahead, the first in line too")
check(p.startAhead(3, policy: sequential) && p.waiting.map { $0.id } == [3, 2], "put ahead: first in line")
check(p.mustYield(1) && p.isRunning(1) && !p.isRunning(3), "the one under way is asked to yield and counts until it has")
check(!p.startAhead(3, policy: sequential) && !p.canStartAhead(3) && !p.startAhead(1, policy: sequential), "nothing to do twice, nor for one under way")
check(!p.move(2, to: 0) && p.waiting.map { $0.id } == [3, 2], "another waiting retrieve does not pass the one put ahead")
check(p.yielded(1, policy: sequential) == [3] && p.waiting.map { $0.id } == [1, 2], "it yields: the other starts, and it waits first in line")
check(p.isInterrupted(1) && !p.mustYield(1) && !p.isInterrupted(2) && p.position(1) == 1, "it waits to resume")
check(p.remove(3, policy: sequential) == [1] && !p.isInterrupted(1), "and resumes when the other ends")
check(p.remove(1, policy: sequential) == [2] && p.remove(2, policy: sequential).isEmpty && p.running.isEmpty, "then the rest of the line")
// The first in line starts ahead too.
var f = RetrieveQueue.State()
_ = (1...2).map { f.submit($0, explicitlyQueued: false, policy: sequential) }
check(f.startAhead(2, policy: sequential) && f.mustYield(1) && f.yielded(1, policy: sequential) == [2] && f.isInterrupted(1), "first in line, ahead of the one under way")
// A request to yield is withdrawn when it is no longer needed: the retrieve
// under way ended first, the one put ahead was cancelled, or moved back down.
var w = RetrieveQueue.State()
_ = (1...3).map { w.submit($0, explicitlyQueued: false, policy: sequential) }
check(w.startAhead(3, policy: sequential) && w.remove(1, policy: sequential) == [3] && w.yielding.isEmpty && !w.mustYield(3), "the one under way ended first")
check(w.startAhead(2, policy: sequential) && w.mustYield(3) && w.remove(2, policy: sequential).isEmpty && !w.mustYield(3), "the one put ahead was cancelled")
var v = RetrieveQueue.State()
_ = (1...3).map { v.submit($0, explicitlyQueued: false, policy: sequential) }
check(v.startAhead(3, policy: sequential) && v.move(3, to: 1) && v.waiting.map { $0.id } == [2, 3] && !v.mustYield(1), "moved back down: it waits its turn")
// A transfer that stopped after the request was withdrawn goes on at once.
check(v.yielded(1, policy: sequential) == [1] && v.isRunning(1) && !v.isInterrupted(1) && v.waiting.map { $0.id } == [2, 3], "stopped for nothing: it starts again")
check(v.yielded(9, policy: sequential).isEmpty, "only a retrieve under way yields")
// Parallel with a limit of 2: the one started last yields; a second one put
// ahead takes the other; those that yielded resume as there is room.
var k = RetrieveQueue.State()
_ = (1...4).map { k.submit($0, explicitlyQueued: false, policy: limit2) }
check(k.startAhead(4, policy: limit2) && k.mustYield(2) && !k.mustYield(1), "limit 2: the one started last yields")
check(k.startAhead(3, policy: limit2) && k.mustYield(1) && k.mustYield(2) && k.waiting.map { $0.id } == [3, 4], "a second one: the other yields too")
check(k.yielded(2, policy: limit2) == [3] && k.mustYield(1) && k.waiting.map { $0.id } == [4, 2], "one yields, the first put ahead starts")
check(k.yielded(1, policy: limit2) == [4] && k.waiting.map { $0.id } == [1, 2] && k.yielding.isEmpty, "the other yields, the second starts")
check(k.remove(3, policy: limit2) == [1] && k.remove(4, policy: limit2) == [2], "those that yielded resume")
// A retrieve started after another is the one that yields, whatever its number.
var n = RetrieveQueue.State()
_ = [5, 6, 7].map { n.submit($0, explicitlyQueued: false, policy: limit2) }
check(n.remove(5, policy: limit2) == [7] && n.submit(8, explicitlyQueued: false, policy: limit2) == false, "6 and 7 under way, 8 waits")
check(n.startAhead(8, policy: limit2) && n.mustYield(7) && !n.mustYield(6), "the last started yields")
// A raised limit makes room: nobody yields any more.
check(n.promote(policy: P(sequential: false, limit: 3)) == [8] && n.yielding.isEmpty, "room made by the preferences withdraws the request")
// Parallel without a limit: the one moved to the top starts, nothing yields.
var u = RetrieveQueue.State()
check(u.submit(1, explicitlyQueued: false, policy: unlimited) && !u.submit(2, explicitlyQueued: true, policy: unlimited) && !u.submit(3, explicitlyQueued: true, policy: unlimited), "two Command retrieves wait")
check(u.startAhead(3, policy: unlimited) && u.isRunning(3) && u.isRunning(1) && u.yielding.isEmpty && u.waiting.map { $0.id } == [2], "no limit: it just starts")
// What a retrieve of several items had ended before it yielded.
let itemA = NSObject(), itemB = NSObject()
let turns = RetrieveQueue.Turns([itemA, itemB])
check(turns.remaining.count == 2 && !turns.hasEnded(itemA), "nothing ended yet")
turns.markEnded(itemA)
check(turns.hasEnded(itemA) && !turns.hasEnded(itemB) && turns.remaining.count == 1 && (turns.remaining[0] as AnyObject) === itemB, "the ended item is not asked for again")

// The rows of Activity: the waiting ones trade the places they hold among
// themselves, in the order of the line; the others stay where they are.
let rows = ["running", "third", "import", "first", "second"]
let places = ["third": 3, "first": 1, "second": 2]
check(RetrieveQueue.arranged(rows) { places[$0] } == ["running", "first", "import", "second", "third"], "rows follow the line")
check(RetrieveQueue.arranged(["a", "b"]) { ["b": 1][$0] } == ["a", "b"], "one waiting row stays")
check(RetrieveQueue.arranged(["a", "b"]) { _ in nil } == ["a", "b"], "no waiting row, no change")
// A drop between rows: the place in line is the waiting rows above the gap,
// the dragged one aside.
let waits = [false, true, false, true, true]
check(RetrieveQueue.index(ofRow: 4, droppedAbove: 0, waits: waits) == 0, "dropped at the top of the list: first in line")
check(RetrieveQueue.index(ofRow: 4, droppedAbove: 3, waits: waits) == 1, "dropped above the second waiting row")
check(RetrieveQueue.index(ofRow: 1, droppedAbove: 5, waits: waits) == 2, "dropped at the end: last in line")
check(RetrieveQueue.index(ofRow: 1, droppedAbove: 2, waits: waits) == 0, "dropped just below itself: no move")
var d = RetrieveQueue.State()
_ = (1...4).map { d.submit($0, explicitlyQueued: false, policy: sequential) }
check(d.move(4, to: RetrieveQueue.index(ofRow: 3, droppedAbove: 1, waits: [false, true, true, true])) && d.waiting.map { $0.id } == [4, 2, 3], "a row dragged to the top goes first")

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
check(shared.move(second, toIndex: 1) && [fourth, second, third].map { shared.position(of: $0) } == [1, 2, 3], "a dragged row moves to an index")
check(shared.move(second, toIndex: 2) && !shared.move(second, toIndex: 2) && !shared.move(first, toIndex: 1), "and back; nothing to move twice or under way")
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

// Real threads, still in Sequential: the retrieve under way yields to the one
// moved to the top, waits in line again and resumes right after it.
var story: [String] = []
let storyLock = NSLock()
func tell(_ line: String) { storyLock.lock(); story.append(line); storyLock.unlock() }
let told = DispatchGroup()
// The thread of a transfer, as the window starts it: handed over before it starts.
func startThread(_ configure: (Thread) -> Void, _ transfer: @escaping @Sendable () -> Void) -> Thread {
    let thread = Thread(block: transfer)
    configure(thread)
    thread.start()
    return thread
}
func retrieve(_ name: String, _ ticket: RetrieveQueue.Ticket, work: TimeInterval) {
    told.enter()
    Thread {
        var turn = 0
        while true {
            let resumed = shared.isInterrupted(ticket)
            guard shared.waitForTurn(ticket) else { tell("\(name) left"); break }
            turn += 1
            let number = turn
            let back = shared.runTurn(ticket, pollInterval: 0.02, start: startThread, willYield: { tell("\(name) asked") }) {
                tell("\(name) turn \(number)\(resumed ? " resumed" : "")")
                let end = Date().addingTimeInterval(work)
                while Date() < end && !Thread.current.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                tell(Thread.current.isCancelled ? "\(name) stopped" : "\(name) ended")
            }
            if !back { break }
        }
        shared.finish(ticket)
        told.leave()
    }.start()
}
let yielder = shared.ticket(explicitlyQueued: false)
let patient = shared.ticket(explicitlyQueued: false)
let urgent = shared.ticket(explicitlyQueued: false)
retrieve("first", yielder, work: 0.8)
retrieve("patient", patient, work: 0.1)
retrieve("urgent", urgent, work: 0.2)
Thread.sleep(forTimeInterval: 0.3)
check(shared.canMoveToTop(urgent) && shared.canMoveToTop(patient) && !shared.canMoveToTop(yielder), "Move to Top serves the waiting ones")
check(shared.move(.top, urgent) && !shared.canMoveToTop(urgent) && !shared.move(.top, urgent), "Move to Top, once")
check(told.wait(timeout: .now() + 10) == .success, "the retrieves ended")
check(story == ["first turn 1", "first asked", "first stopped", "urgent turn 1", "urgent ended",
                "first turn 2 resumed", "first ended", "patient turn 1", "patient ended"], "the one under way yields and resumes: \(story)")
check(shared.waitingCount == 0 && !shared.isInterrupted(yielder), "the queue is empty again")
// Stopped by the user in its turn, a retrieve cancels its transfer and ends;
// one with nothing left to ask for does not go back in line.
story = []
let stopped = shared.ticket(explicitlyQueued: false)
let nothingLeft = shared.ticket(explicitlyQueued: false)
var looks = 0
let stoppedRow = Thread {
    let back = shared.runTurn(stopped, pollInterval: 0.02, start: startThread, whileRunning: { thread in if RetrieveQueue.ticket(of: thread) === stopped { looks += 1 } }) {
        while !Thread.current.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
        tell("stopped transfer cancelled")
    }
    tell("stopped back in line: \(back)")
    shared.finish(stopped)
}
told.enter()
Thread {
    _ = shared.waitForTurn(nothingLeft)
    let back = shared.runTurn(nothingLeft, pollInterval: 0.02, start: startThread, resumes: { false }) {
        while !Thread.current.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
    }
    tell("nothing left back in line: \(back)")
    shared.finish(nothingLeft)
    told.leave()
}.start()
stoppedRow.start()
Thread.sleep(forTimeInterval: 0.2)
stoppedRow.cancel()
Thread.sleep(forTimeInterval: 0.3)
let last = shared.ticket(explicitlyQueued: false)
check(shared.isRunning(nothingLeft) && shared.move(.top, last), "a retrieve put ahead of one that has all it asked for")
check(told.wait(timeout: .now() + 10) == .success, "it ended")
check(story == ["stopped transfer cancelled", "stopped back in line: false", "nothing left back in line: false"], "cancelled or complete, not back in line: \(story)")
check(looks > 2 && shared.isRunning(last), "the transfer's thread is looked at while it runs; the one put ahead starts")
shared.finish(last)
UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)

if failures > 0 { exit(1) }
print("PASS: Parallel, limit, Sequential and Command follow the rule; waiting threads run in turn or leave when cancelled; Activity reorders and names the waiting ones; a retrieve under way yields to one moved to the top and resumes")
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
    ('self.performQueuedRetrieve(items.items, ticket: ticket, status: status)', 'the thread waits for its turn'),
    ('queue.waitForTurn(ticket, whileWaiting:', 'performQueuedRetrieve: waits'),
    ('queue.finish(ticket)', 'performQueuedRetrieve: makes room'),
    ('let back = queue.runTurn(ticket, start: { configure, transfer in', 'performQueuedRetrieve: the transfer has a thread of its own each turn'),
    ('ActivityThread.startUnlisted(name: retrieve.name ?? "", configure: { thread in', 'the thread of a transfer is not a second line in Activity'),
    ('thread.status = retrieve.status', 'the thread of a transfer begins with what the line shows'),
    ('}, resumes: { !turns.remaining.isEmpty }) {', 'a retrieve with nothing left to ask for does not go back in line'),
    ('self.performRetrieve(handed.items, turns: turns)', 'each turn knows what the ones before it ended'),
    ('guard back else { break }', 'a retrieve that yielded waits for its turn again'),
    ('RetrieveQueueActivity.resumingStatus(status, position: position)', 'a line that yielded says it waits to resume'),
    ('node?.setShowErrorMessage(false)', 'a transfer cancelled to yield raises no cancellation notice'),
    ('retrieve.progressDetails = transfer.progressDetails', "the line shows what the transfer's thread reports"),
    ('if turns?.hasEnded(object) == true {', 'an item that ended before the retrieve yielded is not asked for again'),
    ('if !Thread.current.isCancelled { turns?.markEnded(object) }', 'only a transfer that was not cancelled has ended'),
    ('for (item, count) in zip(items, inTransfer) where !turns.hasEnded(item as AnyObject) {', 'what waits to resume stays in transfer'),
    ('RetrieveQueueArrows.install(on: outlineView, column: "Button")', 'the arrows follow Command'),
    ('@objc(queueRetrieveOfItem:)\n    func queueRetrieveOfItem(_ item: Any?) {', 'Command queues the clicked row'),
]:
    if needle not in controller:
        failures.append(f'QueryController: {what}')
queued = controller[controller.index('nonisolated func performQueuedRetrieve('):controller.index('public nonisolated func performRetrieve(_ array: [Any]!)')]
if queued.index('queue.finish(ticket)') < queued.index('self.performRetrieve(handed.items, turns: turns)'):
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
for needle, what in [
    ('RetrieveQueue.arranged(rows, position: queuePosition)', 'the rows follow the line'),
    ('pasteboardWriterForRow row: Int', 'a waiting row can be dragged'),
    ('validateDrop info: NSDraggingInfo', 'a drop is checked'),
    ('RetrieveQueue.shared.move(ticket, toIndex: RetrieveQueue.index(ofRow: dragged, droppedAbove: row, waits: waits))', 'a drop moves the retrieve in the line'),
    ('registerForDraggedTypes([Self.queuedRowType])', 'the list takes its own rows'),
    ('if helper?.canDragRow(row(at: convert(evt.locationInWindow, from: nil))) == true { super.mouseDown(with: evt) }', 'only a waiting row takes the click that drags'),
]:
    if needle not in activity:
        failures.append(f'Activity: {what}')
if 'if let row = (self.view?.delegate as? BrowserActivityHelper)?.row(of: self) { return row }' not in source_text('ThreadCell'):
    failures.append('a line draws its status at its thread\'s place among the threads, not on its own row')
menu = source_text('RetrieveQueueActivity')
for title in ['"Move to Top"', '"Move Up"', '"Move Down"', '"Rename…"']:
    if title not in menu:
        failures.append(f'the Activity menu lacks {title}')
for needle, what in [
    ('.top, queue.canMoveToTop(ticket)),', 'Move to Top serves the first in line too, ahead of the download in progress'),
    ('if move == .top { item.toolTip = moveToTopHelp }', 'Move to Top says what it does to the download in progress'),
    ('"Interrupted, waiting to resume (%ld) - %@"', 'the status of a download that waits to resume'),
]:
    if needle not in menu:
        failures.append(f'Activity menu: {what}')

outline = source_text('QueryOutlineView')
if not ('#selector(QueryController.queueRetrieveOfItem(_:))' in outline or 'Selector(("queueRetrieveOfItem:"))' in outline) or 'tableColumns[clickedColumn].identifier.rawValue == "Button"' not in outline:
    failures.append('QueryOutlineView does not send a Command-click on a download arrow to the queue')

pane = source_text('OSILocationsPreferencePanePref')
if 'QueryRetrieveDownloadSettings.install(below: characterSetPopup, in: mainView)' not in pane:
    failures.append('Settings > Locations does not install the Q&R download rows')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the Q&R window queues its retrieves and Settings > Locations sets the queue')
