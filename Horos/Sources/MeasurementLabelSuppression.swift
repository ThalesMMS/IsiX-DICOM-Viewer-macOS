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
import IsiXImaging
import IsiXPreferences

/// The labels of the measures hidden while Command-Shift is held, for the
/// windows that draw measures: the 2D viewer, the MPR, the orthogonal MPR and
/// PET-CT, the curved MPR, the endoscopy and the volume rendering.
///
/// It is a choice of the Viewers settings, off unless the user turns it on:
/// Command-Shift-3, -4 and -5 are the system's screenshots, and a picture of
/// a viewer taken with them lost its measures. Every view that is told of the
/// modifiers held asks here, and what it is answered holds for all the views
/// of all the windows, so that the planes of a window do not differ and none
/// keeps its labels hidden once the keys are released over another one.
/// Changing the setting holds at once, for the keys held at that moment.
@MainActor
enum MeasurementLabelSuppression {
    /// Whether the views were last told to hide their labels.
    private static var hiding = false
    private static var settingObserver: SettingObserver?

    /// Whether the modifiers held ask the views to hide their labels.
    static func isAsked(by flags: NSEvent.ModifierFlags) -> Bool {
        ViewInput.suppressesLabels(ViewInput.Modifiers(rawValue: flags.rawValue),
                                   enabled: PreferencesSource.process.preferences[ViewerPreferences.commandShiftHidesLabels])
    }

    /// The modifiers held changed, as a view was told: the views hide or show
    /// their labels. Nothing is looked for while none hides and none is to.
    static func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        watchSetting()
        let hide = isAsked(by: flags)
        guard hide || hiding else { return }
        hiding = hide
        for window in NSApp.windows {
            apply(hide, in: window.contentView)
        }
    }

    /// The setting changed: it holds for the keys held now.
    static func settingChanged() {
        modifiersChanged(NSEvent.modifierFlags)
    }

    private static func apply(_ hide: Bool, in view: NSView?) {
        guard let view else { return }
        if let image = view as? DCMView {
            if image.horos_suppress_labels != hide {
                image.horos_suppress_labels = hide
                image.needsDisplay = true
            }
        } else if let volume = view as? VRView {
            volume.hideMeasurementTexts(hide)
        }
        for subview in view.subviews {
            apply(hide, in: subview)
        }
    }

    private static func watchSetting() {
        guard settingObserver == nil else { return }
        let observer = SettingObserver()
        PreferencesSource.process.preferences.addObserver(observer, forKeyPath: ViewerPreferences.commandShiftHidesLabels.name,
                                                          options: [], context: nil)
        settingObserver = observer
    }
}

/// Watches the setting, for the life of the app.
private final class SettingObserver: NSObject, @unchecked Sendable {
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // UserDefaults reports a default on the thread that wrote it.
        onMainActor { MeasurementLabelSuppression.settingChanged() }
    }
}
