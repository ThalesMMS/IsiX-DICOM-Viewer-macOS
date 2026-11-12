/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import Synchronization
import IsiXPreferences
import IsiXDICOMNetwork

/// The DICOM listeners' life cycle: starting the plain and the TLS listener as
/// the preferences say, taking new settings while the application runs,
/// stopping them for a session that is switched away and when quitting, and
/// the DICOM Bonjour advertisement that goes with them.
///
/// The life cycle is on the main actor, where the Listener preferences are
/// bound: the titles are written there only. Each listener runs on a thread of
/// its own, because DCMTK's accept loop blocks for as long as the listener
/// lives; that thread reads nothing but the settings it was given. What the
/// listener threads and the readers of the session's state touch is
/// nonisolated: the running listeners under a mutex, the session under an
/// atomic.
@MainActor
final class DICOMListenerController {

    private nonisolated let processGraph: ProcessGraph

    /// Made by the process graph, the one listener controller of the process.
    nonisolated init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    private nonisolated var preferences: UserDefaults {
        processGraph.preferences
    }

    // MARK: - State

    /// The running listeners, each set by its own thread once it has made it,
    /// and the listener threads started and not yet holding their lock: until
    /// they hold it, waiting on that lock proves nothing.
    private struct Running {
        var plain: DCMTKQueryRetrieveSCP?
        var tls: DCMTKQueryRetrieveSCP?
        var pendingStarts = 0
    }
    private nonisolated let running = Mutex(Running())

    /// The settings the running listeners were started with.
    private var appliedSettings: ListenerSettings?
    /// Set while the listeners stop to take new settings; a change made
    /// meanwhile is applied when that has ended.
    private var applyingSettings = false
    private var settingsChangedMeanwhile = false

    /// Read by the database's cleaning and the browser, from any thread;
    /// written on the main thread when the session switches.
    private nonisolated let sessionInactive = Atomic<Bool>(false)
    nonisolated var isSessionInactive: Bool {
        get { sessionInactive.load(ordering: .relaxed) }
        set { sessionInactive.store(newValue, ordering: .relaxed) }
    }
    /// How long a session that comes back leaves the one it replaces to give
    /// up the listener's ports, before it starts its own listeners.
    private static let sessionPortHandover: TimeInterval = 4
    /// The session's switches so far: a restart still waiting when the session
    /// resigns again is dropped.
    private var sessionSwitches = 0
    private var sessionObservers: [NSObjectProtocol] = []

    /// The DICOM service this process advertises, as an NSNetService for the
    /// callers typed on it; it is never published itself: two registrations of
    /// one name and port would make the daemon rename one of them.
    private(set) var bonjourService: NetService?
    /// The DNS-SD advertisement of the listener (`_dicom._tcp`).
    private(set) var bonjourAdvertisement: BonjourAdvertisement?

    /// The two listeners as they are now.
    nonisolated func listeners() -> (plain: DCMTKQueryRetrieveSCP?, tls: DCMTKQueryRetrieveSCP?) {
        running.withLock { ($0.plain, $0.tls) }
    }

    /// Whether a listener of this process, or another one it was told of
    /// (NinjaSTORESCP), receives what a C-MOVE sends here. Any thread.
    nonisolated var isListening: Bool {
        let listeners = listeners()
        return listeners.plain?.running() == true || listeners.tls?.running() == true
            || preferences[NetworkPreferences.externalStoreSCP]
    }

    // MARK: - Titles

    /// The host's name as AETITLE, written only when it changes. Main thread
    /// only: the Listener preferences bind AETITLE, and a default written on
    /// another thread notifies their bindings on that thread.
    func setAETitleToHostname() {
        var name = [CChar](repeating: 0, count: Int(_POSIX_HOST_NAME_MAX) + 1)
        gethostname(&name, Int(_POSIX_HOST_NAME_MAX))
        let title = ListenerAETitle.fromHostName(name.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) })
        if preferences[NetworkPreferences.aeTitle] != title {
            preferences.set(title, for: NetworkPreferences.aeTitle)
        }
    }

    /// Stores the titles the listeners are about to answer to, on the main
    /// thread, so that their threads only read them: the host's name when it
    /// is asked for, the title derived at launch the first time, and titles cut
    /// to 16 characters.
    private func storeListenerTitles() {
        if preferences[ListenerPreferences.usesHostNameForAETitle] {
            setAETitleToHostname()
        }

        // Until it is stored, AETITLE is a registered default computed from the
        // computer's name at every launch - so renaming the Mac renames the
        // listener, and the remote nodes configured with the old title stop
        // being able to send to it. Nothing said so. Store it the first time,
        // so what the listener answers to is a value the user can see and keep.
        let aeTitle = NetworkPreferences.aeTitle
        if Bundle.main.bundleIdentifier.flatMap({ preferences.persistentDomain(forName: $0) })?[aeTitle.name] == nil,
           let derived = preferences[aeTitle], derived.isEmpty == false {
            preferences.set(derived, for: aeTitle)
            NSLog("--- DICOM listener AE title was not stored; it is now \"%@\", taken from this computer's name. It will no longer change if the computer is renamed.", derived as NSString)
        }

        for key in [aeTitle, ListenerPreferences.tlsAETitle] {
            let title = preferences[key]
            if let limited = ListenerAETitle.limited(title), limited != title {
                preferences.set(limited, for: key)
            }
        }
    }

    // MARK: - Starting and stopping

    /// Starts the listeners the preferences ask for, and the DICOM Bonjour
    /// advertisement five seconds later. It is called restart because a
    /// listener may still run; it must have stopped, or a listener that
    /// cannot take its lock says so. Every start of the listeners comes here.
    func restart() {
        NSLog("restartSTORESCP")

        if ProtectedMode.isActive {
            ProtectedMode.skip("DICOM listener (with and without TLS) and DICOM Bonjour publishing")
            markListenersNotStarted(ListenerStatus.protectedModeReason)
            return
        }

        storeListenerTitles()

        // The built-in listener is the only one: USESTORESCP stays on.
        if preferences[NetworkPreferences.usesStoreSCP] == false {
            preferences.set(true, for: NetworkPreferences.usesStoreSCP)
        }
        let settings = ListenerSettings(preferences: preferences)
        start(tls: false, settings: settings)
        start(tls: true, settings: settings)

        withdrawBonjour()
        if settings.publishesBonjour {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishBonjour() }
            }
        }
    }

    /// Starts one listener on a thread of its own when the settings turn it on.
    private func start(tls: Bool, settings: ListenerSettings) {
        guard tls ? settings.tlsListener : settings.storeSCP else {
            ListenerStatus.setOff(tls: tls)
            return
        }
        running.withLock { if tls { $0.tls = nil } else { $0.plain = nil } }

        // The listener's folder must exist before anything arrives.
        let path = DatabaseIngest.process.incomingFolderPath(of: DicomDatabase.activeLocal())
        FileManager.default.confirmNoIndexDirectory(atPath: path)

        let lock = tls ? STORESCPTLS : STORESCP
        if lock?.try() == true {
            ListenerStatus.setStarting(tls: tls)
            running.withLock { $0.pendingStarts += 1 }
            Self.startThread(named: tls ? "DICOM Store-SCP TLS" : "DICOM Store-SCP") { [self] in
                serve(tls: tls, settings: settings)
            }
            lock?.unlock()
        } else {
            ListenerStatus.setNotListening(reason: ListenerStatus.stillStoppingReason, tls: tls)
            if tls {
                HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM TLS Listener Error", comment: ""), message: NSLocalizedString("Cannot start DICOM TLS Listener. Another thread is already running. Restart IsiX DICOM Viewer.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Listener Error", comment: ""), message: NSLocalizedString("Cannot start DICOM Listener. Another thread is already running. Restart IsiX DICOM Viewer.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }

    /// A listener's thread: it holds the listener's lock for as long as it
    /// runs and makes the listener after taking it, so a lock taken means the
    /// thread has left the listener. The titles were stored on the main thread
    /// before it started; a default written here would notify the Listener
    /// preferences' bindings on this thread.
    private nonisolated func serve(tls: Bool, settings: ListenerSettings) {
        let lock = tls ? STORESCPTLS : STORESCP
        lock?.lock()
        running.withLock { $0.pendingStarts -= 1 }

        let aeTitle = tls ? settings.tlsAETitle : settings.aeTitle
        let port = tls ? settings.tlsPort : settings.port
        // The DCMTK adapter's accept loop rethrows an NSException raised while
        // it starts an association's thread; it ends here, not the process.
        if let exception = HorosObjCException.caught({
            let listener = DCMTKQueryRetrieveSCP(port: port, aeTitle: aeTitle, extraParamaters: ["TLSEnabled": NSNumber(value: tls)])
            running.withLock { if tls { $0.tls = listener } else { $0.plain = listener } }
            listener.run()
        }) {
            LogText.log(exception, stack: true, in: tls ? "DICOMListenerController.serve (TLS)" : "DICOMListenerController.serve")
            ListenerStatus.setNotListening(reason: ListenerStatus.internalErrorReason(exception.reason), tls: tls)
        }

        lock?.unlock()
    }

    /// Starts `body` on a thread of its own named `name`. A listener's thread
    /// blocks in DCMTK's accept loop for the listener's whole life, and the
    /// stop of the listeners waits on their locks for as long as their
    /// associations last: neither belongs on a queue or in the cooperative pool.
    private nonisolated static func startThread(named name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.start()
    }

    /// The listeners the preferences ask for are not started, for `reason`;
    /// the others are off.
    private func markListenersNotStarted(_ reason: String) {
        for (key, tls) in [(NetworkPreferences.storeSCP, false), (ListenerPreferences.tlsListener, true)] {
            if preferences[key] {
                ListenerStatus.setNotListening(reason: reason, tls: tls)
            } else {
                ListenerStatus.setOff(tls: tls)
            }
        }
    }

    /// Records the settings the running listeners were started with.
    func noteAppliedSettings() {
        appliedSettings = ListenerSettings(preferences: preferences)
    }

    /// Restarts the listeners when their settings differ from those they were
    /// started with: on, off, another port, title or timeout.
    func applySettingsIfChanged() {
        if ListenerSettings(preferences: preferences) != appliedSettings {
            applySettings()
        }
    }

    /// Stops the listeners and starts them as the settings now say. A listener
    /// leaves its accept loop within a second, then waits for its
    /// associations, which end, or stop at their next command or timeout; that
    /// wait is not the main thread's.
    private func applySettings() {
        if applyingSettings {
            settingsChangedMeanwhile = true
            return
        }
        applyingSettings = true
        NSLog("--- DICOM listener settings changed: stopping the listeners to apply them")

        Self.startThread(named: "DICOM listener settings") { [self] in
            _ = stopListeners(before: .distantFuture)

            // From the main run loop: restarting may show an alert.
            onMainRunLoop { [self] in
                running.withLock {
                    $0.plain = nil
                    $0.tls = nil
                }
                applyingSettings = false
                appliedSettings = ListenerSettings(preferences: preferences)
                // A session that is not the active one keeps its listener
                // stopped; it starts when the session comes back.
                if isSessionInactive == false || preferences[NetworkPreferences.runListenerOnlyIfActive] == false {
                    restart()
                } else {
                    markListenersNotStarted(ListenerStatus.inactiveSessionReason)
                }
                if settingsChangedMeanwhile {
                    settingsChangedMeanwhile = false
                    applySettingsIfChanged()
                }
            }
        }
    }

    /// Aborts the listeners and waits, until the deadline, for their threads
    /// to end. Each listener thread holds its lock for as long as it runs, and
    /// makes its listener after taking it: each listener is asked once, and a
    /// lock taken means its thread has left the listener, association workers
    /// joined. Returns whether both threads ended in time.
    nonisolated func stopListeners(before deadline: Date) -> Bool {
        while running.withLock({ $0.pendingStarts }) > 0 {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        var asked: DCMTKQueryRetrieveSCP? = nil
        let threads: [(NSRecursiveLock?, () -> DCMTKQueryRetrieveSCP?)] = [
            (STORESCP, { self.listeners().plain }), (STORESCPTLS, { self.listeners().tls })]
        for (lock, listener) in threads {
            while lock?.lock(before: min(deadline, Date(timeIntervalSinceNow: 0.05))) == false {
                if let listener = listener(), listener !== asked { listener.abort(); asked = listener }
                if Date() >= deadline { return false }
            }
            lock?.unlock()
        }
        return true
    }

    /// Aborts the listeners and the incoming transfers; with `wait`, waits for
    /// each listener to leave its loop. The listener's server waits at most a
    /// second for an association before it reads the abort, so nothing has to
    /// wake it. The C-ECHO that used to be sent to the listener's own port
    /// found it already closed and held the main thread until the connection
    /// timed out.
    func stopListeners(wait: Bool) {
        let listeners = listeners()
        listeners.plain?.abort()
        listeners.tls?.abort()

        abortIncomingTransfers()

        if wait {
            while self.listeners().plain?.running() ?? false {
                NSLog("waiting for listener to stop...")
                Thread.sleep(forTimeInterval: 0.1)
            }
            while self.listeners().tls?.running() ?? false {
                NSLog("waiting for TLS listener to stop...")
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        running.withLock {
            $0.plain = nil
            $0.tls = nil
        }
    }

    /// Aborts every DICOM association under way, the listener's and the
    /// sends', and gives them three seconds to end, with the listener's errors
    /// hidden meanwhile.
    func abortIncomingTransfers() {
        let wait = WaitRendering(NSLocalizedString("Abort Incoming DICOM processes...", comment: ""))
        wait?.showWindow(nil)

        Self.whileListenerErrorsHidden(in: preferences) {
            _ = HorosDICOMGlobalAbortBegin()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))

            wait?.close()

            HorosDICOMGlobalAbortEnd()
        }
    }

    /// Runs `body` with hideListenerError on, the user's own value kept under
    /// copyHideListenerError meanwhile, which a launch after a crash puts back.
    /// A hideListenerError given at launch is that launch's alone: nothing is
    /// written then.
    nonisolated static func whileListenerErrorsHidden(in preferences: UserDefaults, _ body: () -> Void) {
        let persists = preferences.isGivenAsLaunchArgument(NetworkPreferences.hidesListenerErrors) == false
        let hidden = preferences[NetworkPreferences.hidesListenerErrors]
        if persists {
            preferences.set(hidden, for: ListenerPreferences.savedHidesListenerErrors)
            preferences.set(true, for: NetworkPreferences.hidesListenerErrors)
            preferences.synchronize()
        }

        body()

        if persists {
            preferences.set(hidden, for: NetworkPreferences.hidesListenerErrors)
            preferences.remove(ListenerPreferences.savedHidesListenerErrors)
            preferences.synchronize()
        }
    }

    /// Says a listener's error in the notices panel, unless hideListenerError
    /// asks for silence. A sheet held the database window until it was
    /// dismissed, once per failed association.
    func reportListenerError(_ message: String) {
        NSLog("*** listener error (displayListenerError): %@", message as NSString)
        if preferences[NetworkPreferences.hidesListenerErrors] == false {
            NetworkNotices.post(title: NSLocalizedString("DICOM Listener Error", comment: ""), message: message)
        }
    }

    // MARK: - The session

    /// Follows the switches of the user's session (fast user switching).
    func observeSessionSwitches() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sessionObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let name = notification.name
                MainActor.assumeIsolated { self?.sessionSwitched(name) }
            })
        }
    }

    /// With RunListenerOnlyIfActive, a session switched away stops its
    /// listeners, and starts them again when it comes back.
    private func sessionSwitched(_ name: Notification.Name) {
        if name == NSWorkspace.sessionDidResignActiveNotification {
            sessionSwitches += 1
            _ = processGraph.browserDatabase?.save(nil)

            if preferences[NetworkPreferences.runListenerOnlyIfActive] {
                NSLog("----- Horos : session deactivation: STOP DICOM LISTENER FOR THIS SESSION")

                // Said first: the listeners end as off unless a reason was given.
                markListenersNotStarted(ListenerStatus.inactiveSessionReason)
                stopListeners(wait: true)

                isSessionInactive = true
            }
        } else if name == NSWorkspace.sessionDidBecomeActiveNotification {
            sessionSwitches += 1
            // Only a listener stopped for the session has ports to wait for.
            // The wait used to be four seconds of the main thread at every
            // return to the session, whether or not anything had been stopped.
            guard isSessionInactive || preferences[NetworkPreferences.runListenerOnlyIfActive] else { return }

            // The session stays inactive for its readers until the listeners
            // start; from the main run loop, as restarting may show an alert.
            let awaited = sessionSwitches
            let handover = Timer(timeInterval: Self.sessionPortHandover, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sessionSwitches == awaited else { return }
                    self.isSessionInactive = false
                    NSLog("----- Horos : session activation: START DICOM LISTENER FOR THIS SESSION")
                    self.restart()
                }
            }
            RunLoop.main.add(handover, forMode: .common)
        }
    }

    // MARK: - Bonjour

    /// Advertises the listener over DNS-SD, as the database's advertisement
    /// does: it refuses a port that is not one, takes the name the daemon
    /// gives it on a collision, and retries only a transient daemon failure.
    private func publishBonjour() {
        NSLog("startDICOMBonjour")

        let txtRecord = DICOMBonjourTXTRecord(preferences: preferences, serverDescription: UserDefaults.bonjourSharingName(),
                                              uid: AppController.uid(), webPortalPort: UserDefaults.webPortalPortNumber())
        let name = txtRecord.aeTitle ?? ""
        let port = ListenerSettings.listeningPort(preferences[NetworkPreferences.aePort])
        bonjourService = NetService(domain: "", type: DICOMBonjourTXTRecord.serviceType, name: name, port: port)
        let advertisement = BonjourAdvertisement(name: name, type: "_dicom._tcp.", port: Int(port))

        let record = txtRecord.entries
        bonjourAdvertisement?.stop()
        bonjourAdvertisement = advertisement
        advertisement.publish(txtRecord: record)

        DICOMNodeService.shared.publisher = advertisement
    }

    /// Withdraws the advertisement, when the listeners restart and when quitting.
    func withdrawBonjour() {
        bonjourService = nil
        bonjourAdvertisement?.stop()
        bonjourAdvertisement = nil
    }
}
