#!/usr/bin/env python3
"""Every script sent to Pages is addressed to the Pages the report is opened in.

A report was opened in the application `PagesApplication.url()` answered with,
and its PDF was exported by that one, but the scripts that fill in a modern
template and the ones that insert images said `tell application id
"com.apple.Pages"` whatever the lookup had found. The Mac has had two Pages:
`com.apple.iWork.Pages`, every version up to 14, and `com.apple.Pages`, the
application that came after it. They can be installed side by side, and then:

  * the copy of the template was opened in one Pages and the fill script asked
    the other for it, waited its thirty seconds and gave up - no report;
  * macOS grants Automation for a pair of applications, so the user was asked
    for a permission that System Settings already showed as granted: the one
    granted was for the other Pages.

On a Mac with only the older Pages the fixed identifier named nothing. Measured,
a script addressed to an identifier no installed application has does not
compile: -1728, "Can't get application id". The fill ended at "The Pages report
could not be created", and the image insertion at the message of -1728, which
is the one that says Microsoft Word is not installed.

The scripts name Pages as `PagesApplication.Target` says, and that is checked
here for the fill, the image insertion and the PDF conversion, for each
identifier a Target can carry. With Pages installed the fill and insertion
scripts are also compiled against it - compiled, never run: nothing is sent to
Pages, so nothing asks for Automation.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []

sources = {name: (root / 'Horos/Sources' / name).read_text() for name in (
    'PagesDocumentFill.swift', 'ReportImagePlacement.swift', 'PagesPDFConversion.swift')}
for name, text in sources.items():
    code = '\n'.join(line for line in text.split('\n') if not line.strip().startswith('//'))
    # In a multi-line literal the quote is bare; in a one-line literal it is escaped.
    if re.search(r'application id \\?"com\.apple', code):
        failures.append('%s addresses Pages by an identifier written into it' % name)
    if re.search(r'urlForApplication\(withBundleIdentifier: "com\.apple\.', code):
        failures.append('%s looks Pages up by itself' % name)
    if 'PagesApplication.target()' not in code:
        failures.append('%s does not ask which Pages the report is opened in' % name)
    if re.search(r'tell application "Pages"', code):
        failures.append('%s names Pages by a name, which two installed applications share' % name)

# The scripts that named Pages by its name - `tell application "Pages"`, which
# two installed applications answer to - are not run by anything and are not
# shipped: no file of them, and nothing in the project copies one.
shipped = sorted(path.name for path in (root / 'Horos/Resources/ReportsToPDF').glob('*.applescript'))
if shipped != ['word2pdf.applescript']:
    failures.append('the report scripts shipped are %s, not the one for Word alone' % shipped)
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
for name in ('pages2pdf.applescript', 'pages092pdf.applescript', 'pages2pages09.applescript'):
    if name in project:
        failures.append('the project still copies %s into the application' % name)
if 'ReportsToPDF/word2pdf.applescript' not in project:
    failures.append("the project no longer copies Word's script, which is used")
for path in (root / 'Horos/Resources').rglob('*.applescript'):
    if 'tell application "Pages"' in path.read_text(errors='replace'):
        failures.append('%s names Pages by its name' % path.relative_to(root))

program = r'''
import Foundation

func check(_ value: Bool, _ what: String, line: Int = #line) {
    if !value { print("FAIL: \(what) (line \(line))"); exit(1) }
}

/// The identifiers a source names an application by, in `application id "..."`.
func addressed(_ source: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: "application id \"([^\"]*)\"")
    let whole = NSRange(source.startIndex..., in: source)
    return pattern.matches(in: source, range: whole).map { String(source[Range($0.range(at: 1), in: source)!]) }
}

let image = ReportPreparedImage(path: "/nowhere/0001.jpg", widthPoints: 340, heightPoints: 170)

/// Every script the application sends to Pages, as it is for `pages`.
func scripts(for pages: PagesApplication.Target) -> [(String, String)] {
    [("fill: read", pages.script(PagesDocumentFill.readScript)),
     ("fill: write", pages.script(PagesDocumentFill.writeScript)),
     ("fill: close", pages.script(PagesDocumentFill.closeScript)),
     ("documents", pages.script(PagesApplication.Target.documentsScript)),
     ("images: first", ReportImageInsertion.pagesMeasureScript(document: "A-B-C", first: image, application: pages.identifier)),
     ("images: place", ReportImageInsertion.pagesPlaceScript(
         document: "A-B-C", images: [image, image],
         figures: ReportImagePlacement.figures(sizes: [CGSize(width: 340, height: 170), CGSize(width: 340, height: 170)],
                                               page: CGSize(width: 595, height: 842)),
         application: pages.identifier)),
     ("images: insert by name", ReportImageInsertion.pagesScript(documentName: "report.pages", images: [image],
                                                                 application: pages.identifier)),
     ("PDF: inventory", PagesPDFConversion.script(PagesPDFConversion.inventoryScriptSource, for: pages.identifier)),
     ("PDF: save", PagesPDFConversion.script(PagesPDFConversion.saveIfModifiedScriptSource, for: pages.identifier)),
     ("PDF: close", PagesPDFConversion.script(PagesPDFConversion.closeIfUnchangedScriptSource, for: pages.identifier)),
     ("PDF: export", PagesPDFConversion.exportScript(for: pages.identifier))]
}

// Whichever Pages the lookup answers with, every script names that one and no other.
for identifier in ["com.apple.Pages", "com.apple.iWork.Pages", "com.apple.later.Pages"] {
    let pages = PagesApplication.Target(url: URL(fileURLWithPath: "/nowhere/\(identifier).app"), identifier: identifier)
    for (name, source) in scripts(for: pages) {
        let named = addressed(source)
        check(!named.isEmpty, "\(name) names no application")
        check(named.allSatisfy { $0 == identifier }, "\(name) for \(identifier) addresses \(Set(named).sorted())")
        check(!source.contains("__PAGES_BUNDLE_ID__"), "\(name) still carries the placeholder")
    }
}
// The fill addresses Pages five times - twice in a handler of its own, which
// is outside the run handler's tell - and each is the target.
let older = PagesApplication.Target(url: URL(fileURLWithPath: "/nowhere/older.app"), identifier: "com.apple.iWork.Pages")
let fillTells = [PagesDocumentFill.readScript, PagesDocumentFill.writeScript, PagesDocumentFill.closeScript]
    .flatMap { addressed(older.script($0)) }
check(fillTells == Array(repeating: "com.apple.iWork.Pages", count: 5), "the fill names Pages \(fillTells)")

func compile(_ source: String) -> NSDictionary? {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return ["NSAppleScriptErrorMessage": "no script"] }
    return script.compileAndReturnError(&error) ? nil : (error ?? ["NSAppleScriptErrorMessage": "no error given"])
}

// What a fixed identifier did on a Mac where no application has it: the script
// does not compile, so nothing of it runs.
let nobody = PagesApplication.Target(url: URL(fileURLWithPath: "/nowhere/nobody.app"),
                                     identifier: "com.apple.Pages-that-no-application-answers-to")
for (name, source) in scripts(for: nobody).prefix(7) {
    let error = compile(source)
    check((error?[NSAppleScript.errorNumber] as? Int) == -1728,
          "\(name), addressed to an identifier nothing has, ended with \(error ?? [:]) and not -1728")
}

if let pages = PagesApplication.target() {
    // The script the Objective-C name builds is the installed Pages' too.
    let script = ReportImageInsertion.pagesScript(documentName: "report.pages", images: [image])
    check(addressed(script) == [pages.identifier], "the image insertion addresses \(addressed(script)), and Pages is \(pages.identifier)")
    // Compiled against the installed Pages, which is where its terminology
    // comes from. Compiling sends Pages nothing.
    for (name, source) in scripts(for: pages).prefix(7) {
        let error = compile(source)
        check(error == nil, "\(name) does not compile for \(pages.identifier): \(error ?? [:])")
    }
    print("PASS: the fill and image scripts compile for \(pages.identifier), the Pages at \(pages.url.path)")
} else {
    let script = ReportImageInsertion.pagesScript(documentName: "report.pages", images: [image])
    check(addressed(script) == ["com.apple.Pages"], "with no Pages the image script names \(addressed(script))")
    print("note: Pages is not installed; the fill and image scripts were not compiled against it")
}
print("PASS: every script names the Pages it is given, for each identifier Pages has")
'''

with tempfile.TemporaryDirectory(prefix='horos-pages-target-') as folder:
    p = Path(folder)
    (p / 'main.swift').write_text(program)
    built = subprocess.run(['xcrun', 'swiftc',
                            str(root / 'Horos/Sources/PagesApplication.swift'),
                            str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                            str(root / 'Horos/Sources/PagesDocumentFill.swift'),
                            str(root / 'Horos/Sources/ReportImagePlacement.swift'),
                            str(root / 'Horos/Sources/PagesPDFConversion.swift'),
                            str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if built.returncode:
        failures.append('the production sources did not compile:\n%s' % (built.stderr or built.stdout))
    else:
        ran = subprocess.run([str(p / 'test')], capture_output=True, text=True)
        sys.stdout.write(ran.stdout)
        if ran.returncode:
            failures.append('a script is addressed to another Pages than the one found:\n%s' % ran.stderr)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the fill, the image insertion and the PDF conversion address the one Pages the lookup found')
