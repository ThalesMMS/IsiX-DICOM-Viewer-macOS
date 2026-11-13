#!/usr/bin/env python3
"""Pages is found by more than the one bundle identifier it used to have.

`Reports` asked `NSWorkspace` for `com.apple.iWork.Pages`, which is what Pages
'09 answered to. Measured on a machine with Pages 15.3.1 installed and signed by
Apple:

    com.apple.iWork.Pages: nil
    com.apple.Pages: /Applications/Pages.app
    apps that open a .pages document: Pages.app

so every Pages report ended at "Pages is not installed or could not be located"
with Pages in the Applications folder.

The lookup asks for both identifiers and then for whatever is registered to open
a Pages document - and takes that one only if it is Apple's, because everything
Horos does with the file afterwards is Pages and nothing else.

`com.apple.iWork.Pages` is every Pages of the Mac up to 14, and `com.apple.Pages`
the application that came after it, so a Mac can have both. The current one is
asked for first, and the answer says where Pages is and what it is addressed by
together: a report opened in one Pages and a script sent to the other is a
second Automation permission and a document the script never finds. The order is
checked here with applications that are only folders, through the lookup's own
seam, because no Mac at hand has two Pages.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
from sources import source_text

root = Path(__file__).resolve().parents[1]
failures = []

# Reports is Swift.
reports = source_text('Reports')
if 'URLForApplicationWithBundleIdentifier:@"com.apple.iWork.Pages"' in reports or \
        'urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages"' in reports:
    failures.append('Pages is still looked up by one identifier only')
if 'PagesApplication.url()' not in reports:
    failures.append('the report generator does not use the shared lookup')
if 'PagesApplication.information()' not in reports:
    failures.append('the version that decides where templates live is not read through it')
# A report that already exists is reopened through the same lookup: opened in
# the user's default application, a Pages report could be in another Pages
# than the one its PDF is asked of.
study_reports = (root / 'Horos/Sources/StudyReports.swift').read_text()
if 'NSWorkspace.shared.openReport(atPath: file)' not in study_reports \
        or 'NSWorkspace.shared.open(URL(fileURLWithPath: file))' in study_reports:
    failures.append('an existing report is not reopened through the Pages lookup')

lookup = (root / 'Horos/Sources/PagesApplication.swift').read_text()
for identifier in ('com.apple.iWork.Pages', 'com.apple.Pages'):
    if identifier not in lookup:
        failures.append('%s is not among the identifiers asked for' % identifier)
if 'com.apple.iwork.pages.pages' not in lookup:
    failures.append('the document type is not used as the last resort')
if 'hasPrefix("com.apple.")' not in lookup:
    failures.append("an application that is not Apple's could be driven as though it were Pages")
# Each lookup asks LaunchServices; the browser asks after every import. The
# answer is kept, and forgotten when an application launches or quits.
if 'answer.withLock' not in lookup or 'didLaunchApplicationNotification' not in lookup \
        or 'didTerminateApplicationNotification' not in lookup:
    failures.append('Pages is looked up again at every call, or its kept answer is never forgotten')

source = r'''
import AppKit
import UniformTypeIdentifiers

// What this machine answers, which is the measurement the fix was made from.
let workspace = NSWorkspace.shared
let old = workspace.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages")
let new = workspace.urlForApplication(withBundleIdentifier: "com.apple.Pages")
print("com.apple.iWork.Pages: \(old?.lastPathComponent ?? "nil")")
print("com.apple.Pages:       \(new?.lastPathComponent ?? "nil")")

let found = PagesApplication.url()
print("the lookup answers:    \(found?.lastPathComponent ?? "nil")")
// The answer is kept, and asked again once an application launches or quits.
precondition(PagesApplication.url() == found, "the kept answer differs from the lookup")
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: workspace)
precondition(PagesApplication.url() == found, "the answer asked again differs")

// Where Pages is and what it is addressed by are one answer.
let target = PagesApplication.target()
precondition(target?.url == found, "the target is not the application the lookup answers with")
if let target {
    precondition(Bundle(url: target.url)?.bundleIdentifier == target.identifier,
                 "Pages would be addressed as \(target.identifier), which is not the application found")
    precondition(target.script("tell application id \"__PAGES_BUNDLE_ID__\"") == "tell application id \"\(target.identifier)\"")
}

// The order, with applications that are only a folder and an Info.plist: they
// are not registered anywhere and nothing starts them.
let stand = FileManager.default.temporaryDirectory.appendingPathComponent("pages-lookup-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: stand) }
func application(_ name: String, _ identifier: String) -> URL {
    let url = stand.appendingPathComponent("\(name).app")
    let contents = url.appendingPathComponent("Contents")
    try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let information: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
    try! PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    return url
}
let current = application("current", "com.apple.Pages")
let older = application("older", "com.apple.iWork.Pages")
typealias Target = PagesApplication.Target
var asked: [String] = []
func lookUp(_ installed: [String: URL], registered: URL? = nil) -> Target? {
    asked = []
    return PagesApplication.lookUp(installed: { asked.append($0); return installed[$0] }, registered: { registered })
}
precondition(lookUp(["com.apple.Pages": current, "com.apple.iWork.Pages": older], registered: older)
             == Target(url: current, identifier: "com.apple.Pages"), "with both installed the current Pages is not the answer")
precondition(asked == ["com.apple.Pages"], "the older identifier was asked for with the current one installed")
precondition(lookUp(["com.apple.iWork.Pages": older]) == Target(url: older, identifier: "com.apple.iWork.Pages"),
             "a Mac with only the older Pages does not address it by its own identifier")
precondition(asked == ["com.apple.Pages", "com.apple.iWork.Pages"], "the identifiers are not asked for current first")
precondition(lookUp(["com.apple.Pages": current]) == Target(url: current, identifier: "com.apple.Pages"))
// Neither identifier: what is registered for the document, when it is Apple's,
// addressed by the identifier it has.
let later = application("later", "com.apple.later.Pages")
precondition(lookUp([:], registered: later) == Target(url: later, identifier: "com.apple.later.Pages"),
             "an Apple application registered for the document is not addressed by its own identifier")
precondition(lookUp([:], registered: application("editor", "org.example.editor")) == nil, "another vendor's editor was taken for Pages")
// The identifier is written into script source: one that is not an identifier is no answer.
precondition(lookUp([:], registered: application("quoted", "com.apple.x\" & (do shell script \"true\") & \"")) == nil,
             "an identifier that is not one would be written into a script")
precondition(lookUp([:], registered: stand.appendingPathComponent("missing.app")) == nil)
precondition(lookUp([:]) == nil, "no Pages anywhere is not nil")

// A report that already exists: a Pages document goes to the Pages found, and
// anything else, or a Pages document with no Pages, to the user's own choice.
let pagesFound = Target(url: older, identifier: "com.apple.iWork.Pages")
precondition(PagesApplication.application(forReportAt: "/reports/A B-1.pages", pages: pagesFound) == older)
precondition(PagesApplication.application(forReportAt: "/reports/A.PAGES", pages: pagesFound) == older)
for other in ["/reports/A.docx", "/reports/A.doc", "/reports/A.rtf", "/reports/A.odt", "/reports/A.pdf", "/reports/A", "/reports/pages"] {
    precondition(PagesApplication.application(forReportAt: other, pages: pagesFound) == nil, "\(other) would be opened in Pages")
}
precondition(PagesApplication.application(forReportAt: "/reports/A.pages", pages: nil) == nil)
precondition(PagesApplication.application(forReportAt: "/reports/A.pages") == found, "a Pages report is not reopened in the Pages found")
print("PASS: the current Pages is asked for first, and each answer is addressed by its own identifier")

// Whatever this machine has, the lookup must not answer with less than the two
// identifiers do, and must not answer with something that is not Apple's.
if old != nil || new != nil {
    precondition(found != nil, "Pages is installed and the lookup did not find it")
}
if let found {
    let bundle = Bundle(url: found)
    precondition(bundle?.bundleIdentifier?.hasPrefix("com.apple.") == true,
                 "the lookup answered with \(bundle?.bundleIdentifier ?? "an unsigned bundle")")
    let information = PagesApplication.information()
    precondition(information?["CFBundleIdentifier"] as? String == bundle?.bundleIdentifier)
    print("its identifier:        \(bundle?.bundleIdentifier ?? "?")")
    print("its version:           \((information?["CFBundleShortVersionString"] as? String) ?? "?")")
} else {
    print("Pages is not installed here; the lookup answering nil is the right answer")
}
print("PASS")

// Workspace migration: no real editor is opened. Missing source/application
// must fail exactly once, including paths with spaces and Unicode.
precondition(!workspace.openDocument(atPath: "/missing Horos relatório.pages", applicationURLs: [], completion: { precondition(!$0) }))
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let document = directory.appendingPathComponent("relatório com espaços.rtf")
let wrapper = FileWrapper(regularFileWithContents: Data("synthetic recipient-free attachment".utf8))
wrapper.preferredFilename = document.lastPathComponent
try wrapper.write(to: document, options: [], originalContentsURL: nil)
let written = try Data(contentsOf: document)
precondition(written == wrapper.regularFileContents)
precondition(wrapper.preferredFilename == document.lastPathComponent)
var callbacks = 0
precondition(!workspace.openDocument(atPath: document.path, applicationIdentifiers: ["org.horos.missing-application-test"]) { opened in
    precondition(!opened)
    callbacks += 1
})
precondition(callbacks == 1)
precondition(FileManager.default.fileExists(atPath: document.path))
let launchFinished = DispatchSemaphore(value: 0)
precondition(workspace.openDocument(atPath: document.path, applicationURLs: [
    directory.appendingPathComponent("missing editor one.app"),
    directory.appendingPathComponent("missing editor two.app")
]) { opened in
    precondition(!opened)
    launchFinished.signal()
})
precondition(launchFinished.wait(timeout: .now() + 10) == .success)
precondition(launchFinished.wait(timeout: .now()) == .timedOut, "completion exactly once after fallback")
precondition(FileManager.default.fileExists(atPath: document.path))
precondition(workspace.icon(for: .plainText).size.width > 0)
precondition(workspace.icon(for: UTType(filenameExtension: "download") ?? .data).size.width > 0)
// Enumeration retains URL paths and the distinct unmountable query used by
// removable writing destinations, without launching or mounting anything.
for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey, .volumeIsReadOnlyKey], options: []) ?? [] {
    var isUnmountable: ObjCBool = false
    workspace.getFileSystemInfo(forPath: volume.path, isRemovable: nil, isWritable: nil,
                                isUnmountable: &isUnmountable, description: nil, type: nil)
    precondition(volume.isFileURL && !volume.path.isEmpty)
}
print("PASS: missing editor/source; Unicode/spaces and FileWrapper bytes/name preserved")
'''
with tempfile.TemporaryDirectory(prefix='horos-pages-lookup-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/PagesApplication.swift'),
                    str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: Pages is looked up by both identifiers, the current one first, and by the document '
      "type; only Apple's own is accepted, and the answer carries the identifier it is addressed by")
