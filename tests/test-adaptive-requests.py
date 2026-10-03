#!/usr/bin/env python3
"""A node's automatic request limit follows its answers, within the operator's ceiling.

NodeRequestLimiter, compiled alone, on a clock the test moves:
- the window starts at the node's limit and never leaves 1...limit;
- a busy answer (429/503) or a transient failure halves it, at most once per
  cooldown, so a burst of busy answers counts once; neutral answers
  (authentication, certificate, cancellation) change nothing;
- the node then waits: a valid Retry-After in seconds or as an HTTP date, at
  most 60 s; without one, or with an invalid one, 1, 2, 4... s, at most 30 s;
  no request starts meanwhile, and a cancelled wait takes no slot;
- answered requests add one at a time, after as many answers as the window and
  a cooldown since the last decrease, back up to the limit; an instance far
  slower than the best seen takes one off;
- five minutes without a request start over; a lower limit clamps the window;
- the fixed mode keeps the limit and ignores every answer; nodes are apart;
- HTTP statuses map to outcomes: 2xx answered, 429/503 busy, 408/425/5xx
  transient, the rest neutral.

And in the sources: WADO-RS acquires in the node's mode, reports each
request's outcome (an instance's latency only), asks a busy request that
brought nothing again at most three more times and lets anything else end the
retrieve; its status shows the window; WADO-URI acquires in the node's mode,
reports statuses, failures and answers, and allows more retry passes in the
automatic mode; the client carries a busy answer's Retry-After; both editors
offer the mode, localized in every catalog.
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
var clock: TimeInterval = 1000
let limiter = NodeRequestLimiter()
limiter.now = { clock }
let node = "A"
func fill() -> Int { var n = 0; while limiter.tryAcquire(node: node, limit: 8, adaptive: true) { n += 1 }; for _ in 0..<n { limiter.release(node: node) }; return n }
check(fill() == 8 && limiter.window(node: node) == 8, "starts at the limit")
// A burst of busy answers counts once; the node then waits its Retry-After.
check(limiter.report(node: node, outcome: .throttled, latency: 0, retryAfter: "3") == 4, "halved")
check(limiter.report(node: node, outcome: .throttled, latency: 0, retryAfter: "3") == 4, "once per cooldown")
check(fill() == 0 && abs(limiter.pause(node: node) - 3) < 0.01, "no request during Retry-After")
let started = Date()
check(!limiter.acquire(node: node, limit: 8, adaptive: true, cancelled: { Date().timeIntervalSince(started) > 0.2 }), "a cancelled wait takes no slot")
clock += 3.01
check(fill() == 4, "after the wait, the window")
// Neutral answers change nothing.
for _ in 0..<5 { limiter.report(node: node, outcome: .neutral, latency: 0, retryAfter: nil) }
check(limiter.window(node: node) == 4 && limiter.pause(node: node) == 0, "neutral")
// Answers add one per window's worth, after the cooldown.
for _ in 0..<4 { limiter.report(node: node, outcome: .success, latency: 0.1, retryAfter: nil) }
check(limiter.window(node: node) == 4, "not within the cooldown")
clock += 5
for _ in 0..<4 { limiter.report(node: node, outcome: .success, latency: 0.1, retryAfter: nil) }
check(limiter.window(node: node) == 5, "one more")
for _ in 0..<5 { limiter.report(node: node, outcome: .success, latency: 0.1, retryAfter: nil) }
check(limiter.window(node: node) == 6, "gradually")
for _ in 0..<50 { limiter.report(node: node, outcome: .success, latency: 0.1, retryAfter: nil) }
check(limiter.window(node: node) == 8, "never above the limit")
// Slow: one off.
limiter.report(node: node, outcome: .success, latency: 0.5, retryAfter: nil)
check(limiter.window(node: node) == 7, "an instance far slower takes one off")
// Backoff without or with an invalid Retry-After: 1, 2, 4 s; HTTP date; caps.
clock += 10
limiter.report(node: node, outcome: .transient, latency: 0, retryAfter: nil)
check(abs(limiter.pause(node: node) - 1) < 0.01, "first backoff 1 s")
limiter.report(node: node, outcome: .throttled, latency: 0, retryAfter: "soon")
check(abs(limiter.pause(node: node) - 2) < 0.01, "invalid Retry-After: backoff 2 s")
limiter.report(node: node, outcome: .throttled, latency: 0, retryAfter: "")
check(abs(limiter.pause(node: node) - 4) < 0.01, "then 4 s")
for _ in 0..<10 { limiter.report(node: node, outcome: .throttled, latency: 0, retryAfter: nil) }
check(limiter.pause(node: node) <= 30.01, "backoff at most 30 s")
check(AdaptiveWindow.retryAfter("3600", at: Date()) == 60, "Retry-After at most 60 s")
let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "GMT")
format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
let date = format.string(from: Date().addingTimeInterval(10))
check(abs((AdaptiveWindow.retryAfter(date, at: Date()) ?? 0) - 10) < 1.5, "HTTP date: \(date)")
check(AdaptiveWindow.retryAfter("-5", at: Date()) == nil && AdaptiveWindow.retryAfter("Tomorrow", at: Date()) == nil, "invalid values")
check(limiter.window(node: node) >= 1, "never below 1")
// Expiry, a lower limit, the fixed mode, nodes apart.
clock += 301
check(fill() == 8, "five minutes later it starts over")
check(limiter.tryAcquire(node: node, limit: 3, adaptive: true) && limiter.window(node: node) == 3, "a lower limit clamps")
limiter.release(node: node)
check(limiter.tryAcquire(node: "B", limit: 2, adaptive: false), "fixed mode")
check(limiter.report(node: "B", outcome: .throttled, latency: 0, retryAfter: "9") == 0 && limiter.pause(node: "B") == 0, "the fixed mode ignores answers")
limiter.release(node: "B")
check(limiter.window(node: node) == 3, "another node's answers do not move this one")
check(NodeRequestLimiter.outcome(forStatus: 200) == .success && NodeRequestLimiter.outcome(forStatus: 429) == .throttled &&
      NodeRequestLimiter.outcome(forStatus: 503) == .throttled && NodeRequestLimiter.outcome(forStatus: 502) == .transient &&
      NodeRequestLimiter.outcome(forStatus: 408) == .transient && NodeRequestLimiter.outcome(forStatus: 401) == .neutral &&
      NodeRequestLimiter.outcome(forStatus: 403) == .neutral && NodeRequestLimiter.outcome(forStatus: 404) == .neutral, "statuses")
check(NodeRequestLimiter.adaptive(forStoredValue: NSNumber(value: true)) && !NodeRequestLimiter.adaptive(forStoredValue: nil) &&
      NodeRequestLimiter.adaptive(forStoredValue: "YES"), "stored mode")
print("PASS: start, halving with hysteresis, Retry-After and backoff, gradual increase, slow, neutral, expiry, clamp, fixed, nodes apart")
'''

with tempfile.TemporaryDirectory(prefix='horos-adaptive-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(root / 'Horos/Sources/NodeRequestLimiter.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True, timeout=300)
    run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
    print(run.stdout.strip())
    check(run.returncode == 0, 'the automatic limit check failed: ' + run.stdout[-300:])

node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()
retrieve = node[node.index('- (BOOL)retrieveDICOMweb'):]
retrieve = retrieve[:retrieve.index('\n}\n')]
check('BOOL adaptive = node.adaptiveRequests;' in retrieve and 'acquireNode:limiterNode limit:limit adaptive:adaptive' in retrieve,
      'WADO-RS acquires in the node mode')
check('reportNode:limiterNode outcome:outcome' in retrieve and
      "latency:[request objectForKey:@\"uid\"] ? NSProcessInfo.processInfo.systemUptime - started : 0" in retrieve,
      'WADO-RS reports, with an instance latency only')
check('attempts < 3' in retrieve and "[[requestError.userInfo objectForKey:@\"HorosDICOMwebObjectsHandedOver\"] unsignedIntegerValue] == 0" in retrieve,
      'a busy request that brought nothing is asked again, a bounded number of times')
check('else if (requestError) @synchronized (poolGuard) { if (!firstError) firstError = [requestError retain]; }' in retrieve,
      'anything else ends the retrieve')
check('requests at once (automatic)' in retrieve, 'the status shows the window')
check(node.count('downloader.adaptiveRequests = [HorosNodeRequestLimiter adaptiveForStoredValue:') == 3, 'WADO-URI uses the node mode')
download = (root / 'Horos/Sources/WADODownload.swift').read_text()
check('tryAcquire(node: node!, limit: Int(WADOMaximumConcurrentDownloads), adaptive: self.adaptiveRequests)' in download and
      'report(NodeRequestLimiter.outcome(forStatus: statusCode), task: task, retryAfter:' in download and
      'if adaptiveRequests { attempts = max(attempts, 4) }' in download, 'WADO-URI acquires, reports and retries in the automatic mode')
client = (root / 'Horos/Sources/DICOMwebClient.swift').read_text()
check('info[Self.retryAfterKey] = wait' in client and 'RequestOutcome' not in client, 'the client carries Retry-After and stays apart')
editor = (root / 'Horos/Sources/DICOMwebNodeEditor.swift').read_text()
check('node.adaptiveRequests = (object as? NSNumber)?.boolValue ?? false' in editor, 'the DICOMweb table edits the mode')
pane = (root / 'Preference Panes/OSILocationsPreferencePane/OSILocationsPreferencePanePref.swift').read_text()
check('automatic.bind(.value, to: self, withKeyPath: "WADOAdaptiveRequests"' in pane and
      'forKey: NodeRequestLimiter.wadoAdaptiveKey as NSString' in pane, 'the WADO sheet edits and saves the mode')
for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    data = catalog.read_bytes()
    text = data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode('utf-8')
    check('"Automatic Limit" =' in text and 'requests at once (automatic)" =' in text and
          'Automatic: fewer requests at once' in text, f'{catalog.parent.name}: strings missing')

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
