#!/usr/bin/env python3
"""No wait for the helper that converts a structured report is without a deadline.

dsr2html writes the XML a structured report is rendered from. Two of the places
that run it polled the task until it ended, however long that took: the load of
the report as the image to show, which the image view asks for on the main
thread, and the export of the selection. A helper that never ended, on a
malformed or huge report, held the thread for good.

What must stay true:

- every place that runs dsr2html runs it through the bounded wait of
  HorosBoundedTask.h, and none launches it or polls it on its own;
- the two places above take their deadline from the constants beside the one of
  the PDF stage, and the load for display waits no longer than that stage;
- with a substitute helper that never ends in the place of dsr2html, each of the
  two returns within its deadline, leaves no child alive and no partial XML, and
  goes on to the PDF stage as when no XML is made; with no helper at all it goes
  on the same way; with a helper that works the XML is kept.

The bounded wait itself - the deadline, a child that ignores SIGTERM, a launch
that raises - is driven by test-task-launch-guard.py.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import sources  # noqa: E402

failures = []


def code_only(text):
    """`text` without its line comments, the lines kept."""
    return '\n'.join(re.sub(r'(^|\s)//.*$', '', line) for line in text.split('\n'))


# --- Every place that runs the helper -------------------------------------------

FOLDERS = [root / folder for folder in sources.FOLDERS] + [root / 'Decompress']
LAUNCH_PATH = re.compile(r'(launchPath|executableURL)[^\n]*dsr2html')
OWN_WAIT = re.compile(r'\.launch\(\)|\blaunch\s*\]|\.run\(\)|waitUntilExit|isRunning')
sites = {}
for folder in FOLDERS:
    for path in sorted(folder.rglob('*')):
        if not path.is_file() or path.suffix not in ('.swift', '.m', '.mm'):
            continue
        text = code_only(path.read_bytes().decode('utf-8' if path.suffix == '.swift' else 'latin1'))
        for match in LAUNCH_PATH.finditer(text):
            # From the helper's path to the PDF stage, which every caller has next.
            stage = text.find('updateReportPDF(', match.end())
            run = text[match.start():stage if stage > 0 else match.start() + 2500]
            line = text.count('\n', 0, match.start()) + 1
            name = '%s:%d' % (path.relative_to(root), line)
            sites[name] = run
            if stage < 0:
                failures.append('%s runs dsr2html with no PDF stage after it; the test no longer knows this caller' % name)
            if 'HorosRunTaskUntilExit' not in run:
                failures.append('%s runs dsr2html without the bounded wait' % name)
            own = OWN_WAIT.search(run)
            if own:
                failures.append('%s launches or polls dsr2html on its own (%s)' % (name, own.group(0)))

OURS = {'Horos/Sources/DCMPix+EncapsulatedDocuments.swift': 'EncapsulatedDocument.conversionTimeoutOnDisplay',
        'Horos/Sources/SelectionMovieExport.swift': 'EncapsulatedDocument.conversionTimeout'}
for file, deadline in OURS.items():
    runs = [run for name, run in sites.items() if name.split(':')[0] == file]
    if len(runs) != 1:
        failures.append('%s runs dsr2html %d times, not once' % (file, len(runs)))
        continue
    if not re.search(r'HorosRunTaskUntilExit\(task, %s, &taskError\)' % re.escape(deadline), runs[0]):
        failures.append('%s does not wait for dsr2html with %s' % (file, deadline))
    if 'removeItem(atPath:' not in runs[0]:
        failures.append('%s keeps what a stopped helper had written as the XML' % file)

# --- The deadlines ----------------------------------------------------------------

constants = code_only((root / 'Modules/IsiXImaging/Sources/Annotations/EncapsulatedDocument.swift').read_text(encoding='utf-8'))


def seconds(name, seen=()):
    match = re.search(r'static let %s: TimeInterval = (\w+(?:\.\d+)?)' % name, constants)
    if not match or name in seen:
        return None
    value = match.group(1)
    return float(value) if re.fullmatch(r'\d+(?:\.\d+)?', value) else seconds(value, (*seen, name))


rendering, display, command = (seconds(name) for name in ('renderingTimeout', 'conversionTimeoutOnDisplay', 'conversionTimeout'))
if None in (rendering, display, command):
    failures.append('a deadline of the rendering of a structured report is gone from EncapsulatedDocument.swift')
else:
    if not 0 < display <= rendering:
        failures.append('the load for display waits %g s for dsr2html, more than the PDF stage (%g s)' % (display, rendering))
    if not display <= command <= 60:
        failures.append('a command waits %g s for dsr2html: less than the display, or more than a minute' % command)

if not failures:
    print('PASS: %d places run dsr2html, all through the bounded wait; display %g s, commands %g s' % (len(sites), display, command))

# --- The two places, run with a substitute helper -----------------------------------


def member(text, start, end='\n    }\n'):
    a = text.index(start)
    return text[a:text.index(end, a) + len(end)]


HARNESS = r'''
import AppKit

setvbuf(stdout, nil, _IONBF, 0)
let scratch = CommandLine.arguments[1]
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

// What the two members read of the application, under its names.
extension FileManager {
    func tmpDirPath() -> String { (scratch as NSString).appendingPathComponent("tmp") }
    @discardableResult func confirmDirectory(atPath path: String) -> String {
        try? createDirectory(atPath: path, withIntermediateDirectories: true); return path
    }
}
enum Bundle {
    struct Main { var resourcePath: String? }
    nonisolated(unsafe) static var main = Main(resourcePath: nil)
}
enum HorosObjCException {
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
}
func _N2LogExceptionImpl(_ exception: NSException, _ stack: Bool, _ function: String) {}
enum EncapsulatedDocument {
    static let renderingTimeout: TimeInterval = 0.1
    static let conversionTimeout: TimeInterval = 0.6
    static let conversionTimeoutOnDisplay: TimeInterval = 0.6
    static func renderings(of file: String, in folder: String) -> (xml: String, pdf: String) {
        let xml = (((folder as NSString).appendingPathComponent("dicomsr_osirix") as NSString)
            .appendingPathComponent((file as NSString).lastPathComponent) as NSString).appendingPathExtension("xml") ?? ""
        return (xml, (xml as NSString).appendingPathExtension("pdf") ?? "")
    }
}
final class DecompressService {
    nonisolated(unsafe) static var shared: DecompressService? = DecompressService()
    var asked: [String] = []
    @discardableResult func updateReportPDF(atPath path: String, timeout: TimeInterval) -> Bool { asked.append(path); return false }
}
final class DCMObject {}
final class DicomImage {
    let path: String
    init(_ path: String) { self.path = path }
    func completePath() -> String? { path }
}
final class DCMPix {
    var srcFile: String?
    var pages = 0, annotated = 0
    func loadPDFPage(_ rep: NSPDFImageRep?) { pages += 1 }
    func loadCustomImageAnnotationsPapyLink(_ index: Int, dcmLink: DCMObject?) { annotated += 1 }
}
extension DCMPix {
//LOAD//
}
enum SelectionMovieExport {
//EXPORT//
}

/// Whether the process the substitute helper recorded for `xml` is gone.
func helperIsGone(_ xml: String) -> Bool {
    guard let text = try? String(contentsOfFile: xml + ".pid", encoding: .utf8),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
    return kill(pid, 0) != 0
}

func run(_ place: String, _ helper: String, _ report: String, _ body: () -> Void) -> (xml: String, elapsed: TimeInterval, asked: Bool) {
    Bundle.main.resourcePath = (scratch as NSString).appendingPathComponent(helper)
    DecompressService.shared?.asked = []
    let xml = EncapsulatedDocument.renderings(of: report, in: FileManager.default.tmpDirPath()).xml
    let before = ProcessInfo.processInfo.systemUptime
    body()
    let elapsed = ProcessInfo.processInfo.systemUptime - before
    return (xml, elapsed, DecompressService.shared?.asked == [xml])
}

for place in ["load", "export"] {
    func render(_ report: String) -> () -> Void {
        if place == "load" {
            return {
                let pix = DCMPix()
                pix.srcFile = "/reports/" + report
                check(pix.loadStructuredReport(DCMObject()), "\(place): the report is not loaded as when no XML is made")
                check(pix.pages == 1 && pix.annotated == 1, "\(place): the page and the annotations are not asked for once")
            }
        }
        return { check(SelectionMovieExport.structuredReportImage(DicomImage("/reports/" + report)) == nil, "\(place): an image without a PDF") }
    }

    // A helper that never ends, and ignores the request to stop.
    var report = place + "-endless.dcm"
    var result = run(place, "endless", report, render(report))
    check(result.elapsed >= 0.6, "\(place): returned before the deadline (\(result.elapsed) s)")
    check(result.elapsed < 8, "\(place): the wait is not bounded (\(result.elapsed) s)")
    check(FileManager.default.fileExists(atPath: result.xml + ".pid"), "\(place): the substitute helper was not the one run")
    check(helperIsGone(result.xml), "\(place): the helper is still alive after the deadline")
    check(!FileManager.default.fileExists(atPath: result.xml), "\(place): what the stopped helper had written is kept as the XML")
    check(result.asked, "\(place): the PDF stage is not reached after the deadline")

    // No helper at all: the launch fails, and nothing is raised.
    report = place + "-absent.dcm"
    result = run(place, "absent", report, render(report))
    check(result.elapsed < 5, "\(place): a helper that cannot start is waited for (\(result.elapsed) s)")
    check(!FileManager.default.fileExists(atPath: result.xml), "\(place): an XML without a helper")
    check(result.asked, "\(place): the PDF stage is not reached when the helper cannot start")

    // A helper that works: its XML is kept, and not made again.
    report = place + "-working.dcm"
    result = run(place, "working", report, render(report))
    check((try? String(contentsOfFile: result.xml, encoding: .utf8)) == "<report/>", "\(place): the XML of a helper that ended is not kept")
    check(result.asked, "\(place): the PDF stage is not reached after a conversion")
    try? FileManager.default.removeItem(atPath: result.xml + ".pid")
    result = run(place, "working", report, render(report))
    check(!FileManager.default.fileExists(atPath: result.xml + ".pid"), "\(place): the XML that exists is made again")
}

if failures == 0 { print("PASS: with a helper that never ends in the place of dsr2html, the load and the export return at their deadline, leave no child and no partial XML, and go on to the PDF stage; a missing helper and a working one too") }
exit(failures == 0 ? 0 : 1)
'''

# The substitutes take dsr2html's arguments: the output is the last one. `exec`
# keeps the recorded process the one that sleeps, with SIGTERM still ignored.
ENDLESS = '''#!/bin/sh
for output; do :; done
echo $$ > "$output.pid"
printf '<partial' > "$output"
trap '' TERM
exec sleep 120
'''
WORKING = '''#!/bin/sh
for output; do :; done
echo $$ > "$output.pid"
printf '<report/>' > "$output"
'''

if shutil.which('xcrun') is None:
    for failure in failures:
        print('FAIL: ' + failure)
    if failures:
        sys.exit(1)
    print('SKIPPED: the run with a substitute helper needs xcrun swiftc')
    sys.exit(2)

load = member(sources.source_text('DCMPix+EncapsulatedDocuments'), '    private func loadStructuredReport(')
export = member(sources.source_text('SelectionMovieExport'), '    private static func structuredReportImage(')
program = (HARNESS.replace('//LOAD//', load.replace('private func', 'func', 1))
           .replace('//EXPORT//', export.replace('private static func', 'static func', 1)))

with tempfile.TemporaryDirectory(prefix='isix-sr-conversion-') as folder:
    scratch = Path(folder)
    for name, script in (('endless', ENDLESS), ('working', WORKING)):
        (scratch / name).mkdir()
        (scratch / name / 'dsr2html').write_text(script)
        (scratch / name / 'dsr2html').chmod(0o755)
    (scratch / 'absent').mkdir()
    (scratch / 'main.swift').write_text(program, encoding='utf-8')
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-import-objc-header', str(root / 'Horos/Sources/HorosBoundedTask.h'),
                            str(scratch / 'main.swift'), '-o', str(scratch / 'harness')],
                           capture_output=True, text=True, timeout=240)
    if build.returncode != 0:
        print(build.stderr)
        failures.append('the two places do not compile against the bounded wait')
    else:
        try:
            ran = subprocess.run([str(scratch / 'harness'), str(scratch)], capture_output=True, text=True, timeout=120)
            sys.stdout.write(ran.stdout)
            if ran.returncode != 0:
                failures.append('the run with a substitute helper failed' + (': ' + ran.stderr.strip()[-400:] if ran.stderr.strip() else ''))
        except subprocess.TimeoutExpired:
            failures.append('the run with a substitute helper did not end: a wait has no deadline')

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
