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

import AppKit
import IsiXInstallation
import IsiXPreferences

/// The automatic checks for a new release: at launch, then as
/// `UpdateCheckSchedule` times them, one after the other, until the
/// application quits. The checks themselves run on the main actor
/// (`UpdateCheck`); App Store and TestFlight builds never check.
actor UpdateCheckScheduler {

    private let processGraph: ProcessGraph
    /// The automatic checks, started once at launch.
    private var checks: Task<Void, Never>? = nil

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    init() {
        self.init(processGraph: ProcessGraph.process)
    }

    /// What the launch does, after the crash marker of the previous run was
    /// found (`crashed`) or not.
    func startAtLaunch(crashed: Bool) {
        #if !MACAPPSTORE
        guard checks == nil else { return }
        let preferences = processGraph.preferences
        let launch = UpdateCheckSchedule.atLaunch(crashed: crashed,
                                                  automaticChecks: preferences[ApplicationPreferences.checkHorosUpdates],
                                                  listenerErrorsHidden: preferences[NetworkPreferences.hidesListenerErrors])
        let graph = processGraph
        switch launch {
        case .automatic:
            checks = Task { await self.runAutomaticChecks() }
        case .afterCrash:
            Task { @MainActor in UpdateCheck(processGraph: graph).run(.afterCrash) }
        case .none:
            break
        }
        #endif
    }

    /// One check now, outside the automatic ones: the menu's, or one asked by
    /// another part of the application. Any thread: now on the main thread,
    /// or later on the main queue.
    nonisolated func checkNow(_ kind: UpdateCheck.Kind) {
        #if !MACAPPSTORE
        let graph = processGraph
        onMainActor { UpdateCheck(processGraph: graph).run(kind) }
        #endif
    }

    /// One check now, then the next step after each one, until cancelled.
    private func runAutomaticChecks() async {
        let graph = processGraph
        var step = UpdateCheckSchedule.Step.check(after: 0)
        while !Task.isCancelled {
            switch step {
            case .check(let delay):
                guard await sleep(delay) else { return }
                await MainActor.run { UpdateCheck(processGraph: graph).run(.automatic) }
                step = UpdateCheckSchedule.afterCheck(automaticChecks: automaticChecks)
            case .wait(let delay):
                guard await sleep(delay) else { return }
                step = UpdateCheckSchedule.afterWait(automaticChecks: automaticChecks)
            }
        }
    }

    private var automaticChecks: Bool {
        processGraph.preferences[ApplicationPreferences.checkHorosUpdates]
    }

    /// Waits `seconds`; false when the checks were cancelled meanwhile.
    private func sleep(_ seconds: TimeInterval) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }
}

/// One look at the update feed, and what the user is told about it.
@MainActor
struct UpdateCheck {

    enum Kind {
        /// Asked from the menu: every outcome is told.
        case manual
        /// The launch or the hourly check: only a release the user was not
        /// told about yet, and only to a release copy, unless the user hides
        /// the listener errors or turned the checks off since.
        case automatic
        /// After a crash: a newer release is offered, nothing else is told.
        case afterCrash
    }

    let processGraph: ProcessGraph

    func run(_ kind: Kind) {
        #if !MACAPPSTORE
        let told = kind != .automatic
        let bundle = Bundle.main
        let currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let displayVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? currentVersion
        let graph = processGraph

        UpdateFeedClient.fetch(url: UpdateFeedClient.stableFeedURL) { (release, error) in // URL_HOROS_VERSION
            // The Swift client delivers all outcomes on the main queue.
            guard let release = release else {
                if let error = error, kind == .manual {
                    _ = HorosAlertPanel.run(title: NSLocalizedString("Unable to Check for Updates", comment: ""),
                                            message: UpdateFeedClient.message(for: error),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
                return
            }
            let summary = UpdateFeedClient.summary(installedVersion: displayVersion ?? "",
                                                   build: currentVersion ?? "",
                                                   availableBuild: release.build)
            let preferences = graph.preferences
            if !release.isNewer(than: currentVersion) {
                if kind == .manual {
                    let button = HorosAlertPanel.run(title: NSLocalizedString("Update Check Result", comment: ""), message: summary,
                                                     defaultButton: NSLocalizedString("OK", comment: ""),
                                                     alternateButton: NSLocalizedString("View Notes", comment: "Opens the latest release's notes"),
                                                     otherButton: nil)
                    if button == HorosAlertPanel.alternateResponse {
                        NSWorkspace.shared.open(UpdateFeedClient.releaseNotesURL)
                    }
                }
            } else if UpdateInstaller.isBusy {
                // That release is already being downloaded or installed.
            } else if (preferences[ApplicationPreferences.checkHorosUpdates] &&
                        !preferences[NetworkPreferences.hidesListenerErrors] && UpdateInstaller.isReleaseCopy &&
                        UpdateInstaller.postponedBuild != release.build) || told {
                // A development copy has no release build number, so it is told about a
                // release only when asked; nobody is asked hourly about the same release.
                UpdateInstaller.postponedBuild = release.build
                if UpdateInstaller.canInstall(release) {
                    let button = HorosAlertPanel.run(title: NSLocalizedString("New Stable Build Available", comment: ""),
                                                     message: summary + "\n\n" + NSLocalizedString("IsiX DICOM Viewer will quit and reopen when the download finishes.", comment: "Update installation notice"),
                                                     defaultButton: NSLocalizedString("Download and Install", comment: ""),
                                                     alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                     otherButton: NSLocalizedString("View Fork Releases", comment: ""))
                    if button == HorosAlertPanel.defaultResponse {
                        UpdateInstaller.install(release,
                            confirmQuit: { graph.currentBrowser?.shouldTerminate(graph.appController) ?? true },
                            quit: { graph.appController?.finishTermination(graph.appController) })
                    } else if button == HorosAlertPanel.otherResponse {
                        NSWorkspace.shared.open(UpdateFeedClient.releasesURL) // URL_HOROS_UPDATE
                    }
                } else {
                    let button = HorosAlertPanel.run(title: NSLocalizedString("New Stable Build Available", comment: ""), message: summary,
                                                     defaultButton: NSLocalizedString("View Fork Releases", comment: ""),
                                                     alternateButton: NSLocalizedString("Continue", comment: ""), otherButton: nil)
                    if button == HorosAlertPanel.defaultResponse {
                        NSWorkspace.shared.open(UpdateFeedClient.releasesURL) // URL_HOROS_UPDATE
                    }
                }
            }
        }
        #endif
    }
}
