#!/usr/bin/env python3
"""Host contract for Word report merge — mock/compilation, not native Word.

The Word merge's remaining acceptance is a real merge in Microsoft Word. This file
does not launch Word, send mail, or write a .doc. It checks that the already-
shipped host still: resolves .doc/.docx by exact name, prepares on a private
copy, publishes only a regular non-empty file, and on AppleScript failure closes
only the merge documents it opened.
"""
from pathlib import Path
import argparse
import subprocess
import sys
import tempfile
from sources import source_path

root = Path(__file__).resolve().parents[1]
failures = []

parser = argparse.ArgumentParser(description=__doc__)
# Reports is Swift; an alternate source is a Reports.swift too.
parser.add_argument('--reports-source', type=Path, default=source_path('Reports'),
                    help='alternate revision of Reports.swift for a before/after regression check')
reports = parser.parse_args().reports_source.read_bytes().decode('utf-8')
replacement = (root / 'Horos/Sources/HorosReportFileReplacement.h').read_text()
placement = (root / 'Horos/Sources/ReportImagePlacement.swift').read_text()
conversion = (root / 'Horos/Sources/PagesPDFConversion.swift').read_text()

source = reports
if 'createNewWordReportForStudy:' not in source:
    failures.append('createNewWordReportForStudy: is missing')
    print('FAIL:\n- ' + '\n- '.join(failures))
    sys.exit(1)

for needle, reason in (
    ('HorosCreateReportFromTemplate', 'the merge still prepares a private copy before publishing'),
    (r'tell application \"Microsoft Word\"', 'the merge still talks to Word'),
    ('on error errorMessage number errorNumber', 'a refused merge must keep the AppleScript number'),
    # Both documents are closed through the helper now: Word rejects a command
    # sent to a stored `active document`, and the variables the old handler
    # tested were undefined whenever `open` was the statement that failed.
    ('my closeReportDocument(mergedName)', 'a failed merge must close the merged document'),
    ('my closeReportDocument(templateName)', 'a failed merge must close the template window'),
    ('on closeReportDocument(theName)', 'the handler that closes the documents is missing'),
    ('The merge did not create a new document.', 'a merge that edited the template in place is a failure'),
    ('hasPrefix("doc")', 'exact .doc/.docx names must still resolve'),
):
    if needle not in source:
        failures.append(reason)

templates = reports[reports.find('class func databaseWordTemplatesDirPath()'):]
templates = templates[:templates.find('class func resolvedDatabaseWordTemplatesDirPath()')]
if 'must never be removed' not in templates and 'never be removed' not in templates:
    failures.append('creating WORD TEMPLATES must not delete a colliding file')
if 'createDirectory(atPath: folder' not in templates:
    failures.append('WORD TEMPLATES is no longer created without deleting a collision')

if 'HorosCreateReportFromTemplate' not in replacement:
    failures.append('HorosCreateReportFromTemplate is missing')

# Image insertion and Pages→PDF stay on their own types.
if 'PagesPDFConversion' in placement:
    failures.append('image insertion was mixed into the Pages PDF converter')
if 'insertSelectedImagesIntoReport' in conversion or 'HorosReportImageInsertion' in conversion:
    failures.append('Pages PDF conversion now inserts report images')
if 'createNewWordReportForStudy' in placement:
    failures.append('image insertion absorbed the Word merge')

if failures:
    print('FAIL:\n- ' + '\n- '.join(failures))
    sys.exit(1)
print('PASS: Word merge host still prepares privately, closes only its windows on error, '
      'and stays off the Pages PDF and image-insertion types')

# Execute the production creation method with an editor substitute. In
# particular, refusing consent must happen before opening/preparing a document,
# not merely before publishing its bytes or its study association.
start = reports.rindex('@objc(createNewWordReportForStudy:toDestinationPath:)')
method = reports[start:reports.index('\n    // MARK: -\n    // MARK: OpenDocument', start)]
# The file-level helpers the method calls (reportingError and the others).
prelude = reports[reports.index('/// What `%@` prints'):reports.index('/** \\brief reports */')]
bridge = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
#import "HorosReportFileReplacement.h"
'''
program = r'''
import Foundation
typealias NSManagedObject = NSMutableDictionary
var templates = "", alert: String? = nil
var consentStatus = 0
var consentChecks = 0, dataWrites = 0, scripts = 0, launches = 0
var cancelMerge = false, missingConfirmation = false
enum HorosAlertPanel {
    static func runCritical(title: String?, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        alert = message
        return 0
    }
}
enum WordReportAutomation {
    static func consentErrorWithoutPrompt() -> NSError? {
        consentChecks += 1
        return consentStatus != 0 ? NSError(domain: "ControlledConsent", code: consentStatus,
            userInfo: [NSLocalizedDescriptionKey: "Controlled refusal"]) : nil
    }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    func openDocument(atPath path: String, applicationIdentifiers: [String]) -> Bool { precondition(applicationIdentifiers == ["com.microsoft.Word"]); launches += 1; return true }
}
PRELUDE
final class Reports: NSObject {
    let templateNameStorage = NSMutableString(string: "")
    class func wordTemplatesList() -> NSMutableArray! { NSMutableArray(array: ["Synthetic.docx"]) }
    class func resolvedDatabaseWordTemplatesDirPath() -> String! { templates }
    class func _runAppleScript(_ source: String!, withArguments args: NSArray!) -> Any! {
        scripts += 1
        let arguments = args as! [String]
        precondition(arguments[2].hasSuffix("-template.docx") && arguments[2].contains("horos-report-template-"), "unique private template")
        precondition((try? FileManager.default.attributesOfItem(atPath: arguments[2]))?[.type] as? String == FileAttributeType.typeRegular.rawValue, "template exists")
        precondition(arguments[1].hasSuffix("-merged.docx") && arguments[1].contains("horos-report-template-"), "unique private output")
        precondition(FileManager.default.contentsEqual(atPath: arguments[1], andPath: arguments[2]), "output exists before Word opens it")
        if missingConfirmation { return nil }
        precondition((try? "controlled merged bytes".write(toFile: arguments[1], atomically: true, encoding: .utf8)) != nil, "output")
        if cancelMerge { NSException(name: NSExceptionName("Controlled cancellation"), reason: "Cancelled (-128)", userInfo: nil).raise() }
        return NSNumber(value: true)
    }
    func generateWordReportMergeData(forStudy study: NSManagedObject!, toPath path: String!) -> String! { dataWrites += 1; return path }
METHOD
}
func check(_ value: Bool, _ what: String, line: Int = #line) { precondition(value, "failed: \(what) (line \(line))") }
let dir = CommandLine.arguments[1]
templates = (dir as NSString).appendingPathComponent("templates")
check((try? FileManager.default.createDirectory(atPath: templates, withIntermediateDirectories: true)) != nil, "templates")
let model = (templates as NSString).appendingPathComponent("Synthetic.docx")
let dest = (dir as NSString).appendingPathComponent("existing.docx")
let original = Data("original template".utf8), previous = Data("previous report".utf8)
check((try? original.write(to: URL(fileURLWithPath: model))) != nil && (try? previous.write(to: URL(fileURLWithPath: dest))) != nil, "fixtures")
let study = NSMutableDictionary(dictionary: ["reportURL": "previous association"])
let report = Reports()
for status in [-1743, -1744, -1712, -600] {
    consentStatus = status
    check(!report.createNewWordReport(forStudy: study, toDestinationPath: dest), "refused")
    check(dataWrites == 0 && scripts == 0 && launches == 0, "nothing prepared")
    check(alert == "Controlled refusal", "refusal shown")
    check(study["reportURL"] as? String == "previous association", "association kept")
    check(FileManager.default.contents(atPath: dest) == previous, "bytes kept")
}
check(consentChecks == 4, "four checks")
consentStatus = 0; cancelMerge = true
check(!report.createNewWordReport(forStudy: study, toDestinationPath: dest), "cancelled")
check(dataWrites == 1 && scripts == 1 && launches == 0 && alert?.contains("-128") == true, "cancellation reported")
check(study["reportURL"] as? String == "previous association", "association kept")
check(FileManager.default.contents(atPath: dest) == previous, "bytes kept")
cancelMerge = false; missingConfirmation = true
check(!report.createNewWordReport(forStudy: study, toDestinationPath: dest), "unconfirmed")
check(dataWrites == 2 && scripts == 2 && launches == 0, "unconfirmed counts")
check(study["reportURL"] as? String == "previous association", "association kept")
check(FileManager.default.contents(atPath: dest) == previous, "bytes kept")
missingConfirmation = false
check(report.createNewWordReport(forStudy: study, toDestinationPath: dest), "created")
check(dataWrites == 3 && scripts == 3 && launches == 1, "created counts")
check(study["reportURL"] as? String == dest, "association")
check((try? String(contentsOfFile: dest, encoding: .utf8)) == "controlled merged bytes", "published")
check(FileManager.default.contents(atPath: model) == original, "template untouched")
print("PASS: production Word creation refuses before preparing/opening, preserves prior bytes/association on cancellation, publishes on controlled success")
'''.replace('METHOD', method).replace('PRELUDE', prelude)
swift = r'''
import Foundation
precondition(WordReportAutomation.error(forStatus: 0) == nil)
for status: Int32 in [-1743, -1744, -1712, -600] {
    let error = WordReportAutomation.error(forStatus: status)!
    precondition(error.code == Int(status))
    precondition(error.localizedDescription.contains(String(status)))
    precondition(error.localizedDescription.contains("No report document was opened or changed"))
    if status != -600 { precondition(error.localizedDescription.contains("System Settings")) }
}
print("PASS: production Swift consent errors preserve the native status and recovery text")
for status: Int32 in [0, -1743, -1744, -600] {
    let error = WordReportAutomation.checkWithoutPrompt {
        precondition(!Thread.isMainThread)
        return status
    }
    precondition(error?.code == (status == 0 ? nil : Int(status)))
}
let releaseSlowCheck = DispatchSemaphore(value: 0)
let timeoutError = WordReportAutomation.checkWithoutPrompt(timeout: .milliseconds(25)) {
    releaseSlowCheck.wait()
    return 0
}
precondition(timeoutError?.code == -1712)
releaseSlowCheck.signal()

func spin(until condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while Date() < deadline {
        if condition() { return }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    preconditionFailure("main-thread completion did not arrive")
}
@MainActor func settle(until condition: () -> Bool) async {
    for _ in 0..<300 {
        if condition() { return }
        try! await Task.sleep(nanoseconds: 10_000_000)
    }
    preconditionFailure("asynchronous consent did not complete")
}
var asynchronousTestsFinished = false
Task { @MainActor in
    let started = DispatchSemaphore(value: 0)
    let respond = DispatchSemaphore(value: 0)
    var completed = false, heartbeat = false, calls = 0
    WordReportAutomation.requestConsent(using: {
        precondition(!Thread.isMainThread)
        started.signal()
        respond.wait()
        return -1743
    }) { error in
        precondition(Thread.isMainThread && error?.code == -1743)
        calls += 1; completed = true
    }
    // The native API may take arbitrarily long. AppKit must still be able to
    // service events while that worker waits for the person's response.
    DispatchQueue.main.async { heartbeat = true }
    await settle { heartbeat && started.wait(timeout: .now()) == .success }
    precondition(!completed)
    WordReportAutomation.requestConsent(using: {
        fatalError("a second consent request must not create another blocked worker")
    }) { error in precondition(error?.code == 1) }
    respond.signal()
    await settle { completed }
    precondition(calls == 1)
    // A completed refusal releases the request slot so retry can succeed.
    completed = false
    WordReportAutomation.requestConsent(using: { 0 }) { error in
        precondition(Thread.isMainThread && error == nil)
        calls += 1; completed = true
    }
    await settle { completed }
    precondition(calls == 2)
    asynchronousTestsFinished = true
}
spin { asynchronousTestsFinished }
print("PASS: blocking consent stays off-main, main events run, duplicate requests are bounded, refusal/retry and synchronous timeout propagate")
'''
with tempfile.TemporaryDirectory(prefix='horos-word-host-') as folder:
    p = Path(folder)
    (p / 'bridge.h').write_text(bridge)
    (p / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fsanitize=address', '-I', str(root / 'Horos/Sources'), '-c',
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / 'exception.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-sanitize=address', '-import-objc-header', str(p / 'bridge.h'),
                    '-Xcc', '-I', '-Xcc', str(root / 'Horos/Sources'), str(p / 'main.swift'), str(p / 'exception.o'),
                    '-o', str(p / 'host')], check=True)
    subprocess.run([str(p / 'host'), str(p)], check=True)
    (p / 'main.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-sanitize=address',
                    str(root / 'Horos/Sources/WordReportAutomation.swift'), str(p / 'main.swift'),
                    '-o', str(p / 'consent')], check=True)
    subprocess.run([str(p / 'consent')], check=True)
