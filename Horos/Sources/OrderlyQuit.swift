//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// Who asks the application to quit, as far as quitting treats them apart.
enum QuitRoute: Sendable, Equatable {
    /// A person at this Mac, or a script: the Quit command, the Dock, a quit
    /// Apple event with no reason. Questions may be put to them.
    case person
    /// The system, which is logging out, restarting or shutting down. Nobody
    /// has to be there, and a question left unanswered would cancel what the
    /// system is doing for every application: no question is put.
    case sessionEnd

    /// The attribute of a quit Apple event that says why the system sends it
    /// ('why?'). A quit a person asks for has none.
    private static let reasonKeyword: AEKeyword = 0x7768_793F

    /// Whether the Apple event being handled is the system's quit for the end
    /// of the session.
    @MainActor private static var handlesSessionEndEvent: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        return event.attributeDescriptor(forKeyword: reasonKeyword) != nil
    }

    /// The route of the request the application delegate is answering now.
    /// The Apple event says it while it is the current one; AppKit may ask the
    /// delegate once the event's handler has returned, and then the notice of
    /// the workspace, posted for the same event, says it.
    @MainActor static func current(notice: SessionEndNotice) -> QuitRoute {
        handlesSessionEndEvent || notice.isRecent ? .sessionEnd : .person
    }
}

/// The workspace's notice that the session is ending, kept with its time: a
/// log out that another application cancelled leaves the notice behind, and a
/// quit asked much later is a person's again.
@MainActor final class SessionEndNotice {
    /// A quit event follows its notice at once; a minute covers a Mac busy
    /// with every other application quitting at the same time.
    static let validity: TimeInterval = 60

    private var received: Date?
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil) { [weak self] _ in
                onMainActor { [weak self] in self?.received = Date() }
            }
    }

    var isRecent: Bool {
        guard let received else { return false }
        return Date().timeIntervalSince(received) < Self.validity
    }
}

/// How long quitting waits for what it stops.
///
/// Each stop has its own limit, so that one thread that never ends does not
/// take the time of the others, and all of them share one. At the end of the
/// session the system waits for the application only so long and then cancels
/// the log out, the restart or the shut down. The reference gives no figure
/// for that wait; reports of it put it at about half a minute, and the shared
/// limit is then half of that. What has not stopped by its deadline is left to
/// the exit, as it was before.
struct QuitTimeLimits: Sendable, Equatable {
    /// What one stop may take.
    let each: TimeInterval
    /// What all the stops may take together.
    let total: TimeInterval

    static let person = QuitTimeLimits(each: 10, total: 30)
    static let sessionEnd = QuitTimeLimits(each: 10, total: 15)

    static func limits(for route: QuitRoute) -> QuitTimeLimits {
        route == .sessionEnd ? .sessionEnd : .person
    }

    /// The deadline of a stop that begins now, the stops having begun at `start`.
    func deadline(since start: Date, now: Date = Date()) -> Date {
        min(now.addingTimeInterval(each), start.addingTimeInterval(total))
    }
}

/// The orderly end of the application, the same whoever asks for it.
///
/// AppKit asks the application delegate before every orderly end: the Quit
/// command, the Dock, a quit Apple event, a log out, a restart, a shut down.
/// The answer is "later": the incoming import, the DICOM listeners and the
/// background threads are stopped, and only then is AppKit told to go on to
/// `exit()`, which destroys the static objects those threads read.
///
/// The waits run off the main thread, on a queue of their own. The main thread goes on serving its
/// run loop, in the mode AppKit keeps while it waits for the reply, so a thread
/// that needs the main thread to end can end, and nothing waits on the main
/// queue: the reply comes from the main run loop, which is served also when
/// AppKit asked from inside a block of that queue.
@MainActor final class OrderlyQuit {
    /// What the application delegate answers AppKit.
    enum Answer: Sendable, Equatable {
        /// Everything is stopped: terminate.
        case now
        /// The reply follows the stops.
        case later
        /// A quit is already under way; this request adds nothing to it. That
        /// holds for the end of the session too: while a question of the Quit
        /// command is on screen a person is looking at it, the system's
        /// request is answered "cancel", and the system then reports that the
        /// application cancelled the log out.
        case cancel
    }

    enum Phase: Sendable, Equatable {
        case idle
        /// The questions are on screen.
        case asking
        /// The questions were answered before AppKit asked.
        case agreed
        case stopping
        case stopped
    }

    /// What quitting does, given by the application: the type decides only
    /// the order, the thread and that each step happens once.
    struct Work {
        /// Whether quitting may go on. With `asking` false no question is put:
        /// what a question would protect is given up, as if Quit were answered.
        var agrees: @MainActor (_ asking: Bool) -> Bool
        /// The first step once quitting is agreed: what is done at once on
        /// the main thread, before any wait.
        var begin: @MainActor () -> Void
        /// Refuses new imports of the incoming folder and cancels those under
        /// way, without waiting.
        var stopImports: @MainActor () -> Void
        /// Stops the DICOM listeners and waits for their threads until the
        /// deadline; whether they ended.
        var stopListeners: @Sendable (_ deadline: Date) -> Bool
        /// Cancels the background threads still listed; how many there are.
        var cancelThreads: @Sendable () -> Int
        /// Waits for the imports to leave until the deadline; whether they did.
        var waitForImports: @Sendable (_ deadline: Date) -> Bool
        /// The last step, on the main thread, once everything has stopped.
        var end: @MainActor () -> Void
        /// Tells AppKit whether to terminate, after `Answer.later`.
        var reply: @MainActor (_ terminate: Bool) -> Void
        /// Runs a block from the main run loop (`onMainRunLoop`).
        var fromMainRunLoop: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
        var log: @Sendable (String) -> Void
    }

    private let work: Work
    /// The waits of the stops: a queue of its own, whose thread may block for
    /// as long as the limits give without taking one from anything else.
    private let waits = DispatchQueue(label: "OrderlyQuit.waits")
    private(set) var phase = Phase.idle

    init(work: Work) {
        self.work = work
    }

    /// The Quit command puts its questions at once, from the menu's action.
    /// False when the answer is no, or when a quit is already under way.
    func agreeNow() -> Bool {
        guard phase == .idle else { return false }
        phase = .asking
        let agreed = work.agrees(true)
        // A request that arrived while the questions were on screen was
        // answered "cancel" and changed nothing.
        phase = agreed ? .agreed : .idle
        return agreed
    }

    /// The questions were put and answered elsewhere: the next request stops
    /// and terminates without asking again.
    func agree() {
        if phase == .idle { phase = .agreed }
    }

    /// AppKit did not ask after all (it refuses while a modal window is up):
    /// the agreement does not wait for a later request.
    func withdrawAgreement() {
        if phase == .agreed { phase = .idle }
    }

    /// AppKit asks whether the application may terminate.
    func request(_ route: QuitRoute) -> Answer {
        switch phase {
        case .stopped:
            return .now
        case .asking, .stopping:
            return .cancel
        case .idle, .agreed:
            let agreed = phase == .agreed
            phase = agreed ? .stopping : .asking
            // Not from here: AppKit may be asking from inside a block of the
            // main queue, where a question's modal loop would hold the queue.
            work.fromMainRunLoop { self.proceed(route, agreed: agreed) }
            return .later
        }
    }

    private func proceed(_ route: QuitRoute, agreed: Bool) {
        if !agreed {
            guard work.agrees(route == .person) else {
                phase = .idle
                work.reply(false)
                return
            }
            phase = .stopping
        }
        work.begin()
        work.stopImports()

        let limits = QuitTimeLimits.limits(for: route)
        let start = Date()
        let stopListeners = work.stopListeners, cancelThreads = work.cancelThreads
        let waitForImports = work.waitForImports, fromMainRunLoop = work.fromMainRunLoop, log = work.log
        waits.async {
            if !stopListeners(limits.deadline(since: start)) {
                log("DICOM listener still running at its deadline; quitting anyway")
            }
            let threadsDeadline = limits.deadline(since: start)
            while cancelThreads() > 0, Date() < threadsDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !waitForImports(limits.deadline(since: start)) {
                log("incoming import still running at its deadline; quitting anyway")
            }
            fromMainRunLoop { self.stopsEnded() }
        }
    }

    private func stopsEnded() {
        work.end()
        phase = .stopped
        work.reply(true)
    }
}
