#!/usr/bin/env python3
"""A Pages report fills placeholders outside the body: text boxes, shapes, tables, groups.

A modern Pages template is filled in by Pages, over AppleScript. The body text
was all that was read, so a placeholder in a table cell, a text box or the
letterhead box a template keeps on its section layout stayed as written, and
so did one inside a group of objects, which is how a letterhead with a logo is
often put together. The
production PagesDocumentFill is compiled here and given what Pages answers - a
descriptor shaped like the open script's result - and the edits it plans are
checked, without Pages.

Measured with Pages 15.4 while writing this, and kept below:

  * `set paragraph i` keeps the paragraph's own break; a line break added to
    the new text left an empty paragraph after it.
  * Rewriting a paragraph that holds an anchored object (U+FFFC: an inline
    table, a text box that moves with the text) deletes the object.
  * An automatic cell reads what is typed into it: 00123 became the number 123,
    so a cell is made a text cell before it is written.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
fill = (root / 'Horos/Sources/PagesDocumentFill.swift').read_text()
failures = []
code = '\n'.join(line for line in fill.split('\n') if not line.strip().startswith('//'))
for needle, reason in (
    ('my collectItems(d, "", {})', 'the open script does not read the items of the document'),
    ('if (class of x) is group then', 'the open script does not go into groups'),
    ('set x to iWork item ((contents of stepText) as integer) of x', 'the write script does not follow a location into groups'),
    ('value of every cell of x', 'the cells of a table are not read in one event'),
    ('set paragraph i of object text of x to newText', 'the text of a text box or shape is not written'),
    ('set format of cell i to text', 'a cell is written without being made a text cell first'),
    ('set value of cell i to newText', 'a cell is not written'),
    ('set paragraph i of body text of d to newText', 'the body is not written a paragraph at a time'),
):
    if needle not in code:
        failures.append(reason)
if 'filled + "\\n"' in code:
    failures.append('a line break is added to a replaced paragraph again, which leaves an empty one after it')

program = r'''
import Foundation

func check(_ value: Bool, _ what: String, line: Int = #line) {
    if !value { print("FAIL: \(what) (line \(line))"); exit(1) }
}
let values = ["name": "Synthetic Patient", "patientID": "00123", "accessionNumber": "ACC-7"]
func substitute(_ text: String) -> String {
    var result = text
    for (key, value) in values { result = result.replacingOccurrences(of: "\u{ab}\(key)\u{bb}", with: value) }
    return result
}

// What the open script answers: the document id, the body text, and per item
// either its text or the texts of its cells.
func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let list = NSAppleEventDescriptor.list()
    for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
    return list
}
func text(_ string: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: string) }
func integer(_ value: Int32) -> NSAppleEventDescriptor { NSAppleEventDescriptor(int32: value) }
// A location is the path of item indices from the document: "5.2" is the second
// item of the group that is the document's fifth.
let body = "Report\n\u{fffc}\nPatient: \u{ab}name\u{bb}\nIndication:\n\u{ab}patientID\u{bb} \u{fffc} anchored"
let answer = list([
    text("DOC-1"), text(body),
    list([
        list([text("text"), text("1"), text("\u{ab}name\u{bb} \u{b7} ID \u{ab}patientID\u{bb}\nInstitution")]),
        list([text("table"), text("2"), list([text("Patient"), text("\u{ab}name\u{bb}"), text(""), text("ID \u{ab}patientID\u{bb}")])]),
        list([text("text"), text("3"), text("Box\nAcc. \u{ab}accessionNumber\u{bb}")]),
        list([text("text"), text("4"), text("no placeholder")]),
        // A group of a logo and a text box, and a group nested in another.
        list([text("text"), text("5.2"), text("Name: \u{ab}name\u{bb}")]),
        list([text("table"), text("6.1.3"), list([text("\u{ab}patientID\u{bb}")])]),
    ]),
])
guard let (identifier, read, items) = PagesDocumentFill.document(from: answer) else {
    print("FAIL: the open script's answer was not read"); exit(1)
}
check(identifier == "DOC-1" && read == body, "id and body")
check(items == [.text(location: "1", text: "\u{ab}name\u{bb} \u{b7} ID \u{ab}patientID\u{bb}\nInstitution"),
                .table(location: "2", cells: ["Patient", "\u{ab}name\u{bb}", "", "ID \u{ab}patientID\u{bb}"]),
                .text(location: "3", text: "Box\nAcc. \u{ab}accessionNumber\u{bb}"),
                .text(location: "4", text: "no placeholder"),
                .text(location: "5.2", text: "Name: \u{ab}name\u{bb}"),
                .table(location: "6.1.3", cells: ["\u{ab}patientID\u{bb}"])], "items")

let edits = PagesDocumentFill.edits(body: read, items: items, substitute: substitute)
check(edits.count % 4 == 0, "four arguments an edit")
let groups = stride(from: 0, to: edits.count, by: 4).map { Array(edits[$0..<$0 + 4]) }
check(groups == [
    // The box first, its first paragraph only, and with no line break added.
    ["o", "1", "1", "Synthetic Patient \u{b7} ID 00123"],
    // Only the cells that change, numbered from 1 as `cell i` counts them.
    ["c", "2", "2", "Synthetic Patient"],
    ["c", "2", "4", "ID 00123"],
    ["o", "3", "2", "Acc. ACC-7"],
    // Inside groups, by the path to the item.
    ["o", "5.2", "1", "Name: Synthetic Patient"],
    ["c", "6.1.3", "1", "00123"],
    // The body last; the paragraph holding an anchored object is left alone.
    ["p", "0", "3", "Patient: Synthetic Patient"],
], "edits: \(groups)")
check(!edits.contains { $0.hasSuffix("\n") }, "no line break added")

// Nothing to fill in: no edits, so the copy is closed as it is.
check(PagesDocumentFill.edits(body: "plain", items: [.text(location: "1", text: "plain")], substitute: substitute).isEmpty, "nothing")
// A document without a body - a page layout one - still has its items filled.
check(PagesDocumentFill.edits(body: "", items: [.text(location: "1", text: "\u{ab}name\u{bb}")], substitute: substitute)
      == ["o", "1", "1", "Synthetic Patient"], "page layout")
// Several paragraphs of the body are written last first.
let order = PagesDocumentFill.edits(body: "\u{ab}name\u{bb}\nx\n\u{ab}patientID\u{bb}", items: [], substitute: substitute)
check(order == ["p", "0", "3", "00123", "p", "0", "1", "Synthetic Patient"], "last first")
// An answer that is not what the script returns is refused rather than guessed at.
check(PagesDocumentFill.document(from: list([text("DOC-1"), text("")])) == nil, "short answer")
check(PagesDocumentFill.document(from: list([text(""), text(""), list([])])) == nil, "no id")
check(PagesDocumentFill.document(from: list([text("D"), text(""), list([list([text("chart"), text("1"), text("")])])])) == nil,
      "unknown kind")
// A location that is not a path of positive indices would address the wrong item.
for bad in ["", "0", "1.", ".1", "1..2", "1.0", "a", "1.-2", "\u{661}"] {
    check(PagesDocumentFill.document(from: list([text("D"), text(""), list([list([text("text"), text(bad), text("x")])])])) == nil,
          "bad location '\(bad)'")
}
check(PagesDocumentFill.document(from: list([text("D"), text(""), list([])]))?.2 == [], "no items")
print("PASS: placeholders in text boxes, shapes, table cells and groups are planned with the body's; paragraphs holding an anchored object are left alone; no line break is added")
'''
with tempfile.TemporaryDirectory(prefix='horos-pages-fields-') as folder:
    p = Path(folder)
    (p / 'main.swift').write_text(program)
    built = subprocess.run(['xcrun', 'swiftc', '-sanitize=address',
                            str(root / 'Horos/Sources/PagesDocumentFill.swift'),
                            str(root / 'Horos/Sources/PagesApplication.swift'),
                            str(p / 'main.swift'), '-o', str(p / 'test')])
    if built.returncode:
        failures.append('the production PagesDocumentFill did not compile')
    elif subprocess.run([str(p / 'test')]).returncode:
        failures.append('the planned edits are wrong')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a Pages report reaches text boxes, shapes, table cells and groups as well as the body')
