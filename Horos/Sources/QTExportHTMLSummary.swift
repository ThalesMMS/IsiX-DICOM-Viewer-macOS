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

// The former code relied on Objective-C's messages to nil and on Foundation
// raising NSExceptions (a template without its markers, an empty series
// array), which the exporter in BrowserController catches. These helpers keep
// both: nil stays nil, and what raised still raises, through the same
// Foundation methods.

/// A "%@" argument: the object, or "(null)" for nil, as -stringWithFormat: wrote it.
private func htmlFormatArgument(_ object: Any?) -> CVarArg {
    guard let object else { return "(null)" as NSString }
    return object as AnyObject as! CVarArg
}

/// +[NSMutableString stringWithString:], which raises for nil.
private func htmlMutableString(_ string: Any?) -> NSMutableString {
    if let string = string as? NSString {
        return NSMutableString(string: string as String)
    }
    return NSMutableString.perform(NSSelectorFromString("stringWithString:"), with: string)!.takeUnretainedValue() as! NSMutableString
}

/// -objectAtIndex:, which raises NSRangeException out of bounds.
private func htmlObject(_ array: Any?, _ index: Int) -> Any? {
    guard let array = array as? NSArray else { return nil }
    return array.object(at: index)
}

/// -componentsSeparatedByString:, whose NSArray raises NSRangeException out of
/// bounds (a Swift array bridged to NSArray would trap instead).
private func htmlComponents(_ string: Any?, _ separator: String) -> NSArray? {
    guard let string = string as AnyObject? else { return nil }
    return string.perform(NSSelectorFromString("componentsSeparatedByString:"), with: separator)?.takeUnretainedValue() as? NSArray
}

/// -valueForKeyPath: sent to an object that may be nil.
private func htmlValue(_ object: Any?, _ keyPath: String) -> Any? {
    guard let object = object as AnyObject? else { return nil }
    return object.value(forKeyPath: keyPath)
}

/// -valueForKey: sent to an object that may be nil.
private func htmlValue(_ object: Any?, forKey key: String) -> Any? {
    guard let object = object as AnyObject? else { return nil }
    return object.value(forKey: key)
}

/// -[NSString filenameString] sent to an object that may be nil.
private func htmlFilenameString(_ string: Any?) -> NSMutableString? {
    guard let string = string as AnyObject? else { return nil }
    return string.perform(#selector(NSString.filenameString))?.takeUnretainedValue() as? NSMutableString
}

/// C's int division as arm64 does it: x / 0 is 0 and INT_MIN / -1 is INT_MIN.
private func htmlDivide(_ a: Int32, _ b: Int32) -> Int32 {
    if b == 0 { return 0 }
    if b == -1 { return 0 &- a }
    return a / b
}

/// -intValue sent to an object that may be nil; anything else raises as it did.
private func htmlIntValue(_ object: Any?) -> Int32 {
    guard let object = object as AnyObject? else { return 0 }
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    (object as? NSObject)?.doesNotRecognizeSelector(NSSelectorFromString("intValue"))
    return 0
}

/// -isEqualToString: sent to an object that may be nil.
private func htmlIsEqualToString(_ string: Any?, _ other: Any?) -> Bool {
    guard let string = string as? NSString, let other = other as? NSString else { return false }
    return string.isEqual(to: other as String)
}

/// -compare:options: sent to an object that may be nil: nil answers
/// NSOrderedSame, as a message to nil returns 0.
private func htmlCompare(_ string: Any?, _ other: Any?, _ options: NSString.CompareOptions) -> ComparisonResult {
    guard let string = string as? NSString else { return .orderedSame }
    guard let other = other as? NSString else {
        // -compare:options: with a nil string: Foundation orders nil first.
        return .orderedDescending
    }
    return string.compare(other as String, options: options)
}

/// -stringFromDate: sent with an object that may be nil.
private func htmlString(_ formatter: DateFormatter, _ date: Any?) -> Any? {
    return formatter.perform(#selector(DateFormatter.string(from:)), with: date)?.takeUnretainedValue()
}

/// -stringByAppendingPathComponent: sent to a string that may be nil.
private func htmlAppendingPathComponent(_ path: Any?, _ component: String) -> String? {
    guard let path = path as? NSString else { return nil }
    return path.appendingPathComponent(component)
}

/// -replaceOccurrencesOfString:withString:options:NSLiteralSearch range:, which raises for a nil replacement.
private func htmlReplace(_ string: NSMutableString, _ target: String, _ replacement: Any?) {
    if let replacement = replacement as? NSString {
        string.replaceOccurrences(of: target, with: replacement as String, options: .literal, range: NSMakeRange(0, string.length))
    } else {
        // What the former call raised for a nil replacement.
        NSException(name: .invalidArgumentException,
                    reason: "-[__NSCFString replaceOccurrencesOfString:withString:options:range:]: nil argument",
                    userInfo: nil).raise()
    }
}

/// -createFileAtPath:contents:attributes: for a path that may be nil, which
/// created nothing.
private func htmlCreateFile(_ path: String?, _ content: Any?) {
    guard let path else { return }
    let data = (content as? NSString)?.data(using: String.Encoding.utf8.rawValue)
    FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
}

/// Used for html export for disk burning.
///
/// Implemented in Swift since #717: the Objective-C name, the selectors and
/// <Horos/QTExportHTMLSummary.h> are those of the former class.
@objc(QTExportHTMLSummary)
public final class QTExportHTMLSummary: NSObject {
    // whole template
    private var patientsListTemplate: NSString?
    private var examsListTemplate: NSString?
    private var seriesTemplate: NSString?
    private var patientsDictionary: NSDictionary?
    private var rootPath: NSString?
    private var footerString: NSString?
    private var uniqueSeriesID: Int32 = 0
    private let dateFormat = DateFormatter()
    private let timeFormat = DateFormatter()

    @objc public var imagePathsDictionary: NSMutableDictionary!

    @objc(nonNilString:)
    public class func nonNilString(_ aString: NSString!) -> NSString! {
        return (aString == nil) ? "" : aString
    }

    /// +nonNilString: of any value, which the former code sent whatever
    /// -valueForKey: returned.
    private class func nonNil(_ object: Any?) -> Any {
        return object ?? ("" as NSString)
    }

    public override init() {
        super.init()

        readTemplates()

        footerString = NSLocalizedString("Made with <a href=\"http://www.horosproject.org\" target=\"_blank\">Horos</a>", comment: "") as NSString

        dateFormat.dateStyle = .short

        timeFormat.timeStyle = .short
    }

    // MARK: -
    // MARK: HTML template

    @objc(readTemplates)
    public func readTemplates() {
        let database = BrowserController.currentBrowser()?.database
        database?.checkForHtmlTemplates()
        let directory = database?.htmlTemplatesDirPath()
        func template(_ name: String) -> NSString? {
            guard let path = htmlAppendingPathComponent(directory, name) else { return nil }
            return try? NSString(contentsOfFile: path, usedEncoding: nil)
        }
        patientsListTemplate = template("QTExportPatientsTemplate.html")
        examsListTemplate = template("QTExportStudiesTemplate.html")
        seriesTemplate = template("QTExportSeriesTemplate.html")
    }

    @objc(fillPatientsListTemplates)
    public func fillPatientsListTemplates() -> String! {
        // working string to process the template
        let tempPatientHTML = htmlMutableString(patientsListTemplate)
        // simple replacements
        htmlReplace(tempPatientHTML, "%page_title%", NSLocalizedString("Patients list", comment: ""))
        htmlReplace(tempPatientHTML, "%patient_list_string%", NSLocalizedString("Patients list", comment: ""))
        htmlReplace(tempPatientHTML, "%footer_string%", footerString)

        // look for the patients list html structure
        var components = htmlComponents(tempPatientHTML, "%start_patient_i%")
        let templateStart = htmlMutableString(htmlObject(components, 0))
        components = htmlComponents(htmlObject(components, 1), "%end_patient_i%")
        let listItemTemplate = htmlObject(components, 0)
        let templateEnd = htmlMutableString(htmlObject(components, 1))

        // create the html patient list
        let tempPatientsList = NSMutableString(capacity: 0)

        if let enumerator = patientsDictionary?.objectEnumerator() {
            while let series = enumerator.nextObject() {
                let tempListItemTemplate = htmlMutableString(listItemTemplate)
                let first = htmlObject(series, 0)
                let linkToPatientPage = NSString(format: "./%@/%@", htmlFormatArgument(htmlFilenameString(htmlValue(first, "study.name"))), "index.html")

                htmlReplace(tempListItemTemplate, "%patient_i_page%", QTExportHTMLSummary.nonNil(linkToPatientPage))
                let patientName = htmlValue(first, "study.name")
                htmlReplace(tempListItemTemplate, "%patient_i_name%", QTExportHTMLSummary.nonNil(patientName))
                let patientDateOfBirth = htmlString(dateFormat, htmlValue(first, "study.dateOfBirth"))
                htmlReplace(tempListItemTemplate, "%patient_i_dateOfBirth%", QTExportHTMLSummary.nonNil(patientDateOfBirth))
                tempPatientsList.append(tempListItemTemplate as String)
            }
        }
        // create the whole html code
        let filledTemplate = NSMutableString(string: templateStart as String)
        filledTemplate.append(tempPatientsList as String)
        filledTemplate.append(templateEnd as String)

        return filledTemplate as String
    }

    @objc(kindOfPath:forSeriesId:inSeriesPaths:)
    public class func kindOfPath(_ path: NSString!, forSeriesId seriesId: Int32, inSeriesPaths seriesPaths: NSDictionary!) -> NSString! {
        // NSString and NSDictionary, not String: -keyForObject: compares the
        // very object the caller passed.
        let seriesIdK = NSNumber(value: seriesId)
        let pathsForSeries = seriesPaths?.object(forKey: seriesIdK) as? NSDictionary
        return pathsForSeries?.key(forObject: path) as? NSString
    }

    @objc(imagePathForSeriesId:kind:)
    func imagePathForSeriesId(_ seriesId: Int32, kind: String!) -> String! {
        // TODO: find and remove from dict and return corresponding item
        if let imagePathsDictionary {
            let seriesIdK = NSNumber(value: seriesId)

            guard let pathsForSeries = imagePathsDictionary.object(forKey: seriesIdK) as? NSDictionary else {
                return nil
            }

            // -objectForKey: nil answered nil.
            guard let kind else { return nil }
            return pathsForSeries.object(forKey: kind) as? String
        }

        return nil
    }

    /// The study/series part of a patient/study/series path.
    private func studyAndSeries(_ path: String) -> String {
        return (htmlComponents(path, "/")!.subarray(with: NSMakeRange(1, 2)) as NSArray).componentsJoined(by: "/")
    }

    /// NSArray, not [Any]: an out of bounds -objectAtIndex: must raise
    /// NSRangeException, as it did, and a Swift array bridged to NSArray traps.
    @objc(fillStudiesListTemplatesForSeries:)
    public func fillStudiesListTemplates(forSeries series: NSArray!) -> String! {
        return fillStudiesList(series)
    }

    private func fillStudiesList(_ series: NSArray?) -> String {
        let count = series?.count ?? 0
        // working string to process the template
        let tempExamsHTML = htmlMutableString(examsListTemplate)
        // simple replacements
        htmlReplace(tempExamsHTML, "%patient_name%", QTExportHTMLSummary.nonNil(htmlValue(htmlObject(series, 0), "study.name")))
        htmlReplace(tempExamsHTML, "%patient_dateOfBirth%", QTExportHTMLSummary.nonNil(htmlString(dateFormat, htmlValue(htmlObject(series, 0), "study.dateOfBirth"))))
        htmlReplace(tempExamsHTML, "%footer_string%", footerString)

        // look for the study html block structure
        var components = htmlComponents(tempExamsHTML, "%study_i_start%")
        let templateHeader = htmlMutableString(htmlObject(components, 0))
        components = htmlComponents(htmlObject(components, 1), "%study_i_end%")
        let studyBlock = htmlObject(components, 0) as! NSString
        let templateFooter = htmlMutableString(htmlObject(components, 1))

        // look for the series list html structure
        components = htmlComponents(studyBlock, "%series_i_start%")
        let studyBlockStart = htmlMutableString(htmlObject(components, 0))
        components = htmlComponents(htmlObject(components, 1), "%series_i_end%")
        let listItemTemplate = htmlObject(components, 0)
        let studyBlockEnd = htmlMutableString(htmlObject(components, 1))

        // create the html studies blocks
        let tempStudyBlock = NSMutableString(capacity: 0)
        // create the html series lists
        var tempSeriesList = NSMutableString(capacity: 0)

        var imagesCount: Int32 = 0

        var lastImageOfSeries = false, lastImageOfStudy = false

        uniqueSeriesID = 0

        let caseDiacriticWidth: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

        var i = 0
        while i < count {
            let current = htmlObject(series, i)
            imagesCount += 1
            if i == count - 1 {
                lastImageOfSeries = true
            } else if htmlIntValue(htmlValue(current, forKey: "id")) != htmlIntValue(htmlValue(htmlObject(series, i + 1), forKey: "id")) {
                lastImageOfSeries = true
            } else if !htmlIsEqualToString(htmlValue(current, forKey: "seriesInstanceUID"), htmlValue(htmlObject(series, i + 1), forKey: "seriesInstanceUID")) {
                lastImageOfSeries = true
            } else if !htmlIsEqualToString(htmlValue(current, "study.id"), htmlValue(htmlObject(series, i + 1), "study.id")) || htmlCompare(htmlValue(current, "study.patientUID"), htmlValue(htmlObject(series, i + 1), "study.patientUID"), caseDiacriticWidth) != .orderedSame {
                lastImageOfSeries = true
            } else {
                lastImageOfSeries = false
            }

            if lastImageOfSeries {
                uniqueSeriesID += 1

                let seriesName = htmlFilenameString(htmlMutableString(QTExportHTMLSummary.nonNil(htmlValue(current, forKey: "name"))))
                let fileName = htmlFilenameString(NSMutableString(format: "%@ - %@", htmlFormatArgument(htmlValue(current, "study.studyName")), htmlFormatArgument(htmlValue(current, "study.id"))))!
                let iId = htmlValue(current, forKey: "id")
                fileName.appendFormat("/%@_%@", htmlFormatArgument(seriesName), htmlFormatArgument(iId))

                fileName.appendFormat("_%d", uniqueSeriesID)

                var thumbnailName: NSString
                if let thumbnail = imagePathForSeriesId(htmlIntValue(iId), kind: "thumb") { // thumbnailName is in patient/study/series format, should be study/series
                    thumbnailName = studyAndSeries(thumbnail) as NSString
                } else {
                    thumbnailName = NSMutableString(format: "%@_thumb.jpg", fileName)
                }

                let htmlName = NSMutableString(format: "%@.html", fileName)

                let tempListItemTemplate = htmlMutableString(listItemTemplate)
                var ext = (imagesCount > 1) ? "mp4" : "jpg"

                let sopClassUID = htmlValue(current, forKey: "seriesSOPClassUID") as? String
                if DCMAbstractSyntaxUID.isPDF(sopClassUID) {
                    ext = "pdf"
                    let tempPdfPath = imagePathForSeriesId(htmlIntValue(iId), kind: ext)
                    if let tempPdfPath { // tempPdfPath is in patient/study/series format, should be study/series
                        fileName.setString(studyAndSeries(tempPdfPath))
                    } else {
                        fileName.appendFormat(".%@", ext as NSString)
                    }
                    htmlReplace(tempListItemTemplate, "%series_i_file%", QTExportHTMLSummary.nonNil(fileName))

                } else if DCMAbstractSyntaxUID.isStructuredReport(sopClassUID) {
                    ext = "pdf"
                    let tempPdfPath = imagePathForSeriesId(htmlIntValue(iId), kind: ext)
                    if let tempPdfPath { // tempPdfPath is in patient/study/series format, should be study/series
                        fileName.setString(studyAndSeries(tempPdfPath))
                    } else {
                        fileName.appendFormat(".%@", ext as NSString)
                    }
                    htmlReplace(tempListItemTemplate, "%series_i_file%", QTExportHTMLSummary.nonNil(fileName))

                } else {
                    let tempXXXPath = imagePathForSeriesId(htmlIntValue(iId), kind: ext)
                    if let tempXXXPath { // tempXXXPath is in patient/study/series format, should be study/series
                        fileName.setString(studyAndSeries(tempXXXPath))
                    } else {
                        fileName.appendFormat(".%@", ext as NSString)
                    }
                    htmlReplace(tempListItemTemplate, "%series_i_file%", QTExportHTMLSummary.nonNil(htmlName))
                }

                htmlReplace(tempListItemTemplate, "%series_i_thumbnail%", QTExportHTMLSummary.nonNil(thumbnailName))
                htmlReplace(tempListItemTemplate, "%series_i_name%", QTExportHTMLSummary.nonNil(htmlValue(current, forKey: "name")))
                htmlReplace(tempListItemTemplate, "%series_i_id%", QTExportHTMLSummary.nonNil(NSString(format: "%@", htmlFormatArgument(htmlValue(current, forKey: "id")))))
                htmlReplace(tempListItemTemplate, "%series_i_images_count%", QTExportHTMLSummary.nonNil(NSString(format: "%d", imagesCount)))
                tempSeriesList.append(tempListItemTemplate as String)

                if ext != "pdf" {
                    createSeriesPage(current as AnyObject?, numberOfImages: imagesCount, outPutFileName: htmlName)
                }

                imagesCount = 0

                if i == count - 1 {
                    lastImageOfStudy = true
                } else if !htmlIsEqualToString(htmlValue(current, "study.studyInstanceUID"), htmlValue(htmlObject(series, i + 1), "study.studyInstanceUID")) {
                    lastImageOfStudy = true
                } else if htmlCompare(htmlValue(current, "study.patientUID"), htmlValue(htmlObject(series, i + 1), "study.patientUID"), caseDiacriticWidth) != .orderedSame {
                    lastImageOfStudy = true
                } else if !htmlIsEqualToString(htmlValue(current, "study.studyName"), htmlValue(htmlObject(series, i + 1), "study.studyName")) {
                    lastImageOfStudy = true
                } else {
                    lastImageOfStudy = false
                }

                if lastImageOfStudy {
                    uniqueSeriesID = 0
                    let tempStudyBlockStart = htmlMutableString(studyBlockStart)
                    htmlReplace(tempStudyBlockStart, "%study_i_name%", QTExportHTMLSummary.nonNil(htmlValue(current, "study.studyName")))
                    let studyDate = htmlString(dateFormat, htmlValue(current, "study.date"))
                    let studyTime = htmlString(timeFormat, htmlValue(current, "study.date"))

                    htmlReplace(tempStudyBlockStart, "%study_i_date%", QTExportHTMLSummary.nonNil(studyDate))
                    htmlReplace(tempStudyBlockStart, "%study_i_time%", QTExportHTMLSummary.nonNil(studyTime))
                    htmlReplace(tempStudyBlockStart, "%study_i_id%", QTExportHTMLSummary.nonNil(htmlValue(current, "study.id")))
                    tempStudyBlock.append(tempStudyBlockStart as String)
                    tempStudyBlock.append(tempSeriesList as String)
                    tempStudyBlock.append(studyBlockEnd as String)
                    tempSeriesList = NSMutableString(capacity: 0)
                }
            }
            i += 1
        }

        // create the whole html code
        let filledTemplate = NSMutableString(string: templateHeader as String)
        filledTemplate.append(tempStudyBlock as String)
        filledTemplate.append(templateFooter as String)

        return filledTemplate as String
    }

    @objc(getMovieWidth:height:imagesArray:)
    public class func getMovieWidth(_ width: UnsafeMutablePointer<Int32>!, height: UnsafeMutablePointer<Int32>!, imagesArray: NSArray!) {
        width.pointee = 0
        height.pointee = 0

        let images = imagesArray

        for im in (images?.value(forKey: "width") as? NSArray) ?? NSArray() {
            if htmlIntValue(im) > width.pointee { width.pointee = htmlIntValue(im) }
        }

        for im in (images?.value(forKey: "height") as? NSArray) ?? NSArray() {
            if htmlIntValue(im) > height.pointee { height.pointee = htmlIntValue(im) }
        }

        let maxWidth: Int32 = 800, maxHeight: Int32 = 800
        let minWidth: Int32 = 400, minHeight: Int32 = 400

        if width.pointee == 0 || height.pointee == 0 {
            return
        }

        // int arithmetic as C did it: products wrap.
        if width.pointee > maxWidth {
            height.pointee = htmlDivide(height.pointee &* maxWidth, width.pointee)
            width.pointee = maxWidth
        }

        if width.pointee < minWidth {
            height.pointee = htmlDivide(height.pointee &* minWidth, width.pointee)
            width.pointee = minWidth
        }

        if height.pointee > maxHeight {
            width.pointee = htmlDivide(width.pointee &* maxHeight, height.pointee)
            height.pointee = maxHeight
        }

        if height.pointee < minHeight {
            width.pointee = htmlDivide(width.pointee &* minHeight, height.pointee)
            height.pointee = minHeight
        }
    }

    @objc(fillSeriesTemplatesForSeries:numberOfImages:)
    public func fillSeriesTemplates(forSeries series: NSManagedObject!, numberOfImages imagesCount: Int32) -> String! {
        return fillSeries(series, numberOfImages: imagesCount)
    }

    /// The series is any object that answers the keys (a DicomSeries in the
    /// app), as the former code sent it messages without checking its class.
    private func fillSeries(_ series: AnyObject?, numberOfImages imagesCount: Int32) -> String {
        let seriesId = htmlValue(series, "id")

        let tempHTML = htmlMutableString(seriesTemplate)

        htmlReplace(tempHTML, "%series_name%", QTExportHTMLSummary.nonNil(htmlValue(series, forKey: "name")))
        htmlReplace(tempHTML, "%patient_name%", QTExportHTMLSummary.nonNil(htmlValue(series, "study.name")))
        htmlReplace(tempHTML, "%patient_dateOfBirth%", QTExportHTMLSummary.nonNil(htmlString(dateFormat, htmlValue(series, "study.dateOfBirth"))))
        htmlReplace(tempHTML, "%series_name%", QTExportHTMLSummary.nonNil(htmlValue(series, forKey: "name")))
        htmlReplace(tempHTML, "%series_id%", QTExportHTMLSummary.nonNil(NSString(format: "%@", htmlFormatArgument(htmlValue(series, forKey: "id")))))
        htmlReplace(tempHTML, "%series_images_count%", QTExportHTMLSummary.nonNil(NSString(format: "%d", imagesCount)))

        // series.name: the -name message the former code sent.
        let name = series?.perform(NSSelectorFromString("name"))?.takeUnretainedValue()
        // +replaceNotAdmitted: edited this mutable string in place and returns it.
        let seriesStr: NSMutableString = BrowserController.replaceNotAdmitted(htmlMutableString(QTExportHTMLSummary.nonNil(htmlFilenameString(name))) as String)

        let fileName = NSMutableString(format: "./%@_%@", seriesStr, htmlFormatArgument(htmlValue(series, forKey: "id")))

        fileName.appendFormat("_%d", uniqueSeriesID)

        let ext = (imagesCount > 1) ? "mp4" : "jpg"

        let tempXXXPath = imagePathForSeriesId(htmlIntValue(seriesId), kind: ext)
        if let tempXXXPath { // tempXXXPath is in patient/study/series format, should be series
            fileName.setString((tempXXXPath as NSString).lastPathComponent)
        } else {
            fileName.appendFormat(".%@", ext as NSString)
        }

        htmlReplace(tempHTML, "%series_file_path%", QTExportHTMLSummary.nonNil(fileName))
        htmlReplace(tempHTML, "%footer_string%", footerString)

        let components: NSArray?

        let widths = (htmlValue(series, "images.width") as AnyObject?)?.perform(NSSelectorFromString("allObjects"))?.takeUnretainedValue() as? NSArray
        if imagesCount > 1 && (widths?.count ?? 0) > 0 {
            htmlReplace(tempHTML, "%series_mov%", "")

            var width: Int32 = 0, height: Int32 = 0

            let images = (htmlValue(series, forKey: "images") as AnyObject?)?.perform(NSSelectorFromString("allObjects"))?.takeUnretainedValue() as? NSArray
            QTExportHTMLSummary.getMovieWidth(&width, height: &height, imagesArray: images)

            htmlReplace(tempHTML, "%width%", NSString(format: "%d", width))
            htmlReplace(tempHTML, "%height%", NSString(format: "%d", height &+ 15)) // +15 is for the movie's controller
            components = htmlComponents(tempHTML, "%series_img%")
        } else {
            htmlReplace(tempHTML, "%series_img%", "")
            components = htmlComponents(tempHTML, "%series_mov%")
        }

        let filledTemplate = htmlMutableString(htmlObject(components, 0))
        filledTemplate.append(htmlObject(components, 2) as! String)

        return filledTemplate as String
    }

    // MARK: -
    // MARK: HTML file creation

    @objc(createHTMLfiles)
    public func createHTMLfiles() {
        createHTMLPatientsList()
        createHTMLStudiesList()
        createHTMLExtraDirectory()
    }

    @objc(createHTMLPatientsList)
    public func createHTMLPatientsList() {
        let htmlContent = fillPatientsListTemplates()
        htmlCreateFile(htmlAppendingPathComponent(rootPath, "/index.html"), htmlContent)
    }

    @objc(createHTMLStudiesList)
    public func createHTMLStudiesList() {
        guard let enumerator = patientsDictionary?.objectEnumerator() else { return }
        while let study = enumerator.nextObject() as? NSArray {
            if study.count > 0 {
                let patientName = htmlFilenameString(htmlValue(htmlObject(study, 0), "study.name"))
                let htmlContent = fillStudiesList(study)
                htmlCreateFile(rootPath?.appendingFormat("/%@/index.html", htmlFormatArgument(patientName)) as String?, htmlContent)
            }
        }
    }

    @objc(createHTMLExtraDirectory)
    public func createHTMLExtraDirectory() {
        let htmlExtraDirectory = htmlAppendingPathComponent(BrowserController.currentBrowser()?.database?.htmlTemplatesDirPath(), "html-extra")
        let destination = htmlAppendingPathComponent(rootPath, "html-extra")
        // -copyItemAtPath:toPath:error: raised for a nil path.
        guard let htmlExtraDirectory else {
            NSException(name: .invalidArgumentException, reason: "*** -[NSFileManager copyItemAtPath:toPath:options:error:]: source path is nil", userInfo: nil).raise()
            return
        }
        guard let destination else {
            NSException(name: .invalidArgumentException, reason: "*** -[NSFileManager copyItemAtPath:toPath:options:error:]: destination path is nil", userInfo: nil).raise()
            return
        }
        try? FileManager.default.copyItem(atPath: htmlExtraDirectory, toPath: destination)
    }

    @objc(createHTMLSeriesPage:numberOfImages:outPutFileName:)
    public func createHTMLSeriesPage(_ series: NSManagedObject!, numberOfImages imagesCount: Int32, outPutFileName fileName: String!) {
        createSeriesPage(series, numberOfImages: imagesCount, outPutFileName: fileName as NSString?)
    }

    private func createSeriesPage(_ series: AnyObject?, numberOfImages imagesCount: Int32, outPutFileName fileName: NSString?) {
        let htmlContent = fillSeries(series, numberOfImages: imagesCount)
        let patientName = htmlFilenameString(htmlValue(series, "study.name"))
        htmlCreateFile(rootPath?.appendingFormat("/%@/%@", htmlFormatArgument(patientName), htmlFormatArgument(fileName)) as String?, htmlContent)
    }

    // MARK: -
    // MARK: setters

    @objc(setPath:)
    public func setPath(_ path: String!) {
        rootPath = path as NSString?
    }

    @objc(setPatientsDictionary:)
    public func setPatientsDictionary(_ dictionary: NSDictionary!) {
        patientsDictionary = dictionary
    }
}
