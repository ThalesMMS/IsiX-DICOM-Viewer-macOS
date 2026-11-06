/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import CoreData
import Foundation
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXDatabase
import IsiXImaging

/// The keys and field kinds of the templates, as the preferences write them:
/// NSString, compared as the Objective-C compared them, without bridging;
/// immutable constants, so shared across threads.
private enum TemplateKey {
    nonisolated(unsafe) static let sameAsDefault: NSString = "sameAsDefault"
    nonisolated(unsafe) static let fullContent: NSString = "fullContent"
    nonisolated(unsafe) static let type: NSString = "type", field: NSString = "field", level: NSString = "level"
    nonisolated(unsafe) static let group: NSString = "group", element: NSString = "element"
    nonisolated(unsafe) static let dicom: NSString = "DICOM", database: NSString = "DB", special: NSString = "Special", manual: NSString = "Manual"
}

/// The ages a special field asks for by their localized names, looked up once.
private enum LocalizedAge {
    static let actual = NSLocalizedString("Patient's Actual Age", comment: "")
    static let atAcquisition = NSLocalizedString("Patient's Age At Acquisition", comment: "")
}

/// The custom annotations of an image: the lines the preferences' templates
/// (Preferences > Annotations) make of its DICOM fields, database fields,
/// ages and typed text, by position, in annotationsDictionary; and the
/// database fields they need, read once, in annotationsDBFields.
extension DCMPix {
    /// The template of this image's modality, copied under the lock of the templates.
    private func annotationTemplate() -> NSDictionary? {
        guard let templates = DCMPixSettings.customImageAnnotations else { return nil }
        objc_sync_enter(templates)
        defer { objc_sync_exit(templates) }
        return ImageAnnotationText.template(forModality: modalityString, in: templates)?.copy() as? NSDictionary
    }

    /// The lines of a position of the template; nil, logged, for an entry of another kind.
    private func annotationLines(_ value: Any?, position: NSString) -> NSArray? {
        if value == nil { return NSArray() }
        guard let lines = value as? NSArray else {
            NSLog("CustomImageAnnotations: the annotations of %@ are not a list of lines", position)
            return nil
        }
        return lines
    }

    private func intValue(_ value: Any?) -> Int32 {
        (value as? NSNumber)?.int32Value ?? (value as? NSString)?.intValue ?? 0
    }

    /// Reads the database fields the templates show, from the image's row, into annotationsDBFields.
    @objc(loadCustomImageAnnotationsDBFields:)
    public dynamic func loadCustomImageAnnotationsDBFields(_ imageObj: DicomImage!) {
        if horos_annotationsDBFields != nil {
            NSLog("***** loadCustomImageAnnotationsDBFields has been called several times !!")
        }
        let fields = NSMutableDictionary()
        horos_annotationsDBFields = fields
        let template = annotationTemplate()
        // Image sides (LowerLeft, LowerMiddle, LowerRight, MiddleLeft, MiddleRight, TopLeft, TopMiddle, TopRight) and sameAsDefault.
        let keys = template?.allKeys ?? []

        // The row as a managed object: all that is asked of it is key-value coding.
        let row: NSManagedObject? = imageObj
        N2ManagedObjectContextPerformAndWait(row?.managedObjectContext) {
            for case let key as NSString in keys where key != TemplateKey.sameAsDefault {
                guard let lines = annotationLines(template?.object(forKey: key), position: key) else { continue }
                for case let line in lines {
                    guard let line = line as? NSDictionary, let content = line.object(forKey: TemplateKey.fullContent) as? NSArray
                            ?? (line.object(forKey: TemplateKey.fullContent) == nil ? NSArray() : nil) else {
                        NSLog("CustomImageAnnotations: a line of %@ is not a list of fields", key)
                        break
                    }
                    for case let field in content {
                        guard let field = field as? NSDictionary else {
                            NSLog("CustomImageAnnotations: a field of %@ is not a field", key)
                            continue
                        }
                        guard (field.object(forKey: TemplateKey.type) as? NSString) == TemplateKey.database else { continue }
                        let name = field.object(forKey: TemplateKey.field) as? String
                        let level = field.object(forKey: TemplateKey.level) as? String
                        var value: Any?
                        if let exception = HorosObjCException.caught({
                            switch AnnotationDatabaseFields.lookup(field: name, level: level) {
                            case .key(let key): value = row?.value(forKey: key)
                            case .keyPath(let path): value = row?.value(forKeyPath: path)
                            case .none: value = nil
                            }
                            fields.setObject(value ?? NSNull(), forKey: AnnotationDatabaseFields.key(field: name, level: level) as NSString)
                        }) {
                            NSLog("CustomImageAnnotations DB Exception: %@", exception)
                        }
                    }
                }
            }
        }
    }

    /// Builds annotationsDictionary: for each position of the template, its
    /// lines with a value, each a list of texts. `dcmObject` is the parsed file
    /// the DICOM fields are read from; without it they are dashes.
    @objc(loadCustomImageAnnotationsPapyLink:DCMLink:)
    public dynamic func loadCustomImageAnnotationsPapyLink(_ fileNb: Int32, dcmLink dcmObject: DCMObject?) {
        let template = annotationTemplate()
        let keys = template?.allKeys ?? []
        for case let key as NSString in keys where key != TemplateKey.sameAsDefault {
            let linesOut = NSMutableArray()
            if let lines = annotationLines(template?.object(forKey: key), position: key) {
                for case let line in lines {
                    guard let line = line as? NSDictionary, let content = line.object(forKey: TemplateKey.fullContent) as? NSArray
                            ?? (line.object(forKey: TemplateKey.fullContent) == nil ? NSArray() : nil) else {
                        NSLog("CustomImageAnnotations: a line of %@ is not a list of fields", key)
                        break
                    }
                    let contentOut = NSMutableArray()
                    var contentForLine = false
                    for case let field in content {
                        guard let field = field as? NSDictionary else {
                            NSLog("CustomImageAnnotations: a field of %@ is not a field", key)
                            continue
                        }
                        if let value = annotationText(of: field, dcmObject: dcmObject, content: &contentForLine) {
                            contentOut.add(value)
                        }
                    }
                    if contentForLine { linesOut.add(contentOut) }
                }
            }
            if let dictionary = horos_annotationsDictionary {
                objc_sync_enter(dictionary)
                dictionary.setObject(linesOut, forKey: key)
                objc_sync_exit(dictionary)
            }
        }
    }

    /// The text of one field of a line; `content` becomes true for a field with a value.
    private func annotationText(of field: NSDictionary, dcmObject: DCMObject?, content: inout Bool) -> String? {
        guard let type = field.object(forKey: TemplateKey.type) as? NSString else { return nil }
        if type == TemplateKey.dicom {
            let group = intValue(field.object(forKey: TemplateKey.group)), element = intValue(field.object(forKey: TemplateKey.element))
            var value: String?
            let read: String? = switch ImageAnnotationText.readField(group: group, element: element) {
            case .repetitionTime: repetitiontime
            case .echoTime: echotime
            case nil: nil
            }
            if let read {
                value = ImageAnnotationText.decimal((read as NSString).floatValue)
            } else if let dcmObject {
                value = getDICOMFieldValue(forGroup: group, element: element, dcmLink: dcmObject)
            }
            if group == ImageAnnotationText.transferSyntax.group && element == ImageAnnotationText.transferSyntax.element {
                value = BrowserController.compressionString(value)
            }
            let shown = ImageAnnotationText.shown(value)
            guard shown.isContent else { return shown.text }
            content = true
            if group == ImageAnnotationText.patientName.group && element == ImageAnnotationText.patientName.element {
                return DCMPixAnnotationPatientNamePrefix + shown.text
            }
            return shown.text
        }
        if type == TemplateKey.database {
            let name = field.object(forKey: TemplateKey.field) as? String
            let level = field.object(forKey: TemplateKey.level) as? String
            var value = horos_annotationsDBFields?.object(forKey: AnnotationDatabaseFields.key(field: name, level: level))
            if value is NSNull { value = nil }
            // No value is a dash, which is not content; the patient's name is still marked.
            guard let found = value else { return level == "study" && name == "name" ? DCMPixAnnotationPatientNamePrefix + "-" : "-" }
            content = true
            if let date = found as? Date {
                return name == "dateOfBirth" ? UserDefaults.dateFormatter().string(from: date) : BrowserController.dateTime(withSecondsFormat: date)
            }
            let text = String(describing: found as AnyObject)
            if (text as NSString).length == 0 { return "-" }
            if level == "study" && name == "name" { return DCMPixAnnotationPatientNamePrefix + text }
            return text
        }
        if type == TemplateKey.special {
            let name = field.object(forKey: TemplateKey.field) as? String
            var value: String?
            switch ImageAnnotationText.special(name, localizedActualAge: LocalizedAge.actual, localizedAgeAtAcquisition: LocalizedAge.atAcquisition) {
            case .actualAge: value = yearOld
            case .ageAtAcquisition: value = yearOldAcquisition
            case .other: value = name
            }
            let shown = ImageAnnotationText.shown(value)
            if shown.isContent { content = true }
            return shown.text
        }
        if type == TemplateKey.manual {
            return ImageAnnotationText.manual(field.object(forKey: TemplateKey.field) as? String)
        }
        return nil
    }

    /// The value of a DICOM field of `dcmObject` as the annotations show it:
    /// each value as text (decimals to six digits, dates, times and date-times
    /// in the browser's formats), several joined by " / "; nil when it has none.
    @objc(getDICOMFieldValueForGroup:element:DCMLink:)
    public dynamic func getDICOMFieldValue(forGroup group: Int32, element: Int32, dcmLink dcmObject: DCMObject?) -> String? {
        guard let attribute = dcmObject?.attribute(for: DICOMAttributeTag(group: group, element: element)) else { return nil }
        let vr = attribute.vr
        var texts: [String] = []
        for case let value in (attribute.values ?? []) {
            if let text = value as? String {
                texts.append(vr == "DS" ? ImageAnnotationText.decimal((text as NSString).floatValue) : text)
            } else if let number = value as? NSNumber {
                texts.append(vr == "FD" || vr == "FL" ? ImageAnnotationText.decimal(number.floatValue) : number.stringValue)
            } else if let date = value as? Date {
                switch vr {
                case "DA": texts.append(UserDefaults.dateFormatter().string(from: date))
                case "TM": texts.append(BrowserController.time(withSecondsFormat: date))
                default: texts.append(BrowserController.dateTime(withSecondsFormat: date))
                }
            }
        }
        return ImageAnnotationText.joined(texts)
    }

    /// The annotations by position: a copy, made under the dictionary's lock.
    @objc(annotationsDictionary)
    public dynamic var annotationsDictionary: NSMutableDictionary! {
        get { lockedCopy(horos_annotationsDictionary) }
        set {
            let old = horos_annotationsDictionary
            guard newValue !== old else { return }
            if let old { objc_sync_enter(old); horos_annotationsDictionary = nil; objc_sync_exit(old) }
            horos_annotationsDictionary = newValue
        }
    }

    /// The database fields the annotations show: a copy, made under the dictionary's lock.
    @objc(annotationsDBFields)
    public dynamic var annotationsDBFields: NSMutableDictionary! {
        get { lockedCopy(horos_annotationsDBFields) }
        set {
            let old = horos_annotationsDBFields
            guard newValue !== old else { return }
            if let old { objc_sync_enter(old); horos_annotationsDBFields = nil; objc_sync_exit(old) }
            horos_annotationsDBFields = newValue
        }
    }

    private func lockedCopy(_ dictionary: NSMutableDictionary?) -> NSMutableDictionary? {
        guard let dictionary else { return nil }
        objc_sync_enter(dictionary)
        defer { objc_sync_exit(dictionary) }
        return dictionary.mutableCopy() as? NSMutableDictionary
    }

    /// Empties the annotations: the next drawing builds them again.
    @objc(reloadAnnotations)
    public dynamic func reloadAnnotations() {
        PapyrusLock?.lock()
        horos_annotationsDictionary?.removeAllObjects()
        PapyrusLock?.unlock()
    }
}
