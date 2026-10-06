//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import Foundation

/// Pages → PDF without touching the report that was asked for.
///
/// Pages 10 on RC4 no longer produced a
/// DICOM PDF, from the menu or from marking the study Validated. The script
/// addressed Pages by its localized name and sent it an `open` of a path.
/// Pages is sandboxed; that `open` is answered and no document appears, so
/// exporting the front document has nothing to write. The original .pages
/// was the one thing that had to survive that failure, and it did only by
/// accident — the script never copied it, so a destination that resolved
/// onto the report would have replaced it.
///
/// The file is opened the way a person opens one, through LaunchServices,
/// which is what grants Pages the file. Export runs against a working copy
/// whose name we chose, so the report on the study is never the destination.
/// When the report is open in Pages with changes not yet on disk, that
/// document - found by its file, never the front one - is saved first, so the
/// PDF has the last edit. A PDF that did not actually appear is discarded;
/// the caller must not import it.
@objc(HorosPagesPDFConversion)
public final class PagesPDFConversion: NSObject {

    @objc(isUsablePDFAtPath:)
    public static func isUsablePDF(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer {
            if #available(macOS 10.15, *) {
                try? handle.close()
            } else {
                handle.closeFile()
            }
        }
        let header = handle.readData(ofLength: 5)
        guard header.count == 5, String(data: header, encoding: .ascii) == "%PDF-" else {
            return false
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 32
    }

    /// Tags that make an encapsulated PDF belong to the study even when no
    /// source DICOM file was found to copy from.
    @objc(associationAttributesWithStudyInstanceUID:patientName:patientID:accessionNumber:studyDescription:)
    public static func associationAttributes(studyInstanceUID: String?,
                                             patientName: String?,
                                             patientID: String?,
                                             accessionNumber: String?,
                                             studyDescription: String?) -> [String: String] {
        var attributes: [String: String] = [:]
        func put(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            attributes[name] = value
        }
        put("StudyInstanceUID", studyInstanceUID)
        put("PatientsName", patientName)
        put("PatientID", patientID)
        put("AccessionNumber", accessionNumber)
        put("StudyDescription", studyDescription)
        return attributes
    }

    /// Writes `pdfPath` from `reportPath`. false leaves `reportPath` as it was
    /// and does not leave a PDF that anyone should import.
    @objc(convertReportAtPath:toPDFAtPath:error:)
    public static func convertReport(at reportPath: String,
                                     toPDFAt pdfPath: String,
                                     error outError: NSErrorPointer) -> Bool {
        let report = URL(fileURLWithPath: reportPath).resolvingSymlinksInPath()
        let destination = URL(fileURLWithPath: pdfPath).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: report.path, isDirectory: &isDirectory) else {
            return fail(1, "The Pages report is missing. Nothing was converted.", outError)
        }
        if destination.path == report.path || isInside(destination, parent: report) {
            return fail(2, "The PDF cannot replace the Pages report. The original report has been left unchanged.", outError)
        }
        guard let application = PagesApplication.url() else {
            return fail(3, "Pages is not installed or could not be located. The original report has been left unchanged.", outError)
        }
        guard let identifier = Bundle(url: application)?.bundleIdentifier,
              ["com.apple.iWork.Pages", "com.apple.Pages"].contains(identifier) else {
            return fail(3, "Pages is not installed or could not be located. The original report has been left unchanged.", outError)
        }

        if let document = openDocumentID(for: report, identifier: identifier),
           run(script(saveIfModifiedScriptSource, for: identifier), [document, identifier]) == nil {
            return fail(7, "The report open in Pages could not be saved, so the PDF would miss its last changes. No PDF was generated, and the report has been left open.", outError)
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("horos-pages-pdf-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return fail(4, "The Pages report could not be copied for export. The original report has been left unchanged.", outError)
        }
        defer { try? FileManager.default.removeItem(at: work) }

        let copy = work.appendingPathComponent("horos-\(UUID().uuidString).pages")
        do {
            try FileManager.default.copyItem(at: report, to: copy)
        } catch {
            return fail(4, "The Pages report could not be copied for export. The original report has been left unchanged.", outError)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // No waiting on the completion handler: it is delivered on the main
        // queue, and report conversion runs on the main thread, so waiting
        // here is a deadlock. The script waits for the document by name.
        NSWorkspace.shared.open([copy], withApplicationAt: application,
                                configuration: configuration, completionHandler: nil)

        var exported: URL?
        for candidate in exportDestinations(application: application, work: work) {
            if run(exportScript(for: identifier), [copy.lastPathComponent, candidate.path,
                                  usesModernExport() ? "1" : "0", identifier]) != nil,
               isUsablePDF(at: candidate.path) {
                exported = candidate
                break
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
        guard let exported else {
            return fail(5, "Pages could not export the report as PDF. Check that IsiX DICOM Viewer is allowed to control Pages in System Settings > Privacy & Security > Automation. The original report has been left unchanged.", outError)
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: exported, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return fail(6, "The PDF was exported but could not be stored. The original report has been left unchanged.", outError)
        }
        if exported.path != destination.path {
            try? FileManager.default.removeItem(at: exported)
        }
        guard isUsablePDF(at: destination.path) else {
            try? FileManager.default.removeItem(at: destination)
            return fail(5, "Pages could not export the report as PDF. The original report has been left unchanged.", outError)
        }
        return true
    }

    /// Closes the report if it is open in Pages, once validation has its DICOM
    /// PDF in the study. A report changed since the export stays open. True
    /// when the report is not open afterwards.
    @objc(closeValidatedReportAtPath:)
    @discardableResult
    public static func closeValidatedReport(at reportPath: String) -> Bool {
        let report = URL(fileURLWithPath: reportPath).resolvingSymlinksInPath()
        guard report.pathExtension.lowercased() == "pages",
              let application = PagesApplication.url(),
              let identifier = Bundle(url: application)?.bundleIdentifier,
              ["com.apple.iWork.Pages", "com.apple.Pages"].contains(identifier),
              let document = openDocumentID(for: report, identifier: identifier) else { return true }
        guard run(script(closeIfUnchangedScriptSource, for: identifier), [document, identifier]) != nil else {
            NSLog("---- the validated Pages report was left open: it changed after the export, or Pages did not close it")
            return false
        }
        return true
    }

    // MARK: talking to Pages

    /// The file of an open document, as Pages gives it: a POSIX path or a file
    /// URL. Anything else is not a file this code can compare.
    static func documentFileURL(_ value: String) -> URL? {
        let url: URL
        if value.hasPrefix("/") {
            url = URL(fileURLWithPath: value)
        } else if let parsed = URL(string: value), parsed.isFileURL {
            url = parsed
        } else {
            return nil
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The id of the open document whose file is `report`, or nil when Pages is
    /// not running, the report is not open, or Pages could not be asked. A
    /// document whose file cannot be read is skipped: at worst the report is
    /// not saved first, as before.
    private static func openDocumentID(for report: URL, identifier: String) -> String? {
        guard let inventory = runDescriptor(script(inventoryScriptSource, for: identifier), [identifier]),
              inventory.numberOfItems > 0 else { return nil }
        let wanted = report.standardizedFileURL.resolvingSymlinksInPath().path
        for index in 1...inventory.numberOfItems {
            guard let item = inventory.atIndex(index),
                  let document = item.atIndex(1)?.stringValue,
                  let file = item.atIndex(2)?.stringValue.flatMap(documentFileURL) else { continue }
            if file.path == wanted { return document }
        }
        return nil
    }

    /// The scripts name Pages in `using terms from`, which they need to compile;
    /// the identifier is one of the two the callers accept.
    static func script(_ source: String, for identifier: String) -> String {
        return source.replacingOccurrences(of: "__PAGES_BUNDLE_ID__", with: identifier)
    }

    /// `POSIX path of (file of d)` inside the tell is sent to Pages, which
    /// answers -1700; taken from a variable it is coerced here.
    static let inventoryScriptSource = """
    on run argv
      set bundleId to item 1 of argv
      set inventory to {}
      if application id "__PAGES_BUNDLE_ID__" is not running then return inventory
      with timeout of 60 seconds
      using terms from application id "__PAGES_BUNDLE_ID__"
      tell application id bundleId
        repeat with candidate in documents
          set documentFile to file of candidate
          if documentFile is not missing value then
            try
              set documentPath to POSIX path of documentFile
            on error
              set documentPath to documentFile as text
            end try
            set end of inventory to {(id of candidate) as text, documentPath}
          end if
        end repeat
      end tell
      end using terms from
      end timeout
      return inventory
    end run
    """

    /// Saving an unchanged document is not needed, and for one Pages has to
    /// convert it can ask where to save.
    static let saveIfModifiedScriptSource = """
    on run argv
      set documentId to item 1 of argv
      set bundleId to item 2 of argv
      with timeout of 120 seconds
      using terms from application id "__PAGES_BUNDLE_ID__"
      tell application id bundleId
        set d to document id documentId
        if modified of d then save d
      end tell
      end using terms from
      end timeout
      return "done"
    end run
    """

    static let closeIfUnchangedScriptSource = """
    on run argv
      set documentId to item 1 of argv
      set bundleId to item 2 of argv
      with timeout of 60 seconds
      using terms from application id "__PAGES_BUNDLE_ID__"
      tell application id bundleId
        set d to document id documentId
        if modified of d then error "The report changed after the export."
        close d saving no
      end tell
      end using terms from
      end timeout
      return "done"
    end run
    """

    /// `export d … as PDF` only compiles inside a block that names Pages: a
    /// target held in a variable gives the compiler no terminology, and the
    /// script failed to compile with -2741. The identifier is one of the two
    /// that convertReport accepts, so it can be written into the source.
    static func exportScript(for identifier: String) -> String {
        return script(exportScriptSource, for: identifier)
    }

    private static let exportScriptSource = """
    on run argv
      set nm to item 1 of argv
      set dest to item 2 of argv
      set modern to item 3 of argv
      set bundleId to item 4 of argv
      with timeout of 600 seconds
      using terms from application id "__PAGES_BUNDLE_ID__"
      tell application id bundleId
        set d to missing value
        repeat with attempt from 1 to 60
          repeat with candidate in documents
            if (name of candidate) is nm then
              set d to contents of candidate
              exit repeat
            end if
          end repeat
          if d is not missing value then exit repeat
          delay 0.5
        end repeat
        if d is missing value then error "Pages did not open " & nm
        if modern is "1" then
          export d to (POSIX file dest) as PDF
        else
          save d as "SLDocumentTypePDF" in (POSIX file dest)
        end if
        close d saving no
      end tell
      end using terms from
      end timeout
      return "done"
    end run
    """

    private static func usesModernExport() -> Bool {
        guard let version = PagesApplication.information()?["CFBundleShortVersionString"] as? String,
              let major = version.split(separator: ".").first,
              let number = Int(major) else { return true }
        return number < 1 || number >= 5
    }

    private static func exportDestinations(application: URL, work: URL) -> [URL] {
        var destinations = [work.appendingPathComponent("export.pdf")]
        if let identifier = Bundle(url: application)?.bundleIdentifier {
            let container = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(identifier)/Data/tmp", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)) != nil
                || FileManager.default.fileExists(atPath: container.path) {
                destinations.append(container.appendingPathComponent("horos-pages-pdf-\(UUID().uuidString).pdf"))
            }
        }
        return destinations
    }

    private static func isInside(_ child: URL, parent: URL) -> Bool {
        let childPath = child.path
        let parentPath = parent.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    private static func run(_ source: String, _ arguments: [String]) -> String? {
        guard let result = runDescriptor(source, arguments) else { return nil }
        return result.stringValue ?? "done"
    }

    private static func runDescriptor(_ source: String, _ arguments: [String]) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else {
            NSLog("---- the script that exports a Pages report would not compile")
            return nil
        }
        let list = NSAppleEventDescriptor.list()
        for (index, value) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            NSLog("---- Pages did not complete the report request: %@", error)
            return nil
        }
        return result
    }

    @discardableResult
    private static func fail(_ code: Int, _ message: String, _ error: NSErrorPointer) -> Bool {
        NSLog("---- Pages PDF conversion failed: %@", message)
        if let error {
            error.pointee = NSError(domain: "HorosPagesPDFConversion", code: code,
                                    userInfo: [NSLocalizedDescriptionKey: message])
        }
        return false
    }
}
