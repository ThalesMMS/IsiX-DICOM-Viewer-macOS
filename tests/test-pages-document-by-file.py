#!/usr/bin/env python3
"""A Pages report is filled in, and takes its images, in the document whose file is the copy.

A modern template is filled in by Pages on a copy named `report.pages`, and
images go into a copy of the report named `Horos-inserted-report.pages`. The
scripts took their document by that name: the first document of the name among
the ones Pages has open. With a document of the user's of the same name open -
`report.pages` is not a rare name - the fill read and rewrote the user's
document and saved it; and a copy left open by an insertion that had failed
was the one the next insertion drew into.

Pages is now handed the copy and asked which of its documents has that file,
and everything after that is addressed to that document by its id. No name
decides anything.

The production sources are compiled here with a Pages that is not Pages: a few
documents with a name, a file and a text, which answers the scripts by what
they do - a script that takes its document by name gets the first of that
name, as the loop over `documents` gave it. Nothing is opened and nothing is
sent to Pages.

    python3 tests/test-pages-document-by-file.py [<git revision>]

With a revision, the fill of that revision is run against the same documents:
on one that took the document by name, the user's document is the one written.

    python3 tests/test-pages-document-by-file.py --live

The same production sources against the Pages installed, for a session that may
send it Apple events: documents made from the template the app ships, with
made-up field values, are opened, filled in, given an image and closed in the
real Pages, with a namesake of each copy open beside it. Only the documents
this run opened are closed, and Pages is quit at the end if it had no document
open at the start. Exit status 2 when Pages is not installed or does not take
the events; 3 when a document did not appear, which may be Pages waiting on a
dialog - its windows are then captured for whoever can look.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
live = sys.argv[1:] == ['--live']
revision = sys.argv[1] if len(sys.argv) > 1 and not live else None
failures = []


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


SOURCES = ['Horos/Sources/PagesApplication.swift', 'Horos/Sources/MainActorCallbacks.swift',
           'Horos/Sources/PagesDocumentFill.swift', 'Horos/Sources/ReportImagePlacement.swift']

if not revision:
    fill = source('Horos/Sources/PagesDocumentFill.swift')
    images = source('Horos/Sources/ReportImagePlacement.swift')
    code = '\n'.join(line for line in fill.split('\n') if not line.strip().startswith('//'))
    if 'name of candidate' in code:
        failures.append('the fill still takes a document by its name')
    start = images.index('static func insertIntoPages(')
    if 'documentName' in images[start:images.index('\n    }\n', start)]:
        failures.append('the images still go into a document taken by its name')

program = r'''
import Foundation

func check(_ value: Bool, _ what: String, line: Int = #line) {
    if !value { print("FAIL: \(what) (line \(line))"); exit(1) }
}
func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let list = NSAppleEventDescriptor.list()
    for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
    return list
}
func text(_ string: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: string) }
func substitute(_ text: String) -> String { text.replacingOccurrences(of: "\u{ab}name\u{bb}", with: "Synthetic Patient") }

/// Pages, as far as these scripts go: documents in the order `documents` gives
/// them, each with a name, the file it was opened from when it has one, and a
/// body. It answers a script by what the script does.
final class Pages {
    struct Document {
        let id: String, name: String, file: String?
        var body: String
        var isOpen = true, read = 0, written = 0, saved = 0
        var images: [String] = []
        /// The pages added at the end, and the frame given to each picture: "page x y width height".
        var pagesAdded = 0, frames: [String] = []
    }
    var documents: [Document]
    /// Documents Pages opens only after it has been asked that many times what it has open.
    var late: [(after: Int, document: Document)] = []
    var asked = 0, deaf = false
    init(_ documents: [Document]) { self.documents = documents }

    subscript(id: String) -> Document { documents.first { $0.id == id }! }
    private func index(id: String) -> Int? { documents.firstIndex { $0.id == id && $0.isOpen } }
    private func index(name: String) -> Int? { documents.firstIndex { $0.name == name && $0.isOpen } }

    func send(_ source: String, _ arguments: [String]) -> NSAppleEventDescriptor? {
        if deaf { return nil }
        if source.contains("set end of inventory to") {
            asked += 1
            documents += late.filter { $0.after == asked }.map(\.document)
            return list(documents.filter { $0.isOpen && $0.file != nil }.map { list([text($0.id), text($0.file!)]) })
        }
        if source.contains("argv contains documentPath") {
            // Closes the document whose file is one of the arguments.
            if let found = documents.firstIndex(where: { $0.isOpen && $0.file.map(arguments.contains) == true }) { documents[found].isOpen = false }
            return text("done")
        }
        if source.contains("collectItems") {
            // The document read: by its name, the first of that name, or by its id.
            let byName = source.contains("(name of candidate) is nm")
            guard let found = byName ? index(name: arguments[0]) : index(id: arguments[0]) else { return nil }
            documents[found].read += 1
            return list([text(documents[found].id), text(documents[found].body), list([])])
        }
        if source.contains("set paragraph i of body text of d to newText") {
            guard let found = index(id: arguments[0]) else { return nil }
            var paragraphs = documents[found].body.components(separatedBy: "\n")
            for edit in stride(from: 1, to: arguments.count, by: 4) where arguments[edit] == "p" {
                paragraphs[Int(arguments[edit + 2])! - 1] = arguments[edit + 3]
            }
            documents[found].body = paragraphs.joined(separator: "\n")
            documents[found].written += 1
            documents[found].saved += 1
            documents[found].isOpen = false
            return text("done")
        }
        if source.contains("make new image with properties {file:figure") || source.contains("set placed to image 1 of page -1 of d") {
            // The two scripts that draw figures: both name their document by its id.
            guard let identified = source.range(of: #"set d to document id "([^"]*)""#, options: .regularExpression),
                  let found = index(id: String(source[identified].dropFirst("set d to document id \"".count).dropLast())) else { return nil }
            func all(_ pattern: String) -> [[String]] {
                let expression = try! NSRegularExpression(pattern: pattern)
                return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
                    (1..<match.numberOfRanges).map { String(source[Range(match.range(at: $0), in: source)!]) }
                }
            }
            documents[found].images += all(#"set figure\d+ to POSIX file "([^"]*)""#).map { $0[0] }
            if source.contains("set placed to make new image with properties {file:figure1}") {
                // A new last page, the first picture in the middle of it at its own size: A4 here.
                documents[found].pagesAdded += 1
                return list([266, 397, 64, 48].map { NSAppleEventDescriptor(int32: $0) })
            }
            var page = documents[found].pagesAdded
            for line in source.components(separatedBy: "\n") {
                if line.contains("tell d to make new page") { page += 1 }
                if let first = all(#"set position of placed to \{(\d+), (\d+)\}"#).first, line.contains("set position of placed") {
                    let size = all(#"set width of placed to (\d+)\n\s*set height of placed to (\d+)"#).first ?? ["?", "?"]
                    documents[found].frames.append("\(page) \(first[0]) \(first[1]) \(size[0]) \(size[1])")
                }
                if line.contains("make new image with properties {file:figure") {
                    let expression = try! NSRegularExpression(pattern: #"width:(\d+), height:(\d+), position:\{(\d+), (\d+)\}"#)
                    let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))!
                    let values = (1...4).map { String(line[Range(match.range(at: $0), in: line)!]) }
                    documents[found].frames.append("\(page) \(values[2]) \(values[3]) \(values[0]) \(values[1])")
                }
            }
            documents[found].pagesAdded = page
            documents[found].saved += 1
            documents[found].isOpen = false
            return text("done")
        }
        if source.contains("close (document id (item 1 of argv)) saving no") {
            guard let found = index(id: arguments[0]) else { return nil }
            documents[found].isOpen = false
            return text("done")
        }
        print("FAIL: a script the test does not know was sent:\n\(source)")
        exit(1)
    }
}

let target = PagesApplication.Target(url: URL(fileURLWithPath: "/nowhere/Pages.app"), identifier: "com.apple.Pages")
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pages-by-file-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
func file(_ name: String, in directory: String) -> String {
    let parent = folder.appendingPathComponent(directory)
    try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let path = parent.appendingPathComponent(name).path
    FileManager.default.createFile(atPath: path, contents: Data("not a document".utf8))
    return path
}
/// The path of a file as Pages gives it: the real one, which for a temporary
/// folder is not the one FileManager wrote.
func real(_ path: String) -> String {
    let pointer = realpath(path, nil)!
    defer { free(pointer) }
    return String(cString: pointer)
}

// The user's own document, open before anything: the name of the copy, another file.
let own = "A letter to \u{ab}name\u{bb}, kept as written"
func usersDocument() -> Pages.Document {
    Pages.Document(id: "USER-1", name: "report.pages", file: real(file("report.pages", in: "Documents")), body: own)
}
let copy = file("report.pages", in: "horos-report-template-a1b2c3")
func theCopy(as spelling: String) -> Pages.Document {
    Pages.Document(id: "COPY-2", name: "report.pages", file: spelling, body: "Report\nPatient: \u{ab}name\u{bb}")
}
func untouched(_ pages: Pages, _ what: String, line: Int = #line) {
    let user = pages["USER-1"]
    check(user.body == own && user.isOpen && user.read == 0 && user.written == 0 && user.saved == 0,
          "\(what): the user's document was read \(user.read) times, written \(user.written), saved \(user.saved), open \(user.isOpen), and is now: \(user.body)", line: line)
}
var opened: [String] = []

#if REVISION
// The fill of the revision asked for: its own wait, its own scripts.
func fill(_ pages: Pages) -> Bool {
    PagesDocumentFill.fill(documentAt: copy, substitute: substitute, in: target, open: { opened.append($0) }, send: pages.send)
}
#else
func fill(_ pages: Pages, attempts: Int = 3) -> Bool {
    PagesDocumentFill.fill(documentAt: copy, substitute: substitute, in: target, open: { opened.append($0) }, send: pages.send,
                           attempts: attempts, pause: 0)
}
#endif

// Two documents of one name, the user's first: only the one whose file is the copy is filled in.
var pages = Pages([usersDocument(), theCopy(as: real(copy))])
check(fill(pages), "the copy was not filled in")
untouched(pages, "a document of the same name open")
check(pages["COPY-2"].body == "Report\nPatient: Synthetic Patient" && pages["COPY-2"].saved == 1 && !pages["COPY-2"].isOpen,
      "the copy is \(pages["COPY-2"])")
check(opened == [copy], "Pages was handed \(opened)")
print("PASS: with a document of the user's of the same name open, only the copy is filled in")

#if !REVISION
// Whatever the order, and however Pages writes the file: as given, as a file URL.
for spelling in [copy, real(copy), URL(fileURLWithPath: real(copy)).absoluteString] {
    pages = Pages([theCopy(as: spelling), usersDocument()])
    check(fill(pages), "the copy, its file written \(spelling), was not found")
    untouched(pages, "the copy first, as \(spelling)")
    check(pages["COPY-2"].written == 1, "the copy was not written")
}
// Pages has not opened the copy yet when first asked: it is waited for, not replaced by the namesake.
pages = Pages([usersDocument()])
pages.late = [(after: 3, document: theCopy(as: real(copy)))]
check(fill(pages, attempts: 5) && pages.asked == 3 && pages["COPY-2"].written == 1, "a copy opened late: asked \(pages.asked) times")
untouched(pages, "a copy opened late")
// The copy never opens: the fill fails, and the namesake is left as it was.
pages = Pages([usersDocument()])
check(!fill(pages, attempts: 4) && pages.asked == 4, "a copy that never opened: asked \(pages.asked) times")
untouched(pages, "a copy that never opened")
// A document with no file - a new, untitled one of the name - is not the copy either.
pages = Pages([Pages.Document(id: "USER-1", name: "report.pages", file: nil, body: own)])
check(!fill(pages, attempts: 2), "an unsaved namesake was taken for the copy")
untouched(pages, "an unsaved namesake")
// Pages cannot be asked: once, and nothing else is sent.
pages = Pages([usersDocument(), theCopy(as: real(copy))])
pages.deaf = true
check(!fill(pages, attempts: 5), "a Pages that does not answer filled something in")
pages.deaf = false
untouched(pages, "a Pages that does not answer")
check(pages["COPY-2"].written == 0, "the copy was written by a Pages that does not answer")
// An edit Pages refuses: the copy is closed by its id, without saving, and only the copy.
final class Refusing { var writes = 0 }
let refusing = Refusing()
pages = Pages([usersDocument(), theCopy(as: real(copy))])
let refused = PagesDocumentFill.fill(documentAt: copy, substitute: substitute, in: target, open: { _ in }, send: { source, arguments in
    if source.contains("set paragraph i of body text of d to newText") { refusing.writes += 1; return nil }
    return pages.send(source, arguments)
}, attempts: 2, pause: 0)
check(!refused && refusing.writes == 1 && !pages["COPY-2"].isOpen && pages["COPY-2"].saved == 0, "a refused edit left the copy \(pages["COPY-2"])")
untouched(pages, "a refused edit")
print("PASS: the copy is found by its file in any order and spelling, waited for, and never replaced by a namesake")

// Images: a copy left open by an insertion that failed has the name of the new copy.
let pictures = (1...3).map { ReportPreparedImage(path: "/nowhere/images/000\($0).jpg", widthPoints: 340, heightPoints: $0 == 2 ? 170 : 255) }
let inserted = file("Horos-inserted-report.pages", in: "horos-report-images-new")
func insertion(_ documents: [Pages.Document], attempts: Int = 3) -> (Bool, Pages) {
    let pages = Pages(documents)
    let done = ReportImageInsertion.insertIntoPages(pictures, copy: inserted, in: target, open: { _ in }, send: pages.send,
                                                    attempts: attempts, pause: 0)
    return (done, pages)
}
let stale = Pages.Document(id: "STALE-1", name: "Horos-inserted-report.pages",
                           file: real(file("Horos-inserted-report.pages", in: "horos-report-images-old")), body: "an earlier report")
let fresh = Pages.Document(id: "NEW-2", name: "Horos-inserted-report.pages", file: real(inserted), body: "this report")
var (done, editor) = insertion([stale, fresh])
check(done && editor["NEW-2"].images == pictures.map(\.path) && editor["NEW-2"].saved == 1 && !editor["NEW-2"].isOpen,
      "the images went to \(editor.documents)")
check(editor["STALE-1"].images.isEmpty && editor["STALE-1"].saved == 0 && editor["STALE-1"].isOpen && editor["STALE-1"].pagesAdded == 0,
      "the copy of another insertion was drawn into")
// On pages of their own after the text, two to a page of A4, in the middle, each in its box.
check(editor["NEW-2"].pagesAdded == 2 && editor["NEW-2"].frames == ["1 128 72 340 255", "1 128 341 340 170", "2 128 72 340 255"],
      "the figures are on \(editor["NEW-2"].pagesAdded) pages at \(editor["NEW-2"].frames)")
// The copy never opens: nothing is drawn anywhere, and the failure has a number to show.
(done, editor) = insertion([stale], attempts: 2)
check(!done && editor["STALE-1"].images.isEmpty && editor["STALE-1"].saved == 0 && editor["STALE-1"].pagesAdded == 0, "images went into a namesake of the copy")
check(ReportImageInsertion.lastErrorMessage().contains("error"), "a copy that never opened has no error to show: \(ReportImageInsertion.lastErrorMessage())")
print("PASS: images go into the document whose file is the copy, on pages of their own, not into a namesake")

// The scripts compile against the Pages installed, when there is one. Nothing is sent.
if let installed = PagesApplication.target() {
    for (name, source) in [("documents", installed.script(PagesApplication.Target.documentsScript)),
                           ("read", installed.script(PagesDocumentFill.readScript)),
                           ("first image", ReportImageInsertion.pagesMeasureScript(document: "A-B-C", first: pictures[0], application: installed.identifier)),
                           ("images", ReportImageInsertion.pagesPlaceScript(
                               document: "A-B-C", images: pictures,
                               figures: ReportImagePlacement.figures(sizes: pictures.map { CGSize(width: $0.widthPoints, height: $0.heightPoints) },
                                                                     page: CGSize(width: 595, height: 842)),
                               application: installed.identifier))] {
        var error: NSDictionary?
        check(NSAppleScript(source: source)?.compileAndReturnError(&error) == true,
              "the \(name) script does not compile for \(installed.identifier): \(error ?? [:])")
    }
    print("PASS: the scripts that find, read and draw into a document by its id compile for \(installed.identifier)")
} else {
    print("note: Pages is not installed; the scripts were not compiled against it")
}
#endif
'''

LIVE = r'''
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
var failed = 0
func check(_ value: Bool, _ what: String) {
    print((value ? "ok:   " : "FAIL: ") + what)
    if !value { failed += 1 }
}
/// A document did not appear, or Pages stopped answering: nothing more is sent.
func stop(_ why: String) -> Never {
    print("STOPPED: \(why)")
    exit(3)
}

guard let pages = PagesApplication.target() else {
    print("skipped: Pages is not installed")
    exit(2)
}
final class Conversation { var number = 0, message = "" }
let conversation = Conversation()
let documentsScript = pages.script(PagesApplication.Target.documentsScript)
let send: PagesApplication.Target.Send = { source, arguments in
    PagesDocumentFill.execute(source, arguments) { number, message in
        conversation.number = number
        conversation.message = message
    }
}
/// A script of this check's own, inside a tell of the Pages found.
func ask(_ body: String, _ arguments: [String] = []) -> NSAppleEventDescriptor? {
    send("on run argv\nwith timeout of 60 seconds\ntell application id \"\(pages.identifier)\"\n\(body)\nend tell\nend timeout\nend run", arguments)
}
func strings(_ list: NSAppleEventDescriptor?) -> [String] {
    guard let list, list.numberOfItems > 0 else { return [] }
    return (1...list.numberOfItems).map { list.atIndex($0)?.stringValue ?? "?" }
}
/// The ids of the documents Pages has open, in the order `documents` gives them.
func openDocuments() -> [String] {
    guard let answer = ask("set ids to {}\nrepeat with c in documents\nset end of ids to (id of c) as text\nend repeat\nreturn ids") else {
        stop("Pages no longer says what it has open (error \(conversation.number): \(conversation.message))")
    }
    return strings(answer)
}
struct State: Equatable { let name: String, body: String, modified: String, images: String }
func state(_ document: String) -> State? {
    let answer = ask("set d to document id (item 1 of argv)\nset t to \"\"\ntry\nset t to (body text of d) as string\nend try\nreturn {name of d, t, (modified of d) as text, (count of images of d) as text}", [document])
    let values = strings(answer)
    return values.count == 4 ? State(name: values[0], body: values[1], modified: values[2], images: values[3]) : nil
}

// Pages takes events from this process, or this check is not for this session.
guard ask("return (count of documents)") != nil else {
    print("skipped: Pages did not take an event from this process (error \(conversation.number): \(conversation.message))")
    exit(2)
}
let version = (Bundle(url: pages.url)?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
print("Pages \(version), \(pages.identifier), at \(pages.url.path)")
let atStart = openDocuments()
print("documents open at the start: \(atStart.count)")

let template = CommandLine.arguments[1]
let base = NSTemporaryDirectory() + "isix-pages-live-\(UUID().uuidString)"
/// A document of this check: the template the app ships, under `name` in a folder of its own.
func make(_ name: String, in folder: String) -> String {
    let directory = base + "/" + folder
    try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let path = directory + "/" + name
    try? FileManager.default.removeItem(atPath: path)
    try! FileManager.default.copyItem(atPath: template, toPath: path)
    return path
}
/// Hands Pages a file the way the application does.
func hand(_ path: String) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: pages.url, configuration: configuration, completionHandler: nil)
}
var mine: [String] = []
/// Opens a document of this check in Pages and answers its id.
func open(_ path: String) -> String {
    hand(path)
    guard let document = pages.documentID(openedFrom: path, send: send) else {
        stop("Pages did not open \(path) in half a minute (error \(conversation.number): \(conversation.message))")
    }
    mine.append(document)
    return document
}
func close(_ document: String) {
    _ = send(pages.script(PagesDocumentFill.closeScript), [document])
    mine.removeAll { $0 == document }
}
/// Made-up values: every field becomes its own name, marked.
func substitute(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{ab}([A-Za-z]+)\u{bb}", with: "SYN:$1", options: .regularExpression)
}
/// What a file holds, read by opening it in Pages: every text the fill reaches.
func texts(of path: String) -> (all: String, images: String, anchored: Int) {
    let document = open(path)
    defer { close(document) }
    guard let answer = send(pages.script(PagesDocumentFill.readScript), [document]),
          let (_, body, items) = PagesDocumentFill.document(from: answer) else {
        stop("Pages did not read \(path) back")
    }
    var all = body
    for item in items {
        switch item {
        case let .text(_, text): all += "\n" + text
        case let .table(_, cells): all += "\n" + cells.joined(separator: "\n")
        }
    }
    return (all, state(document)?.images ?? "?", body.filter { $0 == "\u{fffc}" }.count)
}
func modification(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

// What `file of document` is, which is what the documents are told apart by.
print("--- the file of a document, as Pages gives it")
let decoyPath = make("report.pages", in: "the user's own")
var decoy = open(decoyPath)
let measured = strings(ask("""
set f to file of (document id (item 1 of argv))
set out to {}
try
set end of out to "class: " & ((class of f) as text)
on error m
set end of out to "class: failed, " & m
end try
try
set end of out to "POSIX path: " & (POSIX path of f)
on error m
set end of out to "POSIX path: failed, " & m
end try
try
set end of out to "as text: " & (f as text)
on error m
set end of out to "as text: failed, " & m
end try
return out
""", [decoy]))
for line in measured { print("  " + line.replacingOccurrences(of: base, with: "<folder>")) }
let inventory = send(documentsScript, [pages.identifier])
let listed = (inventory?.numberOfItems ?? 0) > 0 ? (inventory?.atIndex(1)?.atIndex(2)?.stringValue ?? "?") : "?"
print("  the documents script answers: " + listed.replacingOccurrences(of: base, with: "<folder>"))
print("  the folder is \(base.hasPrefix("/var/") ? "/var/..." : base.hasPrefix("/private/var/") ? "/private/var/..." : "elsewhere") to this process")
check(PagesApplication.Target.fileURL(listed) != nil, "what Pages answers is a file this code can compare")
check(pages.documentID(openedFrom: decoyPath, attempts: 1, send: send) == decoy, "the document is found by the path it was opened from")

guard let decoyBefore = state(decoy) else { stop("the state of the namesake could not be read") }
check(decoyBefore.name == "report.pages" || decoyBefore.name == "report", "the namesake is called \(decoyBefore.name)")
check(decoyBefore.body.contains("\u{ab}") && decoyBefore.modified == "false", "the namesake has fields to fill in and no change")
func namesakeIntact(_ what: String) {
    check(openDocuments().contains(decoy), "\(what): the namesake is still open")
    check(state(decoy) == decoyBefore, "\(what): the namesake has its text, fields unfilled, and no change")
}
func onlyMine(_ what: String) {
    check(Set(openDocuments()) == Set(atStart + mine), "\(what): no document is open that was not before (\(openDocuments().count) open, \(atStart.count + mine.count) expected)")
}
func filledIn(_ path: String, _ what: String) {
    check(pages.documentID(openedFrom: path, attempts: 1, send: send) == nil, "\(what): the copy is closed")
    let now = texts(of: path)
    check(!now.all.contains("\u{ab}") && now.all.contains("SYN:name"), "\(what): the copy on disk is filled in, no field left")
}

// (b)(c) The namesake open first, and the fill the application runs.
print("--- a namesake open, then the fill of a copy of the same name")
var copy = make("report.pages", in: "horos-report-template-1")
var before = modification(copy)
check(PagesDocumentFill.fill(documentAt: copy, substitute: substitute), "the fill answers that it filled the copy in")
check(modification(copy) != before, "the file of the copy was written")
filledIn(copy, "namesake first")
namesakeIntact("namesake first")
onlyMine("namesake first")

// (d) The file written the other way: /private/var for /var, or the reverse.
print("--- the path of the copy written the other way")
copy = make("report.pages", in: "horos-report-template-2")
let other = copy.hasPrefix("/private/") ? String(copy.dropFirst("/private".count)) : "/private" + copy
check(other != copy && FileManager.default.fileExists(atPath: other), "the copy is also at \(other.replacingOccurrences(of: base.replacingOccurrences(of: "/private", with: ""), with: "<folder>"))")
check(PagesDocumentFill.fill(documentAt: other, substitute: substitute), "the fill answers that it filled the copy in")
filledIn(copy, "other spelling")
namesakeIntact("other spelling")
onlyMine("other spelling")

// (d) The namesake opened after the copy, so that it is the one in front.
print("--- the namesake opened after the copy")
close(decoy)
copy = make("report.pages", in: "horos-report-template-3")
var copyID = ""
let filled = PagesDocumentFill.fill(documentAt: copy, substitute: substitute, in: pages, open: { path in
    copyID = open(path)
    mine.removeAll { $0 == copyID }
    decoy = open(decoyPath)
    let order = openDocuments().map { $0 == decoy ? "the namesake" : $0 == copyID ? "the copy" : "another" }
    print("  the documents, in the order Pages gives them: \(order.joined(separator: ", "))")
}, send: send)
check(filled, "the fill answers that it filled the copy in")
filledIn(copy, "namesake after")
namesakeIntact("namesake after")
onlyMine("namesake after")

// (f) A copy Pages is never handed: the fill fails and the namesake is not taken for it.
print("--- a copy that never opens")
copy = make("report.pages", in: "horos-report-template-4")
before = modification(copy)
check(!PagesDocumentFill.fill(documentAt: copy, substitute: substitute, in: pages, open: { _ in }, send: send, attempts: 4, pause: 0.25),
      "the fill answers that it failed")
check(modification(copy) == before, "the copy was not written")
namesakeIntact("copy never opened")
onlyMine("copy never opened")

// (f) An edit Pages refuses - a paragraph the body does not have: the copy is closed by its id.
print("--- an edit Pages refuses")
copy = make("report.pages", in: "horos-report-template-5")
let writeScript = pages.script(PagesDocumentFill.writeScript)
conversation.number = 0
var refused = false
let failedFill = PagesDocumentFill.fill(documentAt: copy, substitute: substitute, in: pages, open: hand, send: { source, arguments in
    if source == writeScript {
        let answer = send(source, arguments + ["p", "0", "9999", "a paragraph that is not there"])
        refused = answer == nil
        return answer
    }
    return send(source, arguments)
})
check(!failedFill && refused, "Pages refused the edit (error \(conversation.number)) and the fill answers that it failed")
check(pages.documentID(openedFrom: copy, attempts: 1, send: send) == nil, "the copy is closed")
namesakeIntact("refused edit")
onlyMine("refused edit")
close(decoy)

// (e) Three images, with a copy of an earlier insertion still open under the same name.
print("--- three images, with an earlier copy of the same name open")
let stalePath = make("Horos-inserted-report.pages", in: "horos-report-images-earlier")
let stale = open(stalePath)
guard let staleBefore = state(stale) else { stop("the state of the earlier copy could not be read") }
/// The pages of a document: the characters of the body on each, and the frame of each image on it.
func pagesOf(_ document: String) -> [(characters: Int, frames: [[Int]])] {
    let answer = ask("""
    set d to document id (item 1 of argv)
    set out to {}
    repeat with p from 1 to (count of pages of d)
    set n to 0
    try
    set n to count of characters of ((body text of page p of d) as text)
    end try
    set end of out to "page " & n
    repeat with i in images of page p of d
    set o to position of i
    set end of out to ((item 1 of o) as text) & " " & ((item 2 of o) as text) & " " & ((width of i) as text) & " " & ((height of i) as text)
    end repeat
    end repeat
    return out
    """, [document])
    var pages: [(characters: Int, frames: [[Int]])] = []
    for line in strings(answer) {
        if line.hasPrefix("page ") {
            pages.append((Int(line.dropFirst(5)) ?? -1, []))
        } else if !pages.isEmpty {
            pages[pages.count - 1].frames.append(line.split(separator: " ").map { Int($0) ?? -1 })
        }
    }
    return pages
}
let templatePages = pagesOf(stale)
let report = make("Synthetic report.pages", in: "REPORTS")
// Three pictures of made-up colours: 4:3, wide and tall, so that each has its own size in the box.
var pictures: [String] = []
for (index, size) in [(64, 48), (96, 48), (30, 60)].enumerated() {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size.0, pixelsHigh: size.1, bitsPerSample: 8, samplesPerPixel: 3,
                                  hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<size.1 { for x in 0..<size.0 {
        bitmap.setColor(NSColor(deviceRed: CGFloat(x) / CGFloat(size.0), green: CGFloat(y) / CGFloat(size.1), blue: CGFloat(index) / 3, alpha: 1), atX: x, y: y)
    } }
    pictures.append(base + "/synthetic-\(index + 1).png")
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: pictures[index]))
}
let inserted = ReportImageInsertion.insert(reportPath: report, sources: pictures)
let refusal = (ReportImageInsertion.lastError?[NSAppleScript.errorNumber] as? Int) ?? 0
check(inserted, "the insertion answers that the images are in the report\(inserted ? "" : ": " + ReportImageInsertion.lastErrorMessage())")
// Whatever Pages answered, it was asked about the new copy alone.
check(openDocuments().contains(stale) && state(stale) == staleBefore && pagesOf(stale).count == templatePages.count,
      "the earlier copy is open, without an image, a page or a change")
onlyMine("images")
if inserted {
    // The report as it is on disk, opened again.
    let reopened = open(report)
    let now = pagesOf(reopened)
    let unchanged = state(reopened)?.modified == "false"
    close(reopened)
    print("  the template: \(templatePages.map { "\($0.characters) characters, \($0.frames.count) images" })")
    print("  the report:   \(now.map { "\($0.characters) characters, images at \($0.frames)" })")
    check(now.count == templatePages.count + 2, "the report has two pages more than the template: \(now.count)")
    check(Array(now.prefix(templatePages.count)).map(\.characters) == templatePages.map(\.characters)
          && Array(now.prefix(templatePages.count)).map(\.frames.count) == templatePages.map(\.frames.count),
          "the pages of the text have the text they had, and no image")
    let figures = Array(now.suffix(2))
    // Each in the box of 340 x 255, as ReportImagePlacement sizes it: 340 x 255, 340 x 170 and 128 x 255.
    let sizes = figures.flatMap { $0.frames.map { Array($0.suffix(2)) } }
    check(figures.map(\.frames.count) == [2, 1] && figures.allSatisfy { $0.characters == 0 }, "two figures on a page of their own and the third on the next")
    check(Set(sizes) == Set([[340, 255], [340, 170], [128, 255]]), "the figures have the sizes computed: \(sizes)")
    // In the middle of the page, the first of a page at the margin and the second one box below.
    let width = figures[0].frames.first.map { 2 * $0[0] + $0[2] } ?? 0
    let tops = figures.map { $0.frames.map { $0[1] }.sorted() }
    check(figures.flatMap(\.frames).allSatisfy { abs(2 * $0[0] + $0[2] - width) <= 1 } && (590...620).contains(width),
          "every figure is in the middle of a page \(width) points wide")
    check(tops == [[72, 341], [72]], "the figures are at \(tops) from the top of their pages")
    check(unchanged, "the report opens again in Pages with nothing to save")
} else {
    print("  Pages did not take the images: \(ReportImageInsertion.lastErrorMessage())")
    check((try? Data(contentsOf: URL(fileURLWithPath: report))) != nil, "the report that took no image is still there")
}
close(stale)

// Only what this check opened was closed, and nothing of it is left.
print("--- at the end")
check(openDocuments() == atStart, "the documents open are those open at the start")
if atStart.isEmpty {
    _ = send("tell application id \"\(pages.identifier)\" to quit", [])
    print("Pages was asked to quit: it had no document open at the start")
}
try? FileManager.default.removeItem(atPath: base)
let images = inserted ? "three images went into the new copy alone, on pages of their own" : "Pages refused the images (error \(refusal)), asked of the new copy alone"
print(failed == 0 ? "PASS: the production fill against Pages \(version), a namesake of the copy open beside it; \(images)" : "\(failed) checks failed")
exit(failed == 0 ? 0 : 1)
'''

if live:
    with tempfile.TemporaryDirectory(prefix='horos-pages-live-') as directory:
        work = Path(directory)
        (work / 'main.swift').write_text(LIVE)
        # The application's own insertion is with the writing of a .docx's figures, which reads archives.
        (work / 'bridge.h').write_text('#include "%s"\n#include "%s"\n' % (
            root / 'Horos/Sources/ThirdParty/Libarchive/archive.h', root / 'Horos/Sources/ThirdParty/Libarchive/archive_entry.h'))
        built = subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(work / 'bridge.h'),
                                *(str(root / path) for path in SOURCES),
                                str(root / 'Horos/Sources/PagesPDFConversion.swift'),
                                str(root / 'Horos/Sources/WordDocumentFigures.swift'),
                                str(root / 'Horos/Sources/PagesHeaderFooterFill.swift'),
                                str(work / 'main.swift'), '-larchive', '-o', str(work / 'check')], capture_output=True, text=True)
        if built.returncode:
            print('FAIL: the production sources did not compile:\n%s' % (built.stderr or built.stdout)[-3000:])
            sys.exit(1)
        try:
            ran = subprocess.run([str(work / 'check'), str(root / 'Horos/Resources/ReportTemplate.pages')],
                                 capture_output=True, text=True, timeout=420)
            status, out, err = ran.returncode, ran.stdout, ran.stderr
        except subprocess.TimeoutExpired as late:
            status = 3
            out = (late.stdout or b'').decode('utf-8', 'replace') + '\nSTOPPED: the check did not end in seven minutes\n'
            err = (late.stderr or b'').decode('utf-8', 'replace')
        sys.stdout.write(out)
        if status not in (0, 2):
            sys.stdout.write(err[-3000:])
        if status == 3:
            # Pages may be waiting on a dialog: its windows, for whoever can look.
            found = subprocess.run(['pgrep', '-f', 'Contents/MacOS/Pages'], capture_output=True, text=True).stdout.split()
            shots = root / 'local-validation/work/pages-live-windows'
            tool = root / 'local-validation/inapp-2026-11-12/shot.sh'
            if found and tool.exists():
                print(subprocess.run([str(tool), found[0], str(shots)], capture_output=True, text=True).stdout)
                print('the windows of Pages are in %s' % shots)
        sys.exit(status)

with tempfile.TemporaryDirectory(prefix='horos-pages-by-file-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(program)
    paths = []
    for path in SOURCES:
        copy = work / Path(path).name
        copy.write_text(source(path), encoding='utf-8')
        paths.append(str(copy))
    built = subprocess.run(['xcrun', 'swiftc', *(['-D', 'REVISION'] if revision else []), *paths,
                            str(work / 'main.swift'), '-o', str(work / 'test')], capture_output=True, text=True)
    if built.returncode:
        failures.append('the production sources did not compile:\n%s' % (built.stderr or built.stdout)[-3000:])
    else:
        ran = subprocess.run([str(work / 'test')], capture_output=True, text=True)
        sys.stdout.write(ran.stdout)
        if ran.returncode:
            failures.append('a document that is not the copy was read or written%s' % (':\n' + ran.stderr[-2000:] if ran.stderr else ''))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a Pages fill and an image insertion work on the document whose file is the copy, whatever else has its name')
