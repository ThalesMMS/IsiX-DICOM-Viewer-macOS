#!/usr/bin/env python3
"""A portal response announces the length of the bytes it serves, also from a range's offset.

The portal used to answer through CocoaHTTPServer's response classes; its file
responses took the Content-Length from the attributes of the path, which
describe a symbolic link rather than its target, so a 1024 byte body was
announced as seven bytes and the rest ran into the next response of a
kept-alive connection. Those classes are gone: every portal answer is a
WebPortalResponse, whose body is data (a file of the pages is read, through
its links, into it), sent by the SwiftNIO HTTPConnectionEngine.

This compiles the HTTPServerResponse part of WebPortalResponse.swift, as it is,
with the address and undefined behaviour sanitizers, on a body read from a
synthetic file through a relative link and a link to a link, and checks:

- the announced length is the target's size, and reading to the end delivers
  exactly that, in pieces of any size;
- an offset set for a Range request reads from there and ends at the
  announced length; an offset past the end reads nothing;
- an empty response announces 0 and is done.

What the engine sends with those lengths (Content-Length, Content-Range, the
multipart total) is tests/test-web-portal-http-policy.py.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/WebPortalResponse.swift').read_text()
start = source.find('    // MARK: HTTPServerResponse')
end = source.find('    @objc public var tokens', start)
if start < 0 or end < 0:
    print('FAIL: the HTTPServerResponse part of WebPortalResponse.swift is not where the test expects it')
    sys.exit(1)
conformance = source[start:end]

HARNESS = r'''
import Foundation

protocol HTTPServerResponse: AnyObject {
    var contentLength: UInt64 { get }
    var offset: UInt64 { get set }
    func readData(ofLength length: Int) -> Data?
    var isDone: Bool { get }
    var isChunked: Bool { get }
    var responseHeaderFields: [(String, String)] { get }
    func connectionDidClose()
}

final class WebPortalResponse: NSObject, HTTPServerResponse {
    var mutableHTTPHeaders: NSMutableDictionary! = NSMutableDictionary(dictionary: ["Content-Type": "application/dicom"])
    private var dataStorage: Data?
    private var readOffset: UInt64 = 0
    init(data: Data?) { dataStorage = data }
CONFORMANCE
}

let path = CommandLine.arguments[1]
let expected = Int(CommandLine.arguments[2])!
let body = FileManager.default.contents(atPath: path)!
let response = WebPortalResponse(data: body)
precondition(response.contentLength == UInt64(expected), "announced \(response.contentLength), the file has \(expected)")
var read = Data()
for size in [1, 7, 100, 4096, 1 << 20] {
    response.offset = 0
    read = Data()
    while !response.isDone {
        let piece = response.readData(ofLength: size)!
        precondition(!piece.isEmpty, "an empty read before the end")
        read += piece
    }
    precondition(read == body, "reading in pieces of \(size) gave \(read.count) bytes")
}
response.offset = 1000
var tail = Data()
while !response.isDone { tail += response.readData(ofLength: 10)! }
precondition(tail == body.subdata(in: 1000 ..< body.count) && response.offset == response.contentLength)
response.offset = UInt64(expected + 10)
precondition(response.readData(ofLength: 10)!.isEmpty)
precondition(!response.isChunked && response.responseHeaderFields.contains { $0 == ("Content-Type", "application/dicom") })
let empty = WebPortalResponse(data: nil)
precondition(empty.contentLength == 0 && empty.isDone && empty.readData(ofLength: 10)!.isEmpty)
print("ok")
'''.replace('CONFORMANCE', conformance)

with tempfile.TemporaryDirectory(prefix='horos-portal-response-length-') as work:
    work = Path(work)
    (work / 'main.swift').write_text(HARNESS)
    binary = work / 'harness'
    compiled = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-sanitize=address,undefined', '-o', str(binary),
                               str(work / 'main.swift')], capture_output=True, text=True, timeout=300)
    if compiled.returncode != 0:
        print(compiled.stderr[-3000:])
        print('FAIL: the response harness did not compile')
        sys.exit(1)
    target = work / 'data' / 'payload.bin'
    target.parent.mkdir()
    target.write_bytes(os.urandom(4099))
    (work / 'link').symlink_to('data/payload.bin')
    (work / 'link-to-link').symlink_to('link')
    failures = []
    for name in ('data/payload.bin', 'link', 'link-to-link'):
        run = subprocess.run([str(binary), str(work / name), '4099'], capture_output=True, text=True, timeout=60)
        if run.returncode != 0 or run.stdout.strip() != 'ok':
            failures.append(f'{name}: {run.stdout.strip()} {run.stderr.strip()[-600:]}')
    if failures:
        for failure in failures:
            print('FAIL: ' + failure)
        sys.exit(1)
print('PASS: a portal response announces its body\'s length, through links too, and reads exactly that, from any range offset')
