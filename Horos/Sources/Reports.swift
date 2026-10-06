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
import CoreData
import Synchronization

/// What `%@` prints for an object: its description, or "(null)" for nil.
private func formatArgument(_ value: Any?) -> CVarArg {
    guard let value = value else { return "(null)" as NSString }
    return (value as AnyObject) as? NSObject ?? (String(describing: value) as NSString)
}

/// -[NSString isEqualToString:], which is NO when either side is nil.
private func isEqualString(_ string: String?, _ other: String?) -> Bool {
    guard let string = string, let other = other else { return false }
    return (string as NSString).isEqual(to: other)
}

/// A Cocoa call that reports its failure through an NSError** parameter.
private func reportingError(_ error: NSErrorPointer, _ body: () throws -> Void) -> Bool {
    do {
        try body()
        return true
    } catch let failure {
        error?.pointee = failure as NSError
        return false
    }
}

/** \brief reports */
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/Reports.h> are those of the former class.
@objc(Reports)
public final class Reports: NSObject {

    /// The former templateName ivar: one mutable string, which -templateName
    /// hands out and -setTemplateName: rewrites in place.
    private let templateNameStorage = NSMutableString(string: "")

    /// Pages templates written for Pages 4 are copied once per process.
    /// Whether the Pages templates still have to be copied; the first caller
    /// to take it, from whichever thread, copies them.
    private static let pagesTemplatesFirstTime = Atomic<Bool>(true)

    public override init() {
        super.init()
    }

    @objc(getUniqueFilename:)
    public class func getUniqueFilename(_ study: Any!) -> String! {
        let object = study as AnyObject?
        let s = object?.value(forKey: "accessionNumber")

        if ((s as AnyObject?) as? NSString)?.length ?? 0 > 0 {
            let joined = (object?.value(forKey: "patientUID") as AnyObject? as? NSString)?
                .appendingFormat("-%@", formatArgument(object?.value(forKey: "accessionNumber")))
            return DicomFile.nSreplaceBadCharacter(joined as String?)
        } else {
            let joined = (object?.value(forKey: "patientUID") as AnyObject? as? NSString)?
                .appendingFormat("-%@", formatArgument(object?.value(forKey: "studyInstanceUID")))
            return DicomFile.nSreplaceBadCharacter(joined as String?)
        }
    }

    @objc(getOldUniqueFilename:)
    public class func getOldUniqueFilename(_ study: NSManagedObject!) -> String! {
        let joined = (study?.value(forKey: "patientUID") as AnyObject? as? NSString)?
            .appendingFormat("-%@", formatArgument(study?.value(forKey: "id")))
        return DicomFile.nSreplaceBadCharacter(joined as String?)
    }

    @objc(HFSStyle:)
    func hfsStyle(_ string: String!) -> String! {
        let url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, string as CFString, CFURLPathStyle(rawValue: 1)!, false)
        return (url as NSURL?)?.path
    }

    @objc(HFSPathFromPOSIXPath:)
    func hfsPath(fromPOSIXPath p: String!) -> String! {
        // thanks to stone.com for the pointer to  CFURLCreateWithFileSystemPath()

        let isDirectoryPath = (p as NSString?)?.hasSuffix("/") ?? false
        // Note that for the usual case of absolute paths,  isDirectoryPath is
        // completely ignored by CFURLCreateWithFileSystemPath.
        // isDirectoryPath is only considered for relative paths.
        // This code has not really been tested relative paths...

        guard let url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, p as CFString,
                                                      .cfurlposixPathStyle, isDirectoryPath) else { return nil }

        // Convert URL to a colon-delimited HFS path
        // represented as Unicode characters in an NSString.
        return CFURLCopyFileSystemPath(url, CFURLPathStyle(rawValue: 1)!) as String?
    }

    /// The Objective-C method compared the last field and the current one by
    /// identity (`!=` on two NSString pointers), so the fields stay NSString
    /// objects here, obtained from the same methods, and are compared with ===.
    private static func components(of string: NSString) -> NSArray? {
        string.perform(NSSelectorFromString("componentsSeparatedByString:"), with: ":")?.takeUnretainedValue() as? NSArray
    }

    private static func removingSpaces(_ string: NSString) -> NSString? {
        string.perform(NSSelectorFromString("stringByReplacingOccurrencesOfString:withString:"), with: " ", with: "")?.takeUnretainedValue() as? NSString
    }

    @objc(getDICOMStringValueForField:inDICOMFile:)
    func getDICOMStringValue(forField rawField: String!, inDICOMFile path: String!) -> String! {
        NSLog("Report: DICOM_Field: %@", formatArgument(rawField))

        var found: String?
        do {
            try HorosObjCException.perform {
                let dicomFields = (rawField as NSString?).flatMap { Reports.components(of: $0) }

                var dcmObject: DCMObject? = path.flatMap { HorosDCMTKObject(contentsOfFile: $0) }
                if dcmObject != nil {
                    var lastObj: AnyObject? = nil
                    for element in dicomFields ?? NSArray() {
                        guard let original = element as AnyObject as? NSString else { continue }
                        let dicomField = Reports.removingSpaces(original)

                        if lastObj == nil {
                            lastObj = dcmObject?.attribute(withName: dicomField as String?)
                        }

                        if lastObj == nil {
                            lastObj = dcmObject?.attribute(for: DCMAttributeTag.tag(withTagString: dicomField as String?) as? DCMAttributeTag)
                        }

                        if lastObj == nil {
                            break
                        }

                        if !(lastObj is DCMSequenceAttribute) {
                            break
                        } else {
                            // Read only first item...
                            dcmObject = ((lastObj as? NSObject)?.value(forKey: "sequence") as? NSArray)?.object(at: 0) as? DCMObject

                            if (dicomFields?.lastObject as AnyObject?) !== dicomField {
                                lastObj = nil
                            }
                        }
                    }

                    if let sequence = lastObj as? DCMSequenceAttribute {
                        lastObj = sequence.readableDescription() as NSString?
                    }

                    if let attribute = lastObj as? DCMAttribute {
                        lastObj = attribute.value() as AnyObject?
                    }

                    if let string = lastObj as? NSString {
                        found = string as String
                    }
                }
            }
        } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, false, "-[Reports getDICOMStringValueForField:inDICOMFile:]")
            }
        }

        if let found = found {
            return found
        }

        NSLog("**** Dicom field not found: %@ in %@", formatArgument(rawField), formatArgument(path))

        return nil
    }

    /// The image paths of the study's first series, which DICOM_FIELD
    /// placeholders are read from.
    private func firstSeriesImagePaths(_ study: NSManagedObject!) -> [Any]? {
        let series = BrowserController.currentBrowser()?.childrenArray(study)
        guard (series?.count ?? 0) > 0 else { return nil }
        // The first child goes as it is, whatever its class, as the Objective-C sent it.
        return BrowserController.currentBrowser()?.perform(#selector(BrowserController.imagesPathArray(_:)), with: series?.first)?
            .takeUnretainedValue() as? [Any]
    }

    private func dicomValue(from paths: [Any]?) -> (String?) -> String? {
        return { field in
            (paths?.count ?? 0) > 0 ? self.getDICOMStringValue(forField: field, inDICOMFile: paths?.first as? String) : ""
        }
    }

    @objc(createNewReport:destination:type:)
    @discardableResult
    public func createNewReport(_ study: NSManagedObject!, destination path: String!, type: Int32) -> Bool {
        let uniqueFilename = Reports.getUniqueFilename(study)

        switch type {
        case 0:
            let destinationFile = String(format: "%@%@.%@", formatArgument(path), formatArgument(uniqueFilename), "doc")
            return createNewWordReport(forStudy: study, toDestinationPath: destinationFile)

        case 1:
            let destinationFile = String(format: "%@%@.rtf", formatArgument(path), formatArgument(uniqueFilename))
            let templatePath = (BrowserController.currentBrowser()?.database?.baseDirPath as NSString?)?.appendingPathComponent("ReportTemplate.rtf")
            let values = reportFieldValues(forStudy: study)
            let paths = firstSeriesImagePaths(study)
            let dicomValue = self.dicomValue(from: paths)
            let created = HorosCreateReportFromTemplate(templatePath, destinationFile, { prepared, error in
                var attributes: NSDictionary? = nil
                guard let prepared = prepared,
                      let rtfData = NSData(contentsOfFile: prepared),
                      let rtf = NSMutableAttributedString(rtf: rtfData as Data, documentAttributes: &attributes) else { return false }
                HorosFillAttributedReport(rtf, values as? [AnyHashable: Any], dicomValue)
                let documentAttributes = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
                guard let data = rtf.rtf(from: NSRange(location: 0, length: rtf.length), documentAttributes: documentAttributes) else { return false }
                return reportingError(error) { try (data as NSData).write(toFile: prepared, options: .atomic) }
            }, nil)
            if !created {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Report", comment: ""),
                                                message: NSLocalizedString("The RTF report could not be created. Check the report template and destination. Any existing report has been preserved.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return false
            }
            study?.setValue(destinationFile, forKey: "reportURL")
            if let reportURL = study?.value(forKey: "reportURL") as? String {
                NSWorkspace.shared.openDocument(atPath: reportURL, applicationIdentifiers: ["com.apple.TextEdit"])
            }

        case 2:
            let destinationFile = String(format: "%@%@.%@", formatArgument(path), formatArgument(uniqueFilename), "pages")
            return createNewPagesReport(forStudy: study, toDestinationPath: destinationFile)

        case 5:
            let destinationFile = String(format: "%@%@.%@", formatArgument(path), formatArgument(uniqueFilename), "odt")
            return createNewOpenDocumentReport(forStudy: study, toDestinationPath: destinationFile)

        default:
            break
        }
        return true
    }

    // the sweetly wrapped method is all we need to know:

    @objc(runScript:)
    func runScript(_ txt: String!) {
        let script = txt.flatMap { NSAppleScript(source: $0) }
        var errs: NSDictionary? = nil
        script?.run(withArguments: nil, error: &errs)
        if (errs?.count ?? 0) > 0 {
            NSLog("Error: AppleScript execution failed: %@", formatArgument(errs))
        }
    }

    @objc(_runAppleScript:withArguments:)
    @discardableResult
    class func _runAppleScript(_ source: String!, withArguments args: NSArray!) -> Any! {
        var errs: NSDictionary? = nil

        guard let source = source else {
            NSException(name: .genericException, reason: "Couldn't read script source", userInfo: nil).raise()
            return nil
        }

        guard let script = NSAppleScript(source: source) else {
            NSException(name: .genericException, reason: "Invalid script source", userInfo: nil).raise()
            return nil
        }

        let r = script.run(withArguments: args, error: &errs)
        if let errs = errs {
            // The caller turns this into a generic "report could not be created",
            // so the editor's own number and message have to be recorded here or
            // they are lost: -1712 (timed out, often a modal dialog), -1743
            // (Automation denied), -10024 (sandbox refused the destination).
            NSLog("***** report AppleScript failed: %@ (%@)",
                  formatArgument(errs[NSAppleScript.errorBriefMessage] ?? errs[NSAppleScript.errorMessage] ?? errs),
                  formatArgument(errs[NSAppleScript.errorNumber] ?? "no number"))
            NSException(name: .genericException,
                        reason: String(format: "%@ (%@)",
                                       formatArgument(errs[NSAppleScript.errorMessage] ?? errs[NSAppleScript.errorBriefMessage] ?? errs),
                                       formatArgument(errs[NSAppleScript.errorNumber] ?? "no number")),
                        userInfo: nil).raise()
        }

        return r
    }

    // MARK: -

    @objc(reportFieldValuesForStudy:)
    func reportFieldValues(forStudy aStudy: NSManagedObject!) -> NSDictionary! {
        let date = DateFormatter()
        date.dateStyle = .short
        let longDate = DateFormatter()
        longDate.dateStyle = .long
        let values = NSMutableDictionary()
        for key in aStudy?.entity.attributesByName.keys.map({ $0 }) ?? [] {
            let value = aStudy.value(forKey: key)
            let string: String?
            if let value = value as? NSDate {
                string = date.string(from: value as Date)
            } else {
                string = (value as AnyObject? as? NSObject)?.description
            }
            values.setObject(string ?? "", forKey: key as NSString)
        }
        let now = Date()
        values.setObject(date.string(from: now), forKey: "today" as NSString)
        values.setObject(longDate.string(from: now), forKey: "longtoday" as NSString)
        return values
    }

    @objc(searchAndReplaceFieldsFromStudy:inString:)
    public func searchAndReplaceFields(fromStudy aStudy: NSManagedObject!, in aString: NSMutableString!) {
        guard let aString = aString else { return }
        let values = reportFieldValues(forStudy: aStudy)
        let paths = firstSeriesImagePaths(aStudy)
        HorosFillReportXML(aString, values as? [AnyHashable: Any], dicomValue(from: paths))
    }

    // MARK: -
    // MARK: Word

    @objc public class func checkForWordTemplates() {
        do {
            try HorosObjCException.perform {
                var path = BrowserController.currentBrowser()?.database?.baseDirPath

                if path == nil {
                    path = DicomDatabase.defaultBaseDirPath()
                }

                // previously, we had a single word template in the Horos Data folder
                let oldReportFilePath = (path as NSString?)?.appendingPathComponent("ReportTemplate.doc")

                // today, we use a dir in the database folder, which contains the templates
                guard let templatesDirPath = Reports.databaseWordTemplatesDirPath() else {
                    return
                }

                var templatesCount = 0

                if FileManager.default.fileExists(atPath: templatesDirPath) {
                    for filename in (try? FileManager.default.contentsOfDirectory(atPath: templatesDirPath)) ?? [] {
                        if isEqualString((filename as NSString).pathExtension, "doc") {
                            templatesCount += 1
                        }
                    }
                }

                if templatesCount == 0 {
                    if let oldReportFilePath = oldReportFilePath, FileManager.default.fileExists(atPath: oldReportFilePath) {
                        try? FileManager.default.moveItem(atPath: oldReportFilePath,
                                                          toPath: (templatesDirPath as NSString).appendingPathComponent((oldReportFilePath as NSString).lastPathComponent))
                    } else if let resourcePath = Bundle.main.resourcePath {
                        try? FileManager.default.copyItem(atPath: (resourcePath as NSString).appendingPathComponent("ReportTemplate.doc"),
                                                          toPath: (templatesDirPath as NSString).appendingPathComponent("Basic Report Template.doc"))
                    }
                }
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(exception, false, "+[Reports checkForWordTemplates]")
            }
        }
    }

    @objc public class func databaseWordTemplatesDirPath() -> String! {
        var path = BrowserController.currentBrowser()?.database?.baseDirPath

        if path == nil {
            path = DicomDatabase.defaultBaseDirPath()
        }

        guard let base = path, (base as NSString).length > 0 else { return nil }
        let folder = (base as NSString).appendingPathComponent("WORD TEMPLATES")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? folder : nil
        }
        // A colliding file, dangling symlink, or failed mkdir must never be removed.
        if (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: nil)) == nil {
            return nil
        }
        return folder
    }

    @objc public class func resolvedDatabaseWordTemplatesDirPath() -> String! {
        return (self.databaseWordTemplatesDirPath() as NSString?)?.resolvingSymlinksAndAliases()
    }

    @objc public class func wordTemplatesList() -> NSMutableArray! {
        let templatesArray = NSMutableArray()

        guard let directory = self.resolvedDatabaseWordTemplatesDirPath(), (directory as NSString).length > 0 else { return templatesArray }
        let directoryEnumerator = FileManager.default.enumerator(atPath: directory)
        while let object = directoryEnumerator?.nextObject() {
            directoryEnumerator?.skipDescendents()

            //hasPrefix: compatible with .doc and .docx
            if let filename = object as AnyObject as? NSString, (filename.pathExtension as NSString).hasPrefix("doc") {
                templatesArray.add(filename)
            }
        }

        templatesArray.sort(using: #selector(NSString.compare(_:)))

        return templatesArray
    }

    @objc(generateWordReportMergeDataForStudy:toPath:)
    @discardableResult
    func generateWordReportMergeData(forStudy study: NSManagedObject!, toPath path: String!) -> String! {
        let model = study?.managedObjectContext?.persistentStoreCoordinator?.managedObjectModel

        // allKeys of the entity's own NSDictionary: the columns keep its order.
        let properties = ((model?.entitiesByName["Study"] as NSObject?)?.value(forKey: "attributesByName") as? NSDictionary)?.allKeys ?? []

        let file = NSMutableString(string: "")

        for name in properties {
            file.append(name as AnyObject as? String ?? "")
            file.append("\t")
        }

        file.append("\r")

        let date = DateFormatter()
        date.dateStyle = .short

        for name in properties {
            let value = (name as AnyObject as? String).flatMap { study?.value(forKey: $0) }
            let string: String?

            if let value = value as? NSDate {
                string = date.string(from: value as Date)
            } else {
                string = (value as AnyObject? as? NSObject)?.description
            }

            if let string = string {
                file.append(DicomFile.nSreplaceBadCharacter(string))
            } else {
                file.append("")
            }

            file.append("\t")
        }

        let rtf = NSMutableAttributedString(string: file as String)

        guard let path = path,
              let data = rtf.rtf(from: NSRange(location: 0, length: rtf.length), documentAttributes: [:]) else { return nil }
        return (try? (data as NSData).write(toFile: path, options: .atomic)) != nil ? path : nil
    }

    @objc(createNewWordReportForStudy:toDestinationPath:)
    @discardableResult
    func createNewWordReport(forStudy study: NSManagedObject!, toDestinationPath destinationFile: String!) -> Bool {
        var inTemplateName: String? = templateNameStorage as String

        if (inTemplateName as NSString?)?.length ?? 0 == 0 && Reports.wordTemplatesList().count > 0 {
            inTemplateName = Reports.wordTemplatesList().object(at: 0) as AnyObject as? String
        }

        var templatePath: String? = nil

        let templatesDirPath = type(of: self).resolvedDatabaseWordTemplatesDirPath()
        let filenames: NSArray? = (templatesDirPath as NSString?)?.length ?? 0 > 0
            ? ((try? FileManager.default.contentsOfDirectory(atPath: templatesDirPath!)) as NSArray?)?.sortedArray(using: #selector(NSString.compare(_:))) as NSArray?
            : nil
        let explicitFormat = ((((inTemplateName as NSString?)?.pathExtension as NSString?)?.lowercased) as NSString?)?.hasPrefix("doc") ?? false
        for object in filenames ?? NSArray() {
            guard let filename = object as AnyObject as? NSString else { continue }
            let candidate = (templatesDirPath! as NSString).appendingPathComponent(filename as String)
            if !(((filename.pathExtension as NSString).lowercased as NSString).hasPrefix("doc")) ||
                !isEqualString((try? FileManager.default.attributesOfItem(atPath: candidate))?[.type] as? String, FileAttributeType.typeRegular.rawValue) {
                continue
            }
            // A menu selection includes its extension: never substitute another
            // format with the same stem. Keep legacy extensionless names working.
            if isEqualString(filename as String, inTemplateName) ||
                (!explicitFormat && isEqualString(filename.deletingPathExtension, inTemplateName)) {
                templatePath = candidate
                break
            }
        }

        guard let template = templatePath, FileManager.default.fileExists(atPath: template) else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Microsoft Word", comment: ""),
                                            message: NSLocalizedString("I cannot find the IsiX DICOM Viewer Word Template doc file.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }

        // The browser requests consent asynchronously before calling this method.
        // Recheck without a prompt before opening the private template: a refused name query
        // leaves a window that the error handler cannot identify or close.
        if let consentError = WordReportAutomation.consentErrorWithoutPrompt() {
            NSLog("***** Word report Automation unavailable: %@", formatArgument(consentError))
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Microsoft Word", comment: ""),
                                            message: consentError.localizedDescription,
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }

        // Word 16 returns no value for `open ... add to recent files false`, so
        // `set d to open ...` leaves d undefined and every later reference fails.
        // Track the documents by name instead, and never let the error handler
        // touch a variable the failing statement may not have assigned - it used
        // to raise -2753 of its own and replace Word's error with "variable not
        // defined". Commands are sent to the loop variable of `every document`:
        // Word rejects `active document` and `document 1` as command targets.
        let source = [
            "on run argv\n",
            "  set dataSourceFile to POSIX file (item 1 of argv)\n",
            "  set outFilePath to POSIX file (item 2 of argv)\n",
            "  set templatePath to POSIX file (item 3 of argv)\n",
            "  set templateName to missing value\n",
            "  set mergedName to missing value\n",
            "  tell application \"Microsoft Word\"\n",
            "    set existingNames to name of every document\n",
            "    try\n",
            // Opening an existing private output file grants Word access to that file.
            // Creating a new path during Save As instead asks for the entire containing
            // folder on every report and can leave Word blocked in its access panel.
            "      open outFilePath add to recent files false\n",
            "      my closeReportDocumentAtPath(outFilePath as string)\n",
            "      open templatePath add to recent files false\n",
            "      set templateName to name of active document\n",
            "      open data source data merge of active document name dataSourceFile\n",
            "      set myMerge to data merge of active document\n",
            "      set destination of myMerge to send to new document\n",
            "      execute data merge myMerge\n",
            "      set candidateName to name of active document\n",
            "      if candidateName is templateName or existingNames contains candidateName then error \"The merge did not create a new document.\"\n",
            "      set mergedName to candidateName\n",
            "      set savedMerge to false\n",
            "      repeat with d in (get every document)\n",
            "        if (name of d) is mergedName then\n",
            "          if (item 4 of argv) is \"docx\" then\n",
            "            save as d file name (outFilePath as string) file format format document add to recent files false\n",
            "          else\n",
            "            save as d file name (outFilePath as string) file format format document97 add to recent files false\n",
            "          end if\n",
            "          set savedMerge to true\n",
            "        end if\n",
            "      end repeat\n",
            "      if not savedMerge then error \"The merged document could not be saved.\"\n",
            "      my closeReportDocumentAtPath(outFilePath as string)\n",
            "      set mergedName to missing value\n",
            "      my closeReportDocument(templateName)\n",
            "      set templateName to missing value\n",
            "      return true\n",
            "    on error errorMessage number errorNumber\n",
            "      my closeReportDocumentAtPath(outFilePath as string)\n",
            "      my closeReportDocument(mergedName)\n",
            "      my closeReportDocument(templateName)\n",
            "      error errorMessage number errorNumber\n",
            "    end try\n",
            "  end tell\n",
            "end run\n",
            "\n",
            // Save As changes the name returned by Word. Match the private output's
            // full path rather than the obsolete Form Letters name or another user's
            // document that happens to share the output's basename.
            "on closeReportDocumentAtPath(thePath)\n",
            "  tell application \"Microsoft Word\"\n",
            "    try\n",
            "      repeat with d in (get every document)\n",
            "        if (full name of d) is thePath then\n",
            "          close d saving no\n",
            "          return\n",
            "        end if\n",
            "      end repeat\n",
            "    end try\n",
            "  end tell\n",
            "end closeReportDocumentAtPath\n",
            "\n",
            "on closeReportDocument(theName)\n",
            "  if theName is missing value then return\n",
            "  tell application \"Microsoft Word\"\n",
            "    try\n",
            "      repeat with d in (get every document)\n",
            "        if (name of d) is theName then close d saving no\n",
            "      end repeat\n",
            "    end try\n",
            "  end tell\n",
            "end closeReportDocument\n",
        ].joined()

        var reportError: NSError? = nil
        let created = HorosCreateReportFromTemplate(template, destinationFile, { prepared, error in
            guard let prepared = prepared as NSString? else { return false }
            let directory = prepared.deletingLastPathComponent as NSString
            // Word also identifies unsaved documents by name. Give this private
            // template a per-run name so cleanup cannot target a user's report.doc.
            let privateTemplate = directory.appendingPathComponent(
                ((directory.lastPathComponent + "-template") as NSString).appendingPathExtension(prepared.pathExtension) ?? "")
            if !reportingError(error, { try FileManager.default.moveItem(atPath: prepared as String, toPath: privateTemplate) }) { return false }
            guard let sourceData = self.generateWordReportMergeData(forStudy: study,
                toPath: directory.appendingPathComponent("MergeData.rtf")) else { return false }
            let fileExtension = isEqualString(((destinationFile as NSString?)?.pathExtension as NSString?)?.lowercased, "docx") ? "docx" : "doc"
            let output = directory.appendingPathComponent(
                ((directory.lastPathComponent + "-merged") as NSString).appendingPathExtension(fileExtension) ?? "")
            if !reportingError(error, { try FileManager.default.copyItem(atPath: privateTemplate, toPath: output) }) { return false }
            var result: Any? = nil
            do {
                // Output starts as a template copy. A missing script result must
                // never let that nonempty, unmerged file become the study report.
                try HorosObjCException.perform {
                    result = type(of: self)._runAppleScript(source, withArguments: [sourceData, output, privateTemplate, fileExtension] as NSArray)
                }
            } catch let caught {
                // Keep the editor's own message: the caller only sees a BOOL, and
                // the preparation wrapper would otherwise replace it.
                let exception = (caught as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                error?.pointee = NSError(domain: "HorosWordReport", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: exception.map { $0.reason ?? $0.name.rawValue } ?? (caught as NSError).localizedDescription])
                return false
            }
            if !((result as AnyObject?)?.isEqual(NSNumber(value: true)) ?? false) {
                NSLog("***** Word merge script did not confirm successful save.")
                return false
            }
            var attributes: [FileAttributeKey: Any]? = nil
            if !reportingError(error, { attributes = try FileManager.default.attributesOfItem(atPath: output) }) { return false }
            if !isEqualString(attributes?[.type] as? String, FileAttributeType.typeRegular.rawValue) ||
                ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0) == 0 { return false }
            // Only the private copy is replaced here; publication happens after success.
            return reportingError(error) { try FileManager.default.moveItem(atPath: output, toPath: prepared as String) }
        }, &reportError)
        if !created {
            // Name what Word refused: the generic sentence alone sent people
            // looking at the template when the cause was an Automation refusal or
            // a destination the editor's sandbox would not write.
            let detail = (reportError?.localizedDescription as NSString?)?.length ?? 0 > 0
                ? String(format: "%@\n\n%@",
                         NSLocalizedString("The Word report could not be created. Check the template, Word permissions, and destination. Any existing report has been preserved.", comment: ""),
                         reportError!.localizedDescription)
                : NSLocalizedString("The Word report could not be created. Check the template, Word permissions, and destination. Any existing report has been preserved.", comment: "")
            NSLog("***** Word report not created: %@", formatArgument(reportError ?? ("no error reported" as NSString)))
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Microsoft Word", comment: ""), message: detail,
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }

        study?.setValue(destinationFile, forKey: "reportURL")

        if let destinationFile = destinationFile {
            NSWorkspace.shared.openDocument(atPath: destinationFile, applicationIdentifiers: ["com.microsoft.Word"])
        }

        return true
    }

    // MARK: -
    // MARK: OpenDocument

    // ODT templates live beside the legacy ReportTemplate.odt in the database root.
    @objc public class func openDocumentTemplatesList() -> NSMutableArray! {
        let directory = BrowserController.currentBrowser()?.database?.baseDirPath
        let templates = NSMutableArray()
        for name in directory.flatMap({ try? FileManager.default.contentsOfDirectory(atPath: $0) }) ?? [] {
            let path = (directory! as NSString).appendingPathComponent(name)
            if isEqualString(((name as NSString).pathExtension as NSString).lowercased, "odt") &&
                isEqualString((try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? String, FileAttributeType.typeRegular.rawValue) {
                templates.add(name)
            }
        }
        templates.sort(using: #selector(NSString.compare(_:)))
        return templates
    }

    @objc(pathForOpenDocumentTemplate:)
    public class func pathForOpenDocumentTemplate(_ name: String!) -> String! {
        let templates = self.openDocumentTemplatesList()!
        var name = name
        if (name as NSString?)?.length ?? 0 == 0 {
            name = templates.contains("ReportTemplate.odt") ? "ReportTemplate.odt" : templates.firstObject as AnyObject? as? String
        }
        // Only resolve a listed file, never silently substitute a missing selection.
        guard let listed = name, templates.contains(listed) else { return nil }
        return (BrowserController.currentBrowser()?.database?.baseDirPath as NSString?)?.appendingPathComponent(listed)
    }

    @objc(createNewOpenDocumentReportForStudy:toDestinationPath:)
    @discardableResult
    public func createNewOpenDocumentReport(forStudy aStudy: NSManagedObject!, toDestinationPath aPath: String!) -> Bool {
        let templatePath = type(of: self).pathForOpenDocumentTemplate(templateNameStorage as String)
        let created = HorosCreateOpenDocument(templatePath, aPath, { content in
            self.searchAndReplaceFields(fromStudy: aStudy, in: content)
        }, nil)
        if !created {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Report", comment: ""),
                                            message: NSLocalizedString("The OpenDocument report could not be created. Check the report template and destination. Any existing report has been preserved.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }

        aStudy?.setValue(aPath, forKey: "reportURL")

        // open the modified .odt file
        if let aPath = aPath {
            NSWorkspace.shared.openDocument(atPath: aPath, applicationIdentifiers: ["org.libreoffice.script", "org.openoffice.script"], fallbackToDefault: true)
        }
        Thread.sleep(forTimeInterval: 1)

        // end
        return true
    }

    // MARK: -
    // MARK: Pages.app

    @objc class func databasePagesTemplatesDirPath() -> String! {
        var path = BrowserController.currentBrowser()?.database?.baseDirPath

        if path == nil {
            path = DicomDatabase.defaultBaseDirPath()
        }

        return (path as NSString?)?.appendingPathComponent("PAGES TEMPLATES")
    }

    @objc public class func checkForPagesTemplate() {
        guard let templatesDirPath = Reports.databasePagesTemplatesDirPath() else { return }

        if FileManager.default.fileExists(atPath: templatesDirPath) == false {
            try? FileManager.default.createDirectory(atPath: templatesDirPath, withIntermediateDirectories: false, attributes: nil)
        }

        // Pages template
        let defaultReport = (templatesDirPath as NSString).appendingPathComponent("/Horos Basic Report.pages")
        if FileManager.default.fileExists(atPath: defaultReport) == false, let resourcePath = Bundle.main.resourcePath {
            try? FileManager.default.copyItem(atPath: (resourcePath as NSString).appendingPathComponent("/Horos Report.pages"), toPath: defaultReport)
        }
    }

    @objc(Pages5orHigher)
    public class func pages5orHigher() -> Int32 {
        return HorosPagesUsesModernTemplates(PagesApplication.information() as [AnyHashable: Any]?) ? 1 : 0
    }

    @objc(decompressPagesFileIfNecessary:)
    @discardableResult
    func decompressPagesFileIfNecessary(_ aPath: String!) -> Bool {
        guard let aPath = aPath else { return false }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: aPath, isDirectory: &isDirectory) { return false }
        if isDirectory.boolValue { return true }
        let data = try? NSData(contentsOfFile: aPath, options: .mappedIfSafe)
        guard let unpacked = HorosExtractPagesPackage(data as Data?) else { return false }
        var replaced = false
        var raised: NSException? = nil
        do {
            try HorosObjCException.perform {
                replaced = HorosReplaceReportFile(unpacked, aPath, nil)
            }
        } catch {
            raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        try? FileManager.default.removeItem(atPath: unpacked)
        raised?.raise()
        return replaced
    }

    @objc(createNewPagesReportForStudy:toDestinationPath:)
    @discardableResult
    public func createNewPagesReport(forStudy aStudy: NSManagedObject!, toDestinationPath aPath: String!) -> Bool {
        // Not by one bundle identifier: Pages '09 answers to com.apple.iWork.Pages
        // and Pages 15 to com.apple.Pages, so asking only for the first said "Pages
        // is not installed" with Pages in the Applications folder.
        guard let pagesApplication = PagesApplication.url() else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Pages", comment: ""),
                                            message: NSLocalizedString("Pages is not installed or could not be located. Install Pages before creating a Pages report. No report has been changed.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }
        let templatePath = type(of: self).pathForPagesTemplate(templateNameStorage as String)
        guard let template = templatePath, (template as NSString).length > 0, FileManager.default.fileExists(atPath: template) else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Pages", comment: ""),
                                            message: NSLocalizedString("The selected Pages template could not be found. Choose an available template and try again. No report has been changed.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }
        var error: NSError? = nil
        let created = HorosCreateReportFromTemplate(template, aPath, { prepared, preparationError in
            guard let prepared = prepared else { return false }
            // A template Pages '09 wrote keeps its text in index.xml and can be
            // filled in here. One that Pages 5 or later wrote keeps it in
            // Index/*.iwa, where nothing here can reach it - and unpacking it first
            // would turn the document into a directory - so Pages fills that one in.
            var isDirectory: ObjCBool = false
            var legacy = false
            if FileManager.default.fileExists(atPath: prepared, isDirectory: &isDirectory) && isDirectory.boolValue {
                legacy = FileManager.default.fileExists(atPath: (prepared as NSString).appendingPathComponent("index.xml"))
            } else {
                legacy = HorosPagesArchiveHasIndexXML((try? NSData(contentsOfFile: prepared, options: .mappedIfSafe)) as Data?)
            }

            if legacy {
                if !self.decompressPagesFileIfNecessary(prepared) { return false }
                let indexPath = (prepared as NSString).appendingPathComponent("index.xml")
                var xml: NSMutableString? = nil
                if !reportingError(preparationError, { xml = try NSMutableString(contentsOfFile: indexPath, encoding: String.Encoding.utf8.rawValue) }) { return false }
                guard let xml = xml else { return false }
                self.searchAndReplaceFields(fromStudy: aStudy, in: xml)
                return reportingError(preparationError) { try xml.write(toFile: indexPath, atomically: true, encoding: String.Encoding.utf8.rawValue) }
            }

            let values = self.reportFieldValues(forStudy: aStudy)
            let paths = self.firstSeriesImagePaths(aStudy)
            let dicomValue = self.dicomValue(from: paths)
            return PagesDocumentFill.fill(documentAt: prepared, substitute: { line in
                let filled = NSMutableString(string: line)
                HorosFillReportText(filled, values as? [AnyHashable: Any], dicomValue)
                return filled as String
            })
        }, &error)
        if !created {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Pages", comment: ""),
                                            message: NSLocalizedString("The Pages report could not be created. Check that Pages can open the template, and that IsiX DICOM Viewer is allowed to control Pages in System Settings > Privacy & Security > Automation. The original template and any existing report have been preserved.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }
        aStudy?.setValue(aPath, forKey: "reportURL")
        guard let aPath else { return false }
        return NSWorkspace.shared.openDocument(atPath: aPath, applicationURLs: [pagesApplication]) { opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Pages", comment: ""),
                                            message: NSLocalizedString("The report was created and attached to the study, but Pages could not open it. Check that Pages can launch, then open the report again. The generated report has been kept.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }

    @objc(pathForPagesTemplate:)
    class func pathForPagesTemplate(_ templateName: String!) -> String! {
        var templateName = templateName
        if (templateName as NSString?)?.length ?? 0 == 0 && Reports.pagesTemplatesList().count > 0 {
            templateName = Reports.pagesTemplatesList().object(at: 0) as AnyObject as? String
        }

        if Reports.pages5orHigher() != 0 {
            guard let templateDirectory = self.databasePagesTemplatesDirPath() else { return nil }
            let directoryEnumerator = FileManager.default.enumerator(atPath: templateDirectory)

            while let object = directoryEnumerator?.nextObject() {
                directoryEnumerator?.skipDescendents()
                guard let file = object as AnyObject as? NSString else { continue }
                if isEqualString(file.deletingPathExtension, (templateName as NSString?)?.deletingPathExtension) {
                    if isEqualString(file.pathExtension, "pages") {
                        return (templateDirectory as NSString).appendingPathComponent(file as String)
                    }
                }
            }
        } else {
            let templateDirectoryPathArray = [NSHomeDirectory(), "Library", "Application Support", "iWork", "Pages", "Templates", "OsiriX", "Horos"]
            let templateDirectory = NSString.path(withComponents: templateDirectoryPathArray)
            let directoryEnumerator = FileManager.default.enumerator(atPath: templateDirectory)

            while let object = directoryEnumerator?.nextObject() {
                directoryEnumerator?.skipDescendents()
                guard let file = object as AnyObject as? NSString else { continue }

                if isEqualString(file as String, templateName) || isEqualString(file as String, String(format: "Horos %@", formatArgument(templateName))) {
                    return (templateDirectory as NSString).appendingPathComponent(file as String)
                }
            }
        }

        return nil
    }

    @objc(copyPages4templatesToPages5:)
    class func copyPages4templatesToPages5(_ newDirectory: String!) {
        let templateDirectoryPathArray = [NSHomeDirectory(), "Library", "Application Support", "iWork", "Pages", "Templates", "OsiriX", "Horos"]
        let templateDirectory = NSString.path(withComponents: templateDirectoryPathArray)
        let directoryEnumerator = FileManager.default.enumerator(atPath: templateDirectory)

        while let object = directoryEnumerator?.nextObject() {
            directoryEnumerator?.skipDescendents()
            guard let file = object as AnyObject as? NSString else { continue }
            if file.hasPrefix("Horos ") {
                let fromPath = (templateDirectory as NSString).appendingPathComponent(file as String)
                guard let toDirectory = newDirectory,
                      let toPath = (((toDirectory as NSString).appendingPathComponent(file as String) as NSString)
                        .deletingPathExtension as NSString).appendingPathExtension("pages") else { continue }

                FileManager.default.copyItem(atPath: fromPath, toPath: toPath, byReplacingExisting: false, error: nil)
            }
        }
    }

    @objc public class func pagesTemplatesList() -> NSMutableArray! {
        if Reports.pages5orHigher() != 0 {
            let templateDirectory = self.databasePagesTemplatesDirPath()

            if pagesTemplatesFirstTime.exchange(false, ordering: .relaxed) {
                Reports.copyPages4templatesToPages5(templateDirectory)
            }

            let directoryEnumerator = templateDirectory.flatMap { FileManager.default.enumerator(atPath: $0) }
            let templatesArray = NSMutableArray(capacity: 1)
            while let object = directoryEnumerator?.nextObject() {
                directoryEnumerator?.skipDescendents()
                if let file = object as AnyObject as? NSString, isEqualString(file.pathExtension, "pages") {
                    templatesArray.add(file)
                }
            }

            templatesArray.sort(using: #selector(NSString.compare(_:)))

            return templatesArray
        } else {
            let templateDirectoryPathArray = [NSHomeDirectory(), "Library", "Application Support", "iWork", "Pages", "Templates", "OsiriX", "Horos"]
            let templateDirectory = NSString.path(withComponents: templateDirectoryPathArray)
            let directoryEnumerator = FileManager.default.enumerator(atPath: templateDirectory)

            let templatesArray = NSMutableArray(capacity: 1)
            while let object = directoryEnumerator?.nextObject() {
                directoryEnumerator?.skipDescendents()
                guard let file = object as AnyObject as? NSString else { continue }
                // As before, the match asks for 7 characters where "Horos " has 6,
                // so no legacy template is ever listed.
                let rangeOfOsiriX = file.range(of: "Horos ")
                if rangeOfOsiriX.location == 0 && rangeOfOsiriX.length == 7 {
                    // this is a template for us (we should maybe verify that it is a valid Pages template... but what ever...)
                    templatesArray.add(file.substring(from: 7))
                }
            }

            templatesArray.sort(using: #selector(NSString.compare(_:)))

            return templatesArray
        }
    }

    @objc public func templateName() -> NSMutableString! {
        return templateNameStorage
    }

    @objc(setTemplateName:)
    public func setTemplateName(_ aName: String!) {
        // Resolvers remove only the final extension when comparing names. Keep the
        // selected filename intact so dots and format-like text in its stem survive.
        templateNameStorage.setString(aName ?? "")
    }
}
