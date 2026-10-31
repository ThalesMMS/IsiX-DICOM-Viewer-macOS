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
import IsiXPreferences

/// What the application does when its preferences change: half a second after
/// the last write seen on the main thread, it compares the preferences with
/// those of the previous check (IsiXPreferences' PreferenceChange) and applies
/// what the change asks of the viewers, the database window, the listeners and
/// the series lists, then reads again the settings the drawing and the import
/// keep. On the main actor: everything it answers to is.
@MainActor
final class PreferenceChangeResponder {
    /// Off while the tiling and the reports write preferences of their own
    /// around their work: their writes are not answered.
    static var isChecking = true

    /// How long after the last write the check runs, so that a pane writing
    /// several keys at once is answered once.
    static let delay: TimeInterval = 0.5

    private let processGraph: ProcessGraph
    private let listener: DICOMListenerController
    private let windowArranger: ViewerWindowArranger

    /// The preferences as the previous check read them.
    private var previous: [String: Any] = [:]
    private var pendingCheck: Timer?
    /// The servers' settings apply when the application starts again: said once.
    private var showsRestartNotice = false
    private var observer: (any NSObjectProtocol)?

    init(listener: DICOMListenerController, windowArranger: ViewerWindowArranger, processGraph: ProcessGraph) {
        self.listener = listener
        self.windowArranger = windowArranger
        self.processGraph = processGraph
    }

    convenience init(listener: DICOMListenerController, windowArranger: ViewerWindowArranger) {
        self.init(listener: listener, windowArranger: windowArranger, processGraph: ProcessGraph.process)
    }

    /// Takes the preferences as they are now as those the first change is
    /// compared with, and the listeners' settings as those they run with, and
    /// starts answering.
    func start() {
        previous = processGraph.preferences.dictionaryRepresentation()
        listener.noteAppliedSettings()
        showsRestartNotice = true
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: nil) { [weak self] _ in
            // The defaults post their change on the thread that wrote them.
            // Only a change seen on the main thread schedules the check.
            guard Thread.isMainThread, let self else { return }
            MainActor.assumeIsolated { self.scheduleCheck() }
        }
    }

    /// The check, half a second after the last write; a write before then
    /// puts it off again.
    func scheduleCheck() {
        guard Self.isChecking else { return }
        pendingCheck?.invalidate()
        pendingCheck = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.check() }
        }
    }

    /// Compares the preferences with those of the previous check and answers
    /// what changed.
    func check() {
        pendingCheck?.invalidate()
        pendingCheck = nil
        let preferences = processGraph.preferences
        let current = preferences.dictionaryRepresentation()
        guard let change = PreferenceChange(from: previous, to: current) else { return }
        do {
            try HorosObjCException.perform {
                self.respond(to: change, preferences: preferences)
            }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            NSLog("Exception updating prefs: %@", exception?.description ?? "(null)")
        }
        previous = current
    }

    private func respond(to change: PreferenceChange, preferences: UserDefaults) {
        let viewers = processGraph.viewerRegistry
        if change.seriesListMode || change.seriesListVisible {
            placeSeriesLists(modeChanged: change.seriesListMode, preferences: preferences)
        }
        if change.viewerRedraw {
            for viewer in viewers.displayedViewers {
                for case let view as NSView in viewer.imageViews() ?? [] {
                    view.needsDisplay = true
                }
            }
        }
        if change.lengthPresentation {
            NotificationCenter.default.post(name: Notification.Name(LengthPresentation.changedNotification), object: nil)
        }
        if change.labelFontSize {
            NotificationCenter.default.post(name: NSNotification.Name.OsirixLabelGLFontChange, object: nil)
        }
        for _ in change.mistypedTextKeys {
            NSLog("*** isKindOfClass NSString")
        }

        if change.databaseRefresh {
            processGraph.currentBrowser?.setDBDate()
            _ = processGraph.currentBrowser?.outlineViewRefresh()
        }
        // The DICOM listeners take their settings at once; the other servers
        // need the application restarted.
        listener.applySettingsIfChanged()
        if change.listenerRestart && showsRestartNotice {
            showsRestartNotice = false
            HorosAlertPanel.run(title: NSLocalizedString("DICOM Listener", comment: ""), message: NSLocalizedString("Restart IsiX DICOM Viewer to apply these changes.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
        if change.databaseColumns {
            processGraph.currentBrowser?.refreshColumns()
        }
        if change.petBlendingCLUT {
            DCMView.computePETBlendingCLUT()
        }
        DCMPix.checkUserDefaults(true)

        if change.viewerRefresh || change.viewerReload {
            let displayed = viewers.displayedViewers
            for viewer in displayed {
                viewer.needsDisplayUpdate()
                if change.viewerReload {
                    viewer.displayDICOMOverlays(nil)
                }
            }
            for viewer in displayed where viewer.window?.isMainWindow == true {
                viewer.copySettingsToOthers(nil)
            }
        }

        CompressionSettingsNormalization.normalize(in: preferences)
        // A supplementary folder to burn needs its path.
        if (preferences[ApplicationPreferences.supplementaryBurnPath] ?? "").isEmpty {
            preferences.set(false, for: ApplicationPreferences.burnSupplementaryFolder)
            preferences.remove(ApplicationPreferences.supplementaryBurnPath)
        }

        processGraph.currentBrowser?.setNetworkLogs()
        DicomFile.resetDefaults()
        DCMView.setDefaults()
        ROI.loadDefaultSettings()

        if change.listenerRestart && preferences[NetworkPreferences.usesHostNameForAETitle] {
            listener.setAETitleToHostname()
        }
    }

    /// The series lists after their mode or their visibility changed: the
    /// floating panels are filled by tiling the viewers again; the lists in the
    /// viewers' windows show or hide. The window that had the focus (the
    /// preferences') keeps it.
    private func placeSeriesLists(modeChanged: Bool, preferences: UserDefaults) {
        let viewers = processGraph.viewerRegistry
        let keyWindow = modeChanged ? NSApp.keyWindow : nil
        if modeChanged {
            // Every borrowed list goes back before any viewer's dock changes;
            // detaching still works after the preference is off.
            windowArranger.prepareThumbnailsListsForScreenReconfiguration()
            for viewer in viewers.viewers ?? [] {
                viewer.updateSeriesListMode()
            }
        }
        if preferences[ViewerPreferences.useFloatingThumbnailsList] {
            windowArranger.tileWindows(sender: nil)
            for screen in NSScreen.screens {
                let viewer = viewers.frontMostDisplayedViewer(on: screen)
                viewer?.window?.makeKeyAndOrderFront(nil)
                viewer?.redrawToolbar()
            }
        } else {
            let visible = preferences[ViewerPreferences.seriesListVisible.reading(as: Int.self)] != 0
            for viewer in viewers.displayedViewers {
                viewer.setMatrixVisible(visible)
            }
            if modeChanged {
                windowArranger.tileWindows(sender: nil)
            }
        }
        if keyWindow?.isVisible == true {
            keyWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
