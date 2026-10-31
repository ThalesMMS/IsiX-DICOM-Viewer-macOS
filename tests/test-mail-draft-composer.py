#!/usr/bin/env python3
"""Compile the Mail draft composer and exercise consent, arguments and handler errors.

The viewer's JPEG/Mail export (-endExportImage:) is Swift
(ViewerImageExporter.swift): its call is checked there, in Swift spelling
(HorosMailDraftComposer is MailDraftComposer in Swift). The browser's
-sendMail: is Swift too: BrowserController+Mail.swift hands it to MailExport.swift.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
viewer = (((root / 'Horos/Sources/ViewerController.m').read_text(encoding='latin1')) if (root / 'Horos/Sources/ViewerController.m').exists() else '')
viewer_export = sources.source_text('ViewerImageExporter')
browser = sources.source_text('MailExport')
assert 'MailExport(browser: self).sendSelection()' in sources.source_text('BrowserController+Mail')
script = (root / 'Horos/Resources/Mail.applescript').read_text()
assert 'MailDraftComposer.compose(' in viewer_export and 'MailDraftComposer.compose(' in browser
# The viewer's JPEG draft is titled by the composer's own localized subject.
assert ('MailDraftComposer.compose(subject: MailDraftComposer.viewerImagesSubject, filePaths: mailFilePaths, '
        'completion: { mailError in') in viewer_export
assert 'compose(subject: "' not in viewer_export
# The browser's draft is titled by the composer's localized subject, never a
# literal such as "subject", and never with names of the export (the subject
# travels in clear text; patient and study names stay inside the encrypted ZIP).
assert ('MailDraftComposer.compose(subject: MailDraftComposer.protectedArchiveSubject, filePaths: mailFilePaths,\n'
        '                                  removingFolder: folder) { mailError in') in browser
assert 'compose(subject: "' not in browser
# The export's folder (copies of the images and the archive) is made and
# removed by the composer: it goes once Mail answered, and the export clears
# what an earlier session left.
assert 'folder = try MailDraftComposer.ExportFolder.make()' in browser
assert 'MailDraftComposer.ExportFolder.removeLeftovers()' in browser
assert '"horos-mail-' not in browser
# The ZIP password stays in memory: the sheet's field is a secure field with
# no binding, read only from the field, and nothing writes the
# defaultZIPPasswordForEmail preference, which the export clears.
assert 'view as? NSSecureTextField' in browser and 'field?.stringValue ?? ""' in browser
assert 'preferences.remove(ApplicationPreferences.emailZIPPassword)' in browser
assert 'preferences[ApplicationPreferences.emailZIPPassword]' not in browser
assert 'set(' not in ''.join(line for line in browser.splitlines() if 'emailZIPPassword' in line)
nibs = sorted((root / 'Horos/Resources').glob('*.lproj/MainMenu.xib'))
assert len(nibs) == 12, nibs
fields = set()
for nib in nibs:
    text = nib.read_text(encoding='utf-8')
    assert 'defaultZIPPasswordForEmail' not in text, nib
    window = text.index('<outlet property="ZIPpasswordWindow" destination="')
    window_id = text[window:].split('destination="', 1)[1].split('"', 1)[0]
    start = text.index('<window ', text.index('id="%s"' % window_id) - 600)
    sheet = text[start:text.index('</window>', start)]
    assert 'id="%s"' % window_id in sheet[:sheet.index('>')], nib
    editable = [chunk for chunk in sheet.split('<')[1:] if 'editable="YES"' in chunk]
    assert len(editable) == 1 and editable[0].startswith('secureTextFieldCell '), (nib, editable)
    field = sheet[sheet.rindex('<secureTextField ', 0, sheet.index('<secureTextFieldCell ')):sheet.index('</secureTextField>') + len('</secureTextField>')]
    assert '<binding' not in field, nib
    fields.add(field)
assert len(fields) == 1, 'the password field differs between localizations'
SUBJECTS = {'IsiX DICOM Viewer: images in a password-protected ZIP': 'ZIP',
            'IsiX DICOM Viewer: images exported as JPEG': 'JPEG'}
composer = (root / 'Horos/Sources/MailDraftComposer.swift').read_text()
for subject, kind in SUBJECTS.items():
    assert 'NSLocalizedString("%s", comment:' % subject in composer
    for strings in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
        language = strings.parent.name[:-len('.lproj')]
        entries = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(strings)]))
        if language == 'en':
            assert entries.get(subject, subject) == subject, language
            continue
        value = entries.get(subject)
        assert value and value != subject, '%s: no translated subject' % language
        # A subject travels in clear text: no format argument for patient or study data.
        assert value.startswith('IsiX DICOM Viewer') and kind in value and '%' not in value, (language, value)
assert ('defaultaddress@mac.com' not in viewer and 'defaultaddress@mac.com' not in viewer_export
        and 'defaultaddress@mac.com' not in browser)
assert 'tell application "Finder"' not in script
assert ' send ' not in script.lower()
harness = r'''
import Foundation
import AppKit

func fail(_ code: Int32) -> Never { exit(code) }

let denied = MailDraftComposer.message(errorInfo: [NSAppleScript.errorNumber: -1743], result: nil) ?? ""
if !denied.contains("Automation") || !denied.contains("denied") { fail(1) }
let timeout = MailDraftComposer.message(errorInfo: [NSAppleScript.errorNumber: -1712], result: nil) ?? ""
if !timeout.contains("1712") || !timeout.contains("Automation") || !timeout.contains("incomplete") { fail(2) }
if MailDraftComposer.message(errorInfo: nil, result: NSAppleEventDescriptor(int32: 0)) != nil { fail(3) }
if MailDraftComposer.message(errorInfo: nil, result: nil) == nil { fail(4) }

let subject = MailDraftComposer.protectedArchiveSubject
if subject != "IsiX DICOM Viewer: images in a password-protected ZIP" { fail(14) }
if MailDraftComposer.viewerImagesSubject != "IsiX DICOM Viewer: images exported as JPEG" { fail(15) }
if MailDraftComposer.arguments(subject: MailDraftComposer.viewerImagesSubject, filePaths: ["/tmp/0001.jpg"])
    .atIndex(1)?.stringValue != "IsiX DICOM Viewer: images exported as JPEG" { fail(16) }

// Folders an earlier session left: only export folders (horos-mail-<UUID>,
// real directories) untouched for the given age go.
let temporary = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
let sweep = temporary.appendingPathComponent("sweep", isDirectory: true)
try! FileManager.default.createDirectory(at: sweep, withIntermediateDirectories: false)
let hourAgo = Date(timeIntervalSinceNow: -7200)
func age(_ url: URL) { try! FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: url.path) }
let stale = try! MailDraftComposer.ExportFolder.make(in: sweep)
try! Data("synthetic image".utf8).write(to: stale.appendingPathComponent("0001.dcm"))
age(stale)
let recent = try! MailDraftComposer.ExportFolder.make(in: sweep)
let notes = sweep.appendingPathComponent("horos-mail-notes", isDirectory: true)
try! FileManager.default.createDirectory(at: notes, withIntermediateDirectories: false)
age(notes)
let plainFile = sweep.appendingPathComponent("horos-mail-" + UUID().uuidString)
try! Data("not a folder".utf8).write(to: plainFile)
age(plainFile)
let target = temporary.appendingPathComponent("link-target", isDirectory: true)
try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
age(target)
let link = sweep.appendingPathComponent("horos-mail-" + UUID().uuidString)
try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
let removed = MailDraftComposer.ExportFolder.removeLeftovers(in: sweep, olderThan: 3600)
if removed.map(\.lastPathComponent) != [stale.lastPathComponent] { fail(17) }
for kept in [recent, notes, plainFile, link, target] where !FileManager.default.fileExists(atPath: kept.path) { fail(18) }
let permissions = (try! FileManager.default.attributesOfItem(atPath: recent.path)[.posixPermissions] as! NSNumber).intValue
if permissions != 0o700 || !recent.lastPathComponent.hasPrefix("horos-mail-") { fail(19) }
let arguments = MailDraftComposer.arguments(subject: subject, filePaths: ["/tmp/0002.jpg", "/tmp/0001.jpg"])
if arguments.atIndex(1)?.stringValue != subject { fail(5) }
if arguments.atIndex(2)?.stringValue != "" { fail(6) }
if arguments.atIndex(3)?.int32Value != 2 { fail(7) }
if arguments.atIndex(4)?.atIndex(1)?.stringValue?.hasSuffix("0002.jpg") != true { fail(8) }
if arguments.atIndex(4)?.atIndex(2)?.stringValue?.hasSuffix("0001.jpg") != true { fail(9) }

let missing = MailDraftComposer.compose(
    subject: "subject",
    filePaths: ["/missing-horos-mail-attachment.jpg"],
    scriptURL: nil,
    injectedConsent: NSNumber(value: 0)
) ?? ""
if !missing.contains("missing") || missing.localizedCaseInsensitiveContains("sent") == false { fail(10) }

let denial = MailDraftComposer.compose(
    subject: "subject",
    filePaths: [],
    scriptURL: URL(fileURLWithPath: "/tmp/unused.scpt"),
    injectedConsent: NSNumber(value: -1743)
) ?? ""
if !denial.contains("Automation") || !denial.contains("denied") { fail(11) }

let timeoutConsent = MailDraftComposer.compose(
    subject: "subject",
    filePaths: [],
    scriptURL: URL(fileURLWithPath: CommandLine.arguments[1]),
    injectedConsent: NSNumber(value: 0)
)
// The injected script returns success without talking to Mail.
if timeoutConsent != nil { fail(12) }

let failed = MailDraftComposer.compose(
    subject: "subject",
    filePaths: [],
    scriptURL: URL(fileURLWithPath: CommandLine.arguments[2]),
    injectedConsent: NSNumber(value: 0)
) ?? ""
if !failed.contains("1712") || !failed.contains("Automation") { fail(13) }

precondition(MailDraftComposer.checkWithoutPrompt {
    precondition(!Thread.isMainThread)
    return -1743
} == -1743)
let releaseSlowCheck = DispatchSemaphore(value: 0)
precondition(MailDraftComposer.checkWithoutPrompt(timeout: .milliseconds(25)) {
    releaseSlowCheck.wait()
    return 0
} == -1712)
releaseSlowCheck.signal()

@MainActor func settle(until condition: () -> Bool) async {
    for _ in 0..<300 {
        if condition() { return }
        try! await Task.sleep(nanoseconds: 10_000_000)
    }
    preconditionFailure("asynchronous Mail composition did not complete")
}
var asynchronousTestsFinished = false
Task { @MainActor in
    let started = DispatchSemaphore(value: 0)
    let respond = DispatchSemaphore(value: 0)
    var completed = false, heartbeat = false, calls = 0
    MailDraftComposer.compose(subject: "subject", filePaths: [], scriptURL: nil, using: {
        precondition(!Thread.isMainThread)
        started.signal()
        respond.wait()
        return -1743
    }) { error in
        precondition(Thread.isMainThread && error?.contains("denied") == true)
        calls += 1; completed = true
    }
    DispatchQueue.main.async { heartbeat = true }
    await settle { heartbeat && started.wait(timeout: .now()) == .success }
    precondition(!completed)
    MailDraftComposer.compose(subject: "subject", filePaths: [], scriptURL: nil, using: {
        fatalError("duplicate composition must not start another permission request")
    }) { error in precondition(error?.contains("already pending") == true) }
    respond.signal()
    await settle { completed }
    precondition(calls == 1)

    completed = false
    MailDraftComposer.compose(subject: "subject", filePaths: [],
        scriptURL: URL(fileURLWithPath: CommandLine.arguments[1]), using: { 0 }) { error in
        precondition(Thread.isMainThread && error == nil)
        calls += 1; completed = true
    }
    await settle { completed }
    precondition(calls == 2)

    // A selection/export may disappear while a person considers permission.
    // Never call the Mail handler with attachments that vanished in that time.
    let attachment = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
        .appendingPathComponent("transient.jpg")
    try! Data("synthetic attachment".utf8).write(to: attachment)
    completed = false
    MailDraftComposer.compose(subject: "subject", filePaths: [attachment.path],
        scriptURL: URL(fileURLWithPath: CommandLine.arguments[1]), using: {
        precondition(!Thread.isMainThread)
        started.signal()
        respond.wait()
        return 0
    }) { error in
        precondition(Thread.isMainThread && error?.contains("missing") == true)
        completed = true
    }
    await settle { started.wait(timeout: .now()) == .success }
    try! FileManager.default.removeItem(at: attachment)
    respond.signal()
    await settle { completed }

    // The export's folder goes once Mail answered: the handler still found
    // each attachment in it while it made the draft (the successful script
    // fails on a missing file), and nothing of it is left afterwards.
    let exportFolder = try! MailDraftComposer.ExportFolder.make(in: temporary)
    let archive = exportFolder.appendingPathComponent("Images-synthetic.zip")
    try! Data("synthetic archive".utf8).write(to: archive)
    completed = false
    MailDraftComposer.compose(subject: subject, filePaths: [archive.path],
        scriptURL: URL(fileURLWithPath: CommandLine.arguments[1]), removingFolder: exportFolder, using: { 0 }) { error in
        precondition(Thread.isMainThread && error == nil, error ?? "")
        precondition(!FileManager.default.fileExists(atPath: exportFolder.path))
        completed = true
    }
    await settle { completed }

    // After an error too: a draft that failed leaves no copy of the images.
    let failedFolder = try! MailDraftComposer.ExportFolder.make(in: temporary)
    let failedArchive = failedFolder.appendingPathComponent("Images-synthetic.zip")
    try! Data("synthetic archive".utf8).write(to: failedArchive)
    completed = false
    MailDraftComposer.compose(subject: subject, filePaths: [failedArchive.path],
        scriptURL: URL(fileURLWithPath: CommandLine.arguments[2]), removingFolder: failedFolder, using: { 0 }) { error in
        precondition(error?.contains("1712") == true)
        precondition(!FileManager.default.fileExists(atPath: failedFolder.path))
        completed = true
    }
    await settle { completed }
    asynchronousTestsFinished = true
}
let deadline = Date(timeIntervalSinceNow: 10)
while !asynchronousTestsFinished && Date() < deadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
}
precondition(asynchronousTestsFinished)
fputs("PASS: localized subjects, export folder removed after the draft and after an error, leftovers swept, recipient-free handler, errors, off-main consent, responsive main queue, duplicate guard, refusal/retry, bounded legacy check and expired attachments\n", stdout)
'''

denied_script = '''
on mail_images(email_subject, default_address, image_count, new_files, new_captions, new_comments, cancel_string)
	error "Synthetic timeout" number -1712
end mail_images
'''
successful_script = '''
on mail_images(email_subject, default_address, image_count, new_files, new_captions, new_comments, cancel_string)
	if default_address is not "" then error "recipient was supplied" number 1
	repeat with new_file in new_files
		do shell script "test -f " & quoted form of (new_file as text)
	end repeat
	return 0
end mail_images
'''

with tempfile.TemporaryDirectory(prefix='horos-mail-composer-') as folder:
    path = Path(folder)
    (path / 'main.swift').write_text(harness)
    (path / 'successful.applescript').write_text(successful_script)
    (path / 'timeout.applescript').write_text(denied_script)
    subprocess.run(['osacompile', '-o', str(path / 'successful.scpt'), str(path / 'successful.applescript')], check=True)
    subprocess.run(['osacompile', '-o', str(path / 'timeout.scpt'), str(path / 'timeout.applescript')], check=True)
    compiled = subprocess.run(
        ['xcrun', '--sdk', 'macosx', 'swiftc', '-sanitize=address',
         str(root / 'Horos/Sources/MailDraftComposer.swift'), str(path / 'main.swift'),
         '-o', str(path / 'test')],
        capture_output=True, text=True)
    if compiled.returncode != 0:
        raise SystemExit(compiled.stderr or compiled.stdout)
    subprocess.run([str(path / 'test'), str(path / 'successful.scpt'), str(path / 'timeout.scpt')], check=True)
