#!/usr/bin/env python3
"""A failed export to Photos reaches the user, with a message for its cause.

The import into Photos is a script sent to Photos. When macOS refuses the Apple
Events (the user said no, or the application may not ask), when Photos is not
there, or when Photos answers with an error, the export used to end with a log
line and nothing on screen.

Photos.swift is compiled as it stands, with the process graph's stand-in and a
stand-in of the one call that runs a script, which answers the error the test
gives it: no Apple Event leaves the test. Through it:

1. each error number is of the cause it should be, and each cause has its own
   message; an error of another kind shows its number and the system's message;
2. the error of the script comes back as a value from the import, nil when the
   script ended well; Photos that is not installed is told before any script;
3. the former entry points answer as they did;
4. a quote or a backslash in the album's name or in a path stays inside the
   script's string;
5. the viewer's export shows the message in the exports' alert, and every
   catalog has the five texts, with the arguments of the English ones.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import process_graph_stand_in  # noqa: E402
from sources import source_path, source_text  # noqa: E402

photos = source_text('Photos')
exporter = source_text('ViewerImageExporter')

# --- 5. the call and the alert of the viewer's export -------------------------
assert ('if formatTag == ViewerImageFormat.photos.rawValue && !sharedImageExportFailed && !mailExportFiles.isEmpty {\n'
        '            Photos().importShowingFailure([sharedExportRoot])\n') in exporter
# Every window that exports to Photos tells the user of a failure: none calls
# the entry that answers YES whatever happened.
for path in sorted((root / 'Horos/Sources').glob('*.swift')):
    if path.name != 'Photos.swift':
        assert '.importInPhotos(' not in path.read_text(), path.name
assert sum('.importShowingFailure(' in path.read_text() for path in (root / 'Horos/Sources').glob('*.swift')) >= 5

TEXTS = [
    'Photos Export Failed',
    'Photos access was denied. Allow IsiX DICOM Viewer to control Photos in System Settings > Privacy & Security > Automation, then retry the export.',
    'Photos is not available. Check that Photos is installed and can be opened, then retry the export.',
    'Photos could not import the images (error %ld).',
    'Photos could not import the images (error %ld).\n\n%@',
]
swift_literal = lambda text: json.dumps(text, ensure_ascii=False)  # noqa: E731
for text in TEXTS:
    assert 'NSLocalizedString(%s, comment: "")' % swift_literal(text) in photos, text
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
        assert value.count('\n') == text.count('\n'), (language, text)

# --- 1 to 4. Photos.swift, run ------------------------------------------------
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

// 1. The cause of each number, and its message.
let causes: [(Int, PhotosImportFailure.Reason)] = [
    (-1743, .automationNotPermitted), (-1744, .automationNotPermitted), (-10004, .automationNotPermitted),
    (-600, .photosUnavailable), (-10810, .photosUnavailable), (-10814, .photosUnavailable),
    (-1728, .other), (-1712, .other), (-2741, .other), (-128, .other), (0, .other), (1743, .other), (600, .other),
]
for (number, reason) in causes {
    check(PhotosImportFailure(number: number).reason == reason, "cause of \(number)")
}
let denied = PhotosImportFailure(number: -1743, systemMessage: "Not authorized to send Apple events to Photos.").message
let absent = PhotosImportFailure(number: -600, systemMessage: "Application isn't running.").message
check(denied.contains("Photos access was denied") && denied.contains("Privacy & Security > Automation"), "message of a refusal: \(denied)")
check(!denied.contains("-1743") && !denied.contains("Not authorized"), "a refusal names no number: \(denied)")
check(absent.contains("Photos is not available") && absent.contains("installed"), "message of Photos missing: \(absent)")
check(denied != absent, "one message per cause")
check(PhotosImportFailure(number: -10004).message == denied && PhotosImportFailure(number: -10814).message == absent,
      "the message is the cause's, whatever the number")
let other = PhotosImportFailure(number: -1728, systemMessage: "Photos got an error: Can't get album \"X\".").message
check(other == "Photos could not import the images (error -1728).\n\nPhotos got an error: Can't get album \"X\".", "other error: \(other)")
for silent in [PhotosImportFailure(number: -1712), PhotosImportFailure(number: -1712, systemMessage: "")] {
    check(silent.message == "Photos could not import the images (error -1712).", "other error with no message: \(silent.message)")
}

// 2. The error of the script is the value of the import.
let importer = Photos()
ScriptAnswer.error = nil
check(importer.importFailure(["/tmp/a.jpg"], photosInstalled: true) == nil, "a script that ended well is no failure")
check(ScriptAnswer.sources.count == 1 && ScriptAnswer.sources[0].contains("import (POSIX file \"/tmp/a.jpg\" as alias) into this_album"),
      "the import runs the script of the files: \(ScriptAnswer.sources)")
ScriptAnswer.error = [NSAppleScript.errorNumber: NSNumber(value: -1743),
                      NSAppleScript.errorMessage: "Not authorized to send Apple events to Photos."]
let refusal = importer.importFailure(["/tmp/a.jpg"], photosInstalled: true)
check(refusal == PhotosImportFailure(number: -1743, systemMessage: "Not authorized to send Apple events to Photos."),
      "the script's error comes back: \(String(describing: refusal))")
check(refusal?.reason == .automationNotPermitted, "and is a refusal")
ScriptAnswer.error = [NSAppleScript.errorNumber: NSNumber(value: -2741), NSAppleScript.errorMessage: "Expected end of line."]
check(importer.importFailure([], photosInstalled: true) == PhotosImportFailure(number: -2741, systemMessage: "Expected end of line."),
      "another error keeps its number and message")
// An empty dictionary is no error, as before.
ScriptAnswer.error = [:]
check(importer.importFailure([], photosInstalled: true) == nil, "an empty error dictionary is no failure")
// Photos that is not installed: told before any script.
ScriptAnswer.error = nil
let ran = ScriptAnswer.sources.count
let missing = importer.importFailure(["/tmp/a.jpg"], photosInstalled: false)
check(missing?.number == -600 && missing?.reason == .photosUnavailable, "Photos not installed: \(String(describing: missing))")
check(ScriptAnswer.sources.count == ran, "no script runs without Photos")

// 3. The former entry points: the import answers true whatever the script did,
// and a nil script runs nothing.
ScriptAnswer.error = [NSAppleScript.errorNumber: NSNumber(value: -1743)]
check(importer.importInPhotos(["/tmp/a.jpg"]) == true, "-importInPhotos: answers YES")
check(importer.importInPhotos(nil) == true, "-importInPhotos: of nil answers YES")
let before = ScriptAnswer.sources.count
importer.runScript(nil)
check(ScriptAnswer.sources.count == before, "-runScript: of nil runs nothing")
importer.runScript("beep")
check(ScriptAnswer.sources.last == "beep", "-runScript: runs the text it is given")

// The entry of the windows: an alert with the message of the failure, and none
// when the script ended well.
MainActor.assumeIsolated {
    ScriptAnswer.error = [NSAppleScript.errorNumber: NSNumber(value: -1743)]
    importer.importShowingFailure(["/tmp/a.jpg"])
    check(ScriptAnswer.alerts.count == 1 && ScriptAnswer.alerts[0].contains(PhotosImportFailure(number: -1743).message),
          "a refused import shows its message: \(ScriptAnswer.alerts)")
    ScriptAnswer.error = nil
    importer.importShowingFailure(["/tmp/a.jpg"])
    check(ScriptAnswer.alerts.count == 1, "an import that ended well shows no alert")
}

// 4. The album's name (given on the command line) and the paths stay inside
// their strings.
let body = importer.scriptBody(["/tmp/a \"b\" \\ c.jpg"]) ?? ""
let album = "A \\\"B\\\" \\\\ C"
check(body.contains("if not (exists album \"\(album)\") then \n"), "album tested: \(body)")
check(body.contains("make new album named \"\(album)\" \n"), "album made: \(body)")
check(body.contains("set this_album to album \"\(album)\" \n"), "album taken: \(body)")
check(body.contains("import (POSIX file \"/tmp/a \\\"b\\\" \\\\ c.jpg\" as alias) into this_album skip check duplicates yes \n"), "path: \(body)")
check(body.hasPrefix("tell application \"Photos\"\n") && body.hasSuffix("end tell \n"), "the script addresses Photos: \(body)")

if failed { exit(1) }
print("PASS: causes and messages of a failed import into Photos; the script's error is the import's value; "
      + "former entry points unchanged; album and paths quoted")
'''

with tempfile.TemporaryDirectory(prefix='horos-photos-failure-') as folder:
    folder = Path(folder)
    (folder / 'ScriptStandIn.swift').write_text(STAND_IN)
    (folder / 'main.swift').write_text(MAIN)
    target = ['-target', 'arm64-apple-macos15.0']
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *target, '-module-name', 'PhotosFailure',
                    str(source_path('Photos')), str(folder / 'ScriptStandIn.swift'), str(folder / 'main.swift'),
                    *process_graph_stand_in.swift_flags(folder / 'modules', target),
                    '-o', str(folder / 'probe')], check=True)
    # The album's name comes from the preferences: the argument domain gives
    # it to this run only, and nothing is written. The probe logs each error
    # of the script as the application does: shown only when a check fails.
    run = subprocess.run([str(folder / 'probe'), '-ALBUMNAME', 'A "B" \\ C'], capture_output=True, text=True)
    print(run.stdout, end='')
    if run.returncode:
        raise SystemExit(run.stderr[-4000:] + '\nFAIL: the probe exited with %d' % run.returncode)
