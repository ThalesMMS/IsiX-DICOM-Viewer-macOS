#!/usr/bin/env python3
"""Activity tasks show how many items are done and of how many: «123/1.234».

ActivityProgressCount.swift is compiled as it is, with a double for the two
NSThread properties it writes (progressDetails and progress, which the app
gets from Nitrogen), and driven as the tasks drive it:
- text: the count is grouped as the locale groups digits (1.234 in pt-BR,
  1,234 in en); an unknown total (0 or less) shows the count alone; a peer
  that reports more items than it announced never shows «5/3»; a negative
  count shows 0.
- throttle: the first and the last item always update the thread; between
  them, at most one update every quarter of a second, and a count held back
  is shown when the quarter ends, so the end of a burst without a total (an
  incoming association) or of a cancelled task is not lost.
- thread: a count sets the progress details, and the bar only when asked;
  a receiving association counts one item at a time without a total.
- wiring: the activity cell observes the details, stops observing them and
  draws them; every task with a total reports its count (C-MOVE and C-GET,
  WADO, DICOMweb, C-STORE send, copy to another source, file import) and an
  incoming C-STORE counts what it received.

`<git revision>` as an optional argument reads the wired sources from that
revision, the negative control for the wiring.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []
cell = source('Horos/Sources/ThreadCell.swift')
if 'addObserver(self, forKeyPath: NSThreadProgressDetailsKey' not in cell:
    failures.append('the activity cell must observe the progress details')
if 'removeObserver(self, forKeyPath: NSThreadProgressDetailsKey' not in cell:
    failures.append('the activity cell must stop observing the progress details')
if 'progressDetails' not in cell[cell.find('func drawInterior'):]:
    failures.append('the activity cell must draw the progress details')

WIRED = {
    'Horos/Sources/DCMTKQueryNode.mm': ['setDone: finished total: accounted', 'setDone: self.countOfSuccessfulSuboperations total: self.countOfSuboperations'],
    'Horos/Sources/WADODownload.swift': ['ActivityProgressCount.set(done: Int((WADOTotal - WADOThreads) + WADOBaseTotal), total: Int(WADOGrandTotal)'],
    'Horos/Sources/DCMTKStoreSCU.mm': ['setDone: [[userInfo objectForKey: @"NumberSent"] integerValue] total: [[userInfo objectForKey: @"SendTotal"] integerValue]'],
    'Horos/Sources/BrowserController+Sources+Copy.swift': ['ActivityProgressCount.set(done: i, total: imagePaths.count'],
    'Horos/Sources/DicomDatabase.mm': ['total: paths.count onThread: thread', 'total: dicomFilesArray.count onThread: thread'],
    'Horos/Sources/HorosQueryRetrieveServer.mm': ['countOneOnThread:'],
}
for path, needles in WIRED.items():
    text = source(path)
    for needle in needles:
        if needle not in text:
            failures.append(f'{Path(path).name} does not report its count ({needle[:50]}...)')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

DOUBLE = r'''
import Foundation
import ObjectiveC

// Nitrogen's two NSThread properties, as plain associated values.
nonisolated(unsafe) private var detailsKey: UInt8 = 0
nonisolated(unsafe) private var progressKey: UInt8 = 0
nonisolated(unsafe) private var writesKey: UInt8 = 0
extension Thread {
    @objc var progressDetails: String? {
        get { objc_getAssociatedObject(self, &detailsKey) as? String }
        set {
            objc_setAssociatedObject(self, &detailsKey, newValue, .OBJC_ASSOCIATION_COPY)
            objc_setAssociatedObject(self, &writesKey, NSNumber(value: detailWrites + 1), .OBJC_ASSOCIATION_RETAIN)
        }
    }
    @objc var progress: CGFloat {
        get { CGFloat((objc_getAssociatedObject(self, &progressKey) as? NSNumber)?.doubleValue ?? -1) }
        set { objc_setAssociatedObject(self, &progressKey, NSNumber(value: Double(newValue)), .OBJC_ASSOCIATION_RETAIN) }
    }
    var detailWrites: Int { (objc_getAssociatedObject(self, &writesKey) as? NSNumber)?.intValue ?? 0 }
}
'''

DRIVER = r'''
import Foundation

typealias C = ActivityProgressCount
let pt = Locale(identifier: "pt_BR"), en = Locale(identifier: "en_US")
func expect(_ got: String, _ want: String, _ what: String) {
    precondition(got == want, "\(what): \(got) != \(want)")
}
expect(C.text(done: 123, total: 1234, locale: pt), "123/1.234", "pt grouping")
expect(C.text(done: 123, total: 1234, locale: en), "123/1,234", "en grouping")
expect(C.text(done: 1234567, total: 0, locale: pt), "1.234.567", "unknown total")
expect(C.text(done: 7, total: -1, locale: en), "7", "negative total")
expect(C.text(done: 5, total: 3, locale: en), "5/5", "peer that recounts")
expect(C.text(done: -2, total: 10, locale: en), "0/10", "negative count")
expect(C.text(done: 0, total: 10, locale: en), "0/10", "nothing yet")

precondition(C.shouldUpdate(done: 1, total: 100, now: 10, last: 0), "the first update")
precondition(!C.shouldUpdate(done: 2, total: 100, now: 10.1, last: 10), "too soon")
precondition(C.shouldUpdate(done: 3, total: 100, now: 10.25, last: 10), "a quarter of a second later")
precondition(C.shouldUpdate(done: 100, total: 100, now: 10.01, last: 10), "the last item")
precondition(!C.shouldUpdate(done: 5, total: 0, now: 10.01, last: 10), "no total, too soon")

// on a thread: details always, the bar only when asked
let t = Thread()
C.set(done: 10, total: 40, on: t)
precondition(t.progressDetails == C.text(done: 10, total: 40) && t.progress == -1, "details without the bar: \(String(describing: t.progressDetails)) \(t.progress)")
let u = Thread()
C.set(done: 10, total: 40, setsProgress: true, on: u)
precondition(abs(Double(u.progress) - 0.25) < 1e-9, "the bar: \(u.progress)")

// a burst of 1000 items within a few milliseconds: first and last only
let v = Thread()
for i in 1...1000 { C.set(done: i, total: 1000, on: v) }
precondition(v.detailWrites == 2 && v.progressDetails == C.text(done: 1000, total: 1000), "burst wrote \(v.detailWrites) times, last \(String(describing: v.progressDetails))")

// a receiving association: one at a time, no total
let w = Thread()
C.countOne(on: w)
precondition(w.progressDetails == C.text(done: 1, total: 0), "first received")
Thread.sleep(forTimeInterval: 0.3)
C.countOne(on: w); C.countOne(on: w)
precondition(w.progressDetails == C.text(done: 2, total: 0), "second received after the interval: \(String(describing: w.progressDetails))")
Thread.sleep(forTimeInterval: 0.4)
precondition(w.progressDetails == C.text(done: 3, total: 0), "the held-back third: \(String(describing: w.progressDetails))")
C.countOne(on: w)
Thread.sleep(forTimeInterval: 0.4)
precondition(w.progressDetails == C.text(done: 4, total: 0), "the count kept going while throttled: \(String(describing: w.progressDetails))")

// a burst without a total: the first count at once, the last one when the interval ends
let x = Thread()
for _ in 1...57 { C.countOne(on: x) }
precondition(x.progressDetails == C.text(done: 1, total: 0), "burst start: \(String(describing: x.progressDetails))")
Thread.sleep(forTimeInterval: 0.5)
precondition(x.progressDetails == C.text(done: 57, total: 0), "the burst's last count was lost: \(String(describing: x.progressDetails))")
// a burst that ends at its total leaves nothing behind: still two writes
precondition(v.detailWrites == 2, "a finished burst wrote again: \(v.detailWrites)")
// a count held back and never followed (a cancelled task) is shown too
let y = Thread()
C.set(done: 1, total: 100, setsProgress: true, on: y)
C.set(done: 40, total: 100, setsProgress: true, on: y)
Thread.sleep(forTimeInterval: 0.5)
precondition(y.progressDetails == C.text(done: 40, total: 100) && abs(Double(y.progress) - 0.4) < 1e-9, "held-back count: \(String(describing: y.progressDetails)) \(y.progress)")
C.set(done: 1, total: 1, on: nil)
print("PASS: counts grouped by locale, unknown and recounted totals, throttled to first, last and every quarter second without losing the end of a burst, bar only when asked; every task with a total reports its count and the cell shows it")
'''

with tempfile.TemporaryDirectory(prefix='horos-activity-count-') as directory:
    p = Path(directory)
    (p / 'double.swift').write_text(DOUBLE)
    (p / 'main.swift').write_text(DRIVER)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(root / 'Horos/Sources/ActivityProgressCount.swift'),
                    str(root / 'Horos/Sources/IdentityToken.swift'),
                    str(p / 'double.swift'), str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
