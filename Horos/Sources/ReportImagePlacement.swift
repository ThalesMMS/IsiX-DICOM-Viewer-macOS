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

/// A figure that goes into a Pages or Word report at a size that does not
/// depend on the pixel dimensions of the source, and that stays put when the
/// document is saved and opened again.
@objc(HorosReportImagePlacement)
public final class ReportImagePlacement: NSObject {

    /// 12 cm by 9 cm at 72 pt/inch. A CT or MR frame is fitted inside this box
    /// so two insertions of the same image occupy the same space.
    @objc public static let defaultBox = CGSize(width: 340, height: 255)

    @objc(displaySizeWithPixelWidth:pixelHeight:box:)
    public static func displaySize(pixelWidth: Double, pixelHeight: Double, box: CGSize) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / pixelWidth, box.height / pixelHeight)
        return CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
    }

    @objc(displaySizeWithPixelWidth:pixelHeight:)
    public static func displaySize(pixelWidth: Double, pixelHeight: Double) -> CGSize {
        displaySize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, box: defaultBox)
    }

    /// Where a figure is on the pages of figures a Pages report ends with:
    /// which of those pages, from 0, and its frame there, in points from the
    /// top left corner of the page.
    struct Figure: Equatable {
        let page: Int
        let frame: CGRect
    }

    /// The space left above the first figure of a page and below the last.
    static let figureMargin = 72.0
    /// The space between a figure and the next one down.
    static let figureGap = 14.0

    /// The figures of `sizes`, one under the other in the middle of the page,
    /// as many to a page as boxes fit between its margins - two on A4 and on
    /// Letter. Each has a box of its own whatever its height, so the second
    /// figure of a page is at the same place in every report.
    ///
    /// On pages of their own, after the text: Pages draws a picture a script
    /// gives it on a page, not in the text, and the text makes way for it. On
    /// a page that has text, that moved the text - measured, the last lines of
    /// a report went to a page of their own - where on an empty page it moves
    /// nothing.
    static func figures(sizes: [CGSize], page: CGSize, box: CGSize = defaultBox) -> [Figure] {
        let pitch = box.height + figureGap
        let perPage = max(1, Int(((page.height - 2 * figureMargin + figureGap) / pitch).rounded(.down)))
        return sizes.enumerated().map { index, size in
            let width = size.width.rounded(), height = size.height.rounded()
            return Figure(page: index / perPage,
                          frame: CGRect(x: ((page.width - width) / 2).rounded(),
                                        y: figureMargin + Double(index % perPage) * pitch,
                                        width: width, height: height))
        }
    }

    /// The size of the page, from where Pages put a picture it was given no
    /// place for: in the middle of the page. A document does not say its paper.
    static func pageSize(holding picture: CGRect) -> CGSize {
        CGSize(width: 2 * picture.midX, height: 2 * picture.midY)
    }
}

@objc(HorosReportImageKind)
public enum ReportImageKind: Int {
    case pages
    case word
    case unsupported
}

@objc(HorosReportPreparedImage)
public final class ReportPreparedImage: NSObject {
    @objc public let path: String
    @objc public let widthPoints: Double
    @objc public let heightPoints: Double

    @objc public init(path: String, widthPoints: Double, heightPoints: Double) {
        self.path = path
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
    }
}

/// Copies the selected frames next to the report and asks Pages or Word to
/// insert them as inline figures. The editor is driven on a private copy; the
/// original report is replaced only after that copy has been written.
@objc(HorosReportImageInsertion)
public final class ReportImageInsertion: NSObject {

    /// The last AppleScript or lookup failure. Native Pages/Word proof reads
    /// this number; a generic alert is not a captured error.
    @objc public static var lastError: NSDictionary? {
        get { lastErrorLock.withLock { storedLast.error } }
        // An error set from outside says nothing of the editor it happened in.
        set { lastErrorLock.withLock { storedLast = (newValue, nil) } }
    }
    /// Guards `storedLast`: an insertion may run off the main thread
    /// while the report window reads the message.
    private static let lastErrorLock = NSLock()
    // nonisolated(unsafe): read and written only inside
    // `lastErrorLock.withLock`, by the `lastError` accessors above, by `run`
    // and by `lastErrorMessage`. The error, and the editor of the report it
    // happened in when a script of ours failed there: the same AppleScript
    // number is another sentence for Pages than for Word.
    nonisolated(unsafe) private static var storedLast: (error: NSDictionary?, kind: ReportImageKind?) = (nil, nil)

    /// Human-readable recovery text for the last failure, including the
    /// AppleScript number when the editor timed out, refused Automation, or
    /// could not take the figure.
    @objc public static func lastErrorMessage() -> String {
        let last = lastErrorLock.withLock { storedLast }
        return errorMessage(code: appleScriptErrorCode(last.error), in: last.kind)
    }

    /// The text for an error of which only the number is known: for -1728,
    /// the sentence about Word.
    @objc(errorMessageFromError:)
    public static func errorMessage(from error: NSDictionary?) -> String {
        errorMessage(code: appleScriptErrorCode(error), in: nil)
    }

    /// What a report that its editor has open is refused with: the number the
    /// system has for a file that is busy.
    static let reportOpenInEditor = -47

    /// The text for AppleScript error `code`, in the editor of the report when
    /// that is known.
    static func errorMessage(code: Int, in kind: ReportImageKind?) -> String {
        switch code {
        case -1712:
            return NSLocalizedString("IsiX DICOM Viewer did not receive a reply from Pages or Word in time (error -1712). If macOS asked for Automation permission, allow IsiX DICOM Viewer to control Pages and Microsoft Word in System Settings > Privacy & Security > Automation, then retry. The original report and the source images have been preserved.", comment: "")
        case -609:
            return NSLocalizedString("Pages or Word dropped the Automation connection (error -609). Check that the editor is still running, allow IsiX DICOM Viewer to control it in System Settings > Privacy & Security > Automation, then retry. The original report and the source images have been preserved.", comment: "")
        case -1743:
            return NSLocalizedString("Automation was denied. Allow IsiX DICOM Viewer to control Pages and Microsoft Word in System Settings > Privacy & Security > Automation, then retry. The original report and the source images have been preserved.", comment: "")
        case -1728 where kind == .pages:
            // What Pages answers when it has no such object: the document, or
            // the body text an image goes into. Word's sentence for the same
            // number is about Word not being installed.
            return NSLocalizedString("Pages could not find the report, or a place in it for the image (error -1728). The original report and the source images have been preserved.", comment: "")
        case -1728:
            return NSLocalizedString("Microsoft Word is not installed or could not be located (error -1728). Install Word with creation and editing enabled to insert images into a .doc or .docx report. The original report and the source images have been preserved.", comment: "")
        case reportOpenInEditor where kind == .word:
            return NSLocalizedString("The report is open in Microsoft Word. Close it there, then insert the images again. The original report and the source images have been preserved.", comment: "")
        case -10024:
            return NSLocalizedString("Pages could not insert the image into that container (error -10024). The original report and the source images have been preserved.", comment: "")
        case -43:
            return NSLocalizedString("Pages or Word could not be found (error -43). The original report and the source images have been preserved.", comment: "")
        default:
            if code == 0 {
                return NSLocalizedString("The selected images could not be inserted. The original report and the source images have been preserved.", comment: "")
            }
            return String(format: NSLocalizedString("The selected images could not be inserted (error %ld). The original report and the source images have been preserved.", comment: ""), code)
        }
    }

    @objc(kindOfReportPath:)
    public static func kind(ofReportPath path: String) -> ReportImageKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "pages": return .pages
        case "doc", "docx": return .word
        default: return .unsupported
        }
    }

    @objc(writeJPEG:toPath:)
    public static func writeJPEG(_ image: NSImage, to path: String) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Writes a JPEG next to the report. The source path is never opened for
    /// writing, and a destination that resolves to the source is refused.
    @objc(writeCopyFrom:to:)
    public static func writeCopy(from sourcePath: String, to destinationPath: String) -> Bool {
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
        let destination = URL(fileURLWithPath: destinationPath).resolvingSymlinksInPath()
        guard source != destination else { return false }
        guard let image = NSImage(contentsOf: source) else { return false }
        return writeJPEG(image, to: destination.path)
    }

    @objc(prepareSources:directory:)
    public static func prepare(sources: [String], directory: String) -> [ReportPreparedImage] {
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            return []
        }
        var prepared: [ReportPreparedImage] = []
        for (index, source) in sources.enumerated() {
            let name = String(format: "%04ld.jpg", index + 1)
            let destination = (directory as NSString).appendingPathComponent(name)
            guard writeCopy(from: source, to: destination),
                  let image = NSImage(contentsOfFile: destination) else { return [] }
            let size = ReportImagePlacement.displaySize(
                pixelWidth: Double(image.size.width),
                pixelHeight: Double(image.size.height),
                box: ReportImagePlacement.defaultBox
            )
            guard size.width > 0, size.height > 0 else { return [] }
            prepared.append(ReportPreparedImage(path: destination, widthPoints: size.width, heightPoints: size.height))
        }
        return prepared
    }

    /// Addressed to the Pages the report is opened in, which is the one
    /// `run` hands the private copy to. With no Pages installed the script is
    /// never sent - `run` refuses first - and names the current identifier.
    ///
    /// Kept for who calls it by this name: it takes the document by its name
    /// and asks for the pictures in the text, which Pages 15 refuses (-10024).
    /// The application's own insertion is `insertIntoPages`.
    @objc(pagesScriptWithDocumentName:images:)
    public static func pagesScript(documentName: String, images: [ReportPreparedImage]) -> String {
        pagesScript(documentName: documentName, images: images,
                    application: PagesApplication.target()?.identifier ?? "com.apple.Pages")
    }

    /// `application` is the bundle identifier of the Pages holding the document.
    static func pagesScript(documentName: String, images: [ReportPreparedImage], application: String) -> String {
        var lines = [
            "tell application id \"\(application)\"",
            "  with timeout of 600 seconds",
        ]
        lines.append(contentsOf: waitForNamedDocumentLines(documentName, missing: "Pages did not open the report"))
        lines.append("    try")
        for image in images {
            lines.append("      make new image at end of body text of d with properties {file:(POSIX file \(appleString(image.path))), width:\(appleNumber(image.widthPoints)), height:\(appleNumber(image.heightPoints))}")
        }
        lines.append(contentsOf: closeNamedDocumentOnErrorLines())
        lines.append(contentsOf: [
            "  end timeout",
            "end tell",
        ])
        return lines.joined(separator: "\n")
    }

    /// The first of two scripts that put figures into the Pages document of id
    /// `document`: a page of its own at the end, and the first picture on it,
    /// where and as large as Pages puts it. The answer is that frame - x, y,
    /// width, height - which is how the size of the page is known.
    ///
    /// A picture goes on a page: `make new image at end of body text`, which
    /// is where a figure of a report belongs, is refused by Pages 15 with
    /// -10024, as is every other way of naming the text as the place, and the
    /// document itself is not a place either (-10000, -2763). A page takes
    /// one, by `tell page`. The file is a file object made outside the tell.
    static func pagesMeasureScript(document: String, first image: ReportPreparedImage, application: String) -> String {
        ([
            "set figure1 to POSIX file \(appleString(image.path))",
            "tell application id \"\(application)\"",
            "  with timeout of 600 seconds",
            "    set d to document id \(appleString(document))",
            "    try",
            "      tell d to make new page",
            "      tell page -1 of d",
            "        set placed to make new image with properties {file:figure1}",
            "      end tell",
            "      set origin to position of placed",
            "      return {item 1 of origin, item 2 of origin, width of placed, height of placed}",
        ] + closeDocumentOnErrorLines() + [
            "  end timeout",
            "end tell",
        ]).joined(separator: "\n")
    }

    /// The second script: the first picture, alone on the last page, is given
    /// its frame, the others are made with theirs - on that page or on one
    /// more, as `figures` says - and the document is saved and closed. One
    /// that takes no picture is closed as it was, and the error is passed on
    /// with its number.
    static func pagesPlaceScript(document: String, images: [ReportPreparedImage], figures: [ReportImagePlacement.Figure],
                                 application: String) -> String {
        var lines = images.indices.dropFirst().map { "set figure\($0 + 1) to POSIX file \(appleString(images[$0].path))" }
        lines += [
            "tell application id \"\(application)\"",
            "  with timeout of 600 seconds",
            "    set d to document id \(appleString(document))",
            "    try",
        ]
        for (index, figure) in figures.enumerated() {
            let frame = figure.frame
            let size = "width:\(Int(frame.width)), height:\(Int(frame.height))"
            let position = "{\(Int(frame.minX)), \(Int(frame.minY))}"
            if index == 0 {
                lines += [
                    "      set placed to image 1 of page -1 of d",
                    "      set width of placed to \(Int(frame.width))",
                    "      set height of placed to \(Int(frame.height))",
                    "      set position of placed to \(position)",
                ]
                continue
            }
            if figure.page != figures[index - 1].page {
                lines.append("      tell d to make new page")
            }
            lines += [
                "      tell page -1 of d",
                "        make new image with properties {file:figure\(index + 1), \(size), position:\(position)}",
                "      end tell",
            ]
        }
        lines += [
            "      save d",
            "      close d saving no",
        ]
        return (lines + closeDocumentOnErrorLines() + [
            "  end timeout",
            "end tell",
        ]).joined(separator: "\n")
    }

    /// Kept for who calls it by this name: it takes the document by its name,
    /// the first of that name Word has open, and has Word read each image
    /// from its file. Word is sandboxed: a file it was not given it asks the
    /// user for, in a panel of its own, and answers nothing until the panel is
    /// closed. The application's own insertion is `insertIntoWord`, which
    /// takes the document by its file and hands Word no image file.
    @objc(wordScriptWithDocumentName:images:)
    public static func wordScript(documentName: String, images: [ReportPreparedImage]) -> String {
        var lines = [
            "tell application \"Microsoft Word\"",
            "  with timeout of 600 seconds",
        ]
        lines.append(contentsOf: waitForNamedDocumentLines(documentName, missing: "Word did not open the report"))
        lines.append("    try")
        for image in images {
            // `make inline picture at ... file name "..."`, as this was
            // written before, is not a command of Word 16's dictionary: the
            // script did not compile (-2741) and nothing was ever sent.
            lines.append("      set pic to make new inline picture at end of text object of d with properties {file name:\(appleString(image.path)), save with document:true}")
            lines.append("      set width of pic to \(appleNumber(image.widthPoints))")
            lines.append("      set height of pic to \(appleNumber(image.heightPoints))")
        }
        lines.append(contentsOf: closeNamedDocumentOnErrorLines())
        lines.append(contentsOf: [
            "  end timeout",
            "end tell",
        ])
        return lines.joined(separator: "\n")
    }

    /// The files of the documents Word has open, each as Word writes it, in
    /// POSIX style. A document never saved answers with its name alone, which
    /// is no file. Word has no id for a document: its file is what tells one
    /// from another of the same name.
    ///
    /// The list is not called `found`: inside the tell that is a word of
    /// Word's dictionary - a property of its searches - and not a variable.
    /// The script compiled, set nothing, and answered `missing value` whatever
    /// Word had open.
    static let wordDocumentsScript = [
        "tell application \"Microsoft Word\"",
        // A question with a short answer, asked on the main thread: a Word
        // that does not answer it in twenty seconds is not waited for.
        "  with timeout of 20 seconds",
        "    set openFiles to {}",
        "    repeat with candidate in (get every document)",
        "      try",
        "        set end of openFiles to (posix full name of candidate) as text",
        "      end try",
        "    end repeat",
        "    return openFiles",
        "  end timeout",
        "end tell",
    ].joined(separator: "\n")

    /// The files in what `wordDocumentsScript` answered; nil when the answer is
    /// not a list, which is not Word having nothing open: it is an answer to
    /// another question, and nothing is decided on it.
    static func wordFiles(in answer: NSAppleEventDescriptor) -> [String]? {
        guard answer.descriptorType == typeAEList else { return nil }
        guard answer.numberOfItems > 0 else { return [] }
        return (1...answer.numberOfItems).compactMap { answer.atIndex($0)?.stringValue }
    }

    /// The figures into the Word document whose file is `file`, from the one
    /// whose file is `figures` - each written as Word itself wrote it when
    /// asked, so that the two are the same string. The report is saved and
    /// closed, and the document of the figures closed as it was; a report that
    /// takes no figure is closed as it was too, and the error is passed on
    /// with its number.
    ///
    /// Word reads no image file. It is sandboxed: asked to draw a picture from
    /// a file it was not given, it stops on a "Grant File Access" panel and
    /// answers nothing until someone closes it, and handed the image itself it
    /// stops on a "File Conversion" one. The two documents it was handed it
    /// may read, and the text of one - its figures, a paragraph each, at their
    /// sizes - is put after the text of the other, with no clipboard: a new
    /// last paragraph is made in the report, and the figures go into it
    /// without the last paragraph mark of their document, so that the report
    /// ends with the last figure.
    ///
    /// The two paths are compared in a handler of the script's own: inside the
    /// tell, `case` is a word of Word's dictionary and `considering case` does
    /// not compile. No variable has a name that is a word of that dictionary.
    static func wordScript(documentAt file: String, figuresAt figures: String, count: Int) -> String {
        [
            "on sameFile(one, other)",
            "  considering case",
            "    return one is other",
            "  end considering",
            "end sameFile",
            "",
            "tell application \"Microsoft Word\"",
            // A minute, not ten: this runs on the main thread, and a Word that
            // has stopped on a panel of its own is not waited for any longer.
            "  with timeout of 60 seconds",
            "    set d to missing value",
            "    set figureDocument to missing value",
            "    repeat with candidate in (get every document)",
            "      set candidateFile to \"\"",
            "      try",
            "        set candidateFile to (posix full name of candidate) as text",
            "      end try",
            "      if my sameFile(candidateFile, \(appleString(file))) then set d to contents of candidate",
            "      if my sameFile(candidateFile, \(appleString(figures))) then set figureDocument to contents of candidate",
            "    end repeat",
            "    if d is missing value or figureDocument is missing value then",
            "      try",
            "        if figureDocument is not missing value then close figureDocument saving no",
            "      end try",
            "      try",
            "        if d is not missing value then close d saving no",
            "      end try",
            "      error \"Word no longer has the report open\"",
            "    end if",
            "    try",
            "      set picturesBefore to count of inline pictures of d",
            "      set figureEnd to (end of content of text object of figureDocument) - 1",
            "      insert paragraph at end of text object of d",
            "      set reportEnd to (end of content of text object of d) - 1",
            "      set formatted text of (create range d start reportEnd end reportEnd) to formatted text of (create range figureDocument start 0 end figureEnd)",
            "      if (count of inline pictures of d) is not picturesBefore + \(count) then error \"Word did not take the figures\"",
            "      close figureDocument saving no",
            "      set figureDocument to missing value",
            "      save d",
            "      close d saving no",
            "    on error errorMessage number errorNumber",
            "      try",
            "        if figureDocument is not missing value then close figureDocument saving no",
            "      end try",
            "      try",
            "        close d saving no",
            "      end try",
            "      error errorMessage number errorNumber",
            "    end try",
            "  end timeout",
            "end tell",
        ].joined(separator: "\n")
    }

    /// Closes, as they are, the documents Word has open from `files`: what an
    /// insertion that could not go on leaves of its own in Word.
    static func wordCloseScript(files: [String]) -> String {
        ([
            "on sameFile(one, other)",
            "  considering case",
            "    return one is other",
            "  end considering",
            "end sameFile",
            "",
            "tell application \"Microsoft Word\"",
            "  with timeout of 20 seconds",
            "    repeat with candidate in (get every document)",
            "      set candidateFile to \"\"",
            "      try",
            "        set candidateFile to (posix full name of candidate) as text",
            "      end try",
        ] + files.map { "      if my sameFile(candidateFile, \(appleString($0))) then close candidate saving no" } + [
            "    end repeat",
            "  end timeout",
            "end tell",
        ]).joined(separator: "\n")
    }

    /// The insertion with the editor stood in for: `runner` is given the script
    /// that takes the copy by its name, and the path of the copy.
    @objc(insertWithReportPath:sources:runner:)
    public static func insert(reportPath: String, sources: [String], runner: @escaping (String, String) -> Bool) -> Bool {
        insert(reportPath: reportPath, sources: sources) { kind, copy, images in
            let name = (copy as NSString).lastPathComponent
            return runner(kind == .pages ? pagesScript(documentName: name, images: images)
                                         : wordScript(documentName: name, images: images), copy)
        }
    }

    /// Copies the report and the images, has `perform` put the images into the
    /// copy, and only then puts the copy in the place of the report.
    static func insert(reportPath: String, sources: [String],
                       perform: (ReportImageKind, String, [ReportPreparedImage]) -> Bool) -> Bool {
        lastError = nil
        let kind = kind(ofReportPath: reportPath)
        guard kind != .unsupported, !sources.isEmpty else { return false }
        let original = URL(fileURLWithPath: reportPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: reportPath, isDirectory: &isDirectory) else { return false }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("horos-report-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            // A private name, not the original filename: a script that finds
            // the document by name, as the ones handed to a runner do, would
            // otherwise edit the report that is already open. The app asks
            // Pages and Word for the document by the file of the copy.
            let preparedName = "Horos-inserted-report.\(original.pathExtension)"
            let prepared = work.appendingPathComponent(preparedName)
            try FileManager.default.copyItem(at: original, to: prepared)
            let copies = prepare(sources: sources, directory: work.appendingPathComponent("images").path)
            guard copies.count == sources.count else { return false }
            guard perform(kind, prepared.path, copies) else { return false }
            _ = try FileManager.default.replaceItemAt(original, withItemAt: prepared)
            return true
        } catch {
            return false
        }
    }

    /// The insertion into a Word report, apart from Word itself: `open` hands
    /// Word a file and `send` a script. `figures` is a document that holds
    /// the figures and nothing else, which Word is handed with the copy.
    ///
    /// The figures go into the document whose file is the copy, and no other.
    /// The copy is called `Horos-inserted-report.doc` in every insertion:
    /// taken by that name, the document could be the copy an insertion that
    /// had failed left open - the images went into that one, and the report
    /// was replaced by a copy without them.
    static func insertIntoWord(figures: String, count: Int, copy path: String,
                               open: (String) -> Void, send: PagesApplication.Target.Send,
                               attempts: Int = 60, pause: TimeInterval = 0.5) -> Bool {
        open(path)
        open(figures)
        let opened = wordDocuments(openedFrom: [path, figures], attempts: attempts, pause: pause, send: send)
        guard let opened, opened.count == 2, let document = opened[0], let source = opened[1] else {
            // The number a script's own `error "..."` has, which is what
            // not finding the copy used to end with.
            if lastError == nil {
                rememberError(code: -2700, message: "Word did not open the report", in: .word)
            }
            // A Word that answered, and has one of the two: it is not left
            // there. One that did not answer is not asked again.
            if let left = opened?.compactMap({ $0 }), !left.isEmpty {
                let last = lastErrorLock.withLock { storedLast }
                _ = send(wordCloseScript(files: left), [])
                lastErrorLock.withLock { storedLast = last }
            }
            return false
        }
        return send(wordScript(documentAt: document, figuresAt: source, count: count), []) != nil
    }

    /// The file of the document Word opened from `path`, as Word writes it,
    /// waited for. nil when the document did not appear, and at once when Word
    /// could not be asked.
    static func wordDocument(openedFrom path: String, attempts: Int = 60, pause: TimeInterval = 0.5,
                             send: PagesApplication.Target.Send) -> String? {
        wordDocuments(openedFrom: [path], attempts: attempts, pause: pause, send: send)?.first ?? nil
    }

    /// The files of the documents Word opened from `paths`, each as Word
    /// writes it, waited for until all are there: Word was handed the files
    /// through LaunchServices, which does not say when a document is there.
    /// The paths are compared with their symbolic links resolved - a temporary
    /// folder is `/var/folders` to one and `/private/var/folders` to another -
    /// and what is answered is Word's own writing of each, which is what the
    /// next script is given. A document that did not appear is nil in the
    /// answer, and the answer itself is nil, at once, when Word could not be
    /// asked or answered something that is no list of files.
    static func wordDocuments(openedFrom paths: [String], attempts: Int = 60, pause: TimeInterval = 0.5,
                              send: PagesApplication.Target.Send) -> [String?]? {
        let wanted = paths.map { PagesApplication.Target.fileURL($0)?.path }
        var found = [String?](repeating: nil, count: paths.count)
        for attempt in 1...max(attempts, 1) {
            guard let answer = send(wordDocumentsScript, []), let open = wordFiles(in: answer) else { return nil }
            for (index, path) in wanted.enumerated() {
                found[index] = path.flatMap { path in open.first { PagesApplication.Target.fileURL($0)?.path == path } }
            }
            if !found.contains(where: { $0 == nil }) { break }
            if attempt < attempts { Thread.sleep(forTimeInterval: pause) }
        }
        return found
    }

    /// Hands Pages the copy and has it take the images.
    static func insertIntoPages(_ images: [ReportPreparedImage], copy path: String) -> Bool {
        lastError = nil
        guard let pages = PagesApplication.target() else {
            rememberError(code: -43, message: "Pages is not installed")
            return false
        }
        return insertIntoPages(images, copy: path, in: pages, open: { copy in
            // Waiting on NSWorkspace's completion handler from the main thread
            // is a deadlock; Pages is asked what it has open instead.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open([URL(fileURLWithPath: copy)], withApplicationAt: pages.url,
                                    configuration: configuration, completionHandler: nil)
        }, send: { source, arguments in
            PagesDocumentFill.execute(source, arguments) { number, message in
                rememberError(code: number, message: message, in: .pages)
            }
        })
    }

    /// The insertion into a Pages report, apart from Pages itself: `open`
    /// hands Pages the copy and `send` a script with its arguments.
    ///
    /// The images go into the document whose file is the copy, and no other.
    /// Taken by its name, the document could be a copy an insertion that had
    /// failed left open: the images went into that one, and the report was
    /// replaced by a copy without them.
    static func insertIntoPages(_ images: [ReportPreparedImage], copy path: String, in pages: PagesApplication.Target,
                                open: (String) -> Void, send: PagesApplication.Target.Send,
                                attempts: Int = 60, pause: TimeInterval = 0.5) -> Bool {
        open(path)
        guard let document = pages.documentID(openedFrom: path, attempts: attempts, pause: pause, send: send) else {
            // The number a script's own `error "..."` has, which is what
            // not finding the copy used to end with.
            if lastError == nil {
                rememberError(code: -2700, message: "Pages did not open the report", in: .pages)
            }
            return false
        }
        guard let first = images.first else { return false }
        // Where Pages put the first picture says how large the page is, and
        // with that every figure has its place.
        guard let answer = send(pagesMeasureScript(document: document, first: first, application: pages.identifier), []) else {
            return false
        }
        let placed = (1...4).map { answer.numberOfItems == 4 ? answer.atIndex($0)?.doubleValue ?? 0 : 0 }
        let page = ReportImagePlacement.pageSize(holding: CGRect(x: placed[0], y: placed[1], width: placed[2], height: placed[3]))
        guard placed[2] > 0, placed[3] > 0, page.width > 0, page.height > 0 else {
            if lastError == nil {
                rememberError(code: -2700, message: "Pages did not say where it put the image", in: .pages)
            }
            _ = send("tell application id \"\(pages.identifier)\" to close (document id \(appleString(document))) saving no", [])
            return false
        }
        let figures = ReportImagePlacement.figures(sizes: images.map { CGSize(width: $0.widthPoints, height: $0.heightPoints) }, page: page)
        return send(pagesPlaceScript(document: document, images: images, figures: figures, application: pages.identifier), []) != nil
    }

    /// Opens the private copy the way a person would, then sends the script.
    /// Waiting on NSWorkspace's completion handler from the main thread is a
    /// deadlock; the script waits for the document by name instead.
    @objc(runScript:opening:kind:)
    public static func run(_ script: String, opening path: String, kind: ReportImageKind) -> Bool {
        lastError = nil
        guard let application = applicationURL(for: kind) else {
            rememberError(code: kind == .word ? -1728 : -43,
                          message: kind == .word ? "Microsoft Word is not installed" : "Pages is not installed")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: application,
                                configuration: configuration, completionHandler: nil)
        guard execute(script, in: kind) != nil else {
            closeNamedDocument((path as NSString).lastPathComponent, kind: kind)
            return false
        }
        return true
    }

    /// Runs a script for the editor of `kind`; nil when it failed, and then the
    /// error is the last one, with the editor it happened in.
    static func execute(_ script: String, in kind: ReportImageKind) -> NSAppleEventDescriptor? {
        guard let appleScript = NSAppleScript(source: script) else {
            NSLog("---- the script that inserts a report image would not compile")
            rememberError(code: 1, message: "The script that inserts a report image would not compile")
            return nil
        }
        var error: NSDictionary?
        let answer = appleScript.executeAndReturnError(&error)
        if let error {
            lastErrorLock.withLock { storedLast = (error, kind) }
            NSLog("---- the report image could not be inserted: %@", error)
            return nil
        }
        return answer
    }

    private static func applicationURL(for kind: ReportImageKind) -> URL? {
        switch kind {
        case .pages:
            // The same Pages the script names, and the one a new report opens in.
            return PagesApplication.target()?.url
        case .word:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Word")
        case .unsupported:
            return nil
        }
    }

    private static func waitForNamedDocumentLines(_ name: String, missing: String) -> [String] {
        [
            "    set d to missing value",
            "    repeat with attempt from 1 to 60",
            "      repeat with candidate in documents",
            "        if (name of candidate) is \(appleString(name)) then",
            "          set d to contents of candidate",
            "          exit repeat",
            "        end if",
            "      end repeat",
            "      if d is not missing value then exit repeat",
            "      delay 0.5",
            "    end repeat",
            "    if d is missing value then error \(appleString(missing))",
        ]
    }

    private static func closeNamedDocumentOnErrorLines() -> [String] {
        [
            "      save d",
            "      close d saving no",
        ] + closeDocumentOnErrorLines()
    }

    /// The end of a `try` over document `d`: an error closes the document as it
    /// was and is passed on with its number.
    private static func closeDocumentOnErrorLines() -> [String] {
        [
            "    on error errorMessage number errorNumber",
            "      try",
            "        close d saving no",
            "      end try",
            "      error errorMessage number errorNumber",
            "    end try",
        ]
    }

    /// Only the private copy, never the document the user already had open.
    private static func closeNamedDocument(_ name: String, kind: ReportImageKind) {
        let tell: String
        if kind == .pages {
            guard let pages = PagesApplication.target() else { return }
            tell = "tell application id \"\(pages.identifier)\""
        } else {
            tell = "tell application \"Microsoft Word\""
        }
        let source = [
            tell,
            "  with timeout of 15 seconds",
            "    try",
            "      repeat with candidate in documents",
            "        if (name of candidate) is \(appleString(name)) then",
            "          close (contents of candidate) saving no",
            "          exit repeat",
            "        end if",
            "      end repeat",
            "    end try",
            "  end timeout",
            "end tell",
        ].joined(separator: "\n")
        guard let appleScript = NSAppleScript(source: source) else { return }
        var ignored: NSDictionary?
        appleScript.executeAndReturnError(&ignored)
    }

    static func rememberError(code: Int, message: String, in kind: ReportImageKind? = nil) {
        lastErrorLock.withLock {
            storedLast = ([
                NSAppleScript.errorNumber: NSNumber(value: code),
                NSAppleScript.errorMessage: message,
            ], kind)
        }
    }

    private static func appleScriptErrorCode(_ error: NSDictionary?) -> Int {
        guard let error else { return 0 }
        if let number = error[NSAppleScript.errorNumber] as? NSNumber {
            return number.intValue
        }
        if let number = error["NSAppleScriptErrorNumber"] as? Int {
            return number
        }
        return 0
    }

    private static func appleString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func appleNumber(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
