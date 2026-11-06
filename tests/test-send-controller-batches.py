#!/usr/bin/env python3
"""DICOM send makes one batch per patient, always lets its controller go, and
shares the process's send slots without a data race.

SendController.swift is compiled as it is, with the send queue it hands its
requests to (IsiXDICOMNetwork), the activity threads that carry them
(ActivitySendTransport.swift, ActivityThread) and the process graph that holds
the queue, over the doubles of send_controller_harness.py: DCMTKStoreSCU
records the files of each association and the activity thread it runs on, and
never opens a connection; ThreadsManager starts the thread it is given. Each
case runs in a process of its own and waits, spinning the main run loop, until
no controller is alive and no send is queued.

- batches: three patients, interleaved. One batch per patient, each under its
  own name. (A former loop compared each image with a previous patient UID
  that started nil, so every image went in one batch under the last name.)
- filtered-patient: the first patient has only ROI SR images, filtered out
  with sendROIs off, the second has images. The emptied batch must not stop
  the next one.
- unnamed: a study without a name is sent, under "(null)".
- all-filtered: nothing left after the ROI filter: nothing is sent and the
  controller is released.
- empty: -sendToNode:objects: with no objects; the controller is released.
- concurrent: eight sends at once, with MaximumSendGlobalControllerConcurrentThreads
  at 4. All eight must be sent, never more than three at a time (a send starts
  when none runs or when it makes fewer than the maximum), and every
  controller released.
- dicomweb: a DICOMweb node as the destination. Its files, all patients
  together, go to the STOW-RS send on a listed activity thread, and none to
  DCMTKStoreSCU or the direct transfer.
- tsan: the concurrent case under ThreadSanitizer, which must report no data
  race in SendController.swift, ActivitySendTransport.swift or the queue.
  Skipped, not failed, when the toolchain cannot build with -sanitize=thread.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import send_controller_harness as harness  # noqa: E402

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/SendController.swift').read_text(encoding='utf-8')

DRIVER = harness.DRIVER_PRELUDE + r'''
let node: NSDictionary = ["AETitle": "NOWHERE", "Address": "127.0.0.1", "Port": 1, "Description": "harness"]

UserDefaults.standard.register(defaults: [
    "sendROIs": false,
    "SendControllerConcurrentThreads": 1,
    "MaximumSendControllerConcurrentThreads": 4,
    "MaximumSendGlobalControllerConcurrentThreads": 4,
    "syntaxListOffis": 0,
    "lastSendServer": 0,
    "lastSendWhat": 0,
])

func finish(_ ok: Bool, _ detail: String) -> Never {
    print("\(ok ? "ok" : "wrong") \(detail)")
    exit(ok ? 0 : 1)
}

/// "<thread>: <files>" of each association.
func stores() -> [String] {
    lines().filter { $0.hasPrefix("store") }.map { line in
        let fields = line.dropFirst(7).components(separatedBy: " | ")
        return "\(fields[0]): \(fields[2])"
    }.sorted()
}

let which = CommandLine.arguments[1]
switch which {
case "batches":
    let alpha = DicomStudy("P1", "Alpha"), beta = DicomStudy("P2", "Beta"), gamma = DicomStudy("P3", "Gamma")
    let a = images(alpha, "CT", 1, ["/a1", "/a2", "/a3"])
    let b = images(beta, "CT", 1, ["/b1", "/b2"])
    let g = images(gamma, "CT", 1, ["/g1"])
    send([b[0], a[0], g[0], a[1], b[1], a[2]], to: node)
    let done = finished(within: 10)
    let got = stores()
    finish(done && got == ["Sending... Alpha: /a1,/a2,/a3", "Sending... Beta: /b1,/b2", "Sending... Gamma: /g1"],
           "finished=\(done) \(got)")
case "filtered-patient":
    let alpha = DicomStudy("P1", "Alpha"), beta = DicomStudy("P2", "Beta")
    send(images(alpha, "OsiriX ROI SR", 5002, ["/a-roi"]) + images(beta, "CT", 1, ["/b1", "/b2"]), to: node)
    let done = finished(within: 10)
    let got = stores()
    finish(done && got == ["Sending... Beta: /b1,/b2"], "finished=\(done) \(got)")
case "unnamed":
    send(images(DicomStudy("P1", nil), "CT", 1, ["/u1", "/u2"]), to: node)
    let done = finished(within: 10)
    let got = stores()
    finish(done && got == ["Sending... (null): /u1,/u2"], "finished=\(done) \(got)")
case "all-filtered":
    send(images(DicomStudy("P1", "Alpha"), "OsiriX ROI SR", 5002, ["/r1", "/r2"]), to: node)
    let done = finished(within: 5)
    finish(done && lines().isEmpty, "finished=\(done) sent=\(lines())")
case "empty":
    send([], to: node)
    let done = finished(within: 5)
    finish(done && lines().isEmpty, "finished=\(done) sent=\(lines())")
case "dicomweb":
    let web: NSDictionary = ["DICOMwebNode": "7B0E1C9A-0000-4000-8000-000000000799", "AETitle": "DICOMweb", "Description": "web",
                             "Address": "https://pacs.example/dicom-web", "retrieveMode": 3]
    let alpha = DicomStudy("P1", "Alpha"), beta = DicomStudy("P2", "Beta")
    send(images(alpha, "CT", 1, ["/w1", "/w2"]) + images(beta, "CT", 1, ["/w3"]), to: web)
    let done = finished(within: 10)
    let got = lines()
    finish(done && got == ["stow   activity | 7B0E1C9A-0000-4000-8000-000000000799 Alpha | /w1,/w2,/w3"],
           "finished=\(done) \(got)")
case "concurrent", "tsan":
    storeDelay = 0.3
    for i in 1...8 {
        send(images(DicomStudy("P\(i)", "Patient \(i)"), "CT", 1, ["/c\(i)"]), to: node)
    }
    let done = finished(within: 20)
    recordLock.lock(); let most = mostRunning; recordLock.unlock()
    let sent = stores().count
    finish(done && sent == 8 && most <= 3, "finished=\(done) sent=\(sent)/8 at most \(most) at a time")
default:
    finish(false, "unknown case \(which)")
}
'''

CASES = {
    'batches': 'three interleaved patients go in three batches, each under its own name',
    'filtered-patient': 'a patient emptied by the ROI filter does not stop the next patient\'s batch',
    'unnamed': 'a study without a name is sent and its controller released',
    'all-filtered': 'a selection emptied by the ROI filter releases its controller',
    'empty': 'a send with no objects releases its controller',
    'concurrent': 'eight sends at once all finish, never more than three at a time',
    'dicomweb': 'a DICOMweb destination gets every file by STOW-RS on an activity thread, none by C-STORE',
}
OURS = ('SendController.swift', 'ActivitySendTransport.swift', 'DICOMSendQueue.swift', 'DICOMSendRequest.swift')

failures = []
skipped = []
with tempfile.TemporaryDirectory(prefix='horos-send-batches-') as tmp:
    folder = Path(tmp)
    try:
        send = harness.build(folder, source, DRIVER, 'send')
    except subprocess.CalledProcessError as error:
        print('FAIL: SendController did not build:', (error.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    for case, claim in CASES.items():
        result = harness.run(send, case, timeout=40)
        if result.returncode == 0:
            print('ok:', claim)
        else:
            lines = result.stdout.strip().splitlines()
            failures.append(f'{claim}: {lines[-1] if lines else ("timed out" if result.returncode == -1 else f"exit {result.returncode}")}')

    claim = 'ThreadSanitizer reports no data race in the send'
    try:
        tsan = harness.build(folder, source, DRIVER, 'send-tsan', sanitize=True)
    except subprocess.CalledProcessError as error:
        lines = (error.stderr or b'').decode(errors='replace').strip().splitlines()
        skipped.append(f'{claim}: no -sanitize=thread build ({lines[-1:]})')
    else:
        result = harness.run(tsan, 'tsan', timeout=60)
        reports = result.stderr.split('WARNING: ThreadSanitizer: ')[1:]
        ours = [report for report in reports if any(name in report for name in OURS)]
        if ours:
            first = next((line.strip() for line in ours[0].splitlines() if any(name in line for name in OURS)), '')
            failures.append(f'{claim}: {len(ours)} report(s), first at {first}')
        elif result.returncode != 0:
            lines = result.stdout.strip().splitlines()
            failures.append(f'{claim}: the case did not finish ({lines[-1] if lines else "timed out"})')
        else:
            print('ok:', claim, f'({len(reports)} report(s) in the doubles)' if reports else '')

for item in skipped:
    print('SKIP:', item)
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: one batch per patient, every controller released, the process send slots shared without a race')
