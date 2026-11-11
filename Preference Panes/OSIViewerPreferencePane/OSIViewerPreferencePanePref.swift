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
import PreferencePanes

/// The context of the three user defaults observations, a stable address as
/// the former static NSString was.
private let UserDefaultsObservingContext = IdentityToken()

/// The Viewers preference pane.
///
/// Implemented in Swift: the Objective-C name, the selectors,
/// the xib outlets and <Horos/OSIViewerPreferencePanePref.h> are those of
/// the former class.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIViewerPreferencePanePref)
public class OSIViewerPreferencePanePref: NSPreferencePane {
    @IBOutlet var mainWindow: NSWindow?
    @IBOutlet var captureSeriesNameField: NSTextField?
    /// The windows of the panes that divide the Viewers settings: one nib holds
    /// them all, and each pane shows its own window.
    @IBOutlet var roiWindow: NSWindow?
    @IBOutlet var mouseWindow: NSWindow?
    @IBOutlet var screensWindow: NSWindow?
    @IBOutlet var exportWindow: NSWindow?

    /// The window this pane shows.
    var paneWindow: NSWindow? { mainWindow }

    /// One popup for the two keys of the zoom's interpolation: the second one
    /// only counts with the first one off.
    @objc dynamic var interpolationMode: Int {
        get {
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "NOINTERPOLATION") { return 0 }
            return defaults.bool(forKey: "SOFTWAREINTERPOLATION") ? 2 : 1
        }
        set {
            UserDefaults.standard.set(newValue == 0, forKey: "NOINTERPOLATION")
            UserDefaults.standard.set(newValue == 2, forKey: "SOFTWAREINTERPOLATION")
        }
    }

    /// The pop-up of the precise mouse's movement: its items are tagged 25,
    /// 50 and 75, and the preference keeps the factor, 0.5 when it holds
    /// anything else.
    @objc dynamic var preciseMouseFactorTag: Int {
        get {
            let factor = UserDefaults.standard.object(forKey: "PreciseMouseFactor") as? Double ?? 0.5
            return [0.25, 0.5, 0.75].contains(factor) ? Int(factor * 100) : 50
        }
        set {
            UserDefaults.standard.set([25, 50, 75].contains(newValue) ? Double(newValue) / 100 : 0.5, forKey: "PreciseMouseFactor")
        }
    }

    private var _tlos: NSArray?

    /// -init, which the former class inherited from NSObject: a pane without
    /// its nib, as before.
    public override init() {
        super.init()
    }

    @objc(initWithBundle:)
    public override init(bundle: Bundle) {
        // The former -initWithBundle: called -[super init]: the pane keeps no bundle.
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        let nib = NSNib(nibNamed: "OSIViewerPreferencePanePref", bundle: nil)
        nib?.instantiate(withOwner: self, topLevelObjects: &_tlos)

        if self is OSIViewerROIPreferencePanePref { addROIStatisticsChecks() }
        if type(of: self) == OSIViewerPreferencePanePref.self { translateFromCatalogIfNeeded() }

        if let contentView = paneWindow?.contentView {
            self.mainView = contentView
        }
        self.mainViewDidLoad()

        let controller = NSUserDefaultsController.shared
        controller.addObserver(self, forKeyPath: "values.ReserveScreenForDB", options: [], context: UserDefaultsObservingContext.pointer)
        controller.addObserver(self, forKeyPath: "values.AUTOTILING", options: [], context: UserDefaultsObservingContext.pointer)
        controller.addObserver(self, forKeyPath: "values.UseFloatingThumbnailsList", options: [], context: UserDefaultsObservingContext.pointer)

        // Left empty, the field shows the name a capture gets.
        captureSeriesNameField?.placeholderString = ScreenCaptureSeriesName.defaultName()
    }

    /// Italian and Spanish have a catalog and no copy of this nib. There the
    /// Base nib loads in English, and the texts of this pane's own window are
    /// read from the catalog; a text the catalog lacks stays as it is.
    private func translateFromCatalogIfNeeded() {
        guard let language = Bundle.main.preferredLocalizations.first,
              Bundle.main.url(forResource: "OSIViewerPreferencePanePref", withExtension: "nib", subdirectory: nil, localization: language) == nil,
              let content = mainWindow?.contentView else { return }
        Self.translateFromCatalog(content)
    }

    private static func translateFromCatalog(_ view: NSView) {
        func translated(_ english: String) -> String {
            english.isEmpty ? english : Bundle.main.localizedString(forKey: english, value: english, table: nil)
        }
        if let box = view as? NSBox {
            box.title = translated(box.title)
        } else if let popUp = view as? NSPopUpButton {
            for item in popUp.itemArray { item.title = translated(item.title) }
        } else if let button = view as? NSButton {
            button.title = translated(button.title)
        } else if let label = view as? NSTextField, !label.isEditable {
            label.stringValue = translated(label.stringValue)
        }
        for child in (view as? NSBox)?.contentView?.subviews ?? view.subviews { translateFromCatalog(child) }
    }

    /// Put the compact label setting beside the statistics it overrides.
    /// Build the controls here so that every localized copy of the pane gets them.
    private func addROIStatisticsChecks() {
        let backgroundPath = "values." + ROILabelContrast.backgroundKey
        guard let content = paneWindow?.contentView,
              let box = content.subviews.lazy.compactMap({ $0 as? NSBox }).first(where: { box in
                  box.contentView?.subviews.contains { view in
                      (view.infoForBinding(.value)?[.observedKeyPath] as? String) == backgroundPath
                  } ?? false
              }),
              let inner = box.contentView else { return }

        let rowSpacing: CGFloat = 24
        let addedHeight: CGFloat = 30 + rowSpacing
        let rowY = inner.subviews.map(\.frame.minY).min() ?? 10
        let autoresizing = (content.autoresizesSubviews, inner.autoresizesSubviews)
        content.autoresizesSubviews = false
        inner.autoresizesSubviews = false
        defer {
            content.autoresizesSubviews = autoresizing.0
            inner.autoresizesSubviews = autoresizing.1
        }
        content.setFrameSize(NSSize(width: content.frame.width, height: content.frame.height + addedHeight))
        for view in content.subviews where view !== box {
            view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + addedHeight))
        }
        box.setFrameSize(NSSize(width: box.frame.width, height: box.frame.height + addedHeight))
        for view in inner.subviews {
            view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + addedHeight))
        }

        let defaults = NSUserDefaultsController.shared
        let compactPath = "values.ROIPRIMARYMEASUREMENTONLY"
        let compact = NSButton(checkboxWithTitle: NSLocalizedString("Show Primary Measurement Only", comment: "ROI label display mode"),
                               target: nil, action: nil)
        compact.sizeToFit()
        compact.setFrameOrigin(NSPoint(x: 12, y: rowY + rowSpacing + 4))
        compact.bind(.value, to: defaults, withKeyPath: compactPath, options: nil)
        inner.addSubview(compact)

        // The compact mode can be switched on from the ROI menu and forgotten:
        // while it is on, the statistics checks below are greyed out and keep
        // their choices, and this note says why the labels leave them out.
        let note = NSTextField(labelWithString: NSLocalizedString("On: ROI labels hide the statistics below.",
                                                                  comment: "Viewers pane: shown beside the compact ROI label check while it is on"))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.toolTip = note.stringValue
        note.sizeToFit()
        let noteX = compact.frame.maxX + 8
        note.frame = NSRect(x: noteX, y: compact.frame.midY - note.frame.height / 2,
                            width: min(note.frame.width, max(0, inner.bounds.width - noteX - 12)), height: note.frame.height)
        note.bind(.hidden, to: defaults, withKeyPath: compactPath,
                  options: [.valueTransformerName: NSValueTransformerName.negateBooleanTransformerName])
        inner.addSubview(note)

        let label = NSTextField(labelWithString: NSLocalizedString("Statistics shown:", comment: "Viewers pane: the checks of the statistics ROI labels show"))
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 12, y: rowY + 4))
        inner.addSubview(label)
        var x = label.frame.maxX + 10
        for statistic in ROILabelPresentation.statisticKinds {
            let check = NSButton(checkboxWithTitle: ROILabelPresentation.title(forStatistic: statistic), target: nil, action: nil)
            check.sizeToFit()
            check.setFrameOrigin(NSPoint(x: x, y: rowY + 4))
            check.bind(.value, to: defaults,
                       withKeyPath: "values." + ROILabelPresentation.defaultsKey(forStatistic: statistic), options: nil)
            check.bind(.enabled, to: defaults, withKeyPath: compactPath,
                       options: [.valueTransformerName: NSValueTransformerName.negateBooleanTransformerName])
            inner.addSubview(check)
            x = check.frame.maxX + 12
        }
    }

    /// The field shows the name as it will be written: once its binding has
    /// stored what was typed, not while it does.
    @IBAction func captureSeriesNameChanged(_ sender: Any?) {
        DispatchQueue.main.async { ScreenCaptureSeriesName.normalizePreference() }
    }

    isolated deinit {
        NSLog("dealloc OSIViewerPreferencePanePref")
        let controller = NSUserDefaultsController.shared
        controller.removeObserver(self, forKeyPath: "values.ReserveScreenForDB")
        controller.removeObserver(self, forKeyPath: "values.AUTOTILING")
        controller.removeObserver(self, forKeyPath: "values.UseFloatingThumbnailsList")

        _tlos = nil
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if context != UserDefaultsObservingContext.pointer {
            return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }

        if keyPath == "values.ReserveScreenForDB" {
            self.willChangeValue(forKey: "screensThumbnail")
            self.didChangeValue(forKey: "screensThumbnail")
        }

        if keyPath == "values.AUTOTILING" {
            if UserDefaults.standard.bool(forKey: "AUTOTILING") {
                UserDefaults.standard.set(0, forKey: "WINDOWSIZEVIEWER")
            }
        }

        if keyPath == "values.UseFloatingThumbnailsList" {
            // AppController moves the existing lists after the defaults update.
            UserDefaults.standard.set(true, forKey: "SeriesListVisible")
        }
    }

    public override func willSelect() {
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        self.mainView.window?.makeFirstResponder(nil)
    }

    public override func mainViewDidLoad() {
        if UserDefaults.standard.bool(forKey: "is12bitPluginAvailable") == false {
            UserDefaults.standard.set(false, forKey: "automatic12BitTotoku")
        }
    }

    @objc(appController)
    public func appController() -> AppController! {
        return AppController.shared()
    }
}

/// The popup tags are percentages; the stored preference is a movement factor.
/// ROI labels, and what ROIs do when they are drawn or removed.
@objc(OSIViewerROIPreferencePanePref)
public final class OSIViewerROIPreferencePanePref: OSIViewerPreferencePanePref {
    override var paneWindow: NSWindow? { roiWindow }
}

/// The wheel, the mouse and the lenses.
@objc(OSIViewerMousePreferencePanePref)
public final class OSIViewerMousePreferencePanePref: OSIViewerPreferencePanePref {
    override var paneWindow: NSWindow? { mouseWindow }
}

/// The screens and the size and order of the viewers' windows.
@objc(OSIViewerScreensPreferencePanePref)
public final class OSIViewerScreensPreferencePanePref: OSIViewerPreferencePanePref {
    override var paneWindow: NSWindow? { screensWindow }
}

/// What exporting and capturing images keep.
@objc(OSIViewerExportPreferencePanePref)
public final class OSIViewerExportPreferencePanePref: OSIViewerPreferencePanePref {
    override var paneWindow: NSWindow? { exportWindow }
}
