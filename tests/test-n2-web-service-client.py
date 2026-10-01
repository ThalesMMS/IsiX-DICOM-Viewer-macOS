#!/usr/bin/env python3
"""The N2 web service clients keep their synchronous contract over URLSession (#969).

N2WebServiceClient and N2RedundantWebServiceClient are SDK API for plugins; the
application itself never calls them, so nothing else exercises them. Their
transport was NSURLConnection's sendSynchronousRequest and is now URLSession.
What a plugin sees must not change: the request it sends (method, URL,
parameters, headers, body), the data it gets back, and the NSException it
catches when the server refuses, is unreachable or does not answer in time.

The two production sources are compiled with the Objective-C exception bridge
and driven against a local HTTP server started here. Calls are made from the
main thread and from a background thread: the wait must not depend on the
caller's run loop.
"""
from http.server import BaseHTTPRequestHandler
from pathlib import Path
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
from local_http import ThreadingLocalHTTPServer  # noqa: E402
client = root / 'Nitrogen/Sources/N2WebServiceClient.swift'
redundant = root / 'Nitrogen/Sources/N2RedundantWebServiceClient.swift'
failures = []

# --- no NSURLConnection left outside WADO (whose transport is #968's) -------
for folder in ('Horos/Sources', 'Nitrogen/Sources', 'Preference Panes', 'DCM Framework', 'DICOMPrint'):
    for path in sorted((root / folder).rglob('*')):
        if path.suffix not in ('.swift', '.m', '.mm', '.h') or path.name.startswith('WADODownload'):
            continue
        if b'NSURLConnection' in path.read_bytes():
            failures.append('%s still uses NSURLConnection' % path.relative_to(root))
browser = (root / 'Horos/Sources/BrowserController.m').read_bytes()
if b'WITH_BANNER' in browser.replace(b'when WITH_BANNER was defined', b''):
    failures.append('BrowserController still has WITH_BANNER blocks')
if b'- (IBAction) clickBanner:(id) sender' not in browser:
    failures.append('clickBanner:, declared in the public header, is gone')

# --- the server --------------------------------------------------------------
hits = {'/post-once': 0, '/echo': 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body=b'', content_type='text/plain'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length else b''
        path, _, query = self.path.partition('?')
        if path in hits:
            hits[path] += 1
        if path in ('/echo', '/post-once'):
            self.answer(200, json.dumps({
                'method': self.command, 'path': path, 'query': query,
                'contentType': self.headers.get('Content-Type'),
                'custom': self.headers.get('X-Horos-Test'),
                'length': self.headers.get('Content-Length'),
                'body': body.decode('utf-8', 'replace')}).encode(), 'application/json')
        elif path == '/refused':
            self.answer(503, b'busy')
        elif path == '/missing':
            self.answer(404, b'no')
        elif path == '/empty':
            self.answer(200)
        elif path == '/slow':
            time.sleep(12)  # the client's timeout is 10 s
            self.answer(200, b'late')
        else:
            self.answer(500)

    do_GET = handle_any
    do_POST = handle_any


server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
with socket.socket() as probe:  # a port nothing listens on
    probe.bind(('127.0.0.1', 0))
    closed = probe.getsockname()[1]
base = 'http://127.0.0.1:%d' % port

DRIVER = r'''
import Foundation

let base = CommandLine.arguments[1]
let closed = CommandLine.arguments[2]

func emit(_ key: String, _ value: String) { print(key + "\t" + value.replacingOccurrences(of: "\n", with: " ")) }

/// The call, as a plugin makes it: the data, or the exception's reason.
func call(_ key: String, _ body: () -> Data?) {
    var result: Data?
    do {
        try HorosObjCException.perform { result = body() }
        if let result {
            emit(key, "data:" + (String(data: result, encoding: .utf8) ?? "<binary>"))
        } else {
            emit(key, "nil")
        }
    } catch {
        let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        emit(key, "exception:" + (exception?.name.rawValue ?? "?") + ":" + (exception?.reason ?? ""))
    }
}

// The Objective-C selectors plugins send.
for selector in ["initWithURL:", "requestWithURL:method:content:headers:context:",
                 "requestWithMethod:content:headers:context:", "requestWithMethod:content:headers:",
                 "getWithParameters:", "postWithContent:", "postWithParameters:",
                 "processUrl:context:", "validateResult:"] {
    let responds = N2WebServiceClient.instancesRespond(to: NSSelectorFromString(selector))
    emit("selector." + selector, responds ? "yes" : "no")
}

let echo = N2WebServiceClient(url: URL(string: base + "/echo?kept=1"))
call("get") { echo.get(withParameters: ["name": "a b"]) }
let special = "space é 日本 +%&=/?:#[]@!$'()*,;"
call("get.reserved") { echo.get(withParameters: ["key +&=": special, "empty": ""]) }
call("post.reserved") { echo.post(withParameters: ["key +&=": special, "empty": ""]) }
call("get.rawQuery") { echo.request(with: HTTPGet, content: "&raw=a b%".data(using: .utf8), headers: nil) }
final class CapturingClient: N2WebServiceClient {
    var sent: URL?
    override func processUrl(_ url: URL?, context: Any?) -> URL? { sent = url; return url }
}
let fragmented = CapturingClient(url: URL(string: base + "/echo?old=1#keep"))
call("get.fragment") { fragmented.get(withParameters: ["encoded": "%20 +"]) }
emit("get.fragment.value", fragmented.sent?.fragment ?? "nil")
call("post") { echo.post(withContent: "<x>body</x>".data(using: .utf8)) }
call("headers") {
    echo.request(with: HTTPPost, content: "payload".data(using: .utf8),
                 headers: ["X-Horos-Test": "yes", "Content-Type": "application/xml"])
}
call("status") { N2WebServiceClient(url: URL(string: base + "/missing")).post(withContent: Data()) }
call("empty") { N2WebServiceClient(url: URL(string: base + "/empty")).post(withContent: Data()) }
call("unreachable") { N2WebServiceClient(url: URL(string: "http://127.0.0.1:" + closed + "/x")).post(withContent: Data()) }
let started = Date()
call("timeout") { N2WebServiceClient(url: URL(string: base + "/slow")).post(withContent: Data()) }
emit("timeout.seconds", String(Int(Date().timeIntervalSince(started).rounded())))

// Off the main thread, as a plugin's worker would call it.
var background = ""
let finished = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    var result: Data?
    try? HorosObjCException.perform { result = echo.post(withContent: "bg".data(using: .utf8)) }
    background = result.map { String(data: $0, encoding: .utf8) ?? "" } ?? "nil"
    finished.signal()
}
emit("background.done", finished.wait(timeout: .now() + 30) == .success ? "yes" : "no")
emit("background", background)

// The redundant client goes on to the next URL when one fails, and stops at
// the first that answers: a POST that succeeded is not sent again.
let failover = N2RedundantWebServiceClient()
failover.urls = [URL(string: "http://127.0.0.1:" + closed + "/x")!, URL(string: base + "/refused")!,
                 URL(string: base + "/post-once")!, URL(string: base + "/echo")!]
call("redundant") { failover.post(withContent: "once".data(using: .utf8)) }
let none = N2RedundantWebServiceClient()
none.urls = [URL(string: "http://127.0.0.1:" + closed + "/x")!, URL(string: base + "/refused")!]
call("redundant.allFail") { none.post(withContent: Data()) }
call("redundant.noURLs") { N2RedundantWebServiceClient().post(withContent: Data()) }
'''

BRIDGE = r'''
#define HOROS_BRIDGING_HEADER 1
#import "N2WebServiceClient.h"
#import "HorosObjCException.h"
@interface N2Debug : NSObject
+ (BOOL)isActive;
@end
'''

results = {}
with tempfile.TemporaryDirectory(prefix='horos-n2-client-') as directory:
    folder = Path(directory)
    (folder / 'bridge.h').write_text(BRIDGE)
    (folder / 'n2debug.m').write_text('#import "bridge.h"\n@implementation N2Debug\n'
                                      '+ (BOOL)isActive { return NO; }\n@end\n')
    (folder / 'main.swift').write_text(DRIVER)
    includes = ['-iquote', str(root / 'Nitrogen/Sources'), '-iquote', str(root / 'Horos/Sources'),
                '-iquote', str(folder)]
    built = True
    for source, output in ((root / 'Horos/Sources/HorosObjCException.m', 'exception.o'),
                           (folder / 'n2debug.m', 'n2debug.o')):
        compiled = subprocess.run(['xcrun', 'clang', '-x', 'objective-c', '-fobjc-arc', *includes,
                                   '-c', str(source), '-o', str(folder / output)],
                                  capture_output=True, text=True)
        if compiled.returncode != 0:
            failures.append('%s does not compile:\n%s' % (source.name, compiled.stderr[-1200:]))
            built = False
    if built:
        compiled = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos',
                                   '-import-objc-header', str(folder / 'bridge.h'),
                                   *[flag for include in includes[1::2] for flag in ('-Xcc', '-iquote', '-Xcc', include)],
                                   str(client), str(redundant), str(folder / 'main.swift'),
                                   str(folder / 'exception.o'), str(folder / 'n2debug.o'),
                                   '-framework', 'Cocoa', '-o', str(folder / 'driver')],
                                  capture_output=True, text=True)
        if compiled.returncode != 0:
            failures.append('the clients do not compile:\n%s' % compiled.stderr[-2000:])
            built = False
    if built:
        run = subprocess.run([str(folder / 'driver'), base, str(closed)],
                             capture_output=True, text=True, timeout=120)
        if run.returncode != 0:
            failures.append('the driver failed: %s' % run.stderr[-800:])
        for line in run.stdout.splitlines():
            key, _, value = line.partition('\t')
            results[key] = value
server.shutdown()


def payload(key):
    value = results.get(key, '')
    if not value.startswith('data:'):
        failures.append('%s: expected data, got %r' % (key, value))
        return {}
    try:
        return json.loads(value[5:])
    except ValueError:
        failures.append('%s: not the echo: %r' % (key, value))
        return {}


if results:
    for key, value in results.items():
        if key.startswith('selector.') and value != 'yes':
            failures.append('the Objective-C selector %s is gone' % key[9:])

    get = payload('get')
    # A GET carries its parameters in the query, replacing the URL's own.
    if get and (get['method'], get['query'], get['body']) != ('GET', 'name=a%20b', ''):
        failures.append('the GET is not the one sent before: %r' % get)
    expected = {'key +&=': ["space é 日本 +%&=/?:#[]@!$'()*,;"], 'empty': ['']}
    for key, field in (('get.reserved', 'query'), ('post.reserved', 'body')):
        answer = payload(key)
        if parse_qs(answer.get(field, ''), keep_blank_values=True) != expected:
            failures.append('%s lost delimiters, Unicode or a literal plus/percent: %r' % (key, answer))
    fragment_answer = payload('get.fragment')
    if (parse_qs(fragment_answer.get('query', ''), keep_blank_values=True) != {'encoded': ['%20 +']}
            or results.get('get.fragment.value') != 'keep'):
        failures.append('composing GET changed fragment or decoded/encoded a value twice')
    if parse_qs(payload('get.rawQuery').get('query', ''), keep_blank_values=True) != {'raw': ['a b%']}:
        failures.append('a public GET query body with invalid URL characters was not normalized')
    post = payload('post')
    if post and (post['method'], post['query'], post['body'], post['contentType'], post['length']) != \
            ('POST', 'kept=1', '<x>body</x>', 'text/xml', '11'):
        failures.append('the POST is not the one sent before: %r' % post)
    headers = payload('headers')
    if headers and (headers['custom'], headers['contentType'], headers['body']) != \
            ('yes', 'application/xml', 'payload'):
        failures.append('the caller\'s headers are not sent over the defaults: %r' % headers)

    prefix = 'exception:NSGenericException:[N2WebServiceClient requestWithURL:method:parameters:content:headers:] '
    if results.get('status') != prefix + 'failed with status 404':
        failures.append('an HTTP refusal does not raise as before: %r' % results.get('status'))
    if results.get('empty') != 'data:':
        failures.append('an empty answer is not empty data: %r' % results.get('empty'))
    for key, code in (('unreachable', 'Code=-1004'), ('timeout', 'Code=-1001')):
        value = results.get(key, '')
        if not value.startswith(prefix + 'failed with error: ') or code not in value:
            failures.append('%s does not raise the transport error as before: %r' % (key, value))
    if not 9 <= int(results.get('timeout.seconds', '0')) <= 12:
        failures.append('the timeout is not the 10 s it was: %s s' % results.get('timeout.seconds'))

    if results.get('background.done') != 'yes' or '"body": "bg"' not in results.get('background', ''):
        failures.append('a call from a background thread does not complete: %r'
                        % results.get('background'))

    redundant_answer = payload('redundant')
    if redundant_answer.get('path') != '/post-once':
        failures.append('the redundant client did not stop at the first URL that answered: %r'
                        % redundant_answer)
    if hits['/post-once'] != 1:
        failures.append('the successful POST was sent %d times' % hits['/post-once'])
    if not results.get('redundant.allFail', '').startswith(prefix + 'failed with status 503'):
        failures.append('when every URL fails, the last failure is not the one raised: %r'
                        % results.get('redundant.allFail'))
    if 'has no URLs' not in results.get('redundant.noURLs', ''):
        failures.append('a redundant client with no URL does not say so: %r'
                        % results.get('redundant.noURLs'))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the N2 clients send the same requests over URLSession, raise the same exceptions, '
      'complete off the main thread, and the redundant one fails over without repeating a POST')
