#!/usr/bin/env python3
"""A send made through the send queue goes where, with what, as before.

SendController.swift built each send itself: it sorted the images by patient,
removed duplicate files, made one batch per patient without the app's own SR
series, and ran each batch in an operation queue split over the associations
the settings asked for, after the STOW-RS of a DICOMweb node or the direct
transfer of a Horos peer. It now makes a typed request (DICOMSendRequest,
DICOMSendSelection) and hands it to DICOMSendQueue, whose transport runs each
association on an activity thread.

The same driver is compiled with SendController.swift of the revision before
that change and of this tree, over the doubles of send_controller_harness.py,
and every case must record the same lines: each association (the thread it
runs on, calling and called AE titles, host, port, transfer syntax,
compression, the files in order, the TLS settings it reads), each STOW-RS and
direct transfer, and each alert.

- patients: three patients, interleaved, one batch each under its name;
- split-*: a batch over 3 and 4 associations, more than the maximum, none
  and a negative count;
- duplicates: a file chosen twice goes once, with the first patient that has it;
- app-series / app-series-sent: the ROI, report, annotation, window-state and
  no-autodeletion series are left out unless ROIs are sent;
- case-patients: patient UIDs that differ by case only are one patient;
- unnamed: no patient UID and no study name;
- syntax-tls: the send syntax, a numeric port and a TLS node;
- dicomweb: a DICOMweb node gets every file by STOW-RS on the activity thread;
- direct / direct-fallback: a peer with a token, reached directly, or by
  C-STORE after the direct transfer failed;
- failure: a part that does not send all its files shows the alert;
- cancel: Cancel in the Activity window stops the batch and the next one.

Exits 2 when the history does not reach the revision before the send queue.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import send_controller_harness as harness  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SEND = 'Horos/Sources/SendController.swift'
MARK = 'func sendDICOMFilesOffis'
reference = ('HEAD' if MARK in history_reference.show('HEAD', SEND).decode('utf-8')
             else history_reference.before_text_removed(SEND, MARK))
if reference is None:
    print('skipped: the history does not reach the revision before the send queue')
    sys.exit(2)
if MARK in (ROOT / SEND).read_text(encoding='utf-8'):
    print('skipped: this tree still sends from SendController')
    sys.exit(2)
old_source = history_reference.show(reference, SEND).decode('utf-8')

DRIVER = harness.DRIVER_PRELUDE + r'''
var defaults: [String: Any] = [
    "sendROIs": false,
    "SendControllerConcurrentThreads": 1,
    "MaximumSendControllerConcurrentThreads": 4,
    "MaximumSendGlobalControllerConcurrentThreads": 4,
    "syntaxListOffis": 0,
    "lastSendServer": 0,
    "lastSendWhat": 0,
]

func node(_ extra: [String: Any] = [:]) -> NSDictionary {
    var entry: [String: Any] = ["AETitle": "PACS", "Address": "127.0.0.1", "Port": "11112", "Description": "harness",
                                "TransferSyntax": 0, "Activated": true]
    for (key, value) in extra { entry[key] = value }
    return entry as NSDictionary
}

let alpha = DicomStudy("P1", "Alpha"), beta = DicomStudy("P2", "Beta"), gamma = DicomStudy("P3", "Gamma")
func many(_ study: DicomStudy, _ prefix: String, _ count: Int) -> [DicomImage] {
    images(study, "CT", 1, (1...count).map { "/\(prefix)\(String(format: "%02d", $0))" })
}

let which = CommandLine.arguments[1]
var sends: [([DicomImage], NSDictionary?)] = []
switch which {
case "patients":
    let a = many(alpha, "a", 3), b = many(beta, "b", 2), g = many(gamma, "g", 1)
    sends = [([b[0], a[0], g[0], a[1], b[1], a[2]], node())]
case "split-3":
    defaults["SendControllerConcurrentThreads"] = 3
    sends = [(many(alpha, "s", 10), node())]
case "split-4":
    defaults["SendControllerConcurrentThreads"] = 4
    sends = [(many(alpha, "s", 10), node())]
case "split-over-maximum":
    defaults["SendControllerConcurrentThreads"] = 9
    sends = [(many(alpha, "s", 7), node())]
case "split-zero":
    defaults["SendControllerConcurrentThreads"] = 0
    sends = [(many(alpha, "s", 3), node())]
case "split-negative":
    defaults["SendControllerConcurrentThreads"] = -1
    sends = [(many(alpha, "s", 5), node())]
case "duplicates":
    let first = images(beta, "CT", 1, ["/shared", "/b1"]), second = images(alpha, "CT", 1, ["/a1", "/shared"])
    sends = [(first + second, node())]
case "app-series", "app-series-sent":
    defaults["sendROIs"] = which == "app-series-sent"
    let kept = many(alpha, "a", 2)
    let roi = images(alpha, "OsiriX ROI SR", 5002, ["/roi"]), report = images(alpha, "OsiriX Report SR", 5003, ["/report"])
    let annotations = images(beta, "OsiriX Annotations SR", 5004, ["/annotations"])
    let windows = images(gamma, "OsiriX WindowsState SR", 5006, ["/windows"])
    let marker = images(gamma, "osirix no autodeletion", 5005, ["/marker"])
    let other = images(gamma, "CT", 5002, ["/numbered"])
    sends = [(roi + kept + report + annotations + windows + marker + other, node())]
case "case-patients":
    let upper = DicomStudy("AB", "Upper"), lower = DicomStudy("ab", "Lower"), accent = DicomStudy("áb", "Accent")
    sends = [(images(lower, "CT", 1, ["/l1"]) + images(upper, "CT", 1, ["/u1"]) + images(accent, "CT", 1, ["/x1"]), node())]
case "unnamed":
    sends = [(images(DicomStudy(nil, nil), "CT", 1, ["/n1", "/n2"]) + images(DicomStudy("P9", nil), "CT", 1, ["/n3"]), node())]
case "syntax-tls":
    defaults["syntaxListOffis"] = 13
    defaults["SendControllerConcurrentThreads"] = 2
    let tls: [String: Any] = ["Port": 4242, "TLSEnabled": true, "TLSAuthenticated": "YES", "TLSCertificateVerification": "1",
                              "TLSCipherSuites": [["Cipher": "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", "Supported": true],
                                                  ["Cipher": "OFF", "Supported": false]],
                              "TLSUseDHParameterFileURL": 1, "TLSDHParameterFileURL": "/dh.pem", "Unknown": ["kept": 1]]
    sends = [(many(alpha, "t", 3), node(tls))]
case "dicomweb":
    let web: NSDictionary = ["DICOMwebNode": "7B0E1C9A-0000-4000-8000-000000000799", "AETitle": "DICOMweb", "Description": "web",
                             "Address": "https://pacs.example/dicom-web", "retrieveMode": 3]
    sends = [(many(alpha, "w", 2) + many(beta, "v", 1) + images(alpha, "CT", 1, ["/w01"]), web)]
case "direct", "direct-fallback":
    directSends = which == "direct"
    let peer = node(["HorosDirectTransferVersion": 4, "HorosDirectTransferPort": "8899", "HorosDirectTransferToken": "secret"])
    sends = [(many(alpha, "d", 2) + many(beta, "e", 1), peer)]
case "failure":
    sends = [(images(alpha, "CT", 1, ["/ok"]) + images(beta, "CT", 1, ["/fail"]), node())]
case "cancel":
    waitForCancel = "/a01"
    sends = [(many(alpha, "a", 2) + many(beta, "b", 2), node())]
default:
    print("unknown case \(which)")
    exit(1)
}

UserDefaults.standard.register(defaults: defaults)
for (objects, destination) in sends {
    send(objects, to: destination)
}
if which == "cancel" {
    let deadline = Date(timeIntervalSinceNow: 10)
    while !lines().contains(where: { $0.hasPrefix("store") }) && Date() < deadline {
        autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
    }
    ThreadsManager.cancelAll()
}
let done = finished(within: 20)
print("finished \(done)")
for line in lines().sorted() {
    print(line.replacingOccurrences(of: "\r", with: "\\r"))
}
'''

CASES = ('patients', 'split-3', 'split-4', 'split-over-maximum', 'split-zero', 'split-negative', 'duplicates',
         'app-series', 'app-series-sent', 'case-patients', 'unnamed', 'syntax-tls', 'dicomweb', 'direct',
         'direct-fallback', 'failure', 'cancel')

failures = []
with tempfile.TemporaryDirectory(prefix='horos-send-request-') as directory:
    folder = Path(directory)
    builds = {}
    for side, source in (('old', old_source), ('new', (ROOT / SEND).read_text(encoding='utf-8'))):
        try:
            builds[side] = harness.build(folder, source, DRIVER, f'send-{side}')
        except subprocess.CalledProcessError as error:
            print(f'FAIL: the {side} SendController does not build with the driver:\n'
                  + (error.stderr.decode(errors='replace') if isinstance(error.stderr, bytes) else str(error.stderr))[-4000:])
            sys.exit(1)
    for case in CASES:
        results = {side: harness.run(builds[side], case) for side in builds}
        outputs = {side: result.stdout.strip().splitlines() for side, result in results.items()}
        for side, result in results.items():
            if result.returncode != 0 or not outputs[side] or outputs[side][0] != 'finished true':
                failures.append(f'{case}: the {side} send did not finish (exit {result.returncode}): '
                                f'{(result.stdout + result.stderr)[-800:]}')
        if any(failure.startswith(case + ':') for failure in failures):
            continue
        if outputs['old'] != outputs['new']:
            old, new = set(outputs['old']), set(outputs['new'])
            failures.append(f'{case}: the sends differ\n  before only: {sorted(old - new)}\n  now only:    {sorted(new - old)}')
        elif len(outputs['new']) < 2:
            failures.append(f'{case}: nothing was recorded')
        else:
            print(f'ok: {case} ({len(outputs["new"]) - 1} records)')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'PASS: {len(CASES)} cases send the same files to the same nodes with the same syntax, compression and TLS, '
      f'by the same route, as {reference[:12]}')
