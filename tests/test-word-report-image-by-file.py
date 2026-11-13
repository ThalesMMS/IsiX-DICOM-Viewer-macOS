#!/usr/bin/env python3
"""Images go into the Word document whose file is the copy of the report.

Images are inserted into a copy of the report that is called
`Horos-inserted-report.docx` in every insertion, and the script took its
document by that name: the first document of the name among the ones Word has
open. A copy left open by an insertion that had failed has that name too. The
images then went into that older copy, the new one was put in the place of the
report without them, and the insertion answered that it had worked.

Word is now handed the copy and asked for the files of the documents it has
open; the one that is the file of the copy - compared with symbolic links
resolved - is the document the images go into, named to the script by the
path Word itself gave. Word has no id for a document.

The production source is compiled here with a Word that is not Word: a few
documents with a name and a file, which answers the scripts by what they do.
The script that takes its document by name is still there for who calls it by
its old name, and is run against the same documents to show what it does.
Nothing is opened and nothing is sent to Word. With Word installed, what asks
Word for its documents and what picks the one of the copy are also compiled
against its dictionary, which sends it nothing either.

The command that draws a picture is the one the application already had,
`make inline picture at text object of d file name "..."`, and it is left as it
was here. Word 16's dictionary does not take it as written - the script by name
does not compile with it either - so the script is compiled without pictures,
and what the whole script answers the compiler is printed, not judged: what
command Word takes, and whether Word may read the picture's file without
asking, can only be settled with a Word that takes Apple events.

The mail merge of a Word report is not changed by this: its private template
and its output are named after a folder made for that one report, the merged
document - which has no file before it is saved - is taken only if its name was
not open before, and the saved output is closed by its full path. Those are
checked by test-word-report-merge-script.py.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []

source = (root / 'Horos/Sources/ReportImagePlacement.swift').read_text()
start = source.index('static func insertIntoWord(_ images: [ReportPreparedImage], copy path: String,\n')
body = source[start:source.index('\n    }\n', start)]
if 'documentName' in body or 'lastPathComponent' in body:
    failures.append('the images of a Word report still go into a document taken by its name')
start = source.index('static func wordScript(documentAt file: String')
by_file = source[start:source.index('\n    }\n', start)]
if 'name of candidate' in by_file.replace('posix full name of candidate', ''):
    failures.append('the script that draws into a Word document still compares its name')
for needle, reason in (('posix full name of candidate', 'the document is not told by its file'),
                       ('considering case', 'two paths that differ in case would be one'),
                       ('make inline picture at text object of d', 'the picture is no longer inline'),
                       ('with timeout of', 'drawing can hit the default AppleScript timeout')):
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
    var asked = 0, deaf = false
    init(_ documents: [Document]) { self.documents = documents }
    subscript(file: String) -> Document { documents.first { $0.file == file }! }

    func send(_ source: String, _ arguments: [String]) -> NSAppleEventDescriptor? {
        if deaf { return nil }
        if source.contains("set end of found to (posix full name of candidate) as text") {
            asked += 1
            documents += late.filter { $0.after == asked }.map(\.document)
            return list(documents.filter(\.isOpen).map { text($0.file) })
        }
        guard source.contains("make inline picture at text object of d") else {
            print("FAIL: a script the test does not know was sent:\n\(source)")
            exit(1)
        }
        func first(_ pattern: String) -> String? {
            let expression = try! NSRegularExpression(pattern: pattern)
            guard let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
            return String(source[Range(match.range(at: 1), in: source)!])
        }
        let found: Int?
        if let file = first(#"if my sameFile\(candidateFile, "([^"]*)"\) then"#) {
            found = documents.firstIndex { $0.isOpen && $0.file == file }
        } else if let name = first(#"\(name of candidate\) is "([^"]*)""#) {
            // The first of that name, as the loop over the documents gives it.
            found = documents.firstIndex { $0.isOpen && $0.name == name }
        } else {
            found = nil
        }
        guard let found else { return nil }
        let pictures = try! NSRegularExpression(pattern: #"file name "([^"]*)""#)
        for match in pictures.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            documents[found].pictures.append(String(source[Range(match.range(at: 1), in: source)!]))
        }
        documents[found].saved += 1
        documents[found].isOpen = false
        return text("done")
    }
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("word-by-file-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
func file(in directory: String) -> String {
    let parent = folder.appendingPathComponent(directory)
    try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let path = parent.appendingPathComponent("Horos-inserted-report.docx").path
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
let earlier = real(file(in: "horos-report-images-earlier"))
func stale() -> Word.Document { Word.Document(name: "Horos-inserted-report.docx", file: earlier) }
func fresh(as spelling: String) -> Word.Document { Word.Document(name: "Horos-inserted-report.docx", file: spelling) }
func insert(_ word: Word, attempts: Int = 3) -> Bool {
    ReportImageInsertion.insertIntoWord(images, copy: copy, open: { _ in }, send: word.send, attempts: attempts, pause: 0)
}
func untouched(_ word: Word, _ what: String, line: Int = #line) {
    let old = word[earlier]
    check(old.isOpen && old.pictures.isEmpty && old.saved == 0, "\(what): the earlier copy has \(old.pictures.count) pictures, saved \(old.saved), open \(old.isOpen)", line: line)
}

// The script that takes its document by name, as the application ran it: with
// an earlier copy of the same name open, that one takes the pictures.
var word = Word([stale(), fresh(as: real(copy))])
check(word.send(ReportImageInsertion.wordScript(documentName: "Horos-inserted-report.docx", images: images), []) != nil, "the script by name failed")
check(word[earlier].pictures == images.map(\.path) && word[earlier].saved == 1 && word[real(copy)].pictures.isEmpty && word[real(copy)].isOpen,
      "by name, the pictures did not go to the earlier copy: \(word.documents)")
print("PASS (the defect, shown): taken by name, the earlier copy gets the pictures and the new one is left open without them")

// The application's insertion: by the file, whichever way round and however Word writes the path.
for (first, spelling) in [(true, real(copy)), (false, real(copy)), (true, copy), (false, copy)] {
    word = Word(first ? [stale(), fresh(as: spelling)] : [fresh(as: spelling), stale()])
    check(insert(word), "the copy, written \(spelling), was not found")
    check(word[spelling].pictures == images.map(\.path) && word[spelling].saved == 1 && !word[spelling].isOpen, "the copy is \(word[spelling])")
    untouched(word, "written \(spelling), earlier copy \(first ? "first" : "last")")
}
// Word has not opened the copy yet when first asked: it is waited for, not replaced by the namesake.
word = Word([stale()])
word.late = [(after: 3, document: fresh(as: real(copy)))]
check(insert(word, attempts: 5) && word.asked == 3 && word[real(copy)].pictures.count == 2, "a copy opened late: asked \(word.asked) times")
untouched(word, "a copy opened late")
// The copy never opens: nothing is drawn, the namesake is left, and the failure has a number to show.
word = Word([stale()])
check(!insert(word, attempts: 4) && word.asked == 4, "a copy that never opened: asked \(word.asked) times")
untouched(word, "a copy that never opened")
check(ReportImageInsertion.lastErrorMessage().contains("error -2700"), "a copy that never opened says: \(ReportImageInsertion.lastErrorMessage())")
// A namesake never saved has no file: its name alone is what Word answers, and it is not the copy.
word = Word([Word.Document(name: "Horos-inserted-report.docx", file: "Horos-inserted-report.docx")])
check(!insert(word, attempts: 2) && word.documents[0].pictures.isEmpty && word.documents[0].isOpen, "an unsaved namesake was taken for the copy")
// Word cannot be asked: once, and nothing is drawn.
word = Word([stale(), fresh(as: real(copy))])
word.deaf = true
check(!insert(word, attempts: 5), "a Word that does not answer took pictures")
word.deaf = false
untouched(word, "a Word that does not answer")
check(word[real(copy)].pictures.isEmpty, "the copy was drawn into by a Word that does not answer")
print("PASS: the pictures go into the document whose file is the copy, in any order and spelling, never into a namesake")

// The script names the document by the path Word gave, and compares it exactly.
let script = ReportImageInsertion.wordScript(documentAt: "/private/var/it's \"here\"/Horos-inserted-report.docx", images: images)
check(script.contains(#"if my sameFile(candidateFile, "/private/var/it's \"here\"/Horos-inserted-report.docx") then"#), "the path is not written into the script as a string: \(script)")
check(script.contains("set width of pic to 340") && script.contains("set height of pic to 170") && script.contains("save d") && script.contains("close d saving no")
      && script.contains("on error errorMessage number errorNumber"), "the script no longer sizes, saves, closes and passes the error on")

// Against the dictionary of the Word installed, when there is one: compiled, never run.
if CommandLine.arguments.contains("--word") {
    func compile(_ source: String) -> NSDictionary? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.compileAndReturnError(&error) == true ? nil : (error ?? ["NSAppleScriptErrorMessage": "no error given"])
    }
    for (name, source) in [("documents", ReportImageInsertion.wordDocumentsScript),
                           ("the document of the copy", ReportImageInsertion.wordScript(documentAt: real(copy), images: []))] {
        let error = compile(source)
        check(error == nil, "the script for \(name) does not compile for Word: \(error ?? [:])")
    }
    print("PASS: asking Word for its documents and picking the one of the copy compile against the Microsoft Word installed")
    // The command that draws, as the application had it before: said, not judged.
    for (name, source) in [("by file", ReportImageInsertion.wordScript(documentAt: real(copy), images: images)),
                           ("by name", ReportImageInsertion.wordScript(documentName: "Horos-inserted-report.docx", images: images))] {
        if let error = compile(source) {
            print("note: with its pictures the script \(name) does not compile for this Word: \(error[NSAppleScript.errorMessage] ?? error)")
        } else {
            print("note: with its pictures the script \(name) compiles for this Word")
        }
    }
} else {
    print("note: Microsoft Word is not installed; the scripts were not compiled against its dictionary")
}
'''

word = subprocess.run(['osascript', '-l', 'JavaScript', '-e',
                       "ObjC.import('AppKit'); $.NSWorkspace.sharedWorkspace"
                       ".URLForApplicationWithBundleIdentifier('com.microsoft.Word').isNil()"],
                      capture_output=True, text=True).stdout.strip() == 'false'

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
            failures.append('a document that is not the copy took the pictures%s' % (':\n' + ran.stderr[-2000:] if ran.stderr else ''))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the images of a Word report go into the document whose file is the copy, whatever else has its name')
