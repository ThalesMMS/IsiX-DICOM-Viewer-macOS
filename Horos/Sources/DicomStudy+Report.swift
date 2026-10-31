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

import Foundation
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXPreferences

/// -[NSString isEqualToString:], which is NO when either side is nil.
private func isEqualString(_ string: String?, _ other: String?) -> Bool {
    guard let string = string, let other = other else { return false }
    return (string as NSString).isEqual(to: other)
}

/// Indexes the validated report's DICOM PDF and says whether it went into the
/// study with `studyInstanceUID`; a file on disk is not that, an import can
/// refuse it or file it elsewhere.
private func addValidatedReport(_ database: DicomDatabase?, _ path: String, _ studyInstanceUID: String?) -> Bool {
    var indexed = false
    N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
        guard let database, let context = database.managedObjectContext,
              let studyInstanceUID, !studyInstanceUID.isEmpty else { return }
        let added = DatabaseIngest.process.index([path], preset: .generated, in: database) ?? []
        indexed = added.contains { item in
            guard let objectID = item as? NSManagedObjectID,
                  let image = (try? context.existingObject(with: objectID)) as? DicomImage else { return false }
            return image.series?.study?.studyInstanceUID == studyInstanceUID
        }
    }
    return indexed
}

/// Why a study's report could not be converted to PDF, encapsulated in DICOM
/// or archived, or its windows state archived, as a DICOM SR: the failure the
/// code names, where the former code raised an NSGenericException (or the
/// exception named) with that reason, or an exception an Objective-C callee
/// (the ODT conversion, DCMTK, Core Data) raised. A document is made on the
/// thread that asks for it, and an exception is not changed once raised, hence
/// the unchecked conformance.
enum StudyDocumentError: Error, @unchecked Sendable, CustomStringConvertible {
    case failed(String)
    case named(NSExceptionName, String)
    case raised(NSException)

    /// The exception the code raised before its failures were thrown: what an
    /// Objective-C caller receives, and what the callers log and tell.
    var exception: NSException {
        switch self {
        case .failed(let reason):
            return NSException(name: .genericException, reason: reason, userInfo: nil)
        case .named(let name, let reason):
            return NSException(name: name, reason: reason, userInfo: nil)
        case .raised(let exception):
            return exception
        }
    }

    var description: String { exception.description }

    /// The exception of a failure a conversion threw, or one made of another error.
    static func exception(of error: Error) -> NSException {
        return (error as? StudyDocumentError)?.exception
            ?? NSException(name: .genericException, reason: (error as NSError).localizedDescription, userInfo: nil)
    }

    /// A conversion or an archive called from Objective-C, as a plugin may
    /// call it: its failure reaches the caller as the exception the code raised
    /// before it threw.
    static func raisingForObjectiveC<T>(_ conversion: () throws -> T) -> T {
        do {
            return try conversion()
        } catch {
            exception(of: error).raise()
            fatalError("an exception was raised")
        }
    }
}

/// The DicomStudy (Report) category, in Swift: the selectors and
/// <Horos/DicomStudy+Report.h> are those of the former category. The ODT
/// conversion stays Objective-C, in DicomStudy+Report+CAPI.m.
///
/// The conversions throw StudyDocumentError to Swift; each selector of the
/// former category raises its failure as an NSException, as before.
public extension DicomStudy {

    /// The former +_runAppleScriptAtPath:withArguments:.
    @objc(_runAppleScriptAtPath:withArguments:)
    @discardableResult
    class func _runAppleScript(atPath path: String!, withArguments args: NSArray!) -> Any! {
        return StudyDocumentError.raisingForObjectiveC { try runAppleScript(atPath: path, withArguments: args as? [Any]) }
    }

    /// Runs the AppleScript at `path` with `args`; its result.
    @nonobjc
    @discardableResult
    class func runAppleScript(atPath path: String?, withArguments args: [Any]?) throws -> Any? {
        var errs: NSDictionary? = nil

        guard let path = path else {
            throw StudyDocumentError.failed("NULL script path")
        }

        let source: NSString
        do {
            source = try NSString(contentsOfFile: path, usedEncoding: nil)
        } catch {
            throw StudyDocumentError.failed((error as NSError).localizedDescription)
        }

        guard let script = NSAppleScript(source: source as String) else {
            throw StudyDocumentError.failed("Invalid script source")
        }

        let r = script.run(withArguments: args as NSArray?, error: &errs)
        if let errs = errs {
            throw StudyDocumentError.failed(String(format: "%@", errs))
        }

        return r
    }

    @objc(transformReportAtPath:toPdfAtPath:)
    class func transformReport(atPath reportPath: String!, toPdfAtPath outPdfPath: String!) {
        StudyDocumentError.raisingForObjectiveC { try convertReport(atPath: reportPath, toPdfAtPath: outPdfPath) }
    }

    /// Converts the report at `reportPath` to a PDF at `outPdfPath`, by its
    /// kind: ODT through LibreOffice, RTF drawn here, Pages and Word through
    /// their applications. A missing or empty PDF is a failure.
    @nonobjc
    class func convertReport(atPath reportPath: String?, toPdfAtPath outPdfPath: String?) throws {
        // A PDF already at the destination is not this conversion's result: were the conversion to
        // fail without writing, it must not pass for one.
        if let outPdfPath = outPdfPath, (outPdfPath as NSString).length > 0,
           !isEqualString((outPdfPath as NSString).standardizingPath, (reportPath as NSString?)?.standardizingPath) {
            try? FileManager.default.removeItem(atPath: outPdfPath)
        }

        let reportExtension = ((reportPath as NSString?)?.pathExtension as NSString?)?.lowercased as NSString?
        func extensionIs(_ name: String) -> Bool {
            reportExtension?.isEqual(to: name) ?? false
        }

        if extensionIs("odt") {
            // The Objective-C conversion raises when LibreOffice is missing.
            try HorosObjCException.throwing(StudyDocumentError.raised) {
                self._transformOdt(atPath: reportPath, toPdfAtPath: outPdfPath)
            }
        } else if extensionIs("rtf") || extensionIs("rtfd") {
            // Drawn by the app. /System/Library/Printers/Libraries/convert is gone since OS X 10.8, and
            // cupsfilter has no RTF filter on macOS 27: it exited 1 over the empty PDF made for its
            // output, and that empty PDF went on to every caller.
            do {
                try RichTextReportPDF.convert(reportPath: reportPath ?? "", toPDFAtPath: outPdfPath ?? "")
            } catch {
                throw StudyDocumentError.failed((error as NSError).localizedDescription)
            }
        } else if extensionIs("pages") {
            // Pages 10: the bundled AppleScript named Pages
            // and `open`ed a path. A sandboxed Pages answers that open and
            // never shows the document, so manual and Validated conversion
            // wrote nothing. HorosPagesPDFConversion opens through
            // LaunchServices, exports a working copy, and leaves the report.
            do {
                try PagesPDFConversion.convertReport(at: reportPath ?? "", toPDFAt: outPdfPath ?? "")
            } catch {
                throw StudyDocumentError.failed((error as NSError).localizedDescription)
            }
        } else if extensionIs("doc") || extensionIs("docx") {
            let path = Bundle.main.path(forResource: "word2pdf", ofType: "applescript")
            // +arrayWithObjects: stopped at the first nil.
            var arguments: [Any] = []
            if let reportPath = reportPath {
                arguments.append(reportPath)
                if let outPdfPath = outPdfPath {
                    arguments.append(outPdfPath)
                }
            }
            try self.runAppleScript(atPath: path, withArguments: arguments)
        } else {
            throw StudyDocumentError.failed(String(format: "Can't transform report to PDF: %@", (reportPath as NSString?) ?? "(null)"))
        }

        // Whatever converted it - LibreOffice, Word's script - a missing or empty PDF is a failure for
        // every caller, not a result to export, encapsulate, serve or burn.
        if !PagesPDFConversion.isUsablePDF(at: outPdfPath ?? "") {
            if let outPdfPath = outPdfPath {
                try? FileManager.default.removeItem(atPath: outPdfPath)
            }
            throw StudyDocumentError.failed(NSLocalizedString("The report could not be converted to PDF. The original report has been left unchanged.", comment: ""))
        }
    }

    @objc(saveReportAsPdfAtPath:)
    func saveReportAsPdf(atPath path: String!) {
        StudyDocumentError.raisingForObjectiveC { try writeReportPDF(atPath: path) }
    }

    /// The study's report converted to a PDF at `path`.
    @nonobjc
    func writeReportPDF(atPath path: String?) throws {
        try type(of: self).convertReport(atPath: self.reportURL, toPdfAtPath: path)
    }

    @objc func saveReportAsPdfInTmp() -> String! {
        return StudyDocumentError.raisingForObjectiveC { try reportPDFInTmp() }
    }

    /// The study's report converted to a PDF in the temporary folder; its path.
    /// The PDF is the caller's to remove; nothing else is left there.
    @nonobjc
    func reportPDFInTmp() throws -> String? {
        // mkstemp's empty file reserves the name while the PDF is written beside
        // it with the extension added. It goes once the conversion is over, and
        // so does a PDF the conversion failed to finish: each conversion used to
        // leave an empty file-XXXXXX in the temporary folder.
        let reserved = FileManager.default.tmpFilePathInTmp()
        defer { try? FileManager.default.removeItem(atPath: reserved) }
        let path = (reserved as NSString).appendingPathExtension("pdf")

        do {
            try self.writeReportPDF(atPath: path)
        } catch {
            if let path {
                try? FileManager.default.removeItem(atPath: path)
            }
            throw error
        }

        return path
    }

    /// The former +_ifAvailableCopyAttributeWithName:from:to:alternatively:.
    @objc(_ifAvailableCopyAttributeWithName:from:to:alternatively:)
    @discardableResult
    class func _ifAvailableCopyAttribute(withName name: String!, from: DCMObject!, to: HorosDICOMWriter!, alternatively altvalue: Any!) -> Bool {
        let attribute = from?.attributeValue(withName: name)
        var thevalue: Any? = attribute
        if thevalue == nil, let altvalue = altvalue {
            thevalue = (altvalue as AnyObject) is NSArray ? altvalue : NSArray(object: altvalue)
        }
        if let value = thevalue {
            let values = (value as AnyObject) as? NSArray ?? NSArray(object: value)
            if let name = name {
                _ = to?.setValues(values as! [Any], forName: name)
            }
        }
        return attribute != nil
    }

    /// The former +_ifAvailableCopyAttributeWithName:from:to:.
    @objc(_ifAvailableCopyAttributeWithName:from:to:)
    @discardableResult
    class func _ifAvailableCopyAttribute(withName name: String!, from: DCMObject!, to: HorosDICOMWriter!) -> Bool {
        return self._ifAvailableCopyAttribute(withName: name, from: from, to: to, alternatively: nil)
    }

    @objc(transformPdfAtPath:toDicomAtPath:usingSourceDicomAtPath:)
    class func transformPdf(atPath pdfPath: String!, toDicomAtPath outDicomPath: String!, usingSourceDicomAtPath sourcePath: String!) {
        self.transformPdf(atPath: pdfPath, toDicomAtPath: outDicomPath, usingSourceDicomAtPath: sourcePath, fallbackAttributes: nil)
    }

    @objc(transformPdfAtPath:toDicomAtPath:usingSourceDicomAtPath:fallbackAttributes:)
    class func transformPdf(atPath pdfPath: String!, toDicomAtPath outDicomPath: String!, usingSourceDicomAtPath sourcePath: String!, fallbackAttributes fallback: NSDictionary!) {
        // Read and written by DCMTK: the source through DCMObject's reader,
        // the Encapsulated PDF through HorosDICOMWriter, with the attributes the
        // DCM Framework's +encapsulatedPDF: gave it. Text is UTF-8 (ISO_IR 192);
        // the source's character set is not copied, since its bytes are not.
        let source: DCMObject? = (sourcePath as NSString?)?.length ?? 0 > 0 ? DCMObject.object(contentsOfFile: sourcePath) : nil
        guard let pdf = pdfPath.flatMap({ FileManager.default.contents(atPath: $0) }) else {
            return
        }

        let output = HorosDICOMWriter()
        let pdfStorage = DICOMSOPClass.pdfStorageClassUID()
        _ = output.setValues([pdfStorage as Any], forName: "SOPClassUID")
        _ = output.setValues([DICOMCalendarDate.dicomDate(with: Date()) as Any], forName: "ContentDate")
        _ = output.setValues([DICOMCalendarDate.dicomTime(with: Date()) as Any], forName: "ContentTime")
        _ = output.setValues(["NO"], forName: "BurnedInAnnotation")
        _ = output.setValues([], forName: "AcquisitionDatetime")
        _ = output.setValues([], forName: "DocumentTitle")
        _ = output.setValues([], forName: "PatientsAge")
        _ = output.setValues(["WSD"], forName: "ConversionType")
        _ = output.setValues(["IsiX DICOM Viewer"], forName: "Manufacturer")
        _ = output.setValues(["OT"], forName: "Modality")
        _ = output.setEmptySequenceForName("ConceptNameCodeSequence")
        _ = output.setValues(["application/pdf"], forName: "MIMETypeOfEncapsulatedDocument")
        _ = output.setData(pdf, forName: "EncapsulatedDocument", vr: "OB")
        _ = output.setValues([HorosDICOMWriter.newStudyInstanceUID()], forName: "StudyInstanceUID")
        _ = output.setValues([HorosDICOMWriter.newSeriesInstanceUID()], forName: "SeriesInstanceUID")
        _ = output.setValues([HorosDICOMWriter.newSOPInstanceUID()], forName: "SOPInstanceUID")

        var reportName: Any = NSLocalizedString("Report PDF", comment: "")

        if let stored = PreferencesSource.process.preferences[DatabasePreferences.reportName] {
            reportName = stored.object
        }

        _ = self._ifAvailableCopyAttribute(withName: "StudyInstanceUID", from: source, to: output)
        _ = output.setValues([reportName], forName: "SeriesDescription")
        _ = output.setValues(["1"], forName: "InstanceNumber")
        _ = output.setValues(["1"], forName: "StudyID")
        _ = output.setValues(["0"], forName: "SeriesNumber")
        _ = self._ifAvailableCopyAttribute(withName: "StudyDescription", from: source, to: output)
        _ = self._ifAvailableCopyAttribute(withName: "PatientsName", from: source, to: output, alternatively: "")
        _ = self._ifAvailableCopyAttribute(withName: "PatientID", from: source, to: output, alternatively: "0")
        _ = self._ifAvailableCopyAttribute(withName: "PatientsBirthDate", from: source, to: output, alternatively: NSArray())
        _ = self._ifAvailableCopyAttribute(withName: "AccessionNumber", from: source, to: output, alternatively: NSArray())
        _ = self._ifAvailableCopyAttribute(withName: "ReferringPhysiciansName", from: source, to: output, alternatively: NSArray())
        _ = self._ifAvailableCopyAttribute(withName: "PatientsSex", from: source, to: output, alternatively: "")
        _ = self._ifAvailableCopyAttribute(withName: "StudyDate", from: source, to: output, alternatively: DICOMCalendarDate.dicomDate(with: Date()))
        _ = self._ifAvailableCopyAttribute(withName: "StudyTime", from: source, to: output, alternatively: DICOMCalendarDate.dicomTime(with: Date()))

        _ = output.setValues([DICOMCalendarDate.dicomDate(with: Date()) as Any], forName: "SeriesDate")
        _ = output.setValues([DICOMCalendarDate.dicomTime(with: Date()) as Any], forName: "SeriesTime")

        if let fallback = fallback, (fallback as AnyObject).isKind(of: NSDictionary.self) {
            for (key, _) in fallback {
                guard let name = key as AnyObject as? String else { continue }
                if (name as NSString).isEqual(to: "StudyInstanceUID") {
                    continue
                }
                if (output.values(forName: name)?.count ?? 0) > 0 {
                    continue
                }
                _ = output.setValues([fallback.object(forKey: name) as Any], forName: name)
            }
            if let uid = fallback.object(forKey: "StudyInstanceUID") as AnyObject? as? NSString, uid.length > 0 {
                _ = output.setValues([uid], forName: "StudyInstanceUID")
            }
        }

        _ = output.write(toFile: outDicomPath, transferSyntax: "1.2.840.10008.1.2.1")
    }

    @objc(transformPdfAtPath:toDicomAtPath:)
    func transformPdf(atPath pdfPath: String!, toDicomAtPath outDicomPath: String!) {
        StudyDocumentError.raisingForObjectiveC { try encapsulateReportPDF(atPath: pdfPath, toDicomAtPath: outDicomPath) }
    }

    /// The PDF at `pdfPath` encapsulated in DICOM at `outDicomPath`, in this
    /// study, over the attributes of one of its images.
    @nonobjc
    func encapsulateReportPDF(atPath pdfPath: String?, toDicomAtPath outDicomPath: String?) throws {
        if !PagesPDFConversion.isUsablePDF(at: pdfPath ?? "") {
            throw StudyDocumentError.failed(NSLocalizedString("The report PDF is missing or unreadable. The original report has been left unchanged.", comment: ""))
        }

        // The series in the order of the NSSet's allObjects, as before.
        var sourcePath: String? = nil
        for object in (self.value(forKey: "series") as? NSSet)?.allObjects ?? [] {
            guard let series = object as? DicomSeries else { continue }
            for element in series.sortedImages() ?? [] {
                guard let image = element as? DicomImage else { continue }
                if let completePath = image.completePath(), FileManager.default.fileExists(atPath: completePath) {
                    sourcePath = completePath
                }
                if sourcePath != nil {
                    break
                }
            }
            if sourcePath != nil {
                break
            }
        }

        let fallback = PagesPDFConversion.associationAttributes(studyInstanceUID: self.studyInstanceUID,
                                                                patientName: self.name,
                                                                patientID: self.patientID,
                                                                accessionNumber: self.accessionNumber,
                                                                studyDescription: self.studyName)
        type(of: self).transformPdf(atPath: pdfPath, toDicomAtPath: outDicomPath, usingSourceDicomAtPath: sourcePath,
                                    fallbackAttributes: fallback as NSDictionary)
    }

    @objc(saveReportAsDicomAtPath:)
    func saveReportAsDicom(atPath path: String!) {
        StudyDocumentError.raisingForObjectiveC { try writeReportAsDicom(atPath: path) }
    }

    /// The study's report converted to a PDF and encapsulated in DICOM at `path`.
    @nonobjc
    func writeReportAsDicom(atPath path: String?) throws {
        let pdfPath = try self.reportPDFInTmp()
        // The former @try/@finally: the temporary PDF goes whatever happened,
        // and the failure goes on to the caller.
        defer {
            if let pdfPath = pdfPath {
                try? FileManager.default.removeItem(atPath: pdfPath)
            }
        }
        // The encapsulation reads the study's images through Core Data and the
        // source file through DCMTK, which may raise.
        try HorosObjCException.throwing(StudyDocumentError.raised) {
            if !PagesPDFConversion.isUsablePDF(at: pdfPath ?? "") {
                throw StudyDocumentError.failed(NSLocalizedString("Pages could not export the report as PDF. The original report has been left unchanged.", comment: ""))
            }
            try self.encapsulateReportPDF(atPath: pdfPath, toDicomAtPath: path)
            if !FileManager.default.fileExists(atPath: path ?? "") {
                throw StudyDocumentError.failed(NSLocalizedString("The DICOM PDF could not be written. The original report has been left unchanged.", comment: ""))
            }
        }
    }

    /// The validated report as a DICOM PDF, in the study's own database, which
    /// the browser may not show: written in a new file of its data folder and
    /// indexed there, so a shared database sends it to its server. A study the
    /// browser does not show once had it written and indexed in a scratch
    /// database in the temporary folder, where no server or rebuild ever read
    /// it. A failure is said, and the validation goes on.
    @nonobjc
    func archiveValidatedReportAsDICOMPDF() {
        do {
            // The conversion and the indexing read and write Core Data, which may raise.
            try HorosObjCException.throwing(StudyDocumentError.raised) {
                // Without a database there is nowhere to write it, as there was nowhere without a path.
                guard let database = BrowserDatabaseSource.process.database(of: self) else {
                    throw StudyDocumentError.failed("The DICOM PDF could not be written. The original report has been left unchanged.")
                }
                var failure: Error? = nil
                let inStudy = GeneratedSeriesImport.process.add(into: database, writing: { filePath in
                    do {
                        try self.writeReportAsDicom(atPath: filePath)
                    } catch {
                        failure = error
                        return nil
                    }
                    // Conversion failure must not import an empty path or
                    // replace the Pages report. reportURL is untouched.
                    return FileManager.default.fileExists(atPath: filePath) ? filePath : nil
                }, indexing: { filePath, database in
                    addValidatedReport(dicomStudyGeneratedFilesDatabase(database), filePath, self.studyInstanceUID)
                })
                if let failure { throw failure }
                guard let inStudy else {
                    throw StudyDocumentError.failed("The DICOM PDF could not be written. The original report has been left unchanged.")
                }

                // The report open in Pages closes once its PDF is in this
                // study; until then it is the only copy being worked on.
                if inStudy, PreferencesSource.process.preferences[DatabasePreferences.closePagesReportWhenValidated],
                   let report = self.reportURL {
                    PagesPDFConversion.closeValidatedReport(at: report)
                }
            }
        } catch {
            let e = StudyDocumentError.exception(of: error)
            _N2LogExceptionImpl(e, true, "-[DicomStudy setStateText:]")
            // Validation goes on; the missing DICOM PDF is said, not only logged.
            let reason = "\(self.name ?? ""): \(e.reason ?? e.name.rawValue)"
            DispatchQueue.main.async {
                PreferencesSource.process.processGraph.userNotifications.post(title: NSLocalizedString("Report Error", comment: ""), description: reason, name: "reportConversion")
            }
        }
    }

    @objc func saveReportAsDicomInTmp() -> String! {
        let path = FileManager.default.tmpFilePathInTmp()
        self.saveReportAsDicom(atPath: path)
        return path
    }
}
