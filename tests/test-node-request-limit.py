#!/usr/bin/env python3
"""Each node has its own limit of requests at once, shared by its retrieves.

NodeRequestLimiter, compiled alone:
- a stored limit is clamped into 1...16 deterministically (0 and negatives to
  1, above 16 to 16, numeric text read, anything else the fallback);
- a WADO-URI node without its own limit takes the former global setting,
  WADOMaximumConcurrentDownloads (10 when unset), clamped the same way;
- twelve requests of one node with a limit of 4 never run more than four at
  once, with 1 one at a time, while another node's requests are not held by
  them; a cancelled wait gives no slot.

And in the sources: a DICOMweb node stores MaxRequests (default 4, clamped,
kept when saved); WADO-URI passes take a node slot before each request and
give it back when its task completes or the pass ends; retrieveDICOMweb runs
its requests on a pool of at most the node's limit, each request holding a
node slot, the first error stopping the rest and cancellation reaching every
worker; the Locations pane shows a Parallel Requests column for DICOMweb nodes
and a row in the WADO sheet, made in code for every localization, and saves
the WADO node's choice.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


driver = r'''
import Foundation
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }
typealias L = NodeRequestLimiter
check(L.limit(forStoredValue: nil, fallback: 4) == 4, "nothing stored: the fallback")
check(L.limit(forStoredValue: NSNumber(value: 0), fallback: 4) == 1 && L.limit(forStoredValue: NSNumber(value: -3), fallback: 4) == 1, "below 1")
check(L.limit(forStoredValue: NSNumber(value: 50), fallback: 4) == 16, "above 16")
check(L.limit(forStoredValue: " 8 ", fallback: 4) == 8 && L.limit(forStoredValue: "many", fallback: 4) == 4, "text")
check(L.limit(forStoredValue: nil, fallback: 99) == 16, "the fallback is clamped too")
let defaults = UserDefaults(suiteName: "horos-node-limit-\(getpid())")!
defer { defaults.removePersistentDomain(forName: "horos-node-limit-\(getpid())") }
check(L.wadoLimit(forServer: [:], defaults: defaults) == 10, "the former default, 10")
defaults.set(30, forKey: "WADOMaximumConcurrentDownloads")
check(L.wadoLimit(forServer: [:], defaults: defaults) == 16, "a former setting above 16")
defaults.set(0, forKey: "WADOMaximumConcurrentDownloads")
check(L.wadoLimit(forServer: [:], defaults: defaults) == 1, "a former setting of 0")
check(L.wadoLimit(forServer: ["WADOMaxRequests": 6], defaults: defaults) == 6, "the node's own setting wins")
check(L.wadoKey(forServer: ["Address": "a", "WADOPort": 80, "WADOUrl": "wado"]) != L.wadoKey(forServer: ["Address": "b", "WADOPort": 80, "WADOUrl": "wado"]), "nodes apart")

func run(_ limiter: L, node: String, limit: Int, requests: Int, hold: TimeInterval) {
    let group = DispatchGroup()
    for _ in 0..<requests {
        group.enter()
        Thread.detachNewThread {
            if limiter.acquire(node: node, limit: limit, cancelled: { false }) {
                Thread.sleep(forTimeInterval: hold)
                limiter.release(node: node)
            }
            group.leave()
        }
    }
    group.wait()
}
let limiter = L()
run(limiter, node: "A", limit: 4, requests: 12, hold: 0.05)
check(limiter.peak(node: "A") == 4 && limiter.active(node: "A") == 0, "a limit of 4: peak \(limiter.peak(node: "A"))")
limiter.resetPeak(node: "A")
run(limiter, node: "A", limit: 1, requests: 6, hold: 0.02)
check(limiter.peak(node: "A") == 1, "a limit of 1 is one after the other")
// Node A full: node B is not held by it.
for _ in 0..<2 { check(limiter.tryAcquire(node: "A", limit: 2), "A takes its slots") }
check(!limiter.tryAcquire(node: "A", limit: 2), "A is full")
check(limiter.tryAcquire(node: "B", limit: 2), "B is not held by A")
let started = Date()
check(!limiter.acquire(node: "A", limit: 2, cancelled: { Date().timeIntervalSince(started) > 0.2 }), "a cancelled wait gets no slot")
check(limiter.active(node: "A") == 2, "the cancelled wait took nothing")
limiter.release(node: "A"); limiter.release(node: "A"); limiter.release(node: "B")
check(limiter.active(node: "A") == 0 && limiter.active(node: "B") == 0, "every slot given back")
print("PASS: limits clamped, legacy fallback, shared cap, sequential at 1, nodes apart, cancellation")
'''

with tempfile.TemporaryDirectory(prefix='horos-node-limit-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(root / 'Horos/Sources/NodeRequestLimiter.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip())
    check(run.returncode == 0, 'the limiter check failed')

node = (root / 'Horos/Sources/DICOMwebNode.swift').read_text()
check('public static let maximumRequests = "MaxRequests"' in node and 'defaultMaximumRequests = 4' in node and
      'min(max(value, 1), 16)' in node and 'node[Key.maximumRequests] = maximumRequests' in node,
      'a DICOMweb node stores MaxRequests, 4 by default, clamped')
wado = (root / 'Horos/Sources/WADODownload.swift').read_text()
check('!NodeRequestLimiter.shared.tryAcquire(node: node!, limit: Int(WADOMaximumConcurrentDownloads), adaptive: self.adaptiveRequests)' in wado,
      'a WADO-URI request waits for a node slot')
check('if slotHeld.remove(task) != nil, let node = limiterNode { NodeRequestLimiter.shared.release(node: node) }' in wado,
      'its task completion gives the slot back')
check('for _ in self.slotHeld { NodeRequestLimiter.shared.release(node: node) }' in wado, 'the pass end gives back what is left')
query = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()
check(query.count('downloader.limiterNode = [HorosNodeRequestLimiter WADOKeyForServer:_extraParameters];') == 3,
      'every WADO-URI retrieve of a node uses its limit')
retrieve = query[query.index('- (BOOL)retrieveDICOMweb'):]
retrieve = retrieve[:retrieve.index('\n}\n')]
check('if (running >= (NSUInteger)limit) return;' in retrieve, 'at most the node limit of workers')
acquire = retrieve.index('acquireNode:limiterNode limit:limit')
check(acquire < retrieve.index('@try { requestError = take(') < retrieve.index('releaseNode:limiterNode'),
      'each request holds a node slot')
check('if (!firstError) firstError = [requestError retain];' in retrieve and 'error = [firstError autorelease]' in retrieve,
      'the first error stops the rest and is kept across threads')
check('[worker cancel]' in retrieve, 'cancellation reaches the workers')
editor = (root / 'Horos/Sources/DICOMwebNodeEditor.swift').read_text()
check('NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Column.maximumRequests))' in editor and
      'node.maximumRequests = DICOMwebNode.maximumRequestsChoices[index]' in editor, 'the DICOMweb table edits the limit')
pane = (root / 'Preference Panes/OSILocationsPreferencePane/OSILocationsPreferencePanePref.swift').read_text()
check('addWADORetrieveRows(to: sheet)' in pane and 'forKey: NodeRequestLimiter.wadoKey as NSString' in pane and
      'popup.bind(.selectedTag, to: self, withKeyPath: key' in pane and 'key: "WADOMaxRequests"' in pane, 'the WADO sheet edits and saves the limit')
check('WADOMaxRequests' not in ''.join(p.read_text(errors='ignore') for p in (root / 'Horos/Resources').glob('*.lproj/OSILocationsPreferencePanePref.xib')),
      'no localized nib carries a copy of the new row')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
