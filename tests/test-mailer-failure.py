#!/usr/bin/env python3
"""A failed e-mail of a 3D or MPR window reaches the user, with a message for its cause.

Those windows e-mail their image through a script sent to Mail. When macOS
refuses the Apple Events, when Mail is not there or when Mail answers with an
error, the export used to end with a log line and nothing on screen.

Mailer.swift is compiled as it stands, with MailDraftComposer.swift, whose
texts for the errors of Mail it uses, and a stand-in of the one call that runs
a script, which answers the error the test gives it: no Apple Event leaves the
test. Through it:

1. the message of each error number is the one the drafts of the other
   exports show for it;
2. the error of the script comes back as a value, nil when the script ended
   well; Mail that is not installed is told before any script;
3. the former entry points answer as they did;
4. the entry of the windows shows the message in the exports' alert;
5. the script keeps to what Mail's access group for composing has (the
   outgoing message, its content and an attachment, and no `send`), and a
   quote or a backslash in the path stays inside the script's string;
6. the four windows end at that entry, and every catalog has the texts.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path, source_text  # noqa: E402

mailer = source_text('Mailer')

# --- 6. the callers and the catalogs ------------------------------------------
CALLERS = ('Window3DController', 'OrthogonalMPRViewer', 'OrthogonalMPRPETCTViewer', 'EndoscopyMPRView')
for caller in CALLERS:
    assert source_text(caller).count('email.mailShowingFailure(image: path)') == 1, caller
# No window calls the entry that answers YES whatever happened.
for path in sorted((root / 'Horos/Sources').glob('*.swift')):
    if path.name != 'Mailer.swift':
        assert not re.search(r'\.sendMail\("', path.read_text()), path.name

TEXTS = [
    'Email Export Failed',
    'Mail access was denied. Allow IsiX DICOM Viewer to control Mail in System Settings > Privacy & Security > Automation, then retry the export.',
    'IsiX DICOM Viewer could not finish creating the Mail draft (error %ld). Check Mail and any draft already opened before retrying; attachments may be incomplete.',
]
assert 'NSLocalizedString("Email Export Failed", comment: "")' in mailer
ARGUMENT = re.compile(r'%(?:ld|@)')
catalogs = sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings'))
assert len(catalogs) == 12, catalogs
for catalog in catalogs:
    language = catalog.parent.name[:-len('.lproj')]
    if language == 'en':
        continue
    entries = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(catalog)]))
    for text in TEXTS:
        value = entries.get(text)
        assert value and value != text, '%s: no translation of %r' % (language, text)
        assert ARGUMENT.findall(value) == ARGUMENT.findall(text), (language, text, value)

# --- 1 to 5. Mailer.swift, run ------------------------------------------------
STAND_IN = r'''import Foundation

/// What the script answers, and the scripts that were run.
final class ScriptAnswer {
    nonisolated(unsafe) static var error: NSDictionary?
    nonisolated(unsafe) static var sources: [String] = []
    nonisolated(unsafe) static var alerts: [String] = []
}

/// The application's alert: here it records the message it would show.
enum HorosAlertPanel {
    @MainActor static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) {
        ScriptAnswer.alerts.append(title + ": " + message)
    }
}

/// In the application this is NSAppleScript (N2), which sends the script its
/// open event; here it answers the error it is told and sends nothing.
extension NSAppleScript {
    @discardableResult
    func run(withArguments args: NSArray?, error errs: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) -> Any? {
        ScriptAnswer.sources.append(source ?? "")
        errs?.pointee = ScriptAnswer.error
        return nil
    }
}
'''

MAIN = r'''import Foundation

var failed = false
@MainActor func check(_ condition: Bool, _ what: String) {
    if !condition { failed = true; print("FAIL: " + what) }
}
let image = CommandLine.arguments[1]

// 1. The message of each number is the drafts' message for it.
for number in [-1743, -1744, -1712, -600, -10004, -1728, -128, 0] {
    check(MailerFailure(number: number).message
            == MailDraftComposer.message(errorInfo: [NSAppleScript.errorNumber: number], result: nil),
          "message of \(number)")
}
let denied = MailerFailure(number: -1743).message
check(denied.contains("Mail access was denied") && denied.contains("Privacy & Security > Automation"), "message of a refusal: \(denied)")
check(MailerFailure(number: -1744).message == denied, "the message is the cause's, whatever the number")
let late = MailerFailure(number: -1712).message
check(late.contains("-1712") && late.contains("in time") && late != denied, "message of a late reply: \(late)")
let other = MailerFailure(number: -1728).message
check(other.contains("(error -1728)") && other != denied && other != late, "another error shows its number: \(other)")

// 2. The error of the script is the value of the export.
let mail = Mailer()
ScriptAnswer.error = nil
check(mail.mailFailure(image: image, mailInstalled: true) == nil, "a script that ended well is no failure")
check(ScriptAnswer.sources.count == 1, "the export runs one script: \(ScriptAnswer.sources.count)")
ScriptAnswer.error = [NSAppleScript.errorNumber: NSNumber(value: -1743),
                      NSAppleScript.errorMessage: "Not authorized to send Apple events to Mail."]
check(mail.mailFailure(image: image, mailInstalled: true) == MailerFailure(number: -1743), "the script's error comes back")
ScriptAnswer.error = [NSAppleScript.errorNumber: NSNumber(value: -2741)]
check(mail.mailFailure(image: nil, mailInstalled: true) == MailerFailure(number: -2741), "another error keeps its number")
// An empty dictionary is no error, as before.
ScriptAnswer.error = [:]
check(mail.mailFailure(image: image, mailInstalled: true) == nil, "an empty error dictionary is no failure")
// Mail that is not installed: told before any script.
ScriptAnswer.error = nil
let ran = ScriptAnswer.sources.count
let missing = mail.mailFailure(image: image, mailInstalled: false)
check(missing == MailerFailure(number: -600), "Mail not installed: \(String(describing: missing))")
check(ScriptAnswer.sources.count == ran, "no script runs without Mail")

// 3. The former entry points: the message answers true whatever the script
// did, and a nil script runs nothing.
ScriptAnswer.error = [NSAppleScript.errorNumber: NSNumber(value: -1743)]
check(mail.sendMail("--", to: "--", subject: "", isMIME: true, name: "--", sendNow: false, image: image) == true,
      "-sendMail:… answers YES")
let before = ScriptAnswer.sources.count
mail.runScript(nil)
check(ScriptAnswer.sources.count == before, "-runScript: of nil runs nothing")
mail.runScript("beep")
check(ScriptAnswer.sources.last == "beep", "-runScript: runs the text it is given")

// 4. The entry of the windows: an alert with the message of the failure, and
// none when the script ended well. (Mail is installed on the Mac of the test,
// or the failure is that it is not: an alert either way.)
MainActor.assumeIsolated {
    ScriptAnswer.error = [NSAppleScript.errorNumber: NSNumber(value: -1743)]
    mail.mailShowingFailure(image: image)
    let expected = Mailer.isMailInstalled ? denied : MailerFailure(number: -600).message
    check(ScriptAnswer.alerts == ["Email Export Failed: " + expected], "a refused export shows its message: \(ScriptAnswer.alerts)")
    if Mailer.isMailInstalled {
        ScriptAnswer.error = nil
        mail.mailShowingFailure(image: image)
        check(ScriptAnswer.alerts.count == 1, "an export that ended well shows no alert")
    }
}

// 5. The script: the message, then the attachment in its content, and the
// path inside its string.
let body = mail.mailScriptBody("--", to: "--", subject: "", isMIME: true, name: "--", sendNow: false, image: image) ?? ""
let quoted = image.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
check(image.contains("\"") && image.contains("\\"), "the image's path has a quote and a backslash")
check(body == "tell application \"Mail\"\nactivate\n"
        + "set composeMessage to make new outgoing message with properties {visible:true}\n"
        + "tell composeMessage\n"
        + "set aFile to \"\(quoted)\"\ntell content\nmake new attachment with properties {file name:aFile}\nend tell\n"
        + "end tell\nend tell\n", "the script: \(body)")
let bare = mail.mailScriptBody("--", to: "--", subject: "", isMIME: true, name: "--", sendNow: false, image: image + ".missing") ?? ""
check(bare.contains("make new outgoing message") && !bare.contains("attachment"), "no attachment without its file: \(bare)")
check(mail.mailScriptBody("--", to: "--", subject: "", isMIME: false, name: "--", sendNow: true, image: image) == bare,
      "the other arguments change nothing, sendNow included")
check(body.range(of: "\\bsend\\b", options: .regularExpression) == nil, "the script never sends")

if failed { exit(1) }
print("PASS: messages of a failed e-mail of the 3D windows; the script's error is the export's value; "
      + "former entry points unchanged; the script composes only, with its path quoted")
'''

with tempfile.TemporaryDirectory(prefix='horos-mailer-failure-') as folder:
    folder = Path(folder)
    (folder / 'ScriptStandIn.swift').write_text(STAND_IN)
    (folder / 'main.swift').write_text(MAIN)
    image = folder / 'a "b" \\ c.jpg'
    image.write_bytes(b'\xff\xd8\xff\xd9')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0', '-module-name', 'MailerFailure',
                    str(source_path('Mailer')), str(source_path('MailDraftComposer')),
                    str(folder / 'ScriptStandIn.swift'), str(folder / 'main.swift'), '-o', str(folder / 'probe')], check=True)
    # The probe logs each script and each error of the script as the
    # application does: shown only when a check fails.
    run = subprocess.run([str(folder / 'probe'), str(image)], capture_output=True, text=True)
    print(run.stdout, end='')
    if run.returncode:
        raise SystemExit(run.stderr[-4000:] + '\nFAIL: the probe exited with %d' % run.returncode)
