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
import CoreData

/// -[NSMutableDictionary setObject:forKey:] as the former code sent it: to a
/// nil dictionary it did nothing, and it raised for a nil object or key.
func ciaSetObject(_ dictionary: NSMutableDictionary?, _ object: Any?, forKey key: Any?) {
    guard let dictionary = dictionary else { return }
    guard let object = object else {
        NSException(name: .invalidArgumentException,
                    reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: \(ciaDescription(key)))",
                    userInfo: nil).raise()
        return
    }
    guard let key = key else {
        NSException(name: .invalidArgumentException,
                    reason: "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil",
                    userInfo: nil).raise()
        return
    }
    dictionary.setObject(object, forKey: key as AnyObject as! NSCopying)
}

/// -[NSObject isEqualTo:] sent to an object that may be nil.
private func isEqualTo(_ object: Any?, _ other: Any?) -> Bool {
    return (object as? NSObject)?.isEqual(to: other) ?? false
}

/// The group or element of a DICOM_group_element token: the whole component
/// in hexadecimal, "0x" allowed, as the pane writes it (0x%04x). A component
/// that only starts with hex digits, as "Foo" and "Bar" in DICOM_Foo_Bar,
/// names no tag (#748).
private func hexTagComponent(_ component: String) -> UInt32? {
    let scanner = Scanner(string: component)
    scanner.charactersToBeSkipped = nil
    var value: UInt32 = 0
    guard scanner.scanHexInt32(&value), scanner.isAtEnd else { return nil }
    return value
}

/// The place holder keys of a saved layout, in the order of
/// -[CIALayoutView placeHolderArray].
private let placeHolderKeys = ["LowerLeft", "LowerMiddle", "LowerRight", "MiddleLeft", "MiddleRight", "TopLeft", "TopMiddle", "TopRight"]

/// Edits the custom image annotation layouts of the Annotations preference
/// pane and saves them, per modality, in the CUSTOM_IMAGE_ANNOTATIONS default
/// that DCMPix reads.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// CIALayoutController.h are those of the former class.
@objc(CIALayoutController)
public final class CIALayoutController: NSWindowController, NSTokenFieldDelegate {
    /// Not retained, as the former `assign` ivar: the pane owns this controller.
    private weak var prefPane: OSICustomImageAnnotations?

    /// Not retained, as the former `assign` ivar: the pane's outlet keeps it.
    private weak var layoutView: CIALayoutView?

    private var annotationsArray: [CIAAnnotation] = []
    private var selectedAnnotationValue: CIAAnnotation?

    private var DICOMFieldsArray: NSMutableArray?
    private var databaseStudyFieldsArray = NSMutableArray()
    private var databaseSeriesFieldsArray = NSMutableArray()
    private var databaseImageFieldsArray = NSMutableArray()

    private var annotationNumber: Int32 = 0

    private var annotationsLayout = NSMutableDictionary()
    private var currentModalityValue: String?

    private var skipTextViewDidChangeSelectionNotification = false

    @objc public func currentModality() -> String! {
        return currentModalityValue
    }

    @objc public func annotationsLayoutDictionary() -> NSMutableDictionary! {
        return annotationsLayout
    }

    @objc public func curDictionary() -> NSDictionary! {
        guard let currentModality = currentModalityValue else { return nil }
        return annotationsLayout.object(forKey: currentModality) as? NSDictionary
    }

    @objc public func reloadLayoutDictionary() {
        if let saved = UserDefaults.standard.object(forKey: "CUSTOM_IMAGE_ANNOTATIONS") as? NSDictionary {
            annotationsLayout = saved.mutableCopy() as! NSMutableDictionary
        } else {
            annotationsLayout = NSMutableDictionary()
        }
    }

    public override init(window: NSWindow?) {
        super.init(window: window)

        annotationsArray = []
        databaseStudyFieldsArray = NSMutableArray()
        databaseSeriesFieldsArray = NSMutableArray()
        databaseImageFieldsArray = NSMutableArray()
        selectedAnnotationValue = nil

        annotationNumber = 1

        reloadLayoutDictionary()

        currentModalityValue = "Default"

        skipTextViewDidChangeSelectionNotification = false

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(annotationMouseDragged(_:)), name: NSNotification.Name("CIAAnnotationMouseDraggedNotification"), object: nil)
        center.addObserver(self, selector: #selector(annotationMouseDown(_:)), name: NSNotification.Name("CIAAnnotationMouseDownNotification"), object: nil)
        center.addObserver(self, selector: #selector(annotationMouseUp(_:)), name: NSNotification.Name("CIAAnnotationMouseUpNotification"), object: nil)
        center.addObserver(self, selector: #selector(controlTextDidEndEditing(_:)), name: NSNotification.Name("NSControlTextDidEndEditingNotification"), object: nil)
        center.addObserver(self, selector: #selector(textViewDidChangeSelection(_:)), name: NSNotification.Name("NSTextViewDidChangeSelectionNotification"), object: nil)
    }

    /// The former class had no -initWithCoder: of its own; it is made in code,
    /// by the pane.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Not called by a nib: the pane sends it on every -didSelect, after
    /// -setLayoutView: and -setPrefPane:.
    public override func awakeFromNib() {
        let pane = prefPane

        pane?.titleTextField?.isEnabled = false
        pane?.contentTokenField?.isEnabled = false
        setCustomDICOMFieldEditingEnable(false)

        pane?.contentTokenField?.cell?.wraps = true

        pane?.contentTokenField?.delegate = self

        // DICOM popup button
        DICOMFieldsArray = pane?.prepareDICOMFieldsArrays()?.mutableCopy() as? NSMutableArray

        let DICOMFieldsMenu = pane?.DICOMFieldsPopUpButton?.menu
        DICOMFieldsMenu?.autoenablesItems = false

        pane?.DICOMFieldsPopUpButton?.removeAllItems()

        var item = NSMenuItem()
        item.title = NSLocalizedString("DICOM Fields", comment: "")
        item.isEnabled = false
        DICOMFieldsMenu?.addItem(item)
        for field in DICOMFieldsArray ?? [] {
            item = NSMenuItem()
            item.title = (field as! CIADICOMField).title()
            item.representedObject = field
            DICOMFieldsMenu?.addItem(item)
        }

        pane?.DICOMFieldsPopUpButton?.menu = DICOMFieldsMenu

        // Database popup button
        prepareDatabaseFields()

        let databaseFieldsMenu = pane?.databaseFieldsPopUpButton?.menu
        databaseFieldsMenu?.autoenablesItems = false

        databaseFieldsMenu?.removeAllItems()

        let levels: [(String, String, NSMutableArray)] = [
            (NSLocalizedString("Study level", comment: ""), "study", databaseStudyFieldsArray),
            (NSLocalizedString("Series level", comment: ""), "series", databaseSeriesFieldsArray),
            (NSLocalizedString("Image level", comment: ""), "image", databaseImageFieldsArray),
        ]
        for (index, level) in levels.enumerated() {
            if index > 0 {
                databaseFieldsMenu?.addItem(NSMenuItem.separator())
            }
            item = NSMenuItem()
            item.title = level.0
            item.isEnabled = false
            databaseFieldsMenu?.addItem(item)
            for field in level.2 {
                item = NSMenuItem()
                item.title = "\t\(ciaDescription(field))"
                item.representedObject = "\(level.1).\(ciaDescription(field))"
                databaseFieldsMenu?.addItem(item)
            }
        }

        // Specials popup button
        let specialFieldsMenu = pane?.specialFieldsPopUpButton?.menu

        specialFieldsMenu?.removeAllItems()

        let fields = specialFieldsTitles()!
        let localizedFields = specialFieldsLocalizedTitles()!

        for i in 0..<fields.count {
            item = NSMenuItem()
            item.title = localizedFields.object(at: i) as! String
            item.representedObject = fields.object(at: i)
            specialFieldsMenu?.addItem(item)
        }

        pane?.DICOMFieldsPopUpButton?.isEnabled = false
        pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
        pane?.databaseFieldsPopUpButton?.isEnabled = false
        pane?.specialFieldsPopUpButton?.isEnabled = false
        pane?.databaseFieldsPopUpButton?.selectItem(at: 0)
        pane?.specialFieldsPopUpButton?.selectItem(at: 0)

        pane?.addCustomDICOMFieldButton?.isEnabled = false
        pane?.addDICOMFieldButton?.isEnabled = false
        pane?.addDatabaseFieldButton?.isEnabled = false
        pane?.addSpecialFieldButton?.isEnabled = false

        loadAnnotationLayout(forModality: currentModalityValue)

        pane?.contentTokenField?.tokenizingCharacterSet = CharacterSet.whitespacesAndNewlines
    }

    deinit {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        NotificationCenter.default.removeObserver(self)
    }

    @IBAction public func addAnnotation(_ sender: Any?) {
        var check = true
        if let selectedAnnotation = selectedAnnotationValue {
            check = checkAnnotationContent(selectedAnnotation)
        }

        if check {
            let layoutBounds = layoutView?.bounds ?? .zero
            let center = NSMakePoint(NSMidX(layoutBounds), NSMidY(layoutBounds))
            let anAnnotation = CIAAnnotation(frame: NSMakeRect(center.x - 75.0 / 2.0, center.y - 11, 75, 22))

            if annotationsArray.count == 0 { annotationNumber = 1 }
            anAnnotation.title = "\(ciaDescription(anAnnotation.title)) \(annotationNumber)"
            annotationNumber &+= 1

            annotationsArray.append(anAnnotation)
            layoutView?.addSubview(anAnnotation)
            layoutView?.needsDisplay = true

            selectAnnotation(anAnnotation)
        }
    }

    @IBAction public func removeAnnotation(_ sender: Any?) {
        guard let selectedAnnotation = selectedAnnotationValue else { return }
        let placeHolder = selectedAnnotation.placeHolder

        annotationsArray.removeAll { $0 === selectedAnnotation }
        selectedAnnotation.removeFromSuperview()
        layoutView?.needsDisplay = true

        if selectedAnnotation.placeHolder != nil {
            placeHolder?.hasFocus = false
            placeHolder?.removeAnnotation(selectedAnnotation)
            placeHolder?.updateFrameAroundAnnotations()
            placeHolder?.alignAnnotations()
            layoutView?.needsDisplay = true
        }

        // No KVO notification here, as before.
        selectedAnnotationValue = nil
        let pane = prefPane
        pane?.titleTextField?.stringValue = ""
        pane?.contentTokenField?.stringValue = ""

        pane?.titleTextField?.isEnabled = false
        pane?.contentTokenField?.isEnabled = false
        setCustomDICOMFieldEditingEnable(false)

        pane?.DICOMFieldsPopUpButton?.isEnabled = false
        pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
        pane?.databaseFieldsPopUpButton?.isEnabled = false
        pane?.specialFieldsPopUpButton?.isEnabled = false
        pane?.databaseFieldsPopUpButton?.selectItem(at: 0)
        pane?.specialFieldsPopUpButton?.selectItem(at: 0)
    }

    public override func keyDown(with theEvent: NSEvent) {
        guard let characters = theEvent.characters as NSString?, characters.length != 0 else { return }

        let c = characters.character(at: 0)
        if c == unichar(NSDeleteCharacter) {
            removeAnnotation(self)
            return
        }
        super.keyDown(with: theEvent)
    }

    @IBAction @objc(setTitle:)
    public func setTitle(_ sender: Any?) {
        if let selectedAnnotation = selectedAnnotationValue {
            selectedAnnotation.title = (sender as? NSControl)?.stringValue

            selectedAnnotation.placeHolder?.updateFrameAroundAnnotations()
            layoutView?.updatePlaceHolderOrigins()
            selectedAnnotation.placeHolder?.alignAnnotations()

            layoutView?.needsDisplay = true
        }
    }

    @objc func annotationMouseDragged(_ aNotification: Notification) {
        let annotation = aNotification.object as? CIAAnnotation
        if let aPlaceHolder = annotation?.placeHolder {
            aPlaceHolder.removeAnnotation(annotation)
            aPlaceHolder.alignAnnotations()
            aPlaceHolder.updateFrameAroundAnnotations()
        }

        let placeHolders = layoutView?.placeHolderArray ?? []
        for placeHolder in placeHolders {
            placeHolder.updateFrameAroundAnnotations()
        }
        layoutView?.updatePlaceHolderOrigins()

        layoutView?.needsDisplay = true

        highlightPlaceHolder(for: annotation)
    }

    @objc func annotationMouseDown(_ aNotification: Notification) {
        let annotation = aNotification.object as? CIAAnnotation

        var check = true
        if let selectedAnnotation = selectedAnnotationValue, annotation !== selectedAnnotation {
            check = checkAnnotationContent(selectedAnnotation)
        }

        highlightPlaceHolder(for: annotation)
        if check {
            selectAnnotation(annotation)
        }
    }

    @objc func annotationMouseUp(_ aNotification: Notification) {
        let annotation = aNotification.object as? CIAAnnotation
        let annotationY = annotation?.frame.origin.y ?? 0

        var annotationOutOfPlaceHolder = true

        let placeHolders = layoutView?.placeHolderArray ?? []
        for currentPlaceHolder in placeHolders {
            if currentPlaceHolder.hasFocus && !currentPlaceHolder.containsAnnotation(annotation) {
                // if current place holder contains annotations, we are going to insert the new annotation inbetween the other
                var index: Int32 = -1

                let placed = currentPlaceHolder.annotationsArray()!
                if placed.count > 0 {
                    if (placed.object(at: 0) as! CIAAnnotation).frame.origin.y <= annotationY {
                        index = 0
                    }

                    var j = 0
                    while j < placed.count - 1 {
                        let annotation1 = placed.object(at: j) as! CIAAnnotation
                        let annotation2 = placed.object(at: j + 1) as! CIAAnnotation
                        if annotation1.frame.origin.y == annotationY {
                            index = Int32(j)
                        } else if annotation1.frame.origin.y > annotationY && annotation2.frame.origin.y <= annotationY {
                            index = Int32(j + 1)
                        }
                        j += 1
                    }
                }

                if index >= 0 {
                    currentPlaceHolder.insertAnnotation(annotation, at: index)
                } else {
                    currentPlaceHolder.addAnnotation(annotation)
                }
                annotationOutOfPlaceHolder = false
                break
            }
            if currentPlaceHolder.containsAnnotation(annotation) { annotationOutOfPlaceHolder = false }
        }

        if annotationOutOfPlaceHolder {
            annotation?.placeHolder?.removeAnnotation(annotation)
            annotation?.placeHolder?.alignAnnotations()
        }

        for placeHolder in placeHolders {
            placeHolder.alignAnnotations()
            placeHolder.updateFrameAroundAnnotations()

            layoutView?.needsDisplay = true
        }

        highlightPlaceHolder(for: selectedAnnotationValue)
    }

    @objc(highlightPlaceHolderForAnnotation:)
    public func highlightPlaceHolder(for anAnnotation: CIAAnnotation!) {
        let annotationFrame = anAnnotation?.frame ?? .zero
        let annotationFrameArea = Float(annotationFrame.size.width * annotationFrame.size.height)

        let placeHolders = layoutView?.placeHolderArray ?? []
        var highlightedPlaceHolders: [CIAPlaceHolder] = []
        for placeHolder in placeHolders {
            let interserctionRect = NSIntersectionRect(annotationFrame, placeHolder.frame)
            if interserctionRect.size.width * interserctionRect.size.height >= 0.1 * CGFloat(annotationFrameArea) {
                placeHolder.hasFocus = true
                highlightedPlaceHolders.append(placeHolder)
            } else {
                placeHolder.hasFocus = false
            }
        }

        let numberOfHighlightedPlaceHolders = highlightedPlaceHolders.count
        if numberOfHighlightedPlaceHolders > 1 { // more than one place holder is highlighted
            let mouseLocationInWindow = NSApplication.shared.currentEvent?.locationInWindow ?? .zero
            let mouseLocationInView = layoutView?.convert(mouseLocationInWindow, from: nil) ?? .zero

            // In `float`, as before.
            var distanceToMouse = [Float](repeating: 0, count: numberOfHighlightedPlaceHolders)
            for i in 0..<numberOfHighlightedPlaceHolders {
                let frame = highlightedPlaceHolders[i].frame
                let placeHolderCenter = Float(frame.origin.x + frame.size.width / 2.0)
                distanceToMouse[i] = Float(abs(mouseLocationInView.x - CGFloat(placeHolderCenter)))
            }

            var minDistance = Float.greatestFiniteMagnitude // MAXFLOAT
            var index = -1
            for i in 0..<numberOfHighlightedPlaceHolders {
                if distanceToMouse[i] < minDistance {
                    minDistance = distanceToMouse[i]
                    index = i
                }
            }

            for i in 0..<numberOfHighlightedPlaceHolders {
                if i != index {
                    highlightedPlaceHolders[i].hasFocus = false
                }
            }
        }
    }

    @objc(selectAnnotation:)
    public func selectAnnotation(_ anAnnotation: CIAAnnotation!) {
        if anAnnotation === selectedAnnotationValue { return }

        validateTokenTextField(self)

        for annotation in annotationsArray {
            annotation.setIsSelected(false)
        }
        anAnnotation?.setIsSelected(true)

        // The nib's object controllers bound selection.layoutController.selectedAnnotation.
        willChangeValue(forKey: "selectedAnnotation")
        if selectedAnnotationValue !== anAnnotation {
            selectedAnnotationValue = anAnnotation
        }
        didChangeValue(forKey: "selectedAnnotation")

        let pane = prefPane
        pane?.titleTextField?.isEnabled = true
        pane?.contentTokenField?.isEnabled = true
        setCustomDICOMFieldEditingEnable(true)

        if let title = anAnnotation?.title {
            pane?.titleTextField?.stringValue = title
        }
        pane?.contentTokenField?.objectValue = anAnnotation?.content

        if let anAnnotation = anAnnotation {
            layoutView?.addSubview(anAnnotation) // in order to bring the Annotation to front
        }
        layoutView?.needsDisplay = true

        pane?.DICOMFieldsPopUpButton?.isEnabled = false
        pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
        pane?.databaseFieldsPopUpButton?.isEnabled = false
        pane?.specialFieldsPopUpButton?.isEnabled = false
        pane?.databaseFieldsPopUpButton?.selectItem(at: 0)
        pane?.specialFieldsPopUpButton?.selectItem(at: 0)
        pane?.addCustomDICOMFieldButton?.isEnabled = true
        pane?.addDICOMFieldButton?.isEnabled = true
        pane?.addDatabaseFieldButton?.isEnabled = true
        pane?.addSpecialFieldButton?.isEnabled = true
    }

    /// Only a getter, and its changes are announced by hand in
    /// -selectAnnotation:, as before: there is no setter for KVO to wrap.
    @objc public func selectedAnnotation() -> CIAAnnotation! {
        return selectedAnnotationValue
    }

    @IBAction public func addFieldToken(_ sender: Any?) {
        let pane = prefPane
        let selectedAnnotation = selectedAnnotationValue

        var selectedItem: NSMenuItem?
        if isEqualTo(sender, pane?.DICOMFieldsPopUpButton) || isEqualTo(sender, pane?.databaseFieldsPopUpButton) || isEqualTo(sender, pane?.specialFieldsPopUpButton) {
            selectedItem = (sender as? NSPopUpButton)?.selectedItem
        }

        // see if there is a selected Token in the NSTokenField
        var aTokenIsSelected = false
        var tokenIndexInContent: Int32 = 0
        let range = pane?.contentTokenField?.currentEditor()?.selectedRange ?? NSRange(location: 0, length: 0)

        if range.length == 1 { // one and only one is selected
            aTokenIsSelected = true
            tokenIndexInContent = Int32(truncatingIfNeeded: range.location)
        }

        // next line validates the NSToken field content : same as if the user hit 'return'. we NEED that.
        if let tokenField = pane?.contentTokenField {
            tokenField.sendAction(tokenField.action, to: tokenField.target)
        }

        func append(_ token: String) {
            guard let selectedAnnotation = selectedAnnotation else { return }
            selectedAnnotation.insertObject(token, inContentAt: UInt32(bitPattern: selectedAnnotation.countOfContent()))
        }
        func replaceSelectedToken(with token: String) {
            selectedAnnotation?.removeObjectFromContent(at: UInt32(bitPattern: tokenIndexInContent))
            selectedAnnotation?.insertObject(token, inContentAt: UInt32(bitPattern: tokenIndexInContent))
        }

        if isEqualTo(sender, pane?.DICOMFieldsPopUpButton) {
            if !aTokenIsSelected {
                append("DICOM_" + ciaDescription(((sender as? NSPopUpButton)?.selectedItem?.representedObject as? CIADICOMField)?.name()))
            } else {
                replaceSelectedToken(with: "DICOM_" + ciaDescription((selectedItem?.representedObject as? CIADICOMField)?.name()))
            }
        } else if isEqualTo(sender, pane?.databaseFieldsPopUpButton) {
            if !aTokenIsSelected {
                append("DB_" + ciaDescription(selectedItem?.representedObject))
            } else {
                replaceSelectedToken(with: "DB_" + ciaDescription(selectedItem?.representedObject))
            }
        } else if isEqualTo(sender, pane?.specialFieldsPopUpButton) {
            if !aTokenIsSelected {
                append("Special_" + ciaDescription(selectedItem?.representedObject))
            } else {
                replaceSelectedToken(with: "Special_" + ciaDescription(selectedItem?.representedObject))
            }
        } else if isEqualTo(sender, pane?.addCustomDICOMFieldButton) {
            let group = pane?.dicomGroupTextField?.stringValue
            let element = pane?.dicomElementTextField?.stringValue
            if (group as NSString?)?.isEqual(to: "") == true || (element as NSString?)?.isEqual(to: "") == true {
                _ = CIARunAlertPanel(NSLocalizedString("Custom DICOM Field", comment: ""), NSLocalizedString("Please provide a value for both \"Group\" and \"Element\" fields.", comment: ""), NSLocalizedString("OK", comment: ""), nil, nil)
                return
            }

            if (pane?.DICOMFieldsPopUpButton?.indexOfSelectedItem ?? 0) == 0 {
                // custom field
                let name = pane?.dicomNameTokenField?.stringValue
                if (name as NSString?)?.isEqual(to: "") == true {
                    append("DICOM_\(ciaDescription(group))_\(ciaDescription(element))")
                } else {
                    append("DICOM_\(ciaDescription(group))_\(ciaDescription(element))_\(ciaDescription(name))")
                }
            } else {
                // field in the list
                let fieldName = ciaDescription((pane?.DICOMFieldsPopUpButton?.selectedItem?.representedObject as? CIADICOMField)?.name())
                if !aTokenIsSelected {
                    append("DICOM_" + fieldName)
                } else {
                    replaceSelectedToken(with: "DICOM_" + fieldName)
                }
            }
            pane?.dicomGroupTextField?.stringValue = ""
            pane?.dicomElementTextField?.stringValue = ""
            pane?.dicomNameTokenField?.stringValue = ""
            pane?.dicomGroupTextField?.needsDisplay = true
            pane?.dicomElementTextField?.needsDisplay = true
            pane?.dicomNameTokenField?.needsDisplay = true
        } else if isEqualTo(sender, pane?.addDICOMFieldButton) {
            append("DICOM_")
            pane?.DICOMFieldsPopUpButton?.isEnabled = true
            pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
            pane?.databaseFieldsPopUpButton?.isEnabled = false
            pane?.specialFieldsPopUpButton?.isEnabled = false
            pane?.databaseFieldsPopUpButton?.selectItem(at: 0)
            pane?.specialFieldsPopUpButton?.selectItem(at: 0)
            aTokenIsSelected = false
        } else if isEqualTo(sender, pane?.addDatabaseFieldButton) {
            append("DB_")
            pane?.DICOMFieldsPopUpButton?.isEnabled = false
            pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
            pane?.databaseFieldsPopUpButton?.isEnabled = true
            pane?.specialFieldsPopUpButton?.isEnabled = false
            pane?.databaseFieldsPopUpButton?.selectItem(at: 0)
            pane?.specialFieldsPopUpButton?.selectItem(at: 0)
            aTokenIsSelected = false
        } else if isEqualTo(sender, pane?.addSpecialFieldButton) {
            append("Special_")
            pane?.DICOMFieldsPopUpButton?.isEnabled = false
            pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
            pane?.databaseFieldsPopUpButton?.isEnabled = false
            pane?.specialFieldsPopUpButton?.isEnabled = true
            pane?.databaseFieldsPopUpButton?.selectItem(at: 0)
            pane?.specialFieldsPopUpButton?.selectItem(at: 0)
            aTokenIsSelected = false
        }

        pane?.contentTokenField?.objectValue = selectedAnnotation?.content

        selectedAnnotation?.didChangeValue(forKey: "content")

        if !aTokenIsSelected {
            // select added token
            window?.makeFirstResponder(pane?.contentTokenField)
            pane?.contentTokenField?.currentEditor()?.selectedRange = NSMakeRange((selectedAnnotation?.content?.count ?? 0) - 1, 1)
        }

        pane?.contentTokenField?.needsDisplay = true
    }

    @IBAction public func validateTokenTextField(_ sender: Any?) {
        guard let content = selectedAnnotationValue?.content else { return }
        // -setArray: with the token field's array; nil emptied the content.
        if let tokens = prefPane?.contentTokenField?.objectValue as? NSArray {
            content.setArray(tokens as! [Any])
        } else {
            content.removeAllObjects()
        }
    }

    /// Not used, as before.
    @objc public func resizeTokenField() {
        return
    }

    @objc public func controlTextDidEndEditing(_ aNotification: Notification) {
        let pane = prefPane
        if isEqualTo(aNotification.object, pane?.dicomGroupTextField) {
            var group: UInt32 = 0
            Scanner(string: pane?.dicomGroupTextField?.stringValue ?? "").scanHexInt32(&group)
            if group > 0xffFF { group = 0xffFF }
            pane?.dicomGroupTextField?.stringValue = String(format: "0x%04x", group)
        } else if isEqualTo(aNotification.object, pane?.dicomElementTextField) {
            var element: UInt32 = 0
            Scanner(string: pane?.dicomElementTextField?.stringValue ?? "").scanHexInt32(&element)
            if element > 0xffFF { element = 0xffFF }
            pane?.dicomElementTextField?.stringValue = String(format: "0x%04x", element)

            var i = 0
            while i < (DICOMFieldsArray?.count ?? 0) {
                let field = DICOMFieldsArray!.object(at: i) as! CIADICOMField
                if (String(format: "0x%04x", field.group()) as NSString).isEqual(to: pane?.dicomGroupTextField?.stringValue ?? "")
                    && (String(format: "0x%04x", field.element()) as NSString).isEqual(to: pane?.dicomElementTextField?.stringValue ?? "") {
                    pane?.DICOMFieldsPopUpButton?.selectItem(at: i + 1) // +1 because item at index 0 contains no DICOM fields (it says "DICOM Fields")
                    pane?.dicomNameTokenField?.stringValue = field.name() ?? ""
                    break
                } else {
                    pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
                    pane?.dicomNameTokenField?.stringValue = ""
                }
                i += 1
            }
        }
    }

    public func tokenField(_ tokenField: NSTokenField, readFrom pboard: NSPasteboard) -> [Any]? {
        // handles drag & drop of several tokens
        return pboard.string(forType: .string)?.components(separatedBy: ", ")
    }

    public func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
        perform(#selector(resizeTokenField), with: nil, afterDelay: 0.1)
        return tokens
    }

    @objc public func prepareDatabaseFields() {
        let url = URL(fileURLWithPath: (Bundle.main.resourcePath! as NSString).appendingPathComponent("OsiriXDB_DataModel.mom"))
        let currentModel = NSManagedObjectModel(contentsOf: url)

        func sortedAttributes(_ entity: String, removing ignored: String?) -> [Any] {
            let attributes = NSMutableDictionary(dictionary: currentModel?.entitiesByName[entity]?.attributesByName ?? [:])
            if let ignored = ignored {
                attributes.removeObject(forKey: ignored)
            }
            return (attributes.allKeys as NSArray).sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:)))
        }

        let sortedStudies = sortedAttributes("Study", removing: "windowsState")
        let sortedSeries = sortedAttributes("Series", removing: "thumbnail")
        let sortedImages = sortedAttributes("Image", removing: nil)

        // Replaced, not appended (#748): the pane calls -awakeFromNib, and so
        // this, each time it is selected, and the database menu and the token
        // completions listed every field once more per selection.
        databaseStudyFieldsArray.setArray(sortedStudies)
        databaseSeriesFieldsArray.setArray(sortedSeries)
        databaseImageFieldsArray.setArray(sortedImages)
    }

    @objc public func specialFieldsLocalizedTitles() -> NSMutableArray! {
        let specialFieldsTitles = NSMutableArray()
        specialFieldsTitles.add(NSLocalizedString("Image Size", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("View Size", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Window Level / Window Width", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Image Position", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Zoom", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Rotation Angle", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Mouse Position (px)", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Mouse Position (mm)", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Thickness / Location / Position", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Patient's Actual Age", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Patient's Age At Acquisition", comment: ""))
        specialFieldsTitles.add(NSLocalizedString("Plugin", comment: ""))
        return specialFieldsTitles
    }

    @objc public func specialFieldsTitles() -> NSMutableArray! {
        let specialFieldsTitles = NSMutableArray()
        specialFieldsTitles.add("Image Size")
        specialFieldsTitles.add("View Size")
        specialFieldsTitles.add("Window Level / Window Width")
        specialFieldsTitles.add("Image Position")
        specialFieldsTitles.add("Zoom")
        specialFieldsTitles.add("Rotation Angle")
        specialFieldsTitles.add("Mouse Position (px)")
        specialFieldsTitles.add("Mouse Position (mm)")
        specialFieldsTitles.add("Thickness / Location / Position")
        specialFieldsTitles.add("Patient's Actual Age")
        specialFieldsTitles.add("Patient's Age At Acquisition")
        specialFieldsTitles.add("Plugin")
        return specialFieldsTitles
    }

    /// How many times `substring` occurs in `title`, case aside, counting every
    /// position: the former loops added one completion per occurrence.
    private func occurrences(of substring: NSString, in title: NSString?) -> Int {
        guard let title = title else { return 0 }
        let substringLength = substring.length
        guard title.length >= substringLength else { return 0 }
        let lowercaseSubstring = substring.lowercased
        var count = 0
        for j in 0..<(title.length - substringLength + 1) {
            if (lowercaseSubstring as NSString).isEqual(to: (title.substring(with: NSMakeRange(j, substringLength)) as NSString).lowercased) {
                count += 1
            }
        }
        return count
    }

    // auto completion
    public func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        let resultArray = NSMutableArray()
        let substring = substring as NSString
        let comparisonRange = NSMakeRange(0, substring.length)

        if tokenField.isEqual(to: prefPane?.contentTokenField) {
            resultArray.add(substring)

            for (titles, prefix) in [(databaseStudyFieldsArray, "DB_study."), (databaseSeriesFieldsArray, "DB_series."), (databaseImageFieldsArray, "DB_image.")] {
                for currentTitle in titles {
                    for _ in 0..<occurrences(of: substring, in: currentTitle as? NSString) {
                        resultArray.add("\(prefix)\(ciaDescription(currentTitle))")
                    }
                }
            }

            let localizedTitles = specialFieldsLocalizedTitles()!
            let titles = specialFieldsTitles()!

            for i in 0..<localizedTitles.count {
                for _ in 0..<occurrences(of: substring, in: localizedTitles.object(at: i) as? NSString) {
                    resultArray.add("Special_\(ciaDescription(titles.object(at: i)))")
                }
            }

            for field in DICOMFieldsArray ?? [] {
                let currentTitle = (field as! CIADICOMField).name()
                for _ in 0..<occurrences(of: substring, in: currentTitle as NSString?) {
                    resultArray.add("DICOM_\(ciaDescription(currentTitle))")
                }
            }
        } else if tokenField.isEqual(to: prefPane?.dicomNameTokenField) {
            for field in DICOMFieldsArray ?? [] {
                guard let currentTitle = (field as! CIADICOMField).name() as NSString? else { continue }
                if currentTitle.compare(substring as String, options: .caseInsensitive, range: comparisonRange) == .orderedSame {
                    resultArray.add(currentTitle)
                }
            }
        }

        return resultArray as? [Any]
    }

    @objc public func textViewDidChangeSelection(_ aNotification: Notification) {
        if skipTextViewDidChangeSelectionNotification { return }
        skipTextViewDidChangeSelectionNotification = true

        let pane = prefPane
        if let editor = pane?.contentTokenField?.currentEditor(), editor === (aNotification.object as AnyObject?) {
            let ranges = (aNotification.object as? NSTextView)?.selectedRanges ?? []

            if ranges.count == 1 {
                let selectedRange = ranges[0].rangeValue

                if selectedRange.length == 1 {
                    let tokens = pane?.contentTokenField?.objectValue as? NSArray
                    var selectedString = tokens?.subarray(with: selectedRange).first as? NSString

                    if selectedString?.hasPrefix("DICOM_") == true {
                        pane?.DICOMFieldsPopUpButton?.isEnabled = true
                        pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)

                        pane?.databaseFieldsPopUpButton?.isEnabled = false
                        pane?.databaseFieldsPopUpButton?.selectItem(at: 0)

                        pane?.specialFieldsPopUpButton?.isEnabled = false
                        pane?.specialFieldsPopUpButton?.selectItem(at: 0)

                        if selectedString!.length >= 7 {
                            selectedString = selectedString!.substring(from: 6) as NSString
                            var i = 0
                            while i < (DICOMFieldsArray?.count ?? 0) {
                                if ((DICOMFieldsArray!.object(at: i) as! CIADICOMField).name() as NSString?)?.isEqual(to: selectedString! as String) == true {
                                    pane?.dicomGroupTextField?.stringValue = ""
                                    pane?.dicomElementTextField?.stringValue = ""
                                    pane?.dicomNameTokenField?.stringValue = ""

                                    pane?.DICOMFieldsPopUpButton?.selectItem(at: i + 1)
                                    pane?.DICOMFieldsPopUpButton?.isEnabled = true
                                    break
                                }
                                i += 1
                            }
                        }
                    } else if selectedString?.hasPrefix("DB_") == true {
                        pane?.DICOMFieldsPopUpButton?.isEnabled = false
                        pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
                        pane?.databaseFieldsPopUpButton?.isEnabled = true
                        pane?.specialFieldsPopUpButton?.isEnabled = false
                        pane?.specialFieldsPopUpButton?.selectItem(at: 0)

                        if selectedString!.length >= 4 {
                            selectedString = selectedString!.substring(from: 3) as NSString
                            let index = pane?.databaseFieldsPopUpButton?.menu?.indexOfItem(withRepresentedObject: selectedString) ?? 0
                            pane?.databaseFieldsPopUpButton?.selectItem(at: index)
                        } else {
                            pane?.databaseFieldsPopUpButton?.selectItem(at: 0)
                        }
                    } else if selectedString?.hasPrefix("Special_") == true {
                        pane?.DICOMFieldsPopUpButton?.isEnabled = false
                        pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
                        pane?.databaseFieldsPopUpButton?.isEnabled = false
                        pane?.specialFieldsPopUpButton?.isEnabled = true
                        pane?.databaseFieldsPopUpButton?.selectItem(at: 0)

                        if selectedString!.length >= 9 {
                            selectedString = selectedString!.substring(from: 8) as NSString

                            // An `int`, as before: NSNotFound became -1.
                            let index = Int32(truncatingIfNeeded: specialFieldsTitles().index(of: selectedString!))
                            pane?.specialFieldsPopUpButton?.selectItem(at: Int(index))
                        } else {
                            pane?.databaseFieldsPopUpButton?.selectItem(at: 0)
                        }
                    } else {
                        pane?.DICOMFieldsPopUpButton?.isEnabled = false
                        pane?.DICOMFieldsPopUpButton?.selectItem(at: 0)
                        pane?.databaseFieldsPopUpButton?.isEnabled = false
                        pane?.databaseFieldsPopUpButton?.selectItem(at: 0)
                        pane?.specialFieldsPopUpButton?.isEnabled = false
                        pane?.specialFieldsPopUpButton?.selectItem(at: 0)
                    }
                }
            }
        }
        skipTextViewDidChangeSelectionNotification = false
    }

    @objc(setCustomDICOMFieldEditingEnable:)
    public func setCustomDICOMFieldEditingEnable(_ boo: Bool) {
        let pane = prefPane
        pane?.dicomNameTokenField?.isEnabled = boo
        pane?.dicomGroupTextField?.isEnabled = boo
        pane?.dicomElementTextField?.isEnabled = boo

        pane?.dicomNameTokenField?.stringValue = ""
        pane?.dicomGroupTextField?.stringValue = ""
        pane?.dicomElementTextField?.stringValue = ""

        // Black on the pane's own background disappeared in the dark appearance;
        // the semantic colours follow whichever one is active.
        let textColor: NSColor
        if boo {
            textColor = NSColor.labelColor
        } else {
            textColor = NSColor.disabledControlTextColor
        }

        pane?.groupLabel?.textColor = textColor
        pane?.elementLabel?.textColor = textColor
        pane?.nameLabel?.textColor = textColor
    }

    @objc public func checkAnnotations() -> Bool {
        for annotation in annotationsArray where annotation.placeHolder == nil {
            let r = CIARunAlertPanel(NSLocalizedString("Saving Annotations", comment: ""), NSLocalizedString("Any Annotation left outside the place holders will be lost.", comment: ""), NSLocalizedString("OK", comment: ""), NSLocalizedString("Cancel", comment: ""), nil)
            if r == ciaAlertDefaultReturn {
                return true
            } else {
                return false
            }
        }
        return true
    }

    /// Always true: the former code looked for empty 'DICOM_', 'DB_' and
    /// 'Special_' tokens, and its alert about them was commented out.
    @objc public func checkAnnotationsContent() -> Bool {
        return true
    }

    /// Always true, as -checkAnnotationsContent.
    @objc(checkAnnotationContent:)
    public func checkAnnotationContent(_ annotation: CIAAnnotation!) -> Bool {
        return true
    }

    @objc public func saveAnnotationLayout() {
        saveAnnotationLayout(forModality: currentModalityValue)
    }

    @objc(saveAnnotationLayoutForModality:)
    public func saveAnnotationLayout(forModality modality: String!) {
        let placeHolders = layoutView?.placeHolderArray
        let layoutViewDict = NSMutableDictionary()

        if (prefPane?.sameAsDefaultButton?.state ?? .off) == .on {
            layoutViewDict.setObject("1", forKey: "sameAsDefault" as NSString)
        } else {
            layoutViewDict.setObject("0", forKey: "sameAsDefault" as NSString)

            for i in 0..<8 {
                let placeHolder = placeHolders?[i]

                let annotations = NSMutableArray()
                for case let annotation as CIAAnnotation in placeHolder?.annotationsArray() ?? [] {
                    let annot = NSMutableDictionary()
                    ciaSetObject(annot, annotation.title, forKey: "title")
                    ciaSetObject(annot, annotation.content, forKey: "content")

                    let contentToSave = NSMutableArray()

                    for case let currentField as NSString in annotation.content ?? [] {
                        let fieldDict = NSMutableDictionary()

                        if currentField.hasPrefix("DICOM_") {
                            // Per token, and saved only when known (#748): a
                            // DICOM_ token that named no known field and did not
                            // read as DICOM_group_element was saved with the
                            // previous DICOM_ token's group and element, so the
                            // annotation showed that token's tag. Without them
                            // DCMPix shows "-" for the field.
                            var group: UInt32? = nil, element: UInt32? = nil
                            var name: String = ""
                            var isCustomDICOMField = true
                            if currentField.length > 6 {
                                fieldDict.setObject("DICOM", forKey: "type" as NSString)

                                let comparisonRange = NSMakeRange(6, currentField.length - 6)
                                var k = 0
                                while k < (DICOMFieldsArray?.count ?? 0) && isCustomDICOMField {
                                    let field = DICOMFieldsArray!.object(at: k) as! CIADICOMField
                                    let currentTitle = field.name() ?? ""
                                    if currentField.compare(currentTitle, options: .caseInsensitive, range: comparisonRange) == .orderedSame {
                                        group = UInt32(bitPattern: field.group())
                                        element = UInt32(bitPattern: field.element())
                                        name = field.name() ?? ""
                                        isCustomDICOMField = false
                                    }
                                    k += 1
                                }
                                if isCustomDICOMField {
                                    let components = currentField.components(separatedBy: "_")
                                    if components.count >= 3 {
                                        if let scannedGroup = hexTagComponent(components[1]),
                                           let scannedElement = hexTagComponent(components[2]) {
                                            group = scannedGroup
                                            element = scannedElement
                                        }
                                        if components.count == 4 {
                                            name = components[3]
                                        }
                                    }
                                }
                                if let group = group, let element = element {
                                    fieldDict.setObject(NSNumber(value: Int32(bitPattern: group)), forKey: "group" as NSString)
                                    fieldDict.setObject(NSNumber(value: Int32(bitPattern: element)), forKey: "element" as NSString)
                                }
                                fieldDict.setObject(name, forKey: "name" as NSString)
                                fieldDict.setObject(currentField, forKey: "tokenTitle" as NSString)
                                contentToSave.add(fieldDict)
                            }
                        } else if currentField.hasPrefix("DB_") {
                            // Without a dot the token names no level and field:
                            // it is left out, as an empty DB_ token, instead of
                            // raising NSRangeException (#748).
                            let rangeOfDot = currentField.range(of: ".")
                            if currentField.length > 3 && rangeOfDot.location != NSNotFound {
                                fieldDict.setObject("DB", forKey: "type" as NSString)
                                fieldDict.setObject((currentField.substring(from: 3) as NSString).substring(to: rangeOfDot.location &- 3), forKey: "level" as NSString)
                                fieldDict.setObject(currentField.substring(from: rangeOfDot.location &+ 1), forKey: "field" as NSString)

                                contentToSave.add(fieldDict)
                            }
                        } else if currentField.hasPrefix("Special_") {
                            if currentField.length > 8 {
                                fieldDict.setObject("Special", forKey: "type" as NSString)
                                fieldDict.setObject(currentField.substring(from: 8), forKey: "field" as NSString)
                                contentToSave.add(fieldDict)
                            }
                        } else {
                            fieldDict.setObject("Manual", forKey: "type" as NSString)
                            fieldDict.setObject(currentField, forKey: "field" as NSString)
                            contentToSave.add(fieldDict)
                        }
                    }
                    annot.setObject(contentToSave, forKey: "fullContent" as NSString) // fullContent contains more details than "content" -> use it for display in the DCM view
                    annotations.add(annot)
                }

                layoutViewDict.setObject(annotations, forKey: placeHolderKeys[i] as NSString)
            }
        }
        ciaSetObject(annotationsLayout, layoutViewDict, forKey: modality)

        UserDefaults.standard.set(annotationsLayout, forKey: "CUSTOM_IMAGE_ANNOTATIONS")
    }

    @IBAction public func switchModality(_ sender: Any?) {
        switchModality(sender, save: true)
    }

    @objc(switchModality:save:)
    public func switchModality(_ sender: Any?, save: Bool) {
        let pane = prefPane
        if !checkAnnotations() || !checkAnnotationsContent() {
            if let currentModality = currentModalityValue {
                pane?.modalitiesPopUpButton?.title = currentModality //currentModality
            }
            return
        }

        validateTokenTextField(self)
        selectedAnnotationValue = nil

        pane?.titleTextField?.isEnabled = false
        pane?.contentTokenField?.isEnabled = false
        setCustomDICOMFieldEditingEnable(false)

        if save {
            saveAnnotationLayout(forModality: currentModalityValue)
        }

        let popUp = sender as? NSPopUpButton
        if (popUp?.indexOfSelectedItem ?? 0) == 0 {
            currentModalityValue = "Default"
        } else {
            currentModalityValue = popUp?.selectedItem?.title
        }

        let isDefault = (currentModalityValue as NSString?)?.isEqual(to: "Default") ?? false
        pane?.sameAsDefaultButton?.isHidden = isDefault
        pane?.resetDefaultButton?.isHidden = !isDefault
        loadAnnotationLayout(forModality: currentModalityValue)

        pane?.titleTextField?.stringValue = ""
        pane?.contentTokenField?.stringValue = ""
    }

    @objc(loadAnnotationLayoutForModality:)
    public func loadAnnotationLayout(forModality modality: String!) {
        removeAllAnnotations()

        let pane = prefPane
        pane?.orientationWidgetButton?.state = .off

        let palceHoldersForModality = modality.flatMap { annotationsLayout.object(forKey: $0) as? NSDictionary }
        let placeHolders = layoutView?.placeHolderArray

        var n = 0
        for i in 0..<8 {
            let annotations = palceHoldersForModality?.object(forKey: placeHolderKeys[i]) as? NSArray
            let placeHolder = placeHolders?[i]

            for entry in annotations ?? [] {
                n += 1
                let entry = entry as? NSDictionary
                let anAnnotation = CIAAnnotation(frame: NSMakeRect(10.0, 10.0, 75, 22))
                anAnnotation.title = entry?.object(forKey: "title") as? String
                anAnnotation.setContent(entry?.object(forKey: "content") as? NSArray)

                if (anAnnotation.title as NSString?)?.isEqual(to: "Orientation") == true,
                   anAnnotation.content?.count == 1,
                   (anAnnotation.content.object(at: 0) as? NSString)?.isEqual(to: "Special_Orientation") == true {
                    anAnnotation.isOrientationWidget = true
                    pane?.orientationWidgetButton?.state = .on
                }

                anAnnotation.placeHolder = placeHolder
                placeHolder?.addAnnotation(anAnnotation, animate: false)
                placeHolder?.updateFrameAroundAnnotations(withAnimation: false)

                annotationsArray.append(anAnnotation)
                layoutView?.addSubview(anAnnotation)
            }

            placeHolder?.alignAnnotations()
            placeHolder?.updateFrameAroundAnnotations(withAnimation: false)
        }

        pane?.sameAsDefaultButton?.state = .off

        if n == 0 && !((modality as NSString?)?.isEqual(to: "Default") ?? false) {
            loadAnnotationLayout(forModality: "Default")
            pane?.sameAsDefaultButton?.state = .on
            layoutView?.isEnabled = false
            pane?.orientationWidgetButton?.isEnabled = false
        } else {
            layoutView?.isEnabled = pane?.isUnlocked() ?? false
            pane?.orientationWidgetButton?.isEnabled = pane?.isUnlocked() ?? false
        }

        layoutView?.needsDisplay = true
    }

    @objc public func removeAllAnnotations() {
        let placeHolders = layoutView?.placeHolderArray ?? []
        for placeHolder in placeHolders {
            placeHolder.annotationsArray().removeAllObjects()
            placeHolder.hasFocus = false
            placeHolder.updateFrameAroundAnnotations(withAnimation: false)
        }

        for annotation in annotationsArray {
            annotation.removeFromSuperview()
        }

        annotationsArray.removeAll()
        layoutView?.needsDisplay = true
    }

    @objc(setLayoutView:)
    public func setLayoutView(_ view: CIALayoutView!) {
        layoutView = view
    }

    @objc(setPrefPane:)
    public func setPrefPane(_ aPrefPane: OSICustomImageAnnotations!) {
        prefPane = aPrefPane
    }

    @objc(setOrientationWidgetEnabled:)
    public func setOrientationWidgetEnabled(_ enabled: Bool) {
        let index = [1, 3, 4, 6] // index of the placeholders that can hold an orientation widget
        let placeHolders = layoutView?.placeHolderArray

        if enabled {
            for i in 0..<4 {
                let placeHolder = placeHolders?[index[i]]

                let anAnnotation = CIAAnnotation(frame: NSMakeRect(10.0, 10.0, 75, 22))
                anAnnotation.title = "Orientation"
                anAnnotation.setContent(["Special_Orientation"] as NSArray)
                anAnnotation.isOrientationWidget = true
                anAnnotation.placeHolder = placeHolder
                placeHolder?.insertAnnotation(anAnnotation, at: 0)

                annotationsArray.append(anAnnotation)
                layoutView?.addSubview(anAnnotation)

                placeHolder?.alignAnnotations()
                placeHolder?.updateFrameAroundAnnotations()
                placeHolder?.alignAnnotations()
            }
            layoutView?.display()
        } else {
            for i in 0..<4 {
                guard let placeHolder = placeHolders?[index[i]] else { continue }
                var j = 0
                while j < placeHolder.annotationsArray().count {
                    let anAnnotation = placeHolder.annotationsArray().object(at: j) as! CIAAnnotation
                    if anAnnotation.isOrientationWidget {
                        annotationsArray.removeAll { $0 === anAnnotation }
                        anAnnotation.removeFromSuperview()
                        placeHolder.removeAnnotation(anAnnotation)
                        placeHolder.updateFrameAroundAnnotations()
                        placeHolder.alignAnnotations()
                        layoutView?.needsDisplay = true
                    }
                    j += 1
                }
            }
        }
    }
}
