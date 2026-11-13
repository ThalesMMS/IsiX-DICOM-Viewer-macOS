#!/usr/bin/env python3
"""A send asked with +sendFiles:toNode:usingSyntax: takes the ROIs with it, in the syntax asked, and leaves the Send sheet's settings alone.

+[SendController sendFiles:toNode:usingSyntax:] (and +sendFiles:toNode:, which
calls it) sends every file it is given, the ROI, report and annotation series
of the application included, in the transfer syntax it is asked, whatever the
Send sheet shows. It did so by storing the "send ROIs" setting on and the
syntax under the sheet's own key, queueing the send, and putting back the
value of the first that it had read: a setting that was only the registered
one was stored as the user's, a send that raised left it on, and the syntax
stayed stored, so that the next send of the sheet went in the syntax a plugin
had asked for. The send is now told both itself, and nothing is written.

SendController.swift, as it is, is compiled over the doubles of
send_controller_harness.py. The standard defaults of the harness keep what
they are given in the process's argument domain (harness_defaults), which is
then everything the code under test wrote. With the settings only registered
(ROIs off, syntax 0), stored off and stored on (with the syntax stored at 5):

  * the send asked with +sendFiles:toNode:usingSyntax: has the ROI series in
    its association, with the syntax it was asked (13);
  * what is written of sendROIs and of syntaxListOffis is afterwards what it
    was before: nothing when they were only registered;
  * a send made afterwards as the sheet makes it leaves the ROI series out
    unless the setting is on, and goes in the sheet's syntax, not in 13.

`--source <git revision>` reads SendController.swift from that revision, the
negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness_defaults  # noqa: E402
import send_controller_harness as harness  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SEND = 'Horos/Sources/SendController.swift'
parser = argparse.ArgumentParser()
parser.add_argument('--source', help='read SendController.swift from this Git revision')
args = parser.parse_args()
source = (subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{args.source}:{SEND}']).decode('utf-8') if args.source
          else (ROOT / SEND).read_text(encoding='utf-8'))

DRIVER = harness_defaults.SWIFT + harness.DRIVER_PRELUDE + r'''
UserDefaults.standard.register(defaults: [
    "sendROIs": false,
    "SendControllerConcurrentThreads": 1,
    "MaximumSendControllerConcurrentThreads": 4,
    "MaximumSendGlobalControllerConcurrentThreads": 4,
    "syntaxListOffis": 0,
    "lastSendServer": 0,
    "lastSendWhat": 0,
])
/// What was written to the standard defaults: this harness keeps it in the argument domain.
func written(_ key: String) -> String {
    UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key].map { "\($0)" } ?? "nothing"
}

switch CommandLine.arguments[1] {
case "registered": break
case "stored-off": UserDefaults.standard.set(false, forKey: "sendROIs")
case "stored-on":
    UserDefaults.standard.set(true, forKey: "sendROIs")
    UserDefaults.standard.set(5, forKey: "syntaxListOffis")
default: exit(64)
}
let node: NSDictionary = ["AETitle": "PACS", "Address": "127.0.0.1", "Port": "11112", "Description": "harness", "TransferSyntax": 0, "Activated": true]
let alpha = DicomStudy("P1", "Alpha"), beta = DicomStudy("P2", "Beta")
let before = written("sendROIs"), syntaxBefore = written("syntaxListOffis")

// The send a plugin, a routing rule or a script asks for.
SendController.sendFiles(images(alpha, "CT", 1, ["/asked1", "/asked2"]) + images(alpha, "OsiriX ROI SR", 5002, ["/asked-roi"]),
                         toNode: node as? [AnyHashable: Any], usingSyntax: 13)
let after = written("sendROIs")
var done = finished(within: 20)

// A send as the sheet makes it, afterwards.
send(images(beta, "CT", 1, ["/sheet1"]) + images(beta, "OsiriX ROI SR", 5002, ["/sheet-roi"]), to: node)
done = finished(within: 20) && done

print("finished \(done)")
print("sendROIs written before: \(before), after: \(after), at the end: \(written("sendROIs"))")
print("syntaxListOffis written before: \(syntaxBefore), at the end: \(written("syntaxListOffis"))")
for line in lines().sorted() { print(line.replacingOccurrences(of: "\r", with: "\\r")) }
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-send-files-to-node-') as directory:
    try:
        executable = harness.build(directory, source, DRIVER, 'send-to-node')
    except subprocess.CalledProcessError as error:
        print('FAIL: SendController.swift does not build with the driver:\n'
              + (error.stderr.decode(errors='replace') if isinstance(error.stderr, bytes) else str(error.stderr))[-4000:])
        sys.exit(1)
    for case, was, sheet_sends_rois, syntax in (('registered', 'nothing', False, 'nothing'), ('stored-off', '0', False, 'nothing'),
                                                ('stored-on', '1', True, '5')):
        result = harness.run(executable, case)
        out = result.stdout.strip().splitlines()
        if result.returncode != 0 or not out or out[0] != 'finished true':
            failures.append(f'{case}: the sends did not finish (exit {result.returncode}): {(result.stdout + result.stderr)[-800:]}')
            continue
        stores = [line for line in out if line.startswith('store')]
        asked = [line for line in stores if '/asked1' in line]
        sheet = [line for line in stores if '/sheet1' in line]
        if len(asked) != 1 or '/asked-roi' not in asked[0] or '/asked2' not in asked[0] or ' syntax 13 ' not in asked[0]:
            failures.append(f'{case}: the send asked for did not take its three files with syntax 13: {asked}')
        if len(sheet) != 1 or ('/sheet-roi' in sheet[0]) != sheet_sends_rois:
            failures.append(f'{case}: the sheet\'s send {"left out" if sheet_sends_rois else "took"} the ROI series: {sheet}')
        sheet_syntax = 0 if syntax == 'nothing' else int(syntax)
        if len(sheet) == 1 and f' syntax {sheet_syntax} ' not in sheet[0]:
            failures.append(f'{case}: the sheet\'s send did not go in the sheet\'s syntax ({sheet_syntax}): {sheet}')
        if out[1] != f'sendROIs written before: {was}, after: {was}, at the end: {was}':
            failures.append(f'{case}: the setting was written ({out[1]})')
        if out[2] != f'syntaxListOffis written before: {syntax}, at the end: {syntax}':
            failures.append(f'{case}: the syntax of the sheet was written ({out[2]})')
        if not failures:
            print(f'ok: {case}: {out[1]}; {out[2]}; {len(stores)} associations')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: a send asked with +sendFiles:toNode:usingSyntax: takes the ROI series, in the syntax asked, whatever the sheet says, '
      'and the sheet\'s settings, stored or only registered, are not written')
