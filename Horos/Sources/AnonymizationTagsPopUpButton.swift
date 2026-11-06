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
import IsiXDICOMDataset
import IsiXDICOMFile

/// The comparators of the former CompareDCMAttributeTagNames and
/// CompareDCMAttributeTagStringValues, for the same NSArray sort.
private let compareDCMAttributeTagNames: @convention(c) (Any, Any, UnsafeMutableRawPointer?) -> Int = { lsp, rsp, _ in
    return anonymizationCaseInsensitiveCompare((lsp as? DICOMAttributeTag)?.name, (rsp as? DICOMAttributeTag)?.name)
}

private let compareDCMAttributeTagStringValues: @convention(c) (Any, Any, UnsafeMutableRawPointer?) -> Int = { lsp, rsp, _ in
    return anonymizationCaseInsensitiveCompare((lsp as? DICOMAttributeTag)?.stringValue, (rsp as? DICOMAttributeTag)?.stringValue)
}

/// What %@ wrote for a string, nil included.
private func formatted(_ string: String?) -> String {
    return string ?? "(null)"
}

/// The pop-up menu of DICOM tags of the anonymization panel: the tags of the
/// file being anonymized, the dictionary sorted by name and by value, and
/// Custom...
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/AnonymizationTagsPopUpButton.h> are those of the former class. The
/// selected tag is `selectedAttributeTag`; the former -selectedTag, which
/// Objective-C could not call, left with its override of NSPopUpButton's.
@objc(AnonymizationTagsPopUpButton)
public final class AnonymizationTagsPopUpButton: NSPopUpButton {
    private var selectedAttributeTagStorage: DICOMAttributeTag?

    @objc(tagsMenu)
    public class func tagsMenu() -> NSMenu! {
        return tagsMenu(withTarget: nil, action: nil)
    }

    @objc(tagsForFile:)
    class func tags(forFile dicomFile: String!) -> [Any]! {
        guard let dicomFile = dicomFile, DicomFile.isDICOMFile(dicomFile) else {
            return nil
        }

        // A file DCMTK cannot read gave no attributes, so an empty list.
        let dcmObject = DCMObject.object(contentsOfFile: dicomFile)
        let attributes = dcmObject?.attributes

        let sortedKeys = (attributes?.allKeys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) ?? []
        let tags = NSMutableArray(capacity: sortedKeys.count)

        for key in sortedKeys {
            if let attr = attributes?.object(forKey: key) {
                tags.add(attr)
            }
        }

        return tags as? [Any]
    }

    @objc(tagsMenuWithTarget:action:)
    public class func tagsMenu(withTarget obj: Any!, action: Selector!) -> NSMenu! {
        let tagsMenu = NSMenu(title: "DCM Annotation Tags")
        let target = obj as AnyObject?

        if let tagsOfFile = tags(forFile: AnonymizationSelectorCalls.templateDicomFile()) {
            let tagsOfTheDICOMFile = NSMenu(title: "")
            let tagsOfTheDICOMFileMenuItem = NSMenuItem(title: NSLocalizedString("File(s) tags", comment: ""), action: nil, keyEquivalent: "")
            tagsOfTheDICOMFileMenuItem.submenu = tagsOfTheDICOMFile
            tagsMenu.addItem(tagsOfTheDICOMFileMenuItem)
            for case let tag as DCMAttribute in tagsOfFile {
                do {
                    try HorosObjCException.perform {
                        var valDescription = ""

                        if tag.valueLength < 100 {
                            for v in (tag.values as NSArray?) ?? NSArray() {
                                valDescription += " " + String(describing: v as AnyObject)
                            }
                        }

                        let attributeTag = tag.attrTag
                        let description: String

                        if !valDescription.isEmpty {
                            description = "\(formatted(attributeTag?.stringValue)) - \(formatted(attributeTag?.name)) -\(valDescription)"
                        } else {
                            description = "\(formatted(attributeTag?.stringValue)) - \(formatted(attributeTag?.name))"
                        }

                        let item = NSMenuItem(title: description, action: action, keyEquivalent: "")
                        item.representedObject = attributeTag
                        item.target = target
                        tagsOfTheDICOMFile.addItem(item)
                    }
                } catch {
                    if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                        _N2LogExceptionImpl(e, true, "+[AnonymizationTagsPopUpButton tagsMenuWithTarget:action:]")
                    }
                }
            }
        }

        let tagDictionary = DICOMTagDictionary.sharedTagDictionary()
        let dcmTags = NSMutableArray(capacity: tagDictionary?.count ?? 0)
        for case let dcmTagsKey as String in tagDictionary?.allKeys ?? [] {
            if let tag = DICOMAttributeTag.tag(withTagString: dcmTagsKey) {
                dcmTags.add(tag)
            }
        }

        let tagsSortedByNameMenu = NSMenu(title: "")
        let tagsSortedByNameMenuItem = NSMenuItem(title: NSLocalizedString("Sorted by Name", comment: ""), action: nil, keyEquivalent: "")
        tagsSortedByNameMenuItem.submenu = tagsSortedByNameMenu
        tagsMenu.addItem(tagsSortedByNameMenuItem)
        for case let tag as DICOMAttributeTag in dcmTags.sortedArray(compareDCMAttributeTagNames, context: nil) {
            let item = NSMenuItem(title: "\(formatted(tag.name)) - \(formatted(tag.stringValue))", action: action, keyEquivalent: "")
            item.representedObject = tag
            item.target = target
            tagsSortedByNameMenu.addItem(item)
        }

        let tagsSortedByStringValueMenu = NSMenu(title: "")
        let tagsSortedByStringValueMenuItem = NSMenuItem(title: NSLocalizedString("Sorted by Value", comment: ""), action: nil, keyEquivalent: "")
        tagsSortedByStringValueMenuItem.submenu = tagsSortedByStringValueMenu
        tagsMenu.addItem(tagsSortedByStringValueMenuItem)
        for case let tag as DICOMAttributeTag in dcmTags.sortedArray(compareDCMAttributeTagStringValues, context: nil) {
            let item = NSMenuItem(title: "\(formatted(tag.stringValue)) - \(formatted(tag.name))", action: action, keyEquivalent: "")
            item.representedObject = tag
            item.target = target
            tagsSortedByStringValueMenu.addItem(item)
        }

        return tagsMenu
    }

    /// -[NSPopUpButton initWithFrame:] is -initWithFrame:pullsDown:NO.
    public override init(frame buttonFrame: NSRect) {
        super.init(frame: buttonFrame, pullsDown: false)

        cell = N2CustomTitledPopUpButtonCell()
        autoenablesItems = false
        menu = AnonymizationTagsPopUpButton.tagsMenu(withTarget: self, action: #selector(tagsMenuItemSelectedAction(_:)))

        let extraItem = NSMenuItem(title: NSLocalizedString("Custom...", comment: "Title of menu item allowing the user to specify a custom anonymization dicom tag"),
                                   action: #selector(customMenuItemAction(_:)), keyEquivalent: "")
        extraItem.target = self
        menu?.addItem(extraItem)

        selectedAttributeTag = nil
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(customMenuItemAction:)
    func customMenuItemAction(_ sender: Any?) {
        let panelController = AnonymizationCustomTagPanelController()
        panelController.attributeTag = selectedAttributeTag
        // The sheet's delegate releases the controller.
        let context = Unmanaged.passRetained(panelController).toOpaque()
        window!.beginSheet(panelController.window!) { response in
            self.addCustomTagPanelDidEnd(panelController.window! as! NSPanel, returnCode: response.rawValue, contextInfo: context)
        }
        panelController.window?.orderFront(self)
    }

    @objc(addCustomTagPanelDidEnd:returnCode:contextInfo:)
    func addCustomTagPanelDidEnd(_ panel: NSPanel, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo = contextInfo else {
            return
        }
        let panelController = Unmanaged<AnonymizationCustomTagPanelController>.fromOpaque(contextInfo).takeRetainedValue()

        if returnCode == NSApplication.ModalResponse.stop.rawValue {
            selectedAttributeTag = panelController.attributeTag
        }

        panel.close()
    }

    @objc(tagsMenuItemSelectedAction:)
    func tagsMenuItemSelectedAction(_ menuItem: NSMenuItem) {
        selectedAttributeTag = menuItem.representedObject as? DICOMAttributeTag
    }

    /// Retained and nonatomic in the former header. `dynamic`, so that KVO's
    /// automatic notifications wrap the setter as before; the explicit
    /// -didChangeValueForKey: calls are the former setter's.
    @objc public dynamic var selectedAttributeTag: DICOMAttributeTag! {
        get {
            return selectedAttributeTagStorage
        }
        set {
            let tag = newValue
            selectedAttributeTagStorage = tag

            didChangeValue(forKey: "title")

            for item in itemArray {
                item.state = .off
                if item.hasSubmenu {
                    for subitem in item.submenu?.items ?? [] {
                        subitem.state = tag != nil && (subitem.representedObject as? NSObject)?.isEqual(tag) == true ? .on : .off
                    }
                }
            }

            let displayedTitle: String?
            if let selected = selectedAttributeTagStorage {
                displayedTitle = selected.name != nil ? "\(formatted(selected.name)) - \(formatted(selected.stringValue))" : selected.stringValue
            } else {
                displayedTitle = NSLocalizedString("Select a DICOM tag...", comment: "")
            }
            (cell as? N2CustomTitledPopUpButtonCell)?.displayedTitle = displayedTitle
            needsDisplay = true

            didChangeValue(forKey: "selectedAttributeTag")
        }
    }

    @objc(validateMenuItem:)
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let s = window?.windowController as? AnonymizationPanelController
        let v = s?.anonymizationViewController

        var found = false
        let represented = menuItem.representedObject as? DICOMAttributeTag
        let mg = represented?.group ?? 0, me = represented?.element ?? 0
        for case let t as DICOMAttributeTag in (v?.tags as NSArray?) ?? NSArray() {
            if t.group == mg && t.element == me {
                found = true
                break
            }
        }

        if found {
            menuItem.state = .on
        } else {
            menuItem.state = .off
        }

        return true
    }
}
