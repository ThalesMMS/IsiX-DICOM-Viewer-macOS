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

/// The check for a new release the application makes by itself: one, at
/// launch, when `UpdateCheckSchedule` allows it. Nothing follows it while the
/// application runs, so there is nothing to keep between the launch and the
/// quit. The check itself runs on the main actor (`UpdateCheck`); App Store
/// and TestFlight builds never check.
struct UpdateCheckScheduler: Sendable {

    private let processGraph: ProcessGraph

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    init() {
        self.init(processGraph: ProcessGraph.process)
    }

    /// The check of this launch, when the preferences as they are now allow
    /// it. With them against it the feed is not read, and turning the checks
    /// on later takes effect at the next launch.
    func startAtLaunch() async {
        #if !MACAPPSTORE
        let graph = processGraph
        let preferences = graph.preferences
        guard UpdateCheckSchedule.checksAtLaunch(
            automaticChecks: preferences[ApplicationPreferences.checkHorosUpdates],
            listenerErrorsHidden: preferences[NetworkPreferences.hidesListenerErrors]) else { return }
        await MainActor.run { UpdateCheck(processGraph: graph).run(.automatic) }
        #endif
    }

    /// One check now, outside the launch's: the menu's, or one asked by
    /// another part of the application. Any thread: now on the main thread,
    /// or later on the main queue.
    func checkNow(_ kind: UpdateCheck.Kind) {
        #if !MACAPPSTORE
        let graph = processGraph
        onMainActor { UpdateCheck(processGraph: graph).run(kind) }
        #endif
    }
}

/// One look at the update feed, and what the user is told about it.
@MainActor
struct UpdateCheck {

    enum Kind {
        /// Asked from the menu: every outcome is told.
        case manual
        /// The check of the launch, or one a plugin asks for in the
        /// application's name: only a release the user was not told about in
        /// this session and did not skip, and only to a release copy, unless
        /// the user hides the listener errors or turned the checks off.
        case automatic
    }

    let processGraph: ProcessGraph

    func run(_ kind: Kind) {
        #if !MACAPPSTORE
        let check = self
        UpdateFeedClient.fetch(url: UpdateFeedClient.stableFeedURL) { (release, error) in // URL_HOROS_VERSION
            // The client answers inside a block of the main queue, which a modal
            // loop does not serve. The alerts open from the main run loop, so that
            // what waits for that queue goes on behind an offer left open.
            onMainRunLoop { check.tell(kind, release: release, error: error) }
        }
        #endif
    }

    #if !MACAPPSTORE
    /// What the feed answered, told as `kind` asks.
    private func tell(_ kind: Kind, release: UpdateRelease?, error: NSError?) {
        let bundle = Bundle.main
        let currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let displayVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? currentVersion
        let graph = processGraph
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
        } else if kind == .manual ||
                    (preferences[ApplicationPreferences.checkHorosUpdates] &&
                     !preferences[NetworkPreferences.hidesListenerErrors] && UpdateInstaller.isReleaseCopy &&
                     UpdateInstaller.postponedBuild != release.build &&
                     UpdateCheckSchedule.offersAutomatically(build: release.build,
                                                             skippedBuild: preferences[ApplicationPreferences.skippedUpdateBuild])) {
            // A development copy has no release build number, so it is told about a
            // release only when asked; nobody is asked twice in a session about the
            // same release, nor ever again about one that was skipped.
            UpdateInstaller.postponedBuild = release.build
            switch UpdateOffer(summary: summary, installs: UpdateInstaller.canInstall(release)).run() {
            case .install:
                UpdateInstaller.install(release,
                    confirmQuit: { graph.currentBrowser?.shouldTerminate(graph.appController) ?? true },
                    quit: { graph.appController?.lifecycle.finishTermination(graph.appController) })
            case .releasesPage:
                NSWorkspace.shared.open(UpdateFeedClient.releasesURL) // URL_HOROS_UPDATE
            case .skip:
                preferences.set(release.build, for: ApplicationPreferences.skippedUpdateBuild)
            case .later:
                break
            }
        }
    }
    #endif
}

#if !MACAPPSTORE
/// The alert that offers a release, and what the user answered.
///
/// A copy that can be replaced installs the release, leaves it for later or
/// skips it, and reaches the notes of the release by the link under the text.
/// A copy that cannot be replaced (not in a folder it can be written in, a
/// system too old for the release, no archive for this Mac) gets the release
/// from the releases page only, so that page stays its first button, with the
/// same two other answers.
@MainActor
private struct UpdateOffer {

    enum Choice {
        case install
        case releasesPage
        /// Not this release again: automatic checks offer the next one.
        case skip
        /// Nothing now: the next launch offers it again.
        case later
    }

    let summary: String
    /// The running copy can be replaced by the release.
    let installs: Bool

    func run() -> Choice {
        let title = NSLocalizedString("New Stable Build Available", comment: "")
        let skip = NSLocalizedString("Skip This Version", comment: "Update offer: do not offer this release again")
        guard installs else {
            let button = HorosAlertPanel.run(title: title, message: summary,
                                             defaultButton: NSLocalizedString("View Fork Releases", comment: ""),
                                             alternateButton: NSLocalizedString("Continue", comment: ""), otherButton: skip)
            if button == HorosAlertPanel.defaultResponse { return .releasesPage }
            return button == HorosAlertPanel.otherResponse ? .skip : .later
        }
        // The same alert HorosAlertPanel makes, with the link it has no place for.
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = summary + "\n\n" + NSLocalizedString("IsiX DICOM Viewer will quit and reopen when the download finishes.", comment: "Update installation notice")
        alert.addButton(withTitle: NSLocalizedString("Download and Install", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.addButton(withTitle: skip)
        let notes = ReleaseNotesLink()
        alert.accessoryView = notes.button
        // The button does not retain its target.
        let response = withExtendedLifetime(notes) { alert.runModal() }
        switch response {
        case .alertFirstButtonReturn: return .install
        case .alertThirdButtonReturn: return .skip
        default: return .later
        }
    }
}

/// The link to the notes of the latest release, under the text of the offer.
/// A button drawn as a link: the keyboard and VoiceOver reach it as they
/// reach the alert's own buttons, and the alert stays open behind the page.
@MainActor
private final class ReleaseNotesLink: NSObject {

    let button: NSButton

    override init() {
        button = NSButton(title: "", target: nil, action: #selector(open(_:)))
        super.init()
        button.target = self
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: NSLocalizedString("View Notes", comment: "Opens the latest release's notes"),
            attributes: [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                         .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        button.sizeToFit()
    }

    @objc private func open(_ sender: Any?) {
        NSWorkspace.shared.open(UpdateFeedClient.releaseNotesURL)
    }
}
#endif
