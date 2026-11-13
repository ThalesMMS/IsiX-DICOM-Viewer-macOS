//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import Foundation

/// The figures of a Word report, written into the document itself.
///
/// A .docx is a ZIP archive of XML parts, and a picture in its text is four
/// things: the image file under `media`, a relationship from the document part
/// to it, a content type for its extension, and a paragraph that holds the
/// drawing. They are written here, with no Word: the script that asked Word to
/// draw the picture never compiled against Word 16's dictionary, so no figure
/// was ever inserted, and the command its dictionary does have makes a
/// sandboxed Word read a file it was not given - which it may answer with a
/// panel of its own, while the application waits for it on the main thread.
/// A Word that is not installed, not licensed or not allowed to be driven is
/// no longer in the way either.
///
/// Each figure is a paragraph of its own at the end of the body, in line with
/// the text, at the size `ReportImagePlacement` gives it. Everything else in
/// the document is left byte for byte as it was: the paragraphs are put in at
/// one place of the document part, which is not read into a tree and written
/// out again.
enum WordDocumentFigures {

    enum Failure: Error {
        /// Not a document figures can be written into, and why.
        case unsupported(String)
    }

    private static let mainNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let documentRelationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    private static let imageRelationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    private static let emptyRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>
    """

    /// Writes `images` at the end of the .docx at `path`, in place. A failure
    /// leaves the file as it was.
    static func insert(_ images: [ReportPreparedImage], intoDocumentAt path: String) throws {
        guard !images.isEmpty else { return }
        var entries = try PagesHeaderFooterFill.readArchive(path)
        func position(_ name: String) -> Int? { entries.firstIndex { !$0.directory && $0.name == name } }
        func text(_ name: String) throws -> String {
            guard let found = position(name), let text = String(bytes: entries[found].data, encoding: .utf8) else {
                throw Failure.unsupported("\(name) is missing or is not UTF-8")
            }
            return text
        }
        func store(_ text: String, as name: String) {
            if let found = position(name) {
                entries[found].data = Array(text.utf8)
            } else {
                entries.append(PagesHeaderFooterFill.Entry(name: name, directory: false, data: Array(text.utf8)))
            }
        }

        // The document part, named by the package's own relationships.
        let package = try text("_rels/.rels")
        guard let main = tags("Relationship", in: package).first(where: { attribute("Type", of: $0) == documentRelationship })
            .flatMap({ attribute("Target", of: $0) })
            .map({ $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }) else {
            throw Failure.unsupported("the package names no document part")
        }
        let document = try text(main)
        let folder = (main as NSString).deletingLastPathComponent
        let relationshipsName = (folder.isEmpty ? "" : folder + "/") + "_rels/" + (main as NSString).lastPathComponent + ".rels"
        var relationships = position(relationshipsName) == nil ? emptyRelationships : try text(relationshipsName)
        var types = try text("[Content_Types].xml")

        // The files, each under a name and a relationship no other part has.
        let taken = Set(tags("Relationship", in: relationships).compactMap { attribute("Id", of: $0) })
        var number = taken.compactMap { $0.hasPrefix("rId") ? Int($0.dropFirst(3)) : nil }.max() ?? 0
        var drawing = numbers(after: "docPr", in: document).max() ?? 0
        var names = Set(entries.map(\.name))
        var paragraphs = ""
        var added = ""
        for image in images {
            guard let data = FileManager.default.contents(atPath: image.path), !data.isEmpty else {
                throw Failure.unsupported("the image at \(image.path) could not be read")
            }
            var media = "", index = 0
            repeat {
                index += 1
                media = "media/isix-figure-\(index).jpeg"
            } while names.contains((folder.isEmpty ? "" : folder + "/") + media)
            let name = (folder.isEmpty ? "" : folder + "/") + media
            names.insert(name)
            entries.append(PagesHeaderFooterFill.Entry(name: name, directory: false, data: Array(data)))
            number += 1
            drawing += 1
            added += "<Relationship Id=\"rId\(number)\" Type=\"\(imageRelationship)\" Target=\"\(media)\"/>"
            paragraphs += paragraph(relationship: "rId\(number)", drawing: drawing, widthPoints: image.widthPoints, heightPoints: image.heightPoints,
                                    prefix: try prefix(of: document))
        }
        guard let relationshipsEnd = relationships.range(of: "</Relationships>", options: .backwards) else {
            throw Failure.unsupported("\(relationshipsName) is not a list of relationships")
        }
        relationships.insert(contentsOf: added, at: relationshipsEnd.lowerBound)
        if !tags("Default", in: types).contains(where: { attribute("Extension", of: $0)?.lowercased() == "jpeg" }) {
            guard let typesEnd = types.range(of: "</Types>", options: .backwards) else {
                throw Failure.unsupported("[Content_Types].xml is not a list of types")
            }
            types.insert(contentsOf: "<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>", at: typesEnd.lowerBound)
        }
        var written = document
        written.insert(contentsOf: paragraphs, at: try endOfBody(document))

        // What is written is read back as XML before the file is touched, and
        // the figures have to be where they were meant: the last paragraphs of
        // the body, before its section properties if it has them.
        for part in [relationships, types] { _ = try XMLDocument(data: Data(part.utf8)) }
        guard try figuresAtEndOfBody(written, before: document) == images.count else {
            throw Failure.unsupported("the body of the document is not laid out as expected")
        }
        store(written, as: main)
        store(relationships, as: relationshipsName)
        store(types, as: "[Content_Types].xml")

        let output = path + ".figures"
        defer { try? FileManager.default.removeItem(atPath: output) }
        try PagesHeaderFooterFill.writeArchive(entries, to: output)
        guard rename(output, path) == 0 else { throw Failure.unsupported("the document with its figures could not replace the copy") }
    }

    /// Writes at `path` a document that is `images` and nothing else, a
    /// paragraph each: what Word is handed to take the figures of a .doc
    /// report from, which is not a format to write them into.
    static func write(_ images: [ReportPreparedImage], toNewDocumentAt path: String) throws {
        let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let parts = [
            ("[Content_Types].xml", declaration
                + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/word/document.xml\""
                + " ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"),
            ("_rels/.rels", declaration
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(documentRelationship)\" Target=\"word/document.xml\"/></Relationships>"),
            ("word/document.xml", declaration + "<w:document xmlns:w=\"\(mainNamespace)\"><w:body></w:body></w:document>"),
        ]
        try PagesHeaderFooterFill.writeArchive(parts.map { PagesHeaderFooterFill.Entry(name: $0.0, directory: false, data: Array($0.1.utf8)) },
                                               to: path)
        try insert(images, intoDocumentAt: path)
    }

    // MARK: the document part

    /// The prefix the document gives the WordprocessingML namespace: `w`, in
    /// what Word writes. A document in another vocabulary - the Strict
    /// conformance class has namespaces of its own - is not written into.
    static func prefix(of document: String) throws -> String {
        let pattern = "xmlns:([A-Za-z_][A-Za-z0-9_.-]*)\\s*=\\s*[\"']" + NSRegularExpression.escapedPattern(for: mainNamespace) + "[\"']"
        guard let match = document.range(of: pattern, options: .regularExpression),
              let colon = document[match].firstIndex(of: ":"),
              let end = document[match].firstIndex(where: { $0 == "=" || $0.isWhitespace }) else {
            throw Failure.unsupported("the document is not WordprocessingML")
        }
        return String(document[document.index(after: colon)..<end])
    }

    /// Where a paragraph goes to be the last of the body: before the body's
    /// section properties when the body ends with them, and otherwise before
    /// the end of the body. Section properties hold a copy of themselves when
    /// a change to them is tracked, so the opening tag is matched by counting.
    static func endOfBody(_ document: String) throws -> String.Index {
        let w = try prefix(of: document)
        guard let bodyEnd = document.range(of: "</\(w):body>", options: .backwards) else {
            throw Failure.unsupported("the document has no body")
        }
        let before = document[..<bodyEnd.lowerBound]
        guard let lastTag = before.range(of: "<", options: .backwards) else { return bodyEnd.lowerBound }
        let tag = before[lastTag.lowerBound...]
        let name = "\(w):sectPr"
        func opens(_ tag: Substring) -> Bool {
            tag.hasPrefix("<" + name) && tag.dropFirst(name.count + 1).first.map { $0 == ">" || $0 == "/" || $0.isWhitespace } == true
        }
        if opens(tag) {
            // Section properties with nothing in them: `<w:sectPr/>`.
            return tag.contains("/>") ? lastTag.lowerBound : bodyEnd.lowerBound
        }
        guard tag.hasPrefix("</" + name + ">") else { return bodyEnd.lowerBound }
        var depth = 0
        var search = before.endIndex
        while let found = before[..<search].range(of: "<", options: .backwards) {
            let candidate = before[found.lowerBound...]
            if candidate.hasPrefix("</" + name + ">") {
                depth += 1
            } else if opens(candidate), !(candidate.prefix { $0 != ">" }).hasSuffix("/") {
                depth -= 1
                if depth == 0 { return found.lowerBound }
            }
            search = found.lowerBound
        }
        throw Failure.unsupported("the section properties of the body are not closed")
    }

    /// The figures that are the last paragraphs of the body of `written`, when
    /// it is `before` with only paragraphs of figures added there: the number
    /// of paragraphs added. Both are read as XML, which neither is otherwise.
    static func figuresAtEndOfBody(_ written: String, before: String) throws -> Int {
        func paragraphs(_ text: String) throws -> [XMLElement] {
            let document = try XMLDocument(data: Data(text.utf8))
            guard let body = document.rootElement()?.children?.compactMap({ $0 as? XMLElement })
                .first(where: { $0.localName == "body" && $0.uri == mainNamespace }) else {
                throw Failure.unsupported("the document has no body")
            }
            var children = body.children?.compactMap { $0 as? XMLElement } ?? []
            if children.last?.localName == "sectPr" { children.removeLast() }
            return children
        }
        let old = try paragraphs(before), new = try paragraphs(written)
        let added = new.count - old.count
        guard added > 0, new.prefix(old.count).map(\.xmlString) == old.map(\.xmlString) else { return 0 }
        let figures = new.suffix(added).filter { paragraph in
            paragraph.localName == "p" && ((try? paragraph.nodes(forXPath: ".//*[local-name()='drawing']"))?.count ?? 0) == 1
        }
        return figures.count == added ? added : 0
    }

    /// A paragraph that is one picture in line with the text, `widthPoints` by
    /// `heightPoints`: DrawingML measures in EMU, 12700 to a point. The
    /// namespaces of the drawing are declared on it, whatever the document
    /// declares on its root.
    static func paragraph(relationship: String, drawing: Int, widthPoints: Double, heightPoints: Double, prefix w: String) -> String {
        let width = Int((widthPoints * 12700).rounded()), height = Int((heightPoints * 12700).rounded())
        return "<\(w):p><\(w):r><\(w):drawing>"
            + "<wp:inline xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
            + "<wp:extent cx=\"\(width)\" cy=\"\(height)\"/><wp:docPr id=\"\(drawing)\" name=\"Figure \(drawing)\"/>"
            + "<a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">"
            + "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            + "<pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            + "<pic:nvPicPr><pic:cNvPr id=\"\(drawing)\" name=\"Figure \(drawing)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" r:embed=\"\(relationship)\"/>"
            + "<a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></\(w):drawing></\(w):r></\(w):p>"
    }

    // MARK: reading tags without a tree

    /// The opening tags of the elements called `name`, prefix or not, as written.
    private static func tags(_ name: String, in text: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?" + name + "\\b[^>]*>")
        let whole = NSRange(text.startIndex..., in: text)
        return pattern?.matches(in: text, range: whole).compactMap { Range($0.range, in: text).map { String(text[$0]) } } ?? []
    }

    /// The value of attribute `name` in an opening tag.
    private static func attribute(_ name: String, of tag: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: "\\s" + name + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"),
              let match = pattern.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    /// The `id` of every element called `name`: the drawings of a document are
    /// numbered, and a figure takes a number none has.
    private static func numbers(after name: String, in text: String) -> [Int] {
        tags(name, in: text).compactMap { attribute("id", of: $0).flatMap { Int($0) } }
    }
}

extension ReportImageInsertion {

    /// Inserts the images of `sources` into the report at `reportPath`, each
    /// kind of report its own way: a Pages report by Pages, on pages of their
    /// own; a .docx by writing the figures into the file, with no Word; a .doc,
    /// which is not a format to write into, by Word, from a document the
    /// figures were written into.
    @objc(insertWithReportPath:sources:)
    public static func insert(reportPath: String, sources: [String]) -> Bool {
        insert(reportPath: reportPath, sources: sources, perform: { kind, copy, images in
            switch kind {
            case .pages:
                return insertIntoPages(images, copy: copy)
            case .word where (copy as NSString).pathExtension.lowercased() == "docx":
                let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.Word").isEmpty
                return write(images, intoCopy: copy, ofReportAt: reportPath, wordIsRunning: running,
                             send: { source, _ in execute(source, in: .word) })
            default:
                return insertIntoWord(images, copy: copy)
            }
        })
    }

    /// Hands Word the copy of a .doc report and has it take the images.
    ///
    /// Word is handed no image: the figures are written into a document beside
    /// the copy, in the folder that is removed when the insertion ends, and
    /// Word, which may read the two files it was handed and no other, moves
    /// them from one document to the other.
    static func insertIntoWord(_ images: [ReportPreparedImage], copy path: String) -> Bool {
        lastError = nil
        guard let word = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Word") else {
            rememberError(code: -1728, message: "Microsoft Word is not installed")
            return false
        }
        let figures = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Horos-inserted-figures.docx")
        do {
            try WordDocumentFigures.write(images, toNewDocumentAt: figures)
        } catch {
            NSLog("---- the figures of the Word report could not be written: %@", String(describing: error))
            rememberError(code: 0, message: "The figures of the Word report could not be written", in: .word)
            return false
        }
        return insertIntoWord(figures: figures, count: images.count, copy: path, open: { file in
            // Waiting on NSWorkspace's completion handler from the main thread
            // is a deadlock; Word is asked what it has open instead.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open([URL(fileURLWithPath: file)], withApplicationAt: word,
                                    configuration: configuration, completionHandler: nil)
        }, send: { source, _ in execute(source, in: .word) })
    }

    /// Writes the figures into the copy of a .docx report, unless Word has the
    /// report itself open.
    ///
    /// The copy then takes the place of the report, and a Word that has the
    /// report open keeps the document it read: saved from there, it would
    /// write over the figures, and what had not been saved there would not be
    /// in the file with them. So a Word that is running is asked for the files
    /// of its documents - nothing is sent to one that is not, which has none -
    /// and a report among them is not written under, changed or not; the user
    /// closes it and inserts again. A Word that cannot be asked is not taken
    /// for one that has nothing open: the insertion fails with what it
    /// answered.
    static func write(_ images: [ReportPreparedImage], intoCopy copy: String, ofReportAt report: String,
                      wordIsRunning: Bool, send: PagesApplication.Target.Send) -> Bool {
        if wordIsRunning {
            // An answer that is no list of files is no answer either.
            guard let files = send(wordDocumentsScript, []).flatMap(wordFiles(in:)) else {
                if lastError == nil {
                    rememberError(code: -1712, message: "Microsoft Word did not say which documents it has open", in: .word)
                }
                return false
            }
            let wanted = PagesApplication.Target.fileURL(report)?.path
            if files.contains(where: { PagesApplication.Target.fileURL($0)?.path == wanted }) {
                rememberError(code: reportOpenInEditor, message: "The report is open in Microsoft Word", in: .word)
                return false
            }
        }
        do {
            try WordDocumentFigures.insert(images, intoDocumentAt: copy)
            return true
        } catch {
            NSLog("---- the figures could not be written into the Word report: %@", String(describing: error))
            // No number to show: the sentence for a failure that has none.
            rememberError(code: 0, message: "The figures could not be written into the Word report", in: .word)
            return false
        }
    }
}
