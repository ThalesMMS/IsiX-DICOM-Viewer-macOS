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
/// Implemented in Swift since #711: the Objective-C name, the selectors,
/// the xib outlets and <Horos/OSIViewerPreferencePanePref.h> are those of
/// the former class.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIViewerPreferencePanePref)
public final class OSIViewerPreferencePanePref: NSPreferencePane {
    @IBOutlet var mainWindow: NSWindow?
    @IBOutlet var captureSeriesNameField: NSTextField?

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

        addROIStatisticsChecks()
        addPreviousExamCheck()
        addViewerInteractionControls()

        if let contentView = mainWindow?.contentView {
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

    /// "Previous" on older studies, a check in the right column of the
    /// Miscellaneous box, in the free place under "Only display images of the
    /// same patient". Built here so that every localized copy of the pane
    /// gets it; left out if that place is taken.
    private func addPreviousExamCheck() {
        let anchorPath = "values.onlyDisplayImagesOfSamePatient"
        guard let content = mainWindow?.contentView,
              let box = content.subviews.lazy.compactMap({ $0 as? NSBox }).first(where: { box in
                  box.contentView?.subviews.contains { ($0.infoForBinding(.value)?[.observedKeyPath] as? String) == anchorPath } ?? false
              }),
              let inner = box.contentView,
              let anchor = inner.subviews.first(where: { ($0.infoForBinding(.value)?[.observedKeyPath] as? String) == anchorPath })
        else { return }

        let place = NSRect(x: anchor.frame.minX, y: anchor.frame.minY - 20, width: anchor.frame.width, height: anchor.frame.height)
        guard !inner.subviews.contains(where: { $0.frame.intersects(place) }) else { return }
        let check = NSButton(checkboxWithTitle: NSLocalizedString("Show \"Previous\" on older studies",
                                                                   comment: "Viewers pane: the label on a viewer showing an older study of the patient"),
                             target: nil, action: nil)
        check.frame = place
        check.lineBreakMode = .byTruncatingTail
        check.toolTip = check.title
        check.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values." + PreviousStudyMark.defaultsKey, options: nil)
        inner.addSubview(check)
    }

    /// A check for each statistic of closed ROIs' labels, in a row added at the
    /// bottom of the ROI labels box, which grows to hold it. Built here rather
    /// than in the xib so that every localized copy of the pane gets it.
    private func addROIStatisticsChecks() {
        let backgroundPath = "values." + ROILabelContrast.backgroundKey
        guard let content = mainWindow?.contentView,
              let box = content.subviews.lazy.compactMap({ $0 as? NSBox }).first(where: { box in
                  box.contentView?.subviews.contains { view in
                      (view.infoForBinding(.value)?[.observedKeyPath] as? String) == backgroundPath
                  } ?? false
              }),
              let inner = box.contentView else { return }

        let rowHeight: CGFloat = 30
        let rowY = inner.subviews.map(\.frame.minY).min() ?? 10
        let autoresizing = (content.autoresizesSubviews, inner.autoresizesSubviews)
        content.autoresizesSubviews = false
        inner.autoresizesSubviews = false
        defer {
            content.autoresizesSubviews = autoresizing.0
            inner.autoresizesSubviews = autoresizing.1
        }
        content.setFrameSize(NSSize(width: content.frame.width, height: content.frame.height + rowHeight))
        for view in content.subviews where view !== box {
            view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + rowHeight))
        }
        box.setFrameSize(NSSize(width: box.frame.width, height: box.frame.height + rowHeight))
        for view in inner.subviews {
            view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + rowHeight))
        }

        let label = NSTextField(labelWithString: NSLocalizedString("Statistics shown:", comment: "Viewers pane: the checks of the statistics ROI labels show"))
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 12, y: rowY + 4))
        inner.addSubview(label)
        var x = label.frame.maxX + 10
        for statistic in ROILabelPresentation.statisticKinds {
            let check = NSButton(checkboxWithTitle: ROILabelPresentation.title(forStatistic: statistic), target: nil, action: nil)
            check.sizeToFit()
            check.setFrameOrigin(NSPoint(x: x, y: rowY + 4))
            check.bind(.value, to: NSUserDefaultsController.shared,
                       withKeyPath: "values." + ROILabelPresentation.defaultsKey(forStatistic: statistic), options: nil)
            inner.addSubview(check)
            x = check.frame.maxX + 12
        }
    }

    /// Add the interaction options to every localized version of the existing
    /// Miscellaneous box, preserving the positions of the other sections.
    private func addViewerInteractionControls() {
        let anchorPath = "values.onlyDisplayImagesOfSamePatient"
        guard let content = mainWindow?.contentView,
              let box = content.subviews.lazy.compactMap({ $0 as? NSBox }).first(where: { box in
                  box.contentView?.subviews.contains { ($0.infoForBinding(.value)?[.observedKeyPath] as? String) == anchorPath } ?? false
              }), let inner = box.contentView else { return }

        let rowHeight: CGFloat = 28
        let addedHeight = rowHeight * 4
        let rowY = inner.subviews.map(\.frame.minY).min() ?? 10
        let autoresizing = (content.autoresizesSubviews, inner.autoresizesSubviews)
        content.autoresizesSubviews = false
        inner.autoresizesSubviews = false
        defer {
            content.autoresizesSubviews = autoresizing.0
            inner.autoresizesSubviews = autoresizing.1
        }
        content.setFrameSize(NSSize(width: content.frame.width, height: content.frame.height + addedHeight))
        for view in content.subviews where view !== box && view.frame.minY >= box.frame.maxY {
            view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + addedHeight))
        }
        box.setFrameSize(NSSize(width: box.frame.width, height: box.frame.height + addedHeight))
        for view in inner.subviews {
            view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + addedHeight))
        }

        let defaults = NSUserDefaultsController.shared
        let left: CGFloat = 12
        let right = inner.bounds.width - 12
        func checkbox(_ title: String, key: String, row: CGFloat) -> NSButton {
            let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            button.frame = NSRect(x: left, y: rowY + row * rowHeight, width: right - left, height: 22)
            button.bind(.value, to: defaults, withKeyPath: "values." + key, options: nil)
            inner.addSubview(button)
            return button
        }
        _ = checkbox(NSLocalizedString("Remember MPR plane angles", comment: "Viewers preference"),
                     key: "RememberMPRPlaneAngles", row: 3)
        let preciseMouse = checkbox(NSLocalizedString("Precise mouse for measuring and zoom", comment: "Viewers preference"),
                                    key: "PreciseMouseForMeasuringAndZoom", row: 2)
        _ = checkbox(NSLocalizedString("Logarithmic thick slab slider", comment: "Viewers preference"),
                     key: "LogarithmicThickSlabSlider", row: 0)

        let factor = NSPopUpButton(frame: NSRect(x: right - 78, y: rowY + 2 * rowHeight - 1, width: 78, height: 26), pullsDown: false)
        for percentage in [25, 50, 75] {
            factor.addItem(withTitle: "\(percentage)%")
            factor.lastItem?.tag = percentage
        }
        factor.bind(.selectedTag, to: defaults, withKeyPath: "values.PreciseMouseFactor",
                    options: [.valueTransformer: ViewerMouseFactorTransformer()])
        factor.bind(.enabled, to: defaults, withKeyPath: "values.PreciseMouseForMeasuringAndZoom", options: nil)
        let factorLabel = NSTextField(labelWithString: NSLocalizedString("Mouse movement:", comment: "Precise mouse movement percentage"))
        factorLabel.sizeToFit()
        factorLabel.setFrameOrigin(NSPoint(x: factor.frame.minX - factorLabel.frame.width - 8, y: rowY + 2 * rowHeight + 3))
        factor.setAccessibilityLabel(factorLabel.stringValue)
        preciseMouse.setFrameSize(NSSize(width: factorLabel.frame.minX - left - 12, height: preciseMouse.frame.height))
        inner.addSubview(factorLabel)
        inner.addSubview(factor)

        let seriesLabel = NSTextField(labelWithString: NSLocalizedString("Identify series in the list by:", comment: "Viewers preference"))
        seriesLabel.sizeToFit()
        seriesLabel.setFrameOrigin(NSPoint(x: left, y: rowY + rowHeight + 3))
        inner.addSubview(seriesLabel)
        let series = NSPopUpButton(frame: .zero, pullsDown: false)
        let titles = [NSLocalizedString("Colors", comment: "Series identification mode"),
                      NSLocalizedString("Numbers", comment: "Series identification mode"),
                      NSLocalizedString("Colors and numbers", comment: "Series identification mode")]
        for (index, title) in titles.enumerated() {
            series.addItem(withTitle: title)
            series.lastItem?.tag = index
        }
        series.sizeToFit()
        series.frame = NSRect(x: seriesLabel.frame.maxX + 10, y: rowY + rowHeight - 1,
                              width: max(210, series.frame.width), height: 26)
        series.setAccessibilityLabel(seriesLabel.stringValue)
        series.bind(.selectedTag, to: defaults, withKeyPath: "values.SeriesListIdentificationMode", options: nil)
        inner.addSubview(series)
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
private final class ViewerMouseFactorTransformer: ValueTransformer {
    override class func transformedValueClass() -> AnyClass { NSNumber.self }
    override class func allowsReverseTransformation() -> Bool { true }

    override func transformedValue(_ value: Any?) -> Any? {
        let factor = (value as? NSNumber)?.doubleValue ?? 0.5
        return NSNumber(value: [0.25, 0.5, 0.75].contains(factor) ? Int(factor * 100) : 50)
    }

    override func reverseTransformedValue(_ value: Any?) -> Any? {
        let percentage = (value as? NSNumber)?.intValue ?? 50
        return NSNumber(value: [25, 50, 75].contains(percentage) ? Double(percentage) / 100 : 0.5)
    }
}
