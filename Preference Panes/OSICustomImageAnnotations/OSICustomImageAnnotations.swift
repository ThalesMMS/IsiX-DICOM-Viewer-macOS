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
import UniformTypeIdentifiers
import PreferencePanes

/// The Annotations preference pane: a layout of eight place holders where the
/// user arranges custom image annotations for each modality. CIALayoutController
/// does the work; the pane owns the nib's controls and forwards its actions.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors, the
/// outlets of OSICustomImageAnnotations.xib and OSICustomImageAnnotations.h are
/// those of the former class. The C function compareViewTags stays in
/// OSICustomImageAnnotations+CAPI.m, with the alert panel wrappers Swift needs.
/// NSAlertDefaultReturn, what CIARunAlertPanel and CIARunInformationalAlertPanel
/// answer for the default button.
let ciaAlertDefaultReturn = 1

// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSICustomImageAnnotations)
public final class OSICustomImageAnnotations: NSPreferencePane {
    private var layoutControllerValue: CIALayoutController?

    /// The nib's window, whose content view becomes the main view; the xib
    /// connects it to NSPreferencePane's `_window` too. CIALayoutController is
    /// made with it.
    @IBOutlet public var window: NSWindow!
    @IBOutlet public var modalitiesPopUpButton: NSPopUpButton!
    @IBOutlet public var sameAsDefaultButton: NSButton!
    @IBOutlet public var resetDefaultButton: NSButton!

    @IBOutlet public var orientationWidgetButton: NSButton!

    @IBOutlet public var addAnnotationButton: NSButton!
    @IBOutlet public var removeAnnotationButton: NSButton!

    @IBOutlet public var loadsaveButton: NSSegmentedControl!

    @IBOutlet public var layoutView: CIALayoutView!
    @IBOutlet public var titleLabelTextField: NSTextField!
    @IBOutlet public var titleTextField: NSTextField!
    @IBOutlet public var contentLabeltextField: NSTextField!
    @IBOutlet public var contentTokenField: NSTokenField!
    @IBOutlet public var dicomGroupTextField: NSTextField!
    @IBOutlet public var dicomElementTextField: NSTextField!
    @IBOutlet public var dicomNameTokenField: NSTextField!
    @IBOutlet public var groupLabel: NSTextField!
    @IBOutlet public var elementLabel: NSTextField!
    @IBOutlet public var nameLabel: NSTextField!
    @IBOutlet public var addCustomDICOMFieldButton: NSButton!
    @IBOutlet public var addDICOMFieldButton: NSButton!
    @IBOutlet public var addDatabaseFieldButton: NSButton!
    @IBOutlet public var addSpecialFieldButton: NSButton!
    @IBOutlet public var DICOMFieldsPopUpButton: NSPopUpButton!
    @IBOutlet public var databaseFieldsPopUpButton: NSPopUpButton!
    @IBOutlet public var specialFieldsPopUpButton: NSPopUpButton!
    @IBOutlet public var contentBox: NSBox!
    @IBOutlet public var mainWindow: NSWindow!

    /// Loads the pane's nib itself, from the main bundle, as before: from
    /// NSPreferencePane's -init, not -initWithBundle:, so the log of this
    /// class's -init is not printed.
    public override init(bundle: Bundle) {
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        // The former code kept the nib's top-level objects in an ivar without
        // retaining them (the array comes back autoreleased), so the three
        // object controllers of the nib went away with the autorelease pool,
        // and -dealloc would have over-released the array; panes are cached
        // and never deallocated. They are not kept here either: the window
        // stays alive through the `_window`, `window` and `mainWindow` outlets.
        var topLevelObjects: NSArray?
        let nib = NSNib(nibNamed: "OSICustomImageAnnotations", bundle: nil)
        _ = nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)

        // -setMainView: with the nil content view of a nib that failed to
        // load changed nothing: the main view was still unset.
        if let contentView = mainWindow?.contentView {
            mainView = contentView
        }
        mainViewDidLoad()
    }

    public override init() {
        NSLog("OSICustomImageAnnotations init")
        super.init()
    }

    public override func mainViewDidLoad() {
        //[gray setInterceptsMouse:YES];
    }

    /// Sent by PreferencesWindowController through an NSInvocation.
    @objc(enableControls:)
    public func enableControls(_ enable: Bool) {
        if !enable {
            layoutView?.setDisabledText("")
        } else {
            layoutView?.setDefaultDisabledText()
        }
        let context = NSNumber(value: enable)
        withExtendedLifetime(context) {
            mainView.sortSubviews({ compareViewTags($0, $1, $2) },
                                  context: Unmanaged.passUnretained(context).toOpaque())
        }
    }

    // MARK: -

    /// PreferencesWindowController (DCMTK) builds the list, as before through a
    /// message to the window's controller.
    @objc public func prepareDICOMFieldsArrays() -> NSArray! {
        let windowController = mainView.window?.windowController
        return windowController?.perform(NSSelectorFromString("prepareDICOMFieldsArrays"))?
            .takeUnretainedValue() as? NSArray
    }

    @IBAction public func loadsave(_ sender: Any?) {
        if (sameAsDefaultButton?.state ?? .off) == .on { return }

        if ((sender as? NSSegmentedControl)?.selectedSegment ?? 0) == 0 {    // Save
            switchModality(modalitiesPopUpButton, save: true)

            let sPanel = NSSavePanel()
            sPanel.allowedContentTypes = [UTType(filenameExtension: "plist")!]
            sPanel.nameFieldStringValue = "\(ciaDescription(modalitiesPopUpButton?.selectedItem?.title)).plist"

            sPanel.begin { result in
                if result != .OK {
                    return
                }

                guard let url = sPanel.url else { return }
                _ = self.layoutControllerValue?.curDictionary()?.write(to: url, atomically: true)
            }
        } else {                        // Load
            let sPanel = NSOpenPanel()
            sPanel.allowedContentTypes = [UTType(filenameExtension: "plist")!]

            sPanel.begin { result in
                if result != .OK {
                    return
                }

                let cur = sPanel.url.flatMap { NSDictionary(contentsOf: $0) }
                if let cur = cur {
                    if CIARunInformationalAlertPanel(NSLocalizedString("Settings", comment: ""), NSLocalizedString("Are you really sure you want to replace current settings? It will delete the current settings.", comment: ""), NSLocalizedString("OK", comment: ""), NSLocalizedString("Cancel", comment: ""), nil) == ciaAlertDefaultReturn {
                        let annotationsLayoutDictionary = self.layoutControllerValue?.annotationsLayoutDictionary()

                        ciaSetObject(annotationsLayoutDictionary, cur, forKey: self.layoutControllerValue?.currentModality())

                        self.switchModality(self.modalitiesPopUpButton, save: false)
                    }
                }
            }
        }
    }

    @IBAction public func reset(_ sender: Any?) {
        if CIARunInformationalAlertPanel(NSLocalizedString("Settings", comment: ""), NSLocalizedString("Are you really sure you want to reset the current default settings? It will delete the current settings.", comment: ""), NSLocalizedString("OK", comment: ""), NSLocalizedString("Cancel", comment: ""), nil) == ciaAlertDefaultReturn {
            let annotationsLayoutDictionary = layoutControllerValue?.annotationsLayoutDictionary()

            let dict = Bundle.main.resourcePath.flatMap {
                NSDictionary(contentsOfFile: ($0 as NSString).appendingPathComponent("AnnotationsDefault.plist"))
            }

            ciaSetObject(annotationsLayoutDictionary, dict?.object(forKey: "Default"), forKey: "Default")

            switchModality(modalitiesPopUpButton, save: false)
        }
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        mainView.window?.makeFirstResponder(nil)
    }

    public override func willSelect() {
        assumeMainActor(self) { $0.willSelectOnMainActor() }
    }

    private func willSelectOnMainActor() {
        NSLog("OSICustomImageAnnotations willSelect")

        if (modalitiesPopUpButton?.numberOfItems ?? 0) < 5 {
            let modalities = [NSLocalizedString("Default", comment: ""), "CR", "CT", "DX", "ES", "MG", "MR", "NM", "OT", "PT", "RF", "SC", "US", "XA"]

            modalitiesPopUpButton?.removeAllItems()

            for item in modalities {
                modalitiesPopUpButton?.addItem(withTitle: item)
            }
        }

        if layoutControllerValue == nil {
            layoutControllerValue = CIALayoutController(window: window)
            sameAsDefaultButton?.isHidden = true
            resetDefaultButton?.isHidden = false
        }
    }

    public override func didSelect() {
        assumeMainActor(self) { $0.didSelectOnMainActor() }
    }

    private func didSelectOnMainActor() {
        layoutControllerValue?.setLayoutView(layoutView)
        layoutControllerValue?.setPrefPane(self)
        layoutControllerValue?.awakeFromNib()

        enableControls(isUnlocked())
    }

    public override var shouldUnselect: NSPreferencePaneUnselectReply {
        return assumeMainActor(self) { $0.shouldUnselectOnMainActor() }
    }

    private func shouldUnselectOnMainActor() -> NSPreferencePaneUnselectReply {
        let win = mainView.window
        win?.makeFirstResponder(contentTokenField)

        layoutControllerValue?.validateTokenTextField(self)

        if !(layoutControllerValue?.checkAnnotations() ?? false) || !(layoutControllerValue?.checkAnnotationsContent() ?? false) {
            return .unselectCancel
        } else {
            return .unselectNow
        }
    }

    public override func didUnselect() {
        assumeMainActor(self) { $0.didUnselectOnMainActor() }
    }

    private func didUnselectOnMainActor() {
        if let layoutController = layoutControllerValue {
            layoutController.saveAnnotationLayout()
        }

        DICOMFieldsPopUpButton?.removeAllItems()
    }

    @IBAction public func addAnnotation(_ sender: Any?) {
        layoutControllerValue?.addAnnotation(sender)

        addCustomDICOMFieldButton?.isEnabled = true
        addDICOMFieldButton?.isEnabled = true
        addDatabaseFieldButton?.isEnabled = true
        addSpecialFieldButton?.isEnabled = true
    }

    @IBAction public func removeAnnotation(_ sender: Any?) {
        layoutControllerValue?.removeAnnotation(sender)
        titleTextField?.stringValue = ""

        addCustomDICOMFieldButton?.isEnabled = false
        addDICOMFieldButton?.isEnabled = false
        addDatabaseFieldButton?.isEnabled = false
        addSpecialFieldButton?.isEnabled = false
    }

    @IBAction @objc(setTitle:)
    public func setTitle(_ sender: Any?) {
        layoutControllerValue?.setTitle(sender)
    }

    @IBAction public func addFieldToken(_ sender: Any?) {
        let sender = sender as AnyObject?
        if sender === addCustomDICOMFieldButton || sender === addDICOMFieldButton || sender === addDatabaseFieldButton || sender === addSpecialFieldButton {
            let win = mainView.window
            win?.makeFirstResponder(contentTokenField)
        }
        layoutControllerValue?.addFieldToken(sender)
    }

    @IBAction public func validateTokenTextField(_ sender: Any?) {
        layoutControllerValue?.validateTokenTextField(sender)
    }

    @IBAction public func saveAnnotationLayout(_ sender: Any?) {
        layoutControllerValue?.saveAnnotationLayout(forModality: modalitiesPopUpButton?.selectedItem?.title)
    }

    @IBAction public func switchModality(_ sender: Any?) {
        switchModality(sender, save: true)
    }

    @objc(switchModality:save:)
    public func switchModality(_ sender: Any?, save: Bool) {
        layoutControllerValue?.switchModality(sender, save: save)
        let sameAsDefaultIsOff = (sameAsDefaultButton?.state ?? .off) == .off
        addAnnotationButton?.isEnabled = sameAsDefaultIsOff
        removeAnnotationButton?.isEnabled = sameAsDefaultIsOff
        loadsaveButton?.isEnabled = sameAsDefaultIsOff

        addCustomDICOMFieldButton?.isEnabled = false
        addDICOMFieldButton?.isEnabled = false
        addDatabaseFieldButton?.isEnabled = false
        addSpecialFieldButton?.isEnabled = false
    }

    @objc public func layoutController() -> CIALayoutController! {
        return layoutControllerValue
    }

    @IBAction public func setSameAsDefault(_ sender: Any?) {
        let state = (sameAsDefaultButton?.state ?? .off) == .on

        if state {
            if CIARunInformationalAlertPanel(NSLocalizedString("Default", comment: ""), NSLocalizedString("Are you really sure you want to replace current settings with the default settings? It will delete the current settings.", comment: ""), NSLocalizedString("OK", comment: ""), NSLocalizedString("Cancel", comment: ""), nil) == ciaAlertDefaultReturn {
                layoutControllerValue?.loadAnnotationLayout(forModality: "Default")
            } else {
                sameAsDefaultButton?.state = .off
                return
            }
        } else {
            layoutControllerValue?.loadAnnotationLayout(forModality: modalitiesPopUpButton?.selectedItem?.title)
        }
        layoutView?.isEnabled = !state
        sameAsDefaultButton?.state = state ? .on : .off
        layoutView?.needsDisplay = true

        addAnnotationButton?.isEnabled = !state
        removeAnnotationButton?.isEnabled = !state
        loadsaveButton?.isEnabled = !state

        orientationWidgetButton?.isEnabled = !state
    }

    @IBAction public func toggleOrientationWidget(_ sender: Any?) {
        let state = (orientationWidgetButton?.state ?? .off) == .on

        layoutControllerValue?.setOrientationWidgetEnabled(state)
    }
}
