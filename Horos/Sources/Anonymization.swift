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
import Synchronization

/// What a panel shown by Anonymization carries until it ends: where to save
/// the configuration and whom to tell.
@objc(AnonymizationPanelRepresentation)
final class AnonymizationPanelRepresentation: NSObject {
    @objc var defaultsKey: String?
    @objc var representedObject: Any?
    @objc var target: Any?
    @objc var action: Selector?
}

/// Anonymization templates, their panels, and the anonymization of DICOM
/// files through DCMTK.
///
/// The Objective-C name, the selectors and
/// <Horos/Anonymization.h> are those of the former class. The DCMTK (C++)
/// work on each file is in the compatible HorosGDCMAnonymizer helper.

/// The date format of a DICOM date VR: DA, TM, or DT with its UTC offset.
func anonymizationDICOMDateFormat(_ vr: String?) -> String? {
    switch vr {
    case "DA": return "yyyyMMdd"
    case "TM": return "HHmmss"
    case "DT": return "yyyyMMddHHmmssxx"
    default: return nil
    }
}

/// `date` in `format`, Gregorian with ASCII digits whatever the locale, in the
/// local zone: the zone in which AnonymizationTagsView's field read the date.
func anonymizationDICOMDateString(_ date: Date, format: String, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter.string(from: date)
}

@objc(Anonymization)
public final class Anonymization: NSObject {
    /// Set when the panel opens and read by the panel; a Mutex, so the class
    /// methods can be asked from any thread.
    private static let templateDicomFileValue = Mutex<String?>(nil)

    private static let oldKeys: [String: String] = [
        "Patient's Name": "PatientsName",
        "Patient's Sex": "PatientsSex",
        "Patient's ID": "PatientID",
        "Patient's Weight": "PatientsWeight",
        "Patient's Age": "PatientsAge",
        "Trial Sponsor Name": "ClinicalTrialSponsorName",
        "Patient's Date of Birth": "PatientsBirthDate",
        "Trial Protocol ID": "ClinicalTrialProtocolID",
        "Institution Name": "InstitutionName",
        "Trial Protocol Name": "ClinicalTrialProtocolName",
        "Study ID": "StudyID",
        "Trial Site ID": "ClinicalTrialSiteID",
        "Study Date": "StudyDate",
        "Trial Site Name": "ClinicalTrialSiteName",
        "Study Time": "StudyTime",
        "Trial Subject Reading ID": "ClinicalTrialSubjectReadingID",
        "Aquisition Date/Time": "AcquisitionDatetime",
        "Trial Subject ID": "ClinicalTrialSubjectID",
        "Series Date": "SeriesDate",
        "Trial Time Point ID": "ClinicalTrialTimePointID",
        "Series Time": "SeriesTime",
        "Trial Time Point Description": "ClinicalTrialTimePointDescription",
        "Image Date": "InstanceCreationDate",
        "Trial Coordinating Center Name": "ClinicalTrialCoordinatingCenterName",
        "Image Time": "InstanceCreationTime",
        "Performing Physician": "PerformingPhysiciansName",
        "Referring Physician": "ReferringPhysiciansName",
        "Physicians of Record": "PhysiciansofRecord",
        "AccessionNumber": "AccessionNumber",
    ]

    @objc(tagFromString:)
    public class func tag(from string: String?) -> DCMAttributeTag? {
        // older versions of Horos stored anonymization descriptors using the spaced keys and linked those with the DICOM tags through tags in the xib views and code.
        // here, through the oldKeys dictionary, we support these keys and directly translate them to standard dicom tag names.
        var k = string
        if let key = k, let k2 = oldKeys[key] { k = k2 }

        var tag = DCMAttributeTag.tag(withName: k) as? DCMAttributeTag
        if tag == nil {
            tag = DCMAttributeTag.tag(withTagString: k) as? DCMAttributeTag
        }

        if tag == nil {
            NSLog("Warning: unrecognized DICOM attribute tag %@", k ?? "(null)")
        }

        return tag
    }

    @objc(tagsValuesArrayFromDictionary:)
    public class func tagsValuesArray(from dic: NSDictionary?) -> NSArray {
        let out = NSMutableArray(capacity: dic?.count ?? 0)

        for key in dic?.allKeys ?? [] {
            var v: Any? = dic?.object(forKey: key)

            guard let tag = self.tag(from: key as? String) else {
                continue
            }

            if v is NSNull {
                v = nil
            }

            // if v is null then array contains only 1 object
            out.add(v.map { NSArray(objects: tag, $0) } ?? NSArray(object: tag))
        }

        return out
    }

    @objc(tagsValuesDictionaryFromArray:)
    public class func tagsValuesDictionary(from arr: NSArray?) -> NSDictionary {
        let out = NSMutableDictionary(capacity: arr?.count ?? 0)

        for case let a as NSArray in arr ?? [] {
            let tag = a.object(at: 0) as! DCMAttributeTag
            let v = a.count > 1 ? a.object(at: 1) : ""

            let k: String = tag.name ?? tag.stringValue

            out.setObject(v, forKey: k as NSString)
        }

        return out
    }

    @objc(tagsArrayFromStringsArray:)
    public class func tagsArray(fromStringsArray strings: NSArray?) -> NSArray {
        let out = NSMutableArray(capacity: strings?.count ?? 0)

        for s in strings ?? [] {
            if let tag = self.tag(from: s as? String) {
                out.add(tag)
            }
        }

        return out.copy() as! NSArray
    }

    @objc(stringArrayFromTagsArray:)
    class func stringArray(fromTagsArray tags: NSArray?) -> NSArray {
        let out = NSMutableArray(capacity: tags?.count ?? 0)

        for case let tag as DCMAttributeTag in tags ?? [] {
            out.add(tag.stringValue!)
        }

        return out.copy() as! NSArray
    }

    @objc(tagsValues:isEqualTo:)
    public class func tagsValues(_ a1: NSArray?, isEqualTo a2: NSArray?) -> Bool {
        if (a1?.count ?? 0) != (a2?.count ?? 0) {
            return false
        }
        for case let a as NSArray in a1 ?? [] {
            let atag = a.object(at: 0) as AnyObject
            var found = false
            for case let b as NSArray in a2 ?? [] {
                let btag = b.object(at: 0)
                if atag.isEqual(btag) {
                    let aval = (a.count > 1 ? a.object(at: 1) : "") as AnyObject
                    let bval = (b.count > 1 ? b.object(at: 1) : "") as AnyObject

                    found = true

                    if !(aval === bval || aval.isEqual(bval)) {
                        return false
                    }
                }
            }

            if !found {
                return false
            }
        }

        return true
    }

    // MARK: Panel

    @objc public class func templateDicomFile() -> String? {
        templateDicomFileValue.withLock { $0 }
    }

    @discardableResult
    @MainActor
    @objc(showPanelClass:forDefaultsKey:modalForWindow:modalDelegate:didEndSelector:representedObject:)
    class func showPanelClass(_ c: AnyClass, forDefaultsKey defaultsKey: String?, modalFor window: NSWindow?,
                              modalDelegate delegate: Any?, didEnd sel: Selector?, representedObject: Any?) -> Any? {
        do {
            try HorosObjCException.perform {
                templateDicomFileValue.withLock { $0 = nil }

                // Messages to nil answer nil, as they did: no represented object, no template file.
                guard let outer = representedObject as? NSArray else { return }
                guard let first = outer.object(at: 0) as? NSArray else { return }
                let template = first.object(at: first.count / 2) as? String
                templateDicomFileValue.withLock { $0 = template }
            }
        } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "+[Anonymization showPanelClass:forDefaultsKey:modalForWindow:modalDelegate:didEndSelector:representedObject:]")
            }
        }

        let defaults = NSUserDefaultsController.shared
        let values = Anonymization.tagsValuesArray(from: defaults.dictionary(forKey: defaultsKey) as NSDictionary?)
        let tags = self.tagsArray(fromStringsArray: defaults.array(forKey: "\(defaultsKey ?? "(null)")All") as NSArray?)

        let panelController: AnonymizationPanelController = ObjectIdentifier(c) == ObjectIdentifier(AnonymizationSavePanelController.self)
            ? AnonymizationSavePanelController(tags: tags as? [Any], values: values as? [Any])
            : AnonymizationPanelController(tags: tags as? [Any], values: values as? [Any])
        let ro = AnonymizationPanelRepresentation()
        ro.defaultsKey = defaultsKey
        ro.representedObject = representedObject
        ro.target = delegate
        ro.action = sel
        panelController.representedObject = ro

        // The sheet owns the controller until -panelDidEnd:returnCode:contextInfo: releases it.
        let context = Unmanaged.passRetained(panelController).toOpaque()
        window!.beginSheet(panelController.window!) { response in
            self.panelDidEnd(panelController.window as? NSPanel, returnCode: response.rawValue, contextInfo: context)
        }
        panelController.window?.orderFront(self as AnyObject)

        if delegate == nil {
            NSApp.runModal(for: panelController.window!)
        }

        return panelController
    }

    @discardableResult
    @MainActor
    @objc(showPanelForDefaultsKey:modalForWindow:modalDelegate:didEndSelector:representedObject:)
    public class func showPanel(forDefaultsKey defaultsKey: String?, modalFor window: NSWindow?, modalDelegate delegate: Any?,
                                didEnd sel: Selector?, representedObject: Any?) -> AnonymizationPanelController? {
        showPanelClass(AnonymizationPanelController.self, forDefaultsKey: defaultsKey, modalFor: window, modalDelegate: delegate,
                       didEnd: sel, representedObject: representedObject) as? AnonymizationPanelController
    }

    @discardableResult
    @MainActor
    @objc(showSavePanelForDefaultsKey:modalForWindow:modalDelegate:didEndSelector:representedObject:)
    public class func showSavePanel(forDefaultsKey defaultsKey: String?, modalFor window: NSWindow?, modalDelegate delegate: Any?,
                                    didEnd sel: Selector?, representedObject: Any?) -> AnonymizationSavePanelController? {
        showPanelClass(AnonymizationSavePanelController.self, forDefaultsKey: defaultsKey, modalFor: window, modalDelegate: delegate,
                       didEnd: sel, representedObject: representedObject) as? AnonymizationSavePanelController
    }

    @MainActor
    @objc(panelDidEnd:returnCode:contextInfo:)
    class func panelDidEnd(_ panel: NSPanel?, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo = contextInfo else { return }
        let panelController = Unmanaged<AnonymizationPanelController>.fromOpaque(contextInfo).takeRetainedValue()
        let ro = panelController.representedObject as? AnonymizationPanelRepresentation

        if panelController.end != 0 { // save config
            let viewController = panelController.anonymizationViewController
            UserDefaults.standard.set(stringArray(fromTagsArray: viewController?.tags), forKey: "\(ro?.defaultsKey ?? "(null)")All")
            UserDefaults.standard.set(tagsValuesDictionary(from: viewController?.tagsValues() as NSArray?), forKey: ro?.defaultsKey ?? "")
        }

        panel?.close()

        panelController.representedObject = ro?.representedObject
        if let target = ro?.target as AnyObject? {
            _ = target.perform(ro?.action, with: panelController)
        } else if panelController.end != 0 {
            NSApp.stopModal()
        } else {
            NSApp.abortModal()
        }
    }

    // MARK: Anonymization

    @objc(cleanStringForFile:)
    class func cleanString(forFile s: String) -> String {
        var s = s
        s = s.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: ":", with: "-")

        return s
    }

    @objc(error:)
    class func error(_ s: String) {
        HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: s,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    @objc(anonymizeFiles:dicomImages:toPath:withTags:)
    public class func anonymizeFiles(_ files: NSArray?, dicomImages: NSArray?, toPath dirPath: String?, withTags intags: NSArray?) -> NSDictionary? {
        anonymizeFiles(files, dicomImages: dicomImages, toPath: dirPath, withTags: intags, error: nil)
    }

    // Returns nil and a diagnostic for any incomplete batch; cancellation uses NSUserCancelledError.
    @objc(anonymizeFiles:dicomImages:toPath:withTags:error:)
    public class func anonymizeFiles(_ files: NSArray?, dicomImages: NSArray?, toPath dirPath: String?, withTags intags: NSArray?,
                                     error outError: NSErrorPointer) -> NSDictionary? {
        outError?.pointee = nil
        let failureReasons = NSMutableOrderedSet()
        let failedTags = NSMutableOrderedSet()
        let fileFailures = NSMutableDictionary()
        let originalForStaged = NSMutableDictionary()
        func recordFailure(_ source: Any?, _ reason: String) {
            failureReasons.add(reason)
            guard let source = source else { return }
            var reasons = fileFailures.object(forKey: source) as? NSMutableArray
            if reasons == nil {
                reasons = NSMutableArray()
                fileFailures.setObject(reasons!, forKey: source as! NSCopying)
            }
            if !reasons!.contains(reason) { reasons!.add(reason) }
        }
        func fileResults(_ cancelled: Bool) -> [Any] {
            HorosAnonymizationFileResults(files as? [Any], fileFailures as? [AnyHashable: Any], cancelled)
        }
        let publishedFiles = NSMutableArray()
        var cancelled = false
        guard let files = files, let dicomImages = dicomImages, let intags = intags,
              files.count != 0, files.count == dicomImages.count, intags.count != 0,
              NSSet(array: files as [AnyObject]).count == files.count else {
            outError?.pointee = NSError(domain: "HorosAnonymization", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Select images and at least one field to anonymize. The image selection must be complete and must not repeat a file path.", comment: ""),
                "HorosAnonymizationFileResults": fileResults(false)])

            return nil
        }

        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////

        let tags = NSMutableArray(capacity: intags.count)

        for case let intag as NSArray in intags {
            let tag = intag.object(at: 0) as! DCMAttributeTag
            var val: Any? = intag.count > 1 ? intag.object(at: 1) : nil

            if let date = val as AnyObject?, date.isKind(of: NSDate.self) {
                // DICOM strings, in the zone the tag's field read the date in.
                // DT was the NSDate's description and TM carried a fraction the
                // field never has (#749).
                if let format = anonymizationDICOMDateFormat(tag.vr) {
                    val = anonymizationDICOMDateString((date as! NSDate) as Date, format: format)
                }
            } else if let number = val as AnyObject?, number.isKind(of: NSNumber.self) {
                if tag.vr == "DS" { // Decimal String representing floating point
                    val = (number as! NSNumber).stringValue
                } else if tag.vr == "IS" { // Integer String
                    val = (number as! NSNumber).stringValue
                }
            }

            tags.add(val.map { NSArray(objects: tag, $0) } ?? NSArray(object: tag))
        }

        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////

        var filenameTranslation: NSMutableDictionary? = NSMutableDictionary(capacity: files.count)

        var stagingError: NSError?
        guard let tempDirPath = HorosCreateAnonymizationStagingDirectory(dirPath, &stagingError) else {
            outError?.pointee = NSError(domain: "HorosAnonymization", code: 2, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Cannot create the anonymization working folder. Check destination permissions and available space. The originals were preserved.", comment: ""),
                "HorosAnonymizationFileResults": fileResults(false)])
            return nil
        }

        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////

        // The progress window exists only when this runs on the main thread,
        // so every use of it below is on the main actor.
        var splash: Wait?
        if Thread.isMainThread {
            let fileCount = files.count
            splash = MainActor.assumeIsolated {
                let splash = Wait(string: NSLocalizedString("Processing...", comment: ""))
                splash?.progress()?.maxValue = Double(fileCount * 2)
                splash?.showWindow(Anonymization.self)
                splash?.setCancel(true)
                return splash
            }
        }
        func splashIncrement() {
            if let splash { MainActor.assumeIsolated { splash.increment(by: 1) } }
        }
        func splashCancelled() -> Bool {
            guard let splash else { return false }
            return MainActor.assumeIsolated { splash.pollCancellation() }
        }

        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////

        let producedFiles = NSMutableArray(capacity: files.count)

        var fileIndex = 0

        for filePath in files {
            autoreleasepool {
                var failed = false
                do {
                    try HorosObjCException.perform {
                        guard let filePath = filePath as? String else { failed = true; return }
                        var ext = (filePath as NSString).pathExtension

                        if ext.isEmpty {
                            ext = "dcm"
                        }

                        let tempFileName = String(format: "%d.%@", Int32(truncatingIfNeeded: fileIndex), ext)
                        let tempFilePath = (tempDirPath as NSString).appendingPathComponent(tempFileName)

                        do {
                            try FileManager.default.copyItem(atPath: filePath, toPath: tempFilePath)
                        } catch {
                            failed = true
                            return
                        }

                        filenameTranslation?.setObject(tempFilePath, forKey: filePath as NSString)
                        fileIndex += 1

                        producedFiles.add(tempFilePath)
                        originalForStaged.setObject(filePath, forKey: tempFilePath as NSString)

                        splashIncrement()
                    }
                } catch {
                    failed = true
                }
                if failed {
                    recordFailure(filePath, NSLocalizedString("An input file could not be copied. Check access permissions and available space.", comment: ""))
                }
            }

            if splashCancelled() {
                cancelled = true
                break
            }
        }

        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////

        var anonymationSuccess = !cancelled && producedFiles.count == files.count
        let producedAnonFiles = NSMutableArray(capacity: files.count)

        for case let f as String in producedFiles {
            if cancelled || splashCancelled() {
                cancelled = true
                anonymationSuccess = false
                break
            }

            // The helper asks for the file system form of several paths, and each
            // answer is an autoreleased buffer of a kilobyte and a half. Without a
            // pool of its own for every file they all stayed until the batch ended:
            // a hundred megabytes for thirty thousand files.
            autoreleasepool {
                // DCMTK reads the staged copy, replaces the tags and commits "anon_<name>" beside it.
                let written = HorosGDCMAnonymizer.anonymizeStagedFile(f, tags: (tags as NSArray) as [AnyObject]) { reason, tag in
                    if let tag = tag {
                        failedTags.add(tag)
                    }
                    recordFailure(originalForStaged.object(forKey: f), reason)
                    anonymationSuccess = false
                }
                if let written = written {
                    producedAnonFiles.add(written)
                }
            }
        }

        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////

        if producedAnonFiles.count != producedFiles.count {
            anonymationSuccess = false
        } else {
            for i in 0..<producedAnonFiles.count {
                let produced = producedFiles.object(at: i) as! NSString
                unlink(produced.fileSystemRepresentation)
                do {
                    try FileManager.default.moveItem(atPath: producedAnonFiles.object(at: i) as! String, toPath: produced as String)
                } catch {
                    recordFailure(originalForStaged.object(forKey: produced), NSLocalizedString("An anonymized file could not be prepared for export.", comment: ""))
                    anonymationSuccess = false
                    break
                }
            }
        }

        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////

        if anonymationSuccess == false {
            filenameTranslation = nil
        } else {
            if producedFiles.count != dicomImages.count {
                NSLog("***** anonymizeFiles [producedFiles count] != [dicomImages count]")

                filenameTranslation = nil

                anonymationSuccess = false
            } else {
                let dicomSeries = NSMutableArray()
                let dicomStudies = NSMutableArray()
                let anonymousBatch = NSUUID()

                for i in 0..<dicomImages.count {
                    if splashCancelled() {
                        cancelled = true
                        filenameTranslation = nil
                        break
                    }
                    let inputIndex = i
                    let image = dicomImages.object(at: inputIndex) as AnyObject

                    // What ended the batch inside the former @try, with the reason recorded.
                    var stop = false
                    // What the former @catch handled without an exception being raised here.
                    var raised = false
                    do {
                        try HorosObjCException.perform {
                            // A nil series or study was added to an array, which raised.
                            guard let image = image as? DicomImage, let series = image.series, let study = series.study else {
                                raised = true
                                return
                            }
                            if !dicomSeries.contains(series) {
                                dicomSeries.add(series)
                            }

                            let tempFilePath = producedFiles.object(at: inputIndex) as! NSString
                            let ext = tempFilePath.pathExtension
                            if !dicomStudies.contains(study) {
                                dicomStudies.add(study)
                            }
                            let relativePath = ExportFolderNaming.anonymousPath(batch: anonymousBatch,
                                                                                studyIndex: dicomStudies.index(of: study) + 1,
                                                                                seriesIndex: dicomSeries.index(of: series) + 1)
                            let fileDirPath = ((dirPath ?? "") as NSString).appendingPathComponent(relativePath)

                            do {
                                try HorosObjCException.perform {
                                    _ = FileManager.default.confirmDirectory(atPath: fileDirPath)
                                }
                            } catch {
                                recordFailure(files.object(at: inputIndex), NSLocalizedString("The export folder could not be created. Check destination permissions and available space.", comment: ""))

                                filenameTranslation = nil

                                anonymationSuccess = false

                                stop = true
                                return
                            }

                            var filePath: String
                            // The former code named this counter i too, shadowing the loop's.
                            var suffix = 0
                            repeat {
                                suffix += 1
                                let `is` = suffix != 0 ? String(format: "-%4.4d", Int32(truncatingIfNeeded: suffix)) : ""
                                let fileName = String(format: "IM-%4.4d-%4.4d%@.%@", Int32(truncatingIfNeeded: dicomSeries.count),
                                                      image.instanceNumber?.int32Value ?? 0, `is`, ext)
                                filePath = (fileDirPath as NSString).appendingPathComponent(fileName)

                            } while FileManager.default.fileExists(atPath: filePath)

                            do {
                                try FileManager.default.moveItem(atPath: tempFilePath as String, toPath: filePath)
                            } catch {
                                recordFailure(files.object(at: inputIndex), NSLocalizedString("An anonymized file could not be moved to the export folder.", comment: ""))
                                filenameTranslation = nil
                                anonymationSuccess = false
                                stop = true
                                return
                            }

                            publishedFiles.add(filePath)
                            // Copies preserve input order; avoid scanning the whole mapping per file.
                            filenameTranslation?.setObject(filePath, forKey: files.object(at: inputIndex) as! NSCopying)
                        }
                    } catch {
                        raised = true
                    }
                    if raised {
                        recordFailure(files.object(at: inputIndex), NSLocalizedString("An anonymized file could not be exported.", comment: ""))

                        filenameTranslation = nil

                        anonymationSuccess = false

                        break
                    }
                    if stop {
                        break
                    }

                    splashIncrement()
                }
            }
        }

        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////

        cancelled = cancelled || splashCancelled()
        try? FileManager.default.removeItem(atPath: tempDirPath)
        if let splash { MainActor.assumeIsolated { splash.close() } }

        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////
        //////////////////////

        if !HorosAnonymizationOutputsComplete(files as? [Any], filenameTranslation as? [AnyHashable: Any]) || cancelled {
            filenameTranslation = nil
            var remaining = 0
            for case let path as String in publishedFiles {
                do { try FileManager.default.removeItem(atPath: path) } catch { remaining += 1 }
            }
            if let outError = outError {
                if cancelled && remaining == 0 {
                    outError.pointee = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [
                        "HorosAnonymizationFileResults": fileResults(true)])
                } else {
                    let details = NSMutableArray(object: NSLocalizedString("Anonymization did not produce a complete set of files. The original images have been preserved.", comment: ""))
                    details.addObjects(from: (failureReasons.array as NSArray).subarray(with: NSRange(location: 0, length: min(6, failureReasons.count))))
                    if failedTags.count != 0 {
                        let shown = (failedTags.array as NSArray).subarray(with: NSRange(location: 0, length: min(8, failedTags.count))) as NSArray
                        details.add(String(format: NSLocalizedString("Fields not replaced: %@%@", comment: ""), shown.componentsJoined(by: ", "), failedTags.count > shown.count ? ", ..." : ""))
                    }
                    if remaining != 0 {
                        details.add(NSLocalizedString("Some incomplete output files could not be removed. Do not use this export as a complete anonymized set.", comment: ""))
                    }
                    outError.pointee = NSError(domain: "HorosAnonymization", code: 3, userInfo: [NSLocalizedDescriptionKey: details.componentsJoined(by: "\n\n"),
                        "HorosAnonymizationFileResults": fileResults(cancelled)])
                }
            }
        }
        return filenameTranslation?.copy() as? NSDictionary
    }
}
