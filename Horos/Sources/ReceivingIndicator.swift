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

/// The Dock's signs of what arrives: the download arrow over the application's
/// icon while a listener or an import receives, the badge the import sets, and
/// the sound of a captured key image.
///
/// Receptions start and end on the listener and import threads, which count
/// them in a `ReceivingThreadCounter`; the icon is drawn on the main actor,
/// later, from the count it finds then.
@MainActor
final class ReceivingIndicator {

    private nonisolated let processGraph: ProcessGraph
    /// The receptions of each thread, which any thread changes.
    private nonisolated let receptions = ReceivingThreadCounter()

    /// What the Dock icon was last set for, receiving or not, in which
    /// appearance, and the receiving icon drawn for that appearance.
    private var shownReceivingIconState: String? = nil
    private var receivingIconCache: (appearance: String, icon: NSImage)? = nil
    /// Takes the arrow away two seconds after the last reception.
    private var settleTimer: Timer? = nil
    /// Redraws the receiving icon in the system's new appearance.
    private var appearanceObservation: NSKeyValueObservation? = nil

    nonisolated init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    nonisolated convenience init() {
        self.init(processGraph: ProcessGraph.process)
    }

    /// When the application has finished launching: shows the state of now,
    /// and follows the system's appearance from then on.
    func start() {
        removeApplicationIconPreference()
        updateReceivingIcon(force: false)
        // The receiving icon is drawn in the system's appearance, whichever
        // window is open. The bundle's icon is rendered again with it: the
        // icon style may have changed along with the appearance.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self else { return }
            assumeMainActor(self) {
                DockProgress.forgetRenderedBundleIcon()
                $0.updateReceivingIcon(force: true)
            }
        }
    }

    /// The calling thread starts a reception (`receiving`) or ends one. Any
    /// thread; the icon follows on the main actor.
    nonisolated func showReceiving(_ receiving: Bool) {
        if receiving {
            receptions.begin()
        } else {
            receptions.end()
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.updateReceivingIcon(force: false) }
        }
    }

    /// The badge of the Dock icon; nil takes it away. Any thread: the
    /// database sets it from its import threads, on the main thread now or later.
    nonisolated func setBadgeLabel(_ label: String?) {
        onMainActor {
            NSApp.dockTile.badgeLabel = label
            NSApp.dockTile.display()
        }
    }

    /// The sound of a captured key image.
    func playGrabSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        NSSound(contentsOfFile: path, byReference: false)?.play()
    }

    /// The app icon follows only the system: its light, dark, clear and
    /// tinted styles come from the bundle's icon. The choice the app offered
    /// before, stored as ApplicationIconAppearance and earlier as
    /// UseDarkApplicationIcon, is forgotten.
    private func removeApplicationIconPreference() {
        let preferences = processGraph.preferences
        for key in ["ApplicationIconAppearance", "UseDarkApplicationIcon"] where preferences.object(forKey: key) != nil {
            preferences.removeObject(forKey: key)
        }
    }

    /// The application's icon with the download arrow, while a listener
    /// receives. The icon is the bundle's, as the system draws it in the
    /// current appearance and icon style.
    private func receivingIcon() -> NSImage {
        let icon = DockProgress.renderedBundleIcon()
        let drawing = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { bounds in
            icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 362, y: 690))
            for point in [NSPoint(x: 662, y: 690), NSPoint(x: 662, y: 392),
                          NSPoint(x: 825, y: 392), NSPoint(x: 512, y: 44),
                          NSPoint(x: 200, y: 392), NSPoint(x: 362, y: 392)] {
                arrow.line(to: point)
            }
            arrow.close()
            arrow.lineWidth = 52
            NSColor.white.setStroke()
            arrow.stroke()
            NSColor(srgbRed: 30.0 / 255, green: 94.0 / 255, blue: 190.0 / 255, alpha: 1).setFill()
            arrow.fill()
            return true
        }
        // Drawn once into a bitmap: the Dock gets pixels, not a drawing to replay.
        var rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        guard let pixels = drawing.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return drawing }
        return NSImage(cgImage: pixels, size: rect.size)
    }

    /// Every file received or imported asks for this. Drawing the 1024-point
    /// icon and handing it to the Dock converts its colours on the main
    /// thread, so it happens only when the state shown changes - receiving
    /// or not, and the appearance - or when the system's icon style may
    /// have changed (`force`), and the receiving icon is drawn once per
    /// appearance. A retrieve arrives in batches with short gaps between
    /// them: the arrow stays until two seconds pass without a reception, so
    /// the icon changes twice per retrieve rather than twice per batch.
    private func updateReceivingIcon(force: Bool, settled: Bool = false) {
        let receiving = receptions.receivingThreads != 0
        if !receiving && !force && !settled && shownReceivingIconState?.hasPrefix("receiving ") == true {
            // Each end of a reception starts the two seconds again.
            settleTimer?.invalidate()
            settleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.receivingIconSettled() }
            }
            return
        }
        let appearance = NSApp.effectiveAppearance.name.rawValue
        let state = (receiving ? "receiving " : "idle ") + appearance
        if !force && state == shownReceivingIconState { return }
        shownReceivingIconState = state
        var icon: NSImage? = nil
        if receiving {
            if force || receivingIconCache?.appearance != appearance {
                receivingIconCache = (appearance, receivingIcon())
            }
            icon = receivingIconCache?.icon
        }
        // nil gives the Dock back the bundle's icon, in the system's icon style.
        DockProgress.shared.setApplicationIcon(icon)
    }

    private func receivingIconSettled() {
        settleTimer = nil
        updateReceivingIcon(force: false, settled: true)
    }
}
