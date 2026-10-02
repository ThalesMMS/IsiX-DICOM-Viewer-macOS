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

/// -[NSString isEqualToString:], which is NO when either side is nil.
private func isEqualString(_ string: String?, _ other: String?) -> Bool {
    guard let string = string, let other = other else { return false }
    return (string as NSString).isEqual(to: other)
}

/// Raises an NSGenericException whose reason is `reason`, as
/// [NSException raise:NSGenericException format:@"%@", reason] did.
private func raiseGenericException(_ reason: String) {
    NSException(name: .genericException, reason: reason, userInfo: nil).raise()
}

/// The DicomStudy (Report) category, in Swift since #717: the selectors and
/// <Horos/DicomStudy+Report.h> are those of the former category. The ODT
/// conversion stays Objective-C, in DicomStudy+Report+CAPI.m.
///
/// The methods raise NSExceptions, as before: their callers catch them.
public extension DicomStudy {

    /// The former +_runAppleScriptAtPath:withArguments:.
    @objc(_runAppleScriptAtPath:withArguments:)
    @discardableResult
    class func _runAppleScript(atPath path: String!, withArguments args: NSArray!) -> Any! {
        var errs: NSDictionary? = nil

        guard let path = path else {
            raiseGenericException("NULL script path")
            return nil
        }

        let source: NSString?
        do {
            source = try NSString(contentsOfFile: path, usedEncoding: nil)
        } catch {
            raiseGenericException((error as NSError).localizedDescription)
            return nil
        }
        guard let source = source else {
            raiseGenericException("Couldn't read script source")
            return nil
        }

        guard let script = NSAppleScript(source: source as String) else {
            raiseGenericException("Invalid script source")
            return nil
        }

        let r = script.run(withArguments: args, error: &errs)
        if let errs = errs {
            raiseGenericException(String(format: "%@", errs))
        }

        return r
    }

    @objc(transformReportAtPath:toPdfAtPath:)
    class func transformReport(atPath reportPath: String!, toPdfAtPath outPdfPath: String!) {
        // A PDF already at the destination is not this conversion's result: were the conversion to
        // fail without writing, it must not pass for one (#649).
        if let outPdfPath = outPdfPath, (outPdfPath as NSString).length > 0,
           !isEqualString((outPdfPath as NSString).standardizingPath, (reportPath as NSString?)?.standardizingPath) {
            try? FileManager.default.removeItem(atPath: outPdfPath)
        }

        let reportExtension = ((reportPath as NSString?)?.pathExtension as NSString?)?.lowercased as NSString?
        func extensionIs(_ name: String) -> Bool {
            reportExtension?.isEqual(to: name) ?? false
        }

        if extensionIs("odt") {
            self._transformOdt(atPath: reportPath, toPdfAtPath: outPdfPath)
        } else if extensionIs("rtf") || extensionIs("rtfd") {
            // Drawn by the app. /System/Library/Printers/Libraries/convert is gone since OS X 10.8, and
            // cupsfilter has no RTF filter on macOS 27: it exited 1 over the empty PDF made for its
            // output, and that empty PDF went on to every caller (#649).
            do {
                try RichTextReportPDF.convert(reportPath: reportPath ?? "", toPDFAtPath: outPdfPath ?? "")
            } catch {
                raiseGenericException((error as NSError).localizedDescription)
            }
        } else if extensionIs("pages") {
            // Pages 10 (issue 560 / #129): the bundled AppleScript named Pages
            // and `open`ed a path. A sandboxed Pages answers that open and
            // never shows the document, so manual and Validated conversion
            // wrote nothing. HorosPagesPDFConversion opens through
            // LaunchServices, exports a working copy, and leaves the report.
            var error: NSError? = nil
            if !PagesPDFConversion.convertReport(at: reportPath ?? "", toPDFAt: outPdfPath ?? "", error: &error) {
                raiseGenericException(error?.localizedDescription ?? "Pages could not export the report as PDF. The original report has been left unchanged.")
            }
        } else if extensionIs("doc") || extensionIs("docx") {
            let path = Bundle.main.path(forResource: "word2pdf", ofType: "applescript")
            // +arrayWithObjects: stopped at the first nil.
            let arguments = NSMutableArray()
            if let reportPath = reportPath {
                arguments.add(reportPath)
                if let outPdfPath = outPdfPath {
                    arguments.add(outPdfPath)
                }
            }
            self._runAppleScript(atPath: path, withArguments: arguments)
        } else {
            raiseGenericException(String(format: "Can't transform report to PDF: %@", (reportPath as NSString?) ?? "(null)"))
        }

        // Whatever converted it - LibreOffice, Word's script - a missing or empty PDF is a failure for
        // every caller, not a result to export, encapsulate, serve or burn (#649).
        if !PagesPDFConversion.isUsablePDF(at: outPdfPath ?? "") {
            if let outPdfPath = outPdfPath {
                try? FileManager.default.removeItem(atPath: outPdfPath)
            }
            raiseGenericException(NSLocalizedString("The report could not be converted to PDF. The original report has been left unchanged.", comment: ""))
        }
    }

    @objc(saveReportAsPdfAtPath:)
    func saveReportAsPdf(atPath path: String!) {
        type(of: self).transformReport(atPath: self.reportURL, toPdfAtPath: path)
    }

    @objc func saveReportAsPdfInTmp() -> String! {
        var path: String? = FileManager.default.tmpFilePathInTmp()

        path = (path as NSString?)?.appendingPathExtension("pdf")

        self.saveReportAsPdf(atPath: path)

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
        // Read and written by DCMTK (#738): the source through HorosDCMTKObject,
        // the Encapsulated PDF through HorosDICOMWriter, with the attributes the
        // DCM Framework's +encapsulatedPDF: gave it. Text is UTF-8 (ISO_IR 192);
        // the source's character set is not copied, since its bytes are not.
        let source: DCMObject? = (sourcePath as NSString?)?.length ?? 0 > 0 ? HorosDCMTKObject(contentsOfFile: sourcePath) : nil
        guard let pdf = pdfPath.flatMap({ FileManager.default.contents(atPath: $0) }) else {
            return
        }

        let output = HorosDICOMWriter()
        let pdfStorage = DCMAbstractSyntaxUID.pdfStorageClassUID()
        _ = output.setValues([pdfStorage as Any], forName: "SOPClassUID")
        _ = output.setValues([DCMCalendarDate.dicomDate(with: Date()) as Any], forName: "ContentDate")
        _ = output.setValues([DCMCalendarDate.dicomTime(with: Date()) as Any], forName: "ContentTime")
        _ = output.setValues(["NO"], forName: "BurnedInAnnotation")
        _ = output.setValues([], forName: "AcquisitionDatetime")
        _ = output.setValues([], forName: "DocumentTitle")
        _ = output.setValues([], forName: "PatientsAge")
        _ = output.setValues(["WSD"], forName: "ConversionType")
        _ = output.setValues(["Isis DICOM Viewer"], forName: "Manufacturer")
        _ = output.setValues(["OT"], forName: "Modality")
        _ = output.setEmptySequenceForName("ConceptNameCodeSequence")
        _ = output.setValues(["application/pdf"], forName: "MIMETypeOfEncapsulatedDocument")
        _ = output.setData(pdf, forName: "EncapsulatedDocument", vr: "OB")
        _ = output.setValues([HorosDICOMWriter.newStudyInstanceUID()], forName: "StudyInstanceUID")
        _ = output.setValues([HorosDICOMWriter.newSeriesInstanceUID()], forName: "SeriesInstanceUID")
        _ = output.setValues([HorosDICOMWriter.newSOPInstanceUID()], forName: "SOPInstanceUID")

        var reportName: Any = NSLocalizedString("Report PDF", comment: "")

        if UserDefaults.standard.object(forKey: "ReportName") != nil {
            reportName = UserDefaults.standard.object(forKey: "ReportName")!
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
        _ = self._ifAvailableCopyAttribute(withName: "StudyDate", from: source, to: output, alternatively: DCMCalendarDate.dicomDate(with: Date()))
        _ = self._ifAvailableCopyAttribute(withName: "StudyTime", from: source, to: output, alternatively: DCMCalendarDate.dicomTime(with: Date()))

        _ = output.setValues([DCMCalendarDate.dicomDate(with: Date()) as Any], forName: "SeriesDate")
        _ = output.setValues([DCMCalendarDate.dicomTime(with: Date()) as Any], forName: "SeriesTime")

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
        if !PagesPDFConversion.isUsablePDF(at: pdfPath ?? "") {
            raiseGenericException(NSLocalizedString("The report PDF is missing or unreadable. The original report has been left unchanged.", comment: ""))
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
        let pdfPath = self.saveReportAsPdfInTmp()
        // The former @try/@finally: the temporary PDF goes whatever happened,
        // and an exception goes on to the caller.
        var raised: NSException? = nil
        do {
            try HorosObjCException.perform {
                if !PagesPDFConversion.isUsablePDF(at: pdfPath ?? "") {
                    raiseGenericException(NSLocalizedString("Pages could not export the report as PDF. The original report has been left unchanged.", comment: ""))
                }
                self.transformPdf(atPath: pdfPath, toDicomAtPath: path)
                if !FileManager.default.fileExists(atPath: path ?? "") {
                    raiseGenericException(NSLocalizedString("The DICOM PDF could not be written. The original report has been left unchanged.", comment: ""))
                }
            }
        } catch {
            raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        if let pdfPath = pdfPath {
            try? FileManager.default.removeItem(atPath: pdfPath)
        }
        raised?.raise()
    }

    @objc func saveReportAsDicomInTmp() -> String! {
        let path = FileManager.default.tmpFilePathInTmp()
        self.saveReportAsDicom(atPath: path)
        return path
    }
}
