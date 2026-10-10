#!/usr/bin/env python3
"""A DICOMweb retrieve recovers from what interrupts it, and a held delivery is no inactivity.

A user retrieving about ten studies at once over DICOMweb found slices missing
from some, to be fetched again by hand. A study cut in the middle of its
response was left so: the first error stopped every request still queued, and
the pass that asks for each listed instance still missing ran only without
one. And a cut was easy to come by: while the importer was behind, one
response held its session's delegate queue for its reader, and every other
request of that session, receiving nothing meanwhile, timed out after 60 s of
"inactivity".

The client's sources, with HorosDICOMwebRetrieveRecovery, compiled with the
DICOM-Swift products the app links, over loopback:

- the recovery policy: a lost connection, a timeout, an answer cut short or
  invalid, HTTP 206, 408, 425, 429, 500, 502, 503 and 504 are asked again, or
  resumed when something arrived, up to three attempts in all; HTTP 404, 410,
  400 or 406 are left missing; authentication, credentials, the node's
  settings, TLS, a redirect and a cancellation stop the retrieve; the wait
  before an attempt is 1, 2, 4 s, or the node's Retry-After up to a minute;
- an answer of 206 Partial Content hands over what it brought and says so,
  as HTTP 206 with the count, which the policy resumes;
- three retrieves at once on one session: while the first holds its delivery
  for a reader slower than the inactivity timeout, a second that keeps
  arriving is not timed out and completes; a third whose node stopped sending
  still times out.

And in the sources: retrieveDICOMweb recovers each failed request through the
policy, drops an object that another request of the same retrieve already
brought or that is here, resumes a cut study or series without a listing by
asking for it again, asks with a listing for each listed instance still
missing, asks for whole the series the node counts more instances in than it
lists, reports the first failure nothing made up for once every request has
ended, and stops at once only for a failure no request can get past. move:
calls a DICOMweb study the node counts more instances in than are here
incomplete. A retrieve of several studies tells what did not arrive complete
in one notice at its end; the query window does not call a DICOMweb study
"already here" while its node counts more instances than it listed and than
are here.

Needs the prepared DICOM-Swift products; without them this check is skipped
(exit 2).
"""
import http.server
import re
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
sys.path.insert(0, str(ROOT / 'tools'))
from dicomweb_package import swift_flags  # noqa: E402
from local_http import ThreadingLocalHTTPServer  # noqa: E402

failures = []


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


# --- sources ------------------------------------------------------------------

def block(text, start):
    body = text[text.index(start):]
    return body[:body.index('\n}\n')]


node = (ROOT / 'Horos/Sources/DCMTKQueryNode.mm').read_bytes().decode('latin1')
retrieve = block(node, '- (BOOL)retrieveDICOMweb')
recover = retrieve[retrieve.index('void (^recover)(NSDictionary *, NSError *)'):]
recover = recover[:recover.index('\n    };\n')]
check('[HorosDICOMwebRetrieveRecovery actionForError:requestError attempts:made]' in recover,
      'a failed request recovers as the policy says')
check('if (action == HorosDICOMwebRecoveryActionSkip && !uid) action = HorosDICOMwebRecoveryActionStop;' in recover,
      'a study or series request left missing ends the retrieve')
check(re.search(r'case HorosDICOMwebRecoveryActionRetry: \{.*?delayBeforeAttempt:made \+ 1.*?sleepForTimeInterval.*?\[pending addObject:again\]', recover, re.S)
      is not None, 'asked again after the policy\'s wait, which cancellation cuts short')
check(re.search(r'case HorosDICOMwebRecoveryActionResume:.*?\[interrupted addObject:again\]', recover, re.S) is not None,
      'a cut study or series is kept to be resumed')
check(re.search(r'case HorosDICOMwebRecoveryActionSkip:.*?if \(!unresolved\) unresolved = \[requestError retain\]', recover, re.S) is not None,
      'what is left missing is reported once the others have ended')
check(re.search(r'case HorosDICOMwebRecoveryActionStop:.*?if \(!firstError\) firstError = \[requestError retain\]', recover, re.S) is not None,
      'only a failure no request can get past stops the others')
check('} else if (requestError) recover(request, requestError);' in retrieve, 'the workers hand every failure to the policy')
check(retrieve.count('firstError = [requestError retain]') == 1, 'nothing else stops the retrieve')
check('known = [taken containsObject:objectUID] || [localUIDs containsObject:objectUID];' in retrieve
      and '@synchronized (taken) { [taken addObject:objectUID]; }' in retrieve,
      'an object another request brought, or that is here, is dropped')
known = retrieve.index('if (known) {')
check(retrieve.index('if (!valid) return @"WADO-RS returned invalid') < known < retrieve.index('NSString *destination = [incoming'),
      'only once its identifiers are checked, and before it is queued')
resume = retrieve[retrieve.index('    while (YES) {\n        NSArray *resumed;'):]
resume = resume[:resume.index('\n    }\n')]
check('if (!resumed.count || succeeded || failed() || thread.isCancelled) break;' in resume and 'queueRequest(again);' in resume
      and 'drain();' in resume, 'without a listing, a cut request is asked for again until it is not cut')
second = retrieve.index('NSDictionary *left = _retrieveInventory.unreceivedSeries;')
check(second < retrieve.index('while (YES) {\n        NSArray *resumed;'), 'that comes after the pass for what the listing names')
short = retrieve[retrieve.index('NSMutableDictionary *listedInSeries'):]
short = short[:short.index('drain();')]
check('if (counted > listedCount && ![plan isExcludedSeries:seriesUID] && ![done containsObject:base] && ![done containsObject:path])' in short
      and 'enqueue(path, nil, seriesUID);' in short, 'a series listed short is asked for whole, unless it already arrived whole')
check('if (firstError) { error = [firstError autorelease]; [unresolved release]; }\n    else if (unresolved) error = [unresolved autorelease];' in retrieve,
      'the retrieve reports the failure nothing made up for')
check('!failed() && !unresolvedFailure && !thread.isCancelled' in retrieve, 'a node without a listing is not excused when something stayed missing')
move = block(node, '- (void) move:(NSDictionary*) dict retrieveMode: (int) retrieveMode')
check('dicomwebShort = dicomweb && _retrieveInventory.inventoryConfirmed && counted > here && !_retrieveInventory.excludedSeries.count;' in move
      and 'incomplete = _retrieveInventory.needsAttention || !receivedIndexed || dicomwebShort;' in move,
      'a DICOMweb study its node counts more instances in than are here is incomplete')
check('if (incomplete && showErrorMessage && !self.deferFailureNotice' in move
      and 'if (showErrorMessage && !self.deferFailureNotice)' in block(node, '- (BOOL)reportDICOMwebError:'),
      'a retrieve of several studies defers each one\'s notice')
check('_lastRetrieveIncomplete = !NSThread.currentThread.isCancelled && (incomplete || reportedDICOMwebFailure);' in move,
      'each retrieve says whether it ended incomplete')
query = (ROOT / 'Horos/Sources/QueryController.mm').read_bytes().decode('latin1')
perform = block(query, '- (void) performRetrieve:(NSArray*) array')
check('BOOL batch = moveArray.count > 1;' in perform and '[[d objectForKey: @"query"] setDeferFailureNotice: YES];' in perform,
      'several studies defer their notices')
check(perform.index('setDeferFailureNotice: YES') < perform.index('[object move: d retrieveMode:') < perform.index('NSMutableArray *incomplete = [NSMutableArray array];'),
      'before the retrieves, told after them')
check('%lu of %lu did not arrive complete. Retrieve them again to complete them:' in perform and 'object.lastRetrieveIncomplete == NO || object.showErrorMessage == NO' in perform,
      'one notice lists what did not arrive complete')
check('inventory.unlistedCount > 0 && localNumber < [[item valueForKey:@"numberImages"] intValue]' in query and '!inventory.isSatisfied || listingShort' in query,
      'a DICOMweb study listed short is not "already here"')

# --- client -------------------------------------------------------------------

BOUNDARY = 'recovery1253'
HOLD_PARTS, HOLD_PAYLOAD = 12, 512 * 1024
STEADY_PARTS = 6


def element(group, elem, vr, value):
    if len(value) % 2:
        value += b'\0' if vr == b'UI' else b' '
    if vr in (b'OB', b'OW', b'SQ', b'UN', b'UT'):
        return struct.pack('<HH', group, elem) + vr + b'\0\0' + struct.pack('<I', len(value)) + value
    return struct.pack('<HH', group, elem) + vr + struct.pack('<H', len(value)) + value


def part10(uid, payload=b''):
    meta = (element(2, 1, b'OB', b'\0\1') + element(2, 2, b'UI', b'1.2.840.10008.5.1.4.1.1.7')
            + element(2, 3, b'UI', uid.encode()) + element(2, 0x10, b'UI', b'1.2.840.10008.1.2.1'))
    data = element(8, 0x16, b'UI', b'1.2.840.10008.5.1.4.1.1.7') + element(8, 0x18, b'UI', uid.encode())
    if payload:
        data += element(0x7FE0, 0x10, b'OB', payload)
    return b'\0' * 128 + b'DICM' + element(2, 0, b'UL', struct.pack('<I', len(meta))) + meta + data


def part(uid, payload=b''):
    return f'--{BOUNDARY}\r\nContent-Type: application/dicom\r\n\r\n'.encode() + part10(uid, payload) + b'\r\n'


stop = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def write(self, data):
        self.wfile.write(f'{len(data):x}\r\n'.encode() + data + b'\r\n')
        self.wfile.flush()

    def do_GET(self):
        scenario = self.path.strip('/').split('/')[-1].split('.')[-1]
        self.send_response(206 if scenario == 'partial' else 200)
        self.send_header('Content-Type', f'multipart/related; type="application/dicom"; boundary={BOUNDARY}')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        try:
            if scenario == 'hold':
                for n in range(1, HOLD_PARTS + 1):
                    data = part(f'2.25.1253.hold.{n}', bytes([n]) * HOLD_PAYLOAD)
                    for offset in range(0, len(data), 64 * 1024):
                        self.write(data[offset:offset + 64 * 1024])
            elif scenario == 'steady':
                # A part every 0.25 s, the pause inside the next one.
                parts = [part(f'2.25.1253.steady.{n}', b's' * 4096) for n in range(1, STEADY_PARTS + 1)]
                self.write(parts[0] + parts[1][:300])
                for n in range(1, STEADY_PARTS):
                    time.sleep(0.25)
                    self.write(parts[n][300:] + (parts[n + 1][:300] if n + 1 < STEADY_PARTS else b''))
            elif scenario == 'stall':
                second = part('2.25.1253.stall.2', b'z' * 4096)
                self.write(part('2.25.1253.stall.1') + second[:600])
                stop.wait(30)
                return
            elif scenario == 'partial':
                self.write(part('2.25.1253.partial.1') + part('2.25.1253.partial.2'))
            self.write(f'--{BOUNDARY}--\r\n'.encode())
            self.wfile.write(b'0\r\n\r\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True


DRIVER = r'''
import Foundation
import DicomWebClient
import DicomData

nonisolated(unsafe) var failed = false
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failed = true } }

final class Outcome: @unchecked Sendable {
    let lock = NSLock()
    var uids: [String] = []
    var error: NSError?
    var ended = 0.0
}

func error(_ kind: DICOMwebErrorKind, _ code: Int, handedOver: Int = 0) -> NSError {
    let e = DICOMwebClient.failure(code, "synthetic", kind: kind)
    guard handedOver > 0 else { return e }
    var info = e.userInfo
    info[DICOMwebClient.objectsHandedOverKey] = handedOver
    return NSError(domain: e.domain, code: e.code, userInfo: info)
}

@main struct Check {
    static func main() {
        if NonInteractiveKeychainRead.runHelperIfRequested() { exit(0) }
        let base = CommandLine.arguments[1], work = CommandLine.arguments[2]
        typealias R = DICOMwebRetrieveRecovery
        func action(_ e: NSError, _ attempts: Int = 1) -> DICOMwebRecoveryAction { R.action(for: e, attempts: attempts) }
        // The policy.
        for (kind, code) in [(DICOMwebErrorKind.network, 0), (.timeout, Int(NSURLErrorTimedOut)), (.invalidResponse, 4),
                             (.http, 206), (.http, 408), (.http, 425), (.http, 429), (.http, 500), (.http, 502), (.http, 503), (.http, 504)] {
            check(action(error(kind, code)) == .retry, "\(kind.rawValue)/\(code) is asked again")
            check(action(error(kind, code), 2) == .retry, "\(kind.rawValue)/\(code) is asked a third time")
            check(action(error(kind, code), 3) == .skip, "\(kind.rawValue)/\(code) is left missing after three attempts")
            check(action(error(kind, code, handedOver: 5)) == .resume, "\(kind.rawValue)/\(code) after some objects is resumed")
            check(action(error(kind, code, handedOver: 5), 3) == .skip, "\(kind.rawValue)/\(code) after three attempts is left missing, even after some objects")
        }
        for (kind, code) in [(DICOMwebErrorKind.notFound, 404), (.http, 410), (.http, 400), (.http, 406), (.http, 501)] {
            check(action(error(kind, code)) == .skip, "\(kind.rawValue)/\(code) is left missing at once")
            check(action(error(kind, code, handedOver: 2)) == .skip, "\(kind.rawValue)/\(code) after some objects is left missing")
        }
        for (kind, code) in [(DICOMwebErrorKind.authentication, 401), (.authentication, 403), (.credentials, 1), (.configuration, 1),
                             (.tls, Int(NSURLErrorServerCertificateUntrusted)), (.redirect, 302), (.cancelled, Int(NSURLErrorCancelled))] {
            check(action(error(kind, code)) == .stop, "\(kind.rawValue)/\(code) stops the retrieve")
            check(action(error(kind, code, handedOver: 3)) == .stop, "\(kind.rawValue)/\(code) after some objects stops the retrieve")
        }
        check(R.maximumAttempts == 3, "three attempts in all")
        check(R.delay(beforeAttempt: 2, retryAfter: nil) == 1 && R.delay(beforeAttempt: 3, retryAfter: nil) == 2
              && R.delay(beforeAttempt: 4, retryAfter: nil) == 4, "1, 2, 4 s before the attempts after the first")
        check(R.delay(beforeAttempt: 2, retryAfter: "7") == 7 && R.delay(beforeAttempt: 2, retryAfter: "600") == 60
              && R.delay(beforeAttempt: 2, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT") == 1,
              "the node's Retry-After in seconds, at most a minute; a date is not waited for")

        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { done.signal() }
            func client(_ timeout: Double) throws -> DICOMwebClient {
                DICOMwebClient(node: try DICOMwebNodeConfiguration(address: base, qidoPath: "", wadoPath: "", credentialIdentifier: "",
                                                                   retrieveTransferSyntax: ""), timeout: timeout)
            }
            func take(_ outcome: Outcome, _ url: URL, pause: Double) -> String? {
                let text = String(decoding: (FileManager.default.contents(atPath: url.path) ?? Data()).prefix(400), as: UTF8.self)
                let uid = text.range(of: #"2\.25\.1253\.[a-z]+\.[0-9]+"#, options: .regularExpression).map { String(text[$0]) } ?? ""
                if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                try? FileManager.default.removeItem(at: url)
                outcome.lock.withLock { outcome.uids.append(uid) }
                return nil
            }
            func run(_ c: DICOMwebClient, _ scenario: String, pause: Double = 0) -> Outcome {
                let outcome = Outcome()
                do {
                    _ = try c.retrieve(path: "studies/2.25.\(scenario)", stagingDirectory: work + "/staging-" + scenario,
                                       objectHandler: { take(outcome, $0, pause: pause) }, cancelled: { false })
                } catch { outcome.error = error as NSError }
                outcome.ended = ProcessInfo.processInfo.systemUptime
                return outcome
            }
            do {
                // A 206 hands over what it brought, and says so.
                let partial = run(try client(10), "partial")
                check(partial.uids == ["2.25.1253.partial.1", "2.25.1253.partial.2"], "206: both parts handed over: \(partial.uids)")
                if let e = partial.error {
                    check(e.code == 206 && DICOMwebClient.errorKind(for: e) == .http, "206: HTTP 206: \(e)")
                    check(e.userInfo[DICOMwebClient.objectsHandedOverKey] as? Int == 2, "206: two objects handed over: \(e.userInfo)")
                    check(R.action(for: e, attempts: 1) == .resume, "206: resumed with what is missing")
                    check(DICOMwebClient.logReason(for: e) == "HTTP 206 after 2 objects", "206: logged as such: \(DICOMwebClient.logReason(for: e) ?? "nil")")
                } else { check(false, "206: not a success") }

                // One session, three retrieves.
                let c = try client(1.5)
                c.responseBudgets.retrieveSegmentBytes = 256 * 1024
                c.responseBudgets.retrieveAheadBytes = 1024 * 1024
                var held = Outcome(), steady = Outcome(), stalled = Outcome()
                let all = DispatchGroup()
                let started = ProcessInfo.processInfo.systemUptime
                all.enter(); Thread.detachNewThread { held = run(c, "hold", pause: 0.6); all.leave() }
                Thread.sleep(forTimeInterval: 1.0)
                all.enter(); Thread.detachNewThread { steady = run(c, "steady"); all.leave() }
                all.enter(); Thread.detachNewThread { stalled = run(c, "stall"); all.leave() }
                all.wait()
                print(String(format: "held %.1f s, steady %.1f s, stalled %.1f s after the start",
                             held.ended - started, steady.ended - started, stalled.ended - started))
                check(held.error == nil && held.uids.count == \(HOLD_PARTS),
                      "the held retrieve completes, its reader slower than the timeout: \(held.uids.count) \(String(describing: held.error))")
                check(steady.error == nil && steady.uids.count == \(STEADY_PARTS),
                      "the steady retrieve on the same session is not timed out while the other holds: \(steady.uids.count) \(String(describing: steady.error))")
                check(stalled.error.map { DICOMwebClient.errorKind(for: $0) == .timeout } == true && stalled.uids == ["2.25.1253.stall.1"],
                      "the stalled retrieve still times out: \(stalled.uids) \(String(describing: stalled.error))")
                check(held.ended - started > 4, "the reader held the delivery for several timeouts (\(held.ended - started) s)")
            } catch { check(false, "unexpected \(error)") }
        }
        done.wait()
        if failed { exit(1) }
        print("PASS: the recovery policy; 206 resumable; a held delivery is no inactivity for its session's other requests, a stall still is")
    }
}
'''.replace('\\(HOLD_PARTS)', str(HOLD_PARTS)).replace('\\(STEADY_PARTS)', str(STEADY_PARTS))

with tempfile.TemporaryDirectory(prefix='horos-dicomweb-recovery-') as folder:
    work = Path(folder)
    flags = swift_flags(work)
    (work / 'check.swift').write_text(DRIVER)
    sources = [str(ROOT / 'Horos/Sources' / name) for name in
               ('DICOMwebClient.swift', 'DICOMwebNode.swift', 'DICOMwebCredentials.swift', 'DICOMwebMultipart.swift',
                'NonInteractiveKeychainRead.swift', 'DICOMwebRetrieveRecovery.swift')]
    executable = work / 'check'
    build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings', '-module-cache-path', str(work / 'cache'),
                            *sources, *flags, str(work / 'check.swift'), '-o', str(executable)],
                           capture_output=True, text=True, timeout=900)
    check(build.returncode == 0, 'the client and the check compile\n' + build.stderr[-4000:])
    if build.returncode == 0:
        server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            result = subprocess.run([str(executable), f'http://127.0.0.1:{server.server_address[1]}', str(work)],
                                    capture_output=True, text=True, timeout=180)
            sys.stdout.write(result.stdout)
            check(result.returncode == 0, 'the client checks\n' + result.stderr[-2000:])
        finally:
            stop.set()
            server.shutdown()
            server.server_close()

if failures:
    raise SystemExit(1)
print('PASS: retrieveDICOMweb recovers each request, resumes cuts, asks again for short listings and tells a batch once')
