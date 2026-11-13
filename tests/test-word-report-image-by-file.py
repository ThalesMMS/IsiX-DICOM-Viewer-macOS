#!/usr/bin/env python3
"""Images go into the Word document whose file is the copy of the report, and Word reads no image file.

Images are inserted into a copy of the report that is called
`Horos-inserted-report.doc` in every insertion, and the script took its
document by that name: the first document of the name among the ones Word has
open. A copy left open by an insertion that had failed has that name too. The
images then went into that older copy, the new one was put in the place of the
report without them, and the insertion answered that it had worked.

Word is now handed the copy and asked for the files of the documents it has
open; the one that is the file of the copy - compared with symbolic links
resolved - is the document the images go into, named to the script by the
path Word itself gave. Word has no id for a document.

Three things about the scripts were wrong with the real Word 16, and are
checked here:

- The script that asks Word for its files kept them in a list called `found`,
  which inside the tell is a word of Word's dictionary. It compiled, and
  answered `missing value` whatever Word had open: the copy of a .doc was never
  found, and a .docx open in Word was never seen. Every variable the scripts
  set is asked of the dictionary of the Word installed, which is sent nothing:
  a name that is a word of it cannot be set outside a tell either.
- An answer that is no list of files is not Word having nothing open.
- The command that drew a picture, `make inline picture at ... file name`, is
  not in Word 16's dictionary (-2741), and the one that is makes a sandboxed
  Word read a file it was not given, which it answers with a "Grant File
  Access" panel and silence. The images of a .doc report are written into a
  document of their own, Word is handed that document with the copy, and the
  figures are moved from one to the other inside Word. The script names no
  image file. Every script compiles against the Word installed.

The production source is compiled here with a Word that is not Word: a few
documents with a name and a file, which answers the scripts by what they do.
The script that takes its document by name is still there for who calls it by
its old name, and is run against the same documents to show what it does.
Nothing is opened and nothing is sent to Word.

    python3 tests/test-word-report-image-by-file.py --live

The application's own insertion against the Word installed, for a session that
may send it Apple events: reports and images made up here - a .docx and a .doc
- take their images, with a namesake of the copy open beside it, and are opened
in Word again to count what they hold; a .docx that Word has open is refused.
Only the documents this run opened are closed, and Word is quit at the end if
it was not running at the start. Exit status 2 when Word is not installed or
does not take the events; 3 when a document did not appear, which may be Word
waiting on a panel of its own.

The mail merge of a Word report is not changed by this: its private template
and its output are named after a folder made for that one report, the merged
document - which has no file before it is saved - is taken only if its name was
not open before, and the saved output is closed by its full path. Those are
checked by test-word-report-merge-script.py.
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib

root = Path(__file__).resolve().parents[1]
live = sys.argv[1:] == ['--live']
failures = []

source = (root / 'Horos/Sources/ReportImagePlacement.swift').read_text()
start = source.index('static func insertIntoWord(figures: String, count: Int, copy path: String,\n')
body = source[start:source.index('\n    }\n', start)]
if 'documentName' in body or 'lastPathComponent' in body:
    failures.append('the images of a Word report still go into a document taken by its name')
start = source.index('static func wordScript(documentAt file: String')
by_file = source[start:source.index('\n    }\n', start)]
if 'name of candidate' in by_file.replace('posix full name of candidate', ''):
    failures.append('the script that draws into a Word document still compares its name')
if 'file name' in by_file or 'POSIX file' in by_file:
    failures.append('the script that draws into a Word document has Word read an image file')
for needle, reason in (('posix full name of candidate', 'the document is not told by its file'),
                       ('considering case', 'two paths that differ in case would be one'),
                       ('set formatted text of', 'the figures are not moved from their document'),
                       ('count of inline pictures of d', 'the figures are not counted as pictures in line with the text'),
                       ('with timeout of 60 seconds', 'drawing waits on the main thread for more than a minute')):
    if needle not in by_file:
        failures.append(reason)

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
func first(_ pattern: String, in source: String) -> String? {
    let expression = try! NSRegularExpression(pattern: pattern)
    guard let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
    return String(source[Range(match.range(at: 1), in: source)!])
}
func all(_ pattern: String, in source: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { String(source[Range($0.range(at: 1), in: source)!]) }
}

/// Word, as far as these scripts go: documents in the order `every document`
/// gives them, each with a name and the file it was opened from - or, for one
/// never saved, its name again, as `posix full name` answers.
final class Word {
    struct Document {
        let name: String, file: String
        var isOpen = true, saved = 0
        var pictures: [String] = []
    }
    var documents: [Document]
    var late: [(after: Int, document: Document)] = []
    var asked = 0, deaf = false, noList = false, sent = 0
    init(_ documents: [Document]) { self.documents = documents }
    subscript(file: String) -> Document { documents.first { $0.file == file }! }

    func send(_ source: String, _ arguments: [String]) -> NSAppleEventDescriptor? {
        sent += 1
        if deaf { return nil }
        if source == ReportImageInsertion.wordDocumentsScript {
            asked += 1
            documents += late.filter { $0.after == asked }.map(\.document)
            // What a script that sets a word of the dictionary answers.
            if noList { return NSAppleEventDescriptor(typeCode: 0x6D736E67) }
            return list(documents.filter(\.isOpen).map { text($0.file) })
        }
        func open(_ file: String?) -> Int? { file.flatMap { file in documents.firstIndex { $0.isOpen && $0.file == file } } }
        if source.contains("then close candidate saving no") {
            for file in all(#"if my sameFile\(candidateFile, "([^"]*)"\) then close candidate saving no"#, in: source) {
                if let index = open(file) { documents[index].isOpen = false }
            }
            return text("closed")
        }
        if source.contains("set formatted text of") {
            let report = open(first(#"if my sameFile\(candidateFile, "([^"]*)"\) then set d to"#, in: source))
            let figures = open(first(#"if my sameFile\(candidateFile, "([^"]*)"\) then set figureDocument to"#, in: source))
            guard let report, let figures else {
                // What the script does before its error: neither is left open.
                for index in [report, figures].compactMap({ $0 }) { documents[index].isOpen = false }
                return nil
            }
            let expected = Int(first(#"is not picturesBefore \+ (\d+) then error"#, in: source) ?? "") ?? -1
            documents[figures].isOpen = false
            guard documents[figures].pictures.count == expected else {
                documents[report].isOpen = false
                return nil
            }
            documents[report].pictures += documents[figures].pictures
            documents[report].saved += 1
            documents[report].isOpen = false
            return text("done")
        }
        guard source.contains("make new inline picture at end of text object of d with properties") else {
            print("FAIL: a script the test does not know was sent:\n\(source)")
            exit(1)
        }
        // The first of that name, as the loop over the documents gives it.
        guard let name = first(#"\(name of candidate\) is "([^"]*)""#, in: source),
              let found = documents.firstIndex(where: { $0.isOpen && $0.name == name }) else { return nil }
        documents[found].pictures += all(#"file name:"([^"]*)""#, in: source)
        documents[found].saved += 1
        documents[found].isOpen = false
        return text("done")
    }
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("word-by-file-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
func file(_ name: String = "Horos-inserted-report.doc", in directory: String) -> String {
    let parent = folder.appendingPathComponent(directory)
    try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let path = parent.appendingPathComponent(name).path
    FileManager.default.createFile(atPath: path, contents: Data("not a document".utf8))
    return path
}
/// The path of a file with its links resolved: `/private/var/...` for a temporary folder.
func real(_ path: String) -> String {
    let pointer = realpath(path, nil)!
    defer { free(pointer) }
    return String(cString: pointer)
}
let images = [ReportPreparedImage(path: "/nowhere/images/0001.jpg", widthPoints: 340, heightPoints: 255),
              ReportPreparedImage(path: "/nowhere/images/0002.jpg", widthPoints: 340, heightPoints: 170)]
let copy = file(in: "horos-report-images-new")
let figures = file("Horos-inserted-figures.docx", in: "horos-report-images-new")
let earlier = real(file(in: "horos-report-images-earlier"))
func stale() -> Word.Document { Word.Document(name: "Horos-inserted-report.doc", file: earlier) }
func fresh(as spelling: String) -> Word.Document { Word.Document(name: "Horos-inserted-report.doc", file: spelling) }
/// The document of the figures, as Word has it open: what it holds is the images.
func drawn(as spelling: String = real(figures), _ pictures: [String] = images.map(\.path)) -> Word.Document {
    Word.Document(name: "Horos-inserted-figures.docx", file: spelling, pictures: pictures)
}
func insert(_ word: Word, attempts: Int = 3) -> Bool {
    ReportImageInsertion.lastError = nil
    return ReportImageInsertion.insertIntoWord(figures: figures, count: images.count, copy: copy, open: { _ in }, send: word.send,
                                               attempts: attempts, pause: 0)
}
func untouched(_ word: Word, _ what: String, line: Int = #line) {
    let old = word[earlier]
    check(old.isOpen && old.pictures.isEmpty && old.saved == 0, "\(what): the earlier copy has \(old.pictures.count) pictures, saved \(old.saved), open \(old.isOpen)", line: line)
}

// The script that takes its document by name, as the application ran it: with
// an earlier copy of the same name open, that one takes the pictures.
var word = Word([stale(), fresh(as: real(copy))])
check(word.send(ReportImageInsertion.wordScript(documentName: "Horos-inserted-report.doc", images: images), []) != nil, "the script by name failed")
check(word[earlier].pictures == images.map(\.path) && word[earlier].saved == 1 && word[real(copy)].pictures.isEmpty && word[real(copy)].isOpen,
      "by name, the pictures did not go to the earlier copy: \(word.documents)")
print("PASS (the defect, shown): taken by name, the earlier copy gets the pictures and the new one is left open without them")

// The application's insertion: by the file, whichever way round and however Word writes the paths.
for (first, spelling, figuresSpelling) in [(true, real(copy), real(figures)), (false, real(copy), figures), (true, copy, real(figures)), (false, copy, figures)] {
    word = Word(first ? [stale(), drawn(as: figuresSpelling), fresh(as: spelling)] : [fresh(as: spelling), stale(), drawn(as: figuresSpelling)])
    check(insert(word), "the copy, written \(spelling), was not found")
    check(word[spelling].pictures == images.map(\.path) && word[spelling].saved == 1 && !word[spelling].isOpen, "the copy is \(word[spelling])")
    check(!word[figuresSpelling].isOpen && word[figuresSpelling].saved == 0, "the document of the figures was left \(word[figuresSpelling])")
    untouched(word, "written \(spelling), earlier copy \(first ? "first" : "last")")
}
// Word has not opened the two yet when first asked: they are waited for, both, and the namesake is not taken.
word = Word([stale()])
word.late = [(after: 2, document: drawn()), (after: 3, document: fresh(as: real(copy)))]
check(insert(word, attempts: 5) && word.asked == 3 && word[real(copy)].pictures.count == 2, "a copy opened late: asked \(word.asked) times")
untouched(word, "a copy opened late")
// The copy never opens: nothing is drawn, the namesake is left, the document of
// the figures is not left open, and the failure has a number to show.
word = Word([stale(), drawn()])
check(!insert(word, attempts: 4) && word.asked == 4, "a copy that never opened: asked \(word.asked) times")
untouched(word, "a copy that never opened")
check(!word[real(figures)].isOpen && word[real(figures)].saved == 0, "the document of the figures was left open when the copy did not open")
check(ReportImageInsertion.lastErrorMessage().contains("error -2700"), "a copy that never opened says: \(ReportImageInsertion.lastErrorMessage())")
// The figures never open: the copy is closed as it was, and nothing was drawn into it.
word = Word([stale(), fresh(as: real(copy))])
check(!insert(word, attempts: 2) && !word[real(copy)].isOpen && word[real(copy)].saved == 0 && word[real(copy)].pictures.isEmpty,
      "a copy whose figures did not open was left \(word[real(copy)])")
untouched(word, "figures that never opened")
// A namesake never saved has no file: its name alone is what Word answers, and it is not the copy.
word = Word([Word.Document(name: "Horos-inserted-report.doc", file: "Horos-inserted-report.doc"), drawn()])
check(!insert(word, attempts: 2) && word.documents[0].pictures.isEmpty && word.documents[0].isOpen, "an unsaved namesake was taken for the copy")
// Word holds fewer figures than were written: the report is closed as it was.
word = Word([fresh(as: real(copy)), drawn(as: real(figures), [images[0].path])])
check(!insert(word) && word[real(copy)].pictures.isEmpty && word[real(copy)].saved == 0 && !word[real(copy)].isOpen && !word[real(figures)].isOpen,
      "a report that did not take every figure was saved: \(word.documents)")
// Word cannot be asked: once, and nothing is drawn.
word = Word([stale(), drawn(), fresh(as: real(copy))])
word.deaf = true
check(!insert(word, attempts: 5) && word.sent == 1, "a Word that does not answer was sent \(word.sent) scripts")
word.deaf = false
untouched(word, "a Word that does not answer")
check(word[real(copy)].pictures.isEmpty, "the copy was drawn into by a Word that does not answer")
// Word answers something that is no list of files - what the script answered
// while its list had the name of a word of Word's: that is not "nothing open".
word = Word([stale(), drawn(), fresh(as: real(copy))])
word.noList = true
check(!insert(word, attempts: 5) && word.sent == 1 && word[real(copy)].pictures.isEmpty, "an answer that is no list was read as a list: sent \(word.sent)")
check(ReportImageInsertion.wordFiles(in: NSAppleEventDescriptor(typeCode: 0x6D736E67)) == nil
      && ReportImageInsertion.wordFiles(in: list([])) == []
      && ReportImageInsertion.wordFiles(in: list([text("/a.doc"), text("b.doc")])) == ["/a.doc", "b.doc"], "the files of an answer are not read as they are")
print("PASS: the figures go into the document whose file is the copy, in any order and spelling, never into a namesake, and nothing of the insertion is left open")

// The script names the two documents by the paths Word gave, and compares them exactly.
let script = ReportImageInsertion.wordScript(documentAt: "/private/var/it's \"here\"/Horos-inserted-report.doc",
                                             figuresAt: "/private/var/it's \"here\"/Horos-inserted-figures.docx", count: 2)
check(script.contains(#"if my sameFile(candidateFile, "/private/var/it's \"here\"/Horos-inserted-report.doc") then set d to contents of candidate"#)
      && script.contains(#"if my sameFile(candidateFile, "/private/var/it's \"here\"/Horos-inserted-figures.docx") then set figureDocument to contents of candidate"#),
      "the paths are not written into the script as strings: \(script)")
check(script.contains("is not picturesBefore + 2 then error") && script.contains("save d") && script.contains("close d saving no")
      && script.contains("close figureDocument saving no") && script.contains("on error errorMessage number errorNumber"),
      "the script no longer counts, saves, closes and passes the error on")
check(!script.contains("0001.jpg") && !script.contains("file name"), "the script hands Word an image file")
// The script by name sizes its pictures, with the command Word's dictionary has.
let byName = ReportImageInsertion.wordScript(documentName: "Horos-inserted-report.doc", images: images)
check(byName.contains("set width of pic to 340") && byName.contains("set height of pic to 170") && !byName.contains("make inline picture at"),
      "the script by name is \(byName)")

let scripts = [("asking for the documents", ReportImageInsertion.wordDocumentsScript),
               ("moving the figures", script),
               ("closing what was opened", ReportImageInsertion.wordCloseScript(files: ["/a/b.doc", "/a/c.docx"])),
               ("drawing by name", byName)]
// Against the dictionary of the Word installed, when there is one: compiled, never run.
if CommandLine.arguments.contains("--word") {
    for (name, source) in scripts {
        var error: NSDictionary?
        let compiled = NSAppleScript(source: source)?.compileAndReturnError(&error) == true
        check(compiled, "the script for \(name) does not compile for Word: \(error ?? [:])")
    }
    print("PASS: every script sent to Word compiles against the Microsoft Word installed")
    // A variable is a variable to Word: set with Word's terms and no tell, so
    // nothing is sent, a word of the dictionary cannot be set at all.
    func isVariable(_ name: String) -> Bool {
        var error: NSDictionary?
        let answer = NSAppleScript(source: "using terms from application \"Microsoft Word\"\nset \(name) to 7\nreturn \(name)\nend using terms from")?
            .executeAndReturnError(&error)
        return error == nil && answer?.int32Value == 7
    }
    check(!isVariable("found"), "`found` is no longer a word of Word's dictionary: this check sees nothing")
    var names = Set<String>()
    for (_, source) in scripts {
        names.formUnion(all(#"^\s*set ([A-Za-z_][A-Za-z0-9_]*) to "#, in: source))
        names.formUnion(all(#"^\s*repeat with ([A-Za-z_][A-Za-z0-9_]*) (?:in|from) "#, in: source))
        names.formUnion(all(#"^\s*set end of ([A-Za-z_][A-Za-z0-9_]*) to "#, in: source))
        names.formUnion(all(#"on error ([A-Za-z_][A-Za-z0-9_]*) number"#, in: source))
        names.formUnion(all(#"on error [A-Za-z_][A-Za-z0-9_]* number ([A-Za-z_][A-Za-z0-9_]*)"#, in: source))
    }
    check(names.isSuperset(of: ["openFiles", "candidate", "candidateFile", "d", "figureDocument", "picturesBefore", "figureEnd", "reportEnd", "pic", "errorMessage", "errorNumber"]),
          "the variables of the scripts were not all read: \(names.sorted())")
    for name in names.sorted() {
        check(isVariable(name), "`\(name)` is a word of Word's dictionary: inside the tell the script does not set a variable of that name")
    }
    print("PASS: the \(names.count) variables the scripts set are variables to Word, where `found` is not")
} else {
    print("note: Microsoft Word is not installed; the scripts were not compiled against its dictionary")
}
'''

LIVE = r'''
import AppKit
import Foundation

var failed = 0
func check(_ value: Bool, _ what: String, line: Int = #line) {
    if value { print("ok: \(what)") } else { print("FAIL: \(what) (line \(line))"); failed += 1 }
}
guard let wordURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Word") else {
    print("Microsoft Word is not installed")
    exit(2)
}
let version = (Bundle(url: wordURL)?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.Word").isEmpty
func send(_ source: String) -> NSAppleEventDescriptor? { ReportImageInsertion.execute(source, in: .word) }
func openFiles() -> [String]? { send(ReportImageInsertion.wordDocumentsScript).flatMap(ReportImageInsertion.wordFiles(in:)) }
func handToWord(_ path: String) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: wordURL, configuration: configuration, completionHandler: nil)
}
/// Word's own writing of the file it opened from `path`, waited for; the run ends when it does not appear.
func opened(_ path: String) -> String {
    handToWord(path)
    guard let file = ReportImageInsertion.wordDocument(openedFrom: path, attempts: 80, pause: 0.5, send: { source, _ in send(source) }) else {
        print("FAIL: Word did not open \(path): \(String(describing: ReportImageInsertion.lastError))")
        exit(3)
    }
    return file
}
func close(_ files: [String]) { _ = send(ReportImageInsertion.wordCloseScript(files: files)) }
/// What the document Word has open from `file` holds: whether it may be
/// changed, the sizes of its pictures in line with the text, in points, and
/// its text, in which Word writes a picture as "/" and the end of a paragraph
/// as a return.
func held(_ file: String) -> (readOnly: Bool, pictures: [String], text: String)? {
    let quoted = "\"" + file.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    let answer = send([
        "on sameFile(one, other)", "  considering case", "    return one is other", "  end considering", "end sameFile", "",
        "tell application \"Microsoft Word\"",
        "  with timeout of 30 seconds",
        "    repeat with candidate in (get every document)",
        "      set candidateFile to \"\"",
        "      try",
        "        set candidateFile to (posix full name of candidate) as text",
        "      end try",
        "      if my sameFile(candidateFile, \(quoted)) then",
        "        set pictureSizes to {}",
        "        repeat with onePicture in (get every inline picture of candidate)",
        "          set end of pictureSizes to (((width of onePicture) as integer) as text) & \"x\" & (((height of onePicture) as integer) as text)",
        "        end repeat",
        "        return {read only of candidate, pictureSizes, content of text object of candidate}",
        "      end if",
        "    end repeat",
        "    error \"no such document\"",
        "  end timeout",
        "end tell",
    ].joined(separator: "\n"))
    guard let answer, answer.numberOfItems == 3, let sizes = answer.atIndex(2) else { return nil }
    return (answer.atIndex(1)?.booleanValue ?? true,
            sizes.numberOfItems > 0 ? (1...sizes.numberOfItems).compactMap { sizes.atIndex($0)?.stringValue } : [],
            answer.atIndex(3)?.stringValue ?? "")
}
func bytes(_ path: String) -> Data { FileManager.default.contents(atPath: path) ?? Data() }
func timed(_ work: () -> Bool) -> (Bool, Double) {
    let start = Date()
    let done = work()
    return (done, Date().timeIntervalSince(start))
}

let arguments = CommandLine.arguments
let base = arguments[1], docx = arguments[2], doc = arguments[3], first = arguments[4], second = arguments[5]
/// The text of the two reports, as Word gives it: a return ends each paragraph.
let reportText = "LAUDO DE TESTE\r\rPaciente: TESTE^SINTETICO\rAchados: nenhum, o exame nao existe.\r"

if !wasRunning {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: wordURL, configuration: configuration, completionHandler: nil)
    for _ in 1...60 where NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.Word").first?.isFinishedLaunching != true {
        Thread.sleep(forTimeInterval: 0.5)
    }
}
guard let atStart = openFiles() else {
    print("Word \(version) does not take Apple events from here: \(String(describing: ReportImageInsertion.lastError))")
    exit(2)
}
print("Word \(version), \(wasRunning ? "running" : "started here"); documents open at the start: \(atStart.count)")
func nothingLeft(_ what: String, beside mine: [String] = [], line: Int = #line) {
    let now = openFiles() ?? ["?"]
    check(Set(now) == Set(atStart + mine), "\(what): no document is open that was not before (\(now.count) open, \(atStart.count + mine.count) expected)", line: line)
}

// A .docx, with Word running: the figures are written into the file, and Word opens it.
var (done, seconds) = timed { ReportImageInsertion.insert(reportPath: docx, sources: [first, second]) }
check(done, String(format: "a .docx report took two images in %.1f s: %@", seconds, done ? "" : ReportImageInsertion.lastErrorMessage()))
nothingLeft("after the .docx")
var file = opened(docx)
var holds = held(file)
check(holds?.readOnly == false && holds?.pictures == ["255x255", "340x170"] && holds?.text == reportText + "/\r/\r",
      "Word opens the .docx to be changed: its text, then two figures at their sizes, a paragraph each, and nothing after: \(String(describing: holds))")

// The report is open in Word: the insertion is refused, and the file is not touched.
let before = bytes(docx)
(done, seconds) = timed { ReportImageInsertion.insert(reportPath: docx, sources: [first]) }
check(!done && ReportImageInsertion.lastErrorMessage().contains("open in Microsoft Word") && bytes(docx) == before,
      String(format: "a .docx that Word has open is refused in %.1f s and left as it was: %@", seconds, ReportImageInsertion.lastErrorMessage()))
close([file])
nothingLeft("after the refusal")

// A .doc, with a namesake of the copy open beside it: Word moves the figures in.
let namesake = base + "/earlier/Horos-inserted-report.doc"
try! FileManager.default.createDirectory(atPath: base + "/earlier", withIntermediateDirectories: true)
try! FileManager.default.copyItem(atPath: doc, toPath: namesake)
let namesakeBytes = bytes(namesake)
let stale = opened(namesake)
(done, seconds) = timed { ReportImageInsertion.insert(reportPath: doc, sources: [first, second]) }
check(done, String(format: "a .doc report took two images in %.1f s: %@", seconds, done ? "" : ReportImageInsertion.lastErrorMessage()))
check(seconds < 60, "Word did not stop on a panel of its own: the insertion did not wait for the script's minute")
nothingLeft("after the .doc", beside: [stale])
check(held(stale)?.pictures == [] && bytes(namesake) == namesakeBytes, "the namesake of the copy took no figure and was not saved")
check(bytes(doc).starts(with: [0xD0, 0xCF, 0x11, 0xE0]), "the report is still a Word 97-2004 document")
file = opened(doc)
holds = held(file)
check(holds?.readOnly == false && holds?.pictures == ["255x255", "340x170"] && holds?.text == reportText + "/\r/\r",
      "Word opens the .doc to be changed: its text, then two figures at their sizes, a paragraph each, and nothing after: \(String(describing: holds))")
close([file])
// Once more: the third figure goes after the two.
(done, seconds) = timed { ReportImageInsertion.insert(reportPath: doc, sources: [second]) }
check(done, String(format: "the .doc took a third image in %.1f s: %@", seconds, done ? "" : ReportImageInsertion.lastErrorMessage()))
file = opened(doc)
holds = held(file)
check(holds?.pictures == ["255x255", "340x170", "340x170"] && holds?.text == reportText + "/\r/\r/\r",
      "the .doc holds three figures after its text: \(String(describing: holds))")
close([file, stale])

nothingLeft("at the end")
if !wasRunning {
    _ = send("tell application \"Microsoft Word\" to quit saving no")
    print("Word was asked to quit: it was not running at the start")
}
print(failed == 0 ? "PASS: the application's insertion against Microsoft Word \(version): a .docx written with no Word and opened by it, refused while open there, and a .doc whose figures Word moved in with no image file to read"
                  : "\(failed) checks failed")
exit(failed == 0 ? 0 : 1)
'''

word = subprocess.run(['osascript', '-l', 'JavaScript', '-e',
                       "ObjC.import('AppKit'); $.NSWorkspace.sharedWorkspace"
                       ".URLForApplicationWithBundleIdentifier('com.microsoft.Word').isNil()"],
                      capture_output=True, text=True).stdout.strip() == 'false'


def png(path, w, h, shade):
    raw = b''.join(b'\x00' + bytes(shade(x, y) for x in range(w)) for y in range(h))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 0, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


if live:
    with tempfile.TemporaryDirectory(prefix='horos-word-live-') as directory:
        work = Path(directory).resolve()
        (work / 'main.swift').write_text(LIVE)
        (work / 'bridge.h').write_text('#include "%s"\n#include "%s"\n' % (
            root / 'Horos/Sources/ThirdParty/Libarchive/archive.h', root / 'Horos/Sources/ThirdParty/Libarchive/archive_entry.h'))
        built = subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(work / 'bridge.h'),
                                *(str(root / 'Horos/Sources' / name) for name in (
                                    'WordDocumentFigures.swift', 'ReportImagePlacement.swift', 'PagesHeaderFooterFill.swift',
                                    'PagesApplication.swift', 'PagesDocumentFill.swift', 'MainActorCallbacks.swift')),
                                str(work / 'main.swift'), '-larchive', '-o', str(work / 'check')], capture_output=True, text=True)
        if built.returncode:
            print('FAIL: the production sources did not compile:\n%s' % (built.stderr or built.stdout)[-3000:])
            sys.exit(1)
        # A report and two images that are nobody's: a made-up text, a square and a wide gradient.
        (work / 'report.txt').write_text('LAUDO DE TESTE\n\nPaciente: TESTE^SINTETICO\nAchados: nenhum, o exame nao existe.\n')
        for extension in ('docx', 'doc'):
            subprocess.run(['/usr/bin/textutil', '-convert', extension, str(work / 'report.txt'),
                            '-output', str(work / ('report.' + extension))], check=True)
        png(work / 'square.png', 256, 256, lambda x, y: (x ^ y) & 255)
        png(work / 'wide.png', 320, 160, lambda x, y: x * 255 // 320)
        try:
            ran = subprocess.run([str(work / 'check'), str(work), str(work / 'report.docx'), str(work / 'report.doc'),
                                  str(work / 'square.png'), str(work / 'wide.png')], capture_output=True, text=True, timeout=420)
            status, out, err = ran.returncode, ran.stdout, ran.stderr
        except subprocess.TimeoutExpired as late:
            status = 3
            out = (late.stdout or b'').decode('utf-8', 'replace') + '\nSTOPPED: the check did not end in seven minutes\n'
            err = (late.stderr or b'').decode('utf-8', 'replace')
        sys.stdout.write(out)
        if status not in (0, 2):
            sys.stdout.write(err[-3000:])
        sys.exit(status)

with tempfile.TemporaryDirectory(prefix='horos-word-by-file-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(program)
    built = subprocess.run(['xcrun', 'swiftc',
                            str(root / 'Horos/Sources/ReportImagePlacement.swift'),
                            str(root / 'Horos/Sources/PagesApplication.swift'),
                            str(root / 'Horos/Sources/PagesDocumentFill.swift'),
                            str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                            str(work / 'main.swift'), '-o', str(work / 'test')], capture_output=True, text=True)
    if built.returncode:
        failures.append('the production source did not compile:\n%s' % (built.stderr or built.stdout)[-3000:])
    else:
        ran = subprocess.run([str(work / 'test')] + (['--word'] if word else []), capture_output=True, text=True)
        sys.stdout.write(ran.stdout)
        if ran.returncode:
            failures.append('a script or a document is not as it should be%s' % (':\n' + ran.stderr[-2000:] if ran.stderr else ''))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the images of a Word report go into the document whose file is the copy, whatever else has its name, and Word reads no image file')
