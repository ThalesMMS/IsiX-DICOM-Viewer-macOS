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
import ObjectiveC

/// The class methods of Anonymization (Anonymization.h) that the anonymization
/// interface calls, sent by their Objective-C selectors. The collections go
/// through as the Foundation objects they are: bridged to a Swift dictionary,
/// a template's keys would enumerate in another order.
enum AnonymizationSelectorCalls {
    private static var anonymization: AnyClass {
        return NSClassFromString("Anonymization")!
    }

    private static func implementation<Function>(_ name: String, as type: Function.Type) -> (Selector, Function) {
        let selector = NSSelectorFromString(name)
        let method = class_getClassMethod(anonymization, selector)!
        return (selector, unsafeBitCast(method_getImplementation(method), to: type))
    }

    /// +[Anonymization tagsValuesArrayFromDictionary:]
    static func tagsValuesArray(fromDictionary dic: AnyObject?) -> NSArray? {
        typealias Function = @convention(c) (AnyClass, Selector, AnyObject?) -> Unmanaged<AnyObject>?
        let (selector, function) = implementation("tagsValuesArrayFromDictionary:", as: Function.self)
        return function(anonymization, selector, dic)?.takeUnretainedValue() as? NSArray
    }

    /// +[Anonymization tagsValuesDictionaryFromArray:]
    static func tagsValuesDictionary(fromArray arr: NSArray?) -> NSDictionary? {
        typealias Function = @convention(c) (AnyClass, Selector, NSArray?) -> Unmanaged<AnyObject>?
        let (selector, function) = implementation("tagsValuesDictionaryFromArray:", as: Function.self)
        return function(anonymization, selector, arr)?.takeUnretainedValue() as? NSDictionary
    }

    /// +[Anonymization tagsValues:isEqualTo:]
    static func tagsValues(_ a1: NSArray?, isEqualTo a2: NSArray?) -> Bool {
        typealias Function = @convention(c) (AnyClass, Selector, NSArray?, NSArray?) -> ObjCBool
        let (selector, function) = implementation("tagsValues:isEqualTo:", as: Function.self)
        return function(anonymization, selector, a1, a2).boolValue
    }

    /// +[Anonymization templateDicomFile]
    static func templateDicomFile() -> String? {
        typealias Function = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let (selector, function) = implementation("templateDicomFile", as: Function.self)
        return function(anonymization, selector)?.takeUnretainedValue() as? String
    }
}

/// -[NSString caseInsensitiveCompare:] as Objective-C sent it: a nil receiver
/// answered NSOrderedSame, and a nil argument sorts before any string.
func anonymizationCaseInsensitiveCompare(_ lhs: String?, _ rhs: String?) -> Int {
    guard let lhs = lhs else {
        return ComparisonResult.orderedSame.rawValue
    }
    guard let rhs = rhs else {
        return ComparisonResult.orderedDescending.rawValue
    }
    return (lhs as NSString).caseInsensitiveCompare(rhs).rawValue
}

/// CompareArraysByNameOfDCMAttributeTagAtIndexZero (kept, with its C++ name, in
/// AnonymizationViewController+CAPI.mm): Swift cannot name a C++ function, so
/// the array is sorted by the same NSArray method with this equivalent.
private let compareArraysByNameOfDCMAttributeTagAtIndexZero: @convention(c) (Any, Any, UnsafeMutableRawPointer?) -> Int = { arg1, arg2, _ in
    let name1 = ((arg1 as! NSArray).object(at: 0) as? DCMAttributeTag)?.name
    let name2 = ((arg2 as! NSArray).object(at: 0) as? DCMAttributeTag)?.name
    return anonymizationCaseInsensitiveCompare(name1, name2)
}

/// The tags an anonymization replaces, each with a check box and a value, and
/// the templates (the "anonymizeTemplate" user default) that fill them.
///
/// Implemented in Swift since #712: the Objective-C name, the selectors and
/// <Horos/AnonymizationViewController.h> are those of the former class.
@objc(AnonymizationViewController)
public final class AnonymizationViewController: NSViewController {
    /// Read-only in the former header. The nib sets them.
    @IBOutlet @objc public private(set) var annotationsBox: N2AdaptiveBox!
    @IBOutlet @objc public private(set) var templatesPopup: NSPopUpButton!
    @IBOutlet @objc public private(set) var tagsView: AnonymizationTagsView!
    @IBOutlet var saveTemplateButton: NSButton!
    @IBOutlet var deleteTemplateButton: NSButton!

    /// Retained and read-only in the former header. Do not add elements
    /// directly: use addTag and removeTag.
    @objc public private(set) var tags: NSMutableArray!

    private var formatsAreOkStorage = false

    /// Read-only for other classes, and bound by the nibs. The private
    /// -setFormatsAreOk: below is what KVO observes, as it observed the class
    /// extension's setter.
    @objc public var formatsAreOk: Bool {
        return formatsAreOkStorage
    }

    /// `dynamic`, so that it is sent as a message and KVO's automatic
    /// notifications wrap it. The explicit -didChangeValueForKey: is the former
    /// setter's.
    @objc(setFormatsAreOk:) private dynamic func setFormatsAreOk(_ flag: Bool) {
        if flag == formatsAreOkStorage {
            return
        }
        formatsAreOkStorage = flag
        didChangeValue(forKey: "formatsAreOk")
    }

    /// The KVO context the former class used: the tags view itself.
    private var tagsViewContext: UnsafeMutableRawPointer? {
        return tagsView.map { Unmanaged.passUnretained($0).toOpaque() }
    }

    private var tagList: NSArray {
        return tags ?? NSArray()
    }

    /// -[NSUserDefaultsController dictionaryForKey:] (NSUserDefaultsController+N2)
    /// for "anonymizeTemplate", as the NSDictionary it returns.
    private static func anonymizeTemplates() -> NSDictionary? {
        let selector = #selector(NSUserDefaultsController.dictionary(forKey:))
        return NSUserDefaultsController.shared.perform(selector, with: "anonymizeTemplate")?.takeUnretainedValue() as? NSDictionary
    }

    /// What -[NSMutableDictionary setObject:forKey:] and -removeObjectForKey:
    /// raised for a nil key or object.
    private static func raiseNilArgument(_ selector: String) {
        NSException(name: .invalidArgumentException,
                    reason: "*** -[__NSDictionaryM \(selector)]: key or object cannot be nil", userInfo: nil).raise()
    }

    @objc class func basicTags() -> NSArray {
        let tags = NSMutableArray()
        for name in ["PatientsName", "PatientsSex", "PatientID", "PatientsWeight", "PatientsAge"] {
            // +arrayWithObjects: stopped at the first nil.
            guard let tag = DCMAttributeTag.tag(withName: name) else {
                break
            }
            tags.add(tag)
        }
        return tags.copy() as! NSArray
    }

    @objc func refreshTemplatesList() {
        templatesPopup.removeAllItems()
        let templates = AnonymizationViewController.anonymizeTemplates()
        let names = (templates?.allKeys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) ?? []
        for case let name as String in names {
            templatesPopup.addItem(withTitle: name)
        }
        templatesPopup.isEnabled = (templates?.count ?? 0) > 0
    }

    /// -initWithNibName:@"AnonymizationView" bundle:NULL; the view is loaded here.
    @objc(initWithTags:values:)
    public init(tags shownDcmTags: [Any]!, values: [Any]!) {
        super.init(nibName: "AnonymizationView", bundle: nil)
        _ = view // load
        AnonymizationFieldsScroll.install(in: annotationsBox, document: tagsView)
        saveTemplateButton.keyEquivalent = "s"
        saveTemplateButton.keyEquivalentModifierMask = .command

        tags = NSMutableArray()

        // templates

        let tempCell = templatesPopup.cell
        templatesPopup.cell = N2CustomTitledPopUpButtonCell()
        templatesPopup.cell?.controlSize = tempCell?.controlSize ?? .regular
        templatesPopup.cell?.font = tempCell?.font
        templatesPopup.autoenablesItems = false
        templatesPopup.target = self
        templatesPopup.action = #selector(templatesPopupAction(_:))
        refreshTemplatesList()

        // tags

        let dcmTagsToShow = (shownDcmTags as NSArray?)?.mutableCopy() as? NSMutableArray

        if (dcmTagsToShow?.count ?? 0) == 0 {
            dcmTagsToShow?.addObjects(from: AnonymizationViewController.basicTags() as! [Any])
        }

        for tag in dcmTagsToShow ?? NSMutableArray() {
            addTag(tag as? DCMAttributeTag)
        }

        setTagsValues(values)
        observeValue(forKeyPath: nil, of: nil, change: nil, context: tagsViewContext)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(adaptBoxToAnnotations)
    public func adaptBoxToAnnotations() {
        AnonymizationFieldsScroll.update(document: tagsView, height: tagsView.idealSize().height)
    }

    @objc(addTag:)
    public func addTag(_ tag: DCMAttributeTag!) {
        guard let tag = tag else {
            return
        }

        if tags.contains(tag) {
            return
        }

        tags.add(tag)
        tagsView.addTag(tag)

        tagsView.checkBox(forObject: tag)?.cell?.addObserver(self, forKeyPath: "state", options: .initial, context: tagsViewContext)
        tagsView.textField(forObject: tag)?.addObserver(self, forKeyPath: "value", options: .initial, context: tagsViewContext)
        tagsView.textField(forObject: tag)?.addObserver(self, forKeyPath: "formatIsOk", options: .initial, context: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(observeTextDidChangeNotification(_:)),
                                               name: NSControl.textDidChangeNotification, object: tagsView.textField(forObject: tag))

        adaptBoxToAnnotations()
    }

    @objc(removeTag:)
    public func removeTag(_ tag: DCMAttributeTag!) {
        guard let tag = tag, tags.contains(tag) else {
            return
        }

        tagsView.checkBox(forObject: tag)?.cell?.removeObserver(self, forKeyPath: "state")
        tagsView.textField(forObject: tag)?.removeObserver(self, forKeyPath: "value")
        tagsView.textField(forObject: tag)?.removeObserver(self, forKeyPath: "formatIsOk")
        NotificationCenter.default.removeObserver(self, name: NSControl.textDidChangeNotification, object: tagsView.textField(forObject: tag))

        tags.remove(tag)
        tagsView.removeTag(tag)

        adaptBoxToAnnotations()
    }

    @objc func nameOfCurrentMatchingTemplate() -> String? {
        let currentTagsValues = tagsValues() as NSArray?

        var matchName: String?
        if let templates = AnonymizationViewController.anonymizeTemplates() {
            // In the dictionary's own order: the last match wins, as before.
            for (name, template) in templates {
                let named = AnonymizationSelectorCalls.tagsValuesArray(fromDictionary: template as AnyObject)
                if AnonymizationSelectorCalls.tagsValues(currentTagsValues, isEqualTo: named) {
                    matchName = name as? String
                }
            }
        }

        return matchName
    }

    @objc func updateFormatsAreOk() {
        var ok = true
        for tag in tagList {
            let textField = tagsView.textField(forObject: tag)
            if !(textField?.formatIsOk ?? false) {
                ok = false
            }
        }
        setFormatsAreOk(ok)
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                      change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        assumeMainActor((keyPath, context)) { (keyPath, context) in
            if context == tagsViewContext {
                let matchName = nameOfCurrentMatchingTemplate()

                if let matchName = matchName {
                    templatesPopup.selectItem(withTitle: matchName)
                } else {
                    templatesPopup.selectedItem?.state = .off
                }

                (templatesPopup.cell as? N2CustomTitledPopUpButtonCell)?.displayedTitle = matchName ?? NSLocalizedString("Custom", comment: "")
                templatesPopup.needsDisplay = true

                deleteTemplateButton.isEnabled = matchName != nil
            } else if keyPath == "formatIsOk" {
                updateFormatsAreOk()
            }
        }
    }

    @objc(observeTextDidChangeNotification:)
    func observeTextDidChangeNotification(_ notif: Notification) {
        observeValue(forKeyPath: nil, of: nil, change: nil, context: tagsViewContext)
    }

    isolated deinit {
        while let tags = tags, tags.count > 0 {
            removeTag(tags.object(at: tags.count - 1) as? DCMAttributeTag)
        }

        tags = nil
    }

    @objc(tagsValues)
    public func tagsValues() -> [Any]! {
        let out = NSMutableArray()

        for tag in tagList {
            if let checkBox = tagsView.checkBox(forObject: tag), checkBox.state.rawValue != 0 {
                let tf = tagsView.textField(forObject: tag)

                let value: Any? = ((tf?.stringValue as NSString?)?.length ?? 0) > 0 ? tf?.objectValue : nil

                // +arrayWithObjects: stopped at a nil value.
                if let value = value {
                    out.add(NSArray(objects: tag, value))
                } else {
                    out.add(NSArray(object: tag))
                }
            }
        }

        return (out.copy() as! NSArray) as? [Any]
    }

    @objc(setTagsValues:)
    public func setTagsValues(_ tagsValues: [Any]!) {
        let tagsValues = (tagsValues as NSArray?)?.sortedArray(compareArraysByNameOfDCMAttributeTagAtIndexZero, context: nil)

        let zeroTags = tags?.mutableCopy() as? NSMutableArray


        // this removes all previous tags
        if (tagsValues?.count ?? 0) > 0 {
            while let tags = tags, tags.count > 0 {
                removeTag(tags.object(at: 0) as? DCMAttributeTag)
            }
        }

        for case let tagValue as NSArray in tagsValues ?? [] {
            let tag = tagValue.object(at: 0) as? DCMAttributeTag
            addTag(tag)
            let value: Any? = tagValue.count > 1 ? tagValue.object(at: 1) : nil
            let checkBox = tagsView.checkBox(forObject: tag)
            checkBox?.state = value != nil ? .on : .off
            let textField = tagsView.textField(forObject: tag)

            if let value = value, !(value is NSString) {
                do {
                    try HorosObjCException.perform {
                        textField?.objectValue = value
                    }
                } catch {
                    NSLog("Warning: invalid value type %@ for DICOM tag %@",
                          NSStringFromClass(type(of: value as AnyObject)), tag?.name ?? "(null)")
                }
            } else {
                textField?.stringValue = (value as? String) ?? ""
            }

            if let tag = tag {
                zeroTags?.remove(tag)
            }
        }

        for tag in zeroTags ?? NSMutableArray() {
            tagsView.checkBox(forObject: tag)?.state = .off
            tagsView.textField(forObject: tag)?.stringValue = ""
        }

        observeValue(forKeyPath: nil, of: nil, change: nil, context: tagsViewContext)


        /* UGLY HOTFIX / WORKAROUND UNTIL REVIEWING N2AdaptiveBox
         ------------------------------------------------------ */
        if let browserWindow = BrowserController.currentBrowser()?.window {
            var frame = browserWindow.frame
            frame.size.width -= 1
            browserWindow.setFrame(frame, display: true)
            frame.size.width += 1
            browserWindow.setFrame(frame, display: true)
        }
        /* ---------------------------------------------------- */
    }

    @objc(saveTemplate:withName:)
    func saveTemplate(_ templ: [Any]!, withName name: String!) {
        let dic = (AnonymizationViewController.anonymizeTemplates()?.mutableCopy() as? NSMutableDictionary) ?? NSMutableDictionary()

        guard let template = AnonymizationSelectorCalls.tagsValuesDictionary(fromArray: templ as NSArray?), let name = name else {
            AnonymizationViewController.raiseNilArgument("setObject:forKey:")
            return
        }
        dic.setObject(template, forKey: name as NSString)
        UserDefaults.standard.set(dic, forKey: "anonymizeTemplate")

        refreshTemplatesList()
        observeValue(forKeyPath: nil, of: nil, change: nil, context: tagsViewContext)
    }

    @objc(templatesPopupAction:)
    func templatesPopupAction(_ sender: NSPopUpButton) {
        let name = sender.selectedItem?.title
        let dic = name.flatMap { AnonymizationViewController.anonymizeTemplates()?.object(forKey: $0) }
        let arr = AnonymizationSelectorCalls.tagsValuesArray(fromDictionary: dic as AnyObject?)
        setTagsValues(arr as? [Any])
        // backwards compatibility: prefs might contain NSStrings, which might not match with the corresponding objects, so if no match is found we autosave
        let match = nameOfCurrentMatchingTemplate()
        if !(name != nil && match != nil && (name! as NSString).isEqual(to: match!)) {
            saveTemplate(tagsValues(), withName: name)
        }
    }

    @IBAction @objc(saveTemplateAction:)
    public func saveTemplateAction(_ sender: Any!) {
        let panelController = AnonymizationTemplateNamePanelController(replaceValues: AnonymizationViewController.anonymizeTemplates()?.allKeys)
        // The sheet's delegate releases the controller.
        let context = Unmanaged.passRetained(panelController).toOpaque()
        view.window!.beginSheet(panelController.window!) { response in
            self.saveTemplateNamePanelDidEnd(panelController.window! as! NSPanel, returnCode: response.rawValue, contextInfo: context)
        }
        panelController.window?.orderFront(self)
    }

    @objc(saveTemplateNamePanelDidEnd:returnCode:contextInfo:)
    func saveTemplateNamePanelDidEnd(_ panel: NSPanel, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo = contextInfo else {
            return
        }
        let panelController = Unmanaged<AnonymizationTemplateNamePanelController>.fromOpaque(contextInfo).takeRetainedValue()

        if returnCode == NSApplication.ModalResponse.stop.rawValue {
            saveTemplate(tagsValues(), withName: panelController.value())
        }

        panel.close()
    }

    @IBAction @objc(deleteTemplateAction:)
    public func deleteTemplateAction(_ sender: Any!) {
        let name = (templatesPopup.cell as? N2CustomTitledPopUpButtonCell)?.displayedTitle
        let dic = AnonymizationViewController.anonymizeTemplates()?.mutableCopy() as? NSMutableDictionary

        if let dic = dic {
            guard let name = name else {
                AnonymizationViewController.raiseNilArgument("removeObjectForKey:")
                return
            }
            dic.removeObject(forKey: name)
        }
        UserDefaults.standard.set(dic, forKey: "anonymizeTemplate")

        refreshTemplatesList()
        observeValue(forKeyPath: nil, of: nil, change: nil, context: tagsViewContext)
    }
}
