#!/usr/bin/env python3
"""A fill that cannot go on closes the copy of the template it had Pages open.

A modern template is filled in by Pages: the copy is handed to Pages through
LaunchServices and the scripts then read it, write it, save it and close it.
When a script failed after that - the document never read, an edit refused -
nothing closed the copy: it stayed open in Pages, an untouched or half-filled
template in front of the user, under the alert saying the report could not be
created.

The copy is closed without saving, by the id of the document whose file it is
- the same question the fill starts with - and never by its name: the copy is
called `report.pages`, a document of the user's may be too, and that one is not
this code's to close.

The production PagesDocumentFill is compiled here with a conversation that is
not Pages: what would be opened and every script that would be sent are
recorded, and the answers are the test's. Nothing is opened and nothing is
sent to Pages.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []

fill = (root / 'Horos/Sources/PagesDocumentFill.swift').read_text()
code = '\n'.join(line for line in fill.split('\n') if not line.strip().startswith('//'))
if 'close (document id (item 1 of argv)) saving no' not in code:
    failures.append('the copy is not closed by its id, without saving')
if 'name of candidate' in code:
    failures.append('a document is taken by its name, which a document of the user may share')

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

let pages = PagesApplication.Target(url: URL(fileURLWithPath: "/nowhere/Pages.app"), identifier: "com.apple.iWork.Pages")
let scripts = ["documents": pages.script(PagesApplication.Target.documentsScript), "read": pages.script(PagesDocumentFill.readScript),
               "write": pages.script(PagesDocumentFill.writeScript), "close": pages.script(PagesDocumentFill.closeScript)]
check(Set(scripts.values).count == 4, "the scripts are not four different ones")

// The copy, in a temporary folder as the report generator makes it, and what
// Pages has open: a document of the user's with the name of the copy, and the copy.
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fill-copy-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let copy = folder.appendingPathComponent("report.pages").path
FileManager.default.createFile(atPath: copy, contents: Data("not a document".utf8))
let real = realpath(copy, nil).map { pointer -> String in defer { free(pointer) }; return String(cString: pointer) }!
let open = list([list([text("USER-1"), text("/Users/someone/Documents/report.pages")]), list([text("COPY-2"), text(real)])])

/// One fill against answers of the test's: what was opened, and the scripts
/// sent with their arguments, by name.
func fill(_ answers: [String: NSAppleEventDescriptor?]) -> (filled: Bool, opened: [String], sent: [(String, [String])]) {
    var opened: [String] = [], sent: [(String, [String])] = []
    let filled = PagesDocumentFill.fill(documentAt: copy, substitute: substitute, in: pages, open: { opened.append($0) }, send: { source, arguments in
        guard let name = scripts.first(where: { $0.value == source })?.key else {
            print("FAIL: a script that is none of the four was sent"); exit(1)
        }
        check(opened == [copy], "\(name) was sent before the copy was handed to Pages")
        check(!arguments.contains("USER-1") && !arguments.contains("report.pages"), "\(name) was sent for \(arguments)")
        sent.append((name, arguments))
        return answers[name] ?? nil
    }, attempts: 2, pause: 0)
    return (filled, opened, sent)
}
let document = list([text("COPY-2"), text("Patient: \u{ab}name\u{bb}"), list([])])
let plain = list([text("COPY-2"), text("nothing to fill in"), list([])])
let done = text("done")

// A fill that works: found, read, written, and nothing more.
var run = fill(["documents": open, "read": document, "write": done])
check(run.filled && run.opened == [copy], "a fill that works is reported as failed")
check(run.sent.map(\.0) == ["documents", "read", "write"], "a fill that works sent \(run.sent.map(\.0))")
check(run.sent[0].1 == ["com.apple.iWork.Pages"] && run.sent[1].1 == ["COPY-2"]
      && run.sent[2].1 == ["COPY-2", "p", "0", "1", "Patient: Synthetic Patient"], "arguments: \(run.sent)")
// Nothing to fill in: the copy is closed as it is.
run = fill(["documents": open, "read": plain, "close": done])
check(run.filled && run.sent.map(\.0) == ["documents", "read", "close"] && run.sent[2].1 == ["COPY-2"], "nothing to fill in sent \(run.sent)")

// Pages has no document of that file: nothing was opened that could be closed.
run = fill(["documents": list([list([text("USER-1"), text("/Users/someone/Documents/report.pages")])])])
check(!run.filled && run.sent.map(\.0) == ["documents", "documents"], "a copy that never opened sent \(run.sent.map(\.0))")
// Pages cannot be asked: once.
run = fill([:])
check(!run.filled && run.sent.map(\.0) == ["documents"], "a Pages that does not answer was sent \(run.sent.map(\.0))")
// The copy could not be read, or the answer is not a document: the copy is closed, by its id.
for answer in [nil, list([text("COPY-2"), text("")])] as [NSAppleEventDescriptor?] {
    run = fill(["documents": open, "read": answer, "close": done])
    check(!run.filled && run.sent.map(\.0) == ["documents", "read", "close"] && run.sent[2].1 == ["COPY-2"], "an unread copy sent \(run.sent)")
}
// An edit Pages refused: the copy is half written and is closed without saving.
run = fill(["documents": open, "read": document, "close": done])
check(!run.filled && run.sent.map(\.0) == ["documents", "read", "write", "close"] && run.sent[3].1 == ["COPY-2"], "a refused edit sent \(run.sent.map(\.0))")
// Closing the copy failing too changes nothing: the fill has failed already.
run = fill(["documents": open, "read": document])
check(!run.filled && run.sent.map(\.0) == ["documents", "read", "write", "close"], "a refused close sent \(run.sent.map(\.0))")
print("PASS: a fill that fails closes the copy by its id, and one that works sends nothing more")

// The script compiles against the Pages installed, when there is one. Nothing is sent.
if let installed = PagesApplication.target() {
    var error: NSDictionary?
    check(NSAppleScript(source: installed.script(PagesDocumentFill.closeScript))?.compileAndReturnError(&error) == true,
          "the script that closes the copy does not compile for \(installed.identifier): \(error ?? [:])")
    print("PASS: the script that closes the copy compiles for \(installed.identifier)")
} else {
    print("note: Pages is not installed; the script that closes the copy was not compiled")
}
'''

with tempfile.TemporaryDirectory(prefix='horos-pages-abandon-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(program)
    built = subprocess.run(['xcrun', 'swiftc',
                            str(root / 'Horos/Sources/PagesDocumentFill.swift'),
                            str(root / 'Horos/Sources/PagesApplication.swift'),
                            str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                            str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True)
    if built.returncode:
        failures.append('the production PagesDocumentFill did not compile:\n%s' % (built.stderr or built.stdout))
    else:
        ran = subprocess.run([str(work / 'test')], capture_output=True, text=True)
        sys.stdout.write(ran.stdout)
        if ran.returncode:
            failures.append('a fill that fails leaves its copy open:\n%s' % ran.stderr[-2000:])

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a Pages fill that fails closes the copy it opened, the document of that file and never one of its name')
