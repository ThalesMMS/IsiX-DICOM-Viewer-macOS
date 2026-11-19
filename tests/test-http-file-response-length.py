#!/usr/bin/env python3
"""A response announces the length of the bytes it serves, also from a range's offset.

The portal used to answer through CocoaHTTPServer's response classes; its file
responses took the Content-Length from the attributes of the path, which
describe a symbolic link rather than its target, so a 1024 byte body was
announced as seven bytes and the rest ran into the next response of a
kept-alive connection. The classes are the application's now, under the names
the plugin SDK gave them: HTTPDataResponse, whose body is data (every portal
answer is a WebPortalResponse, a subclass: a file of the pages is read,
through its links, into it), and HTTPFileResponse, which reads a file as it is
sent. The SwiftNIO HTTPConnectionEngine sends both.

This compiles HTTPDataResponse.swift and HTTPFileResponse.swift, as they are,
against HTTPResponse.h and the engine's two response protocols, with the
address and undefined behaviour sanitizers, and checks on a synthetic file
reached by its path, through a relative link and through a link to a link:

- a data response of the file's bytes, and a file response of the path,
  announce the target's size, and reading to the end delivers exactly that, in
  pieces of any size;
- an offset set for a Range request reads from there and ends at the
  announced length; an offset past the end reads nothing;
- an empty response announces 0 and is done; a file response of a path that
  cannot be opened is nil;
- the header fields sent are those of -httpHeaders, as the portal's response
  answers it, and the Objective-C selectors of the SDK's HTTPResponse protocol
  answer the same as the engine's protocol.

What the engine sends with those lengths (Content-Length, Content-Range, the
multipart total) is tests/test-web-portal-http-policy.py.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
engine = (sources / 'HTTPConnectionEngine.swift').read_text()


def declaration(name):
    start = engine.find(f'protocol {name}: AnyObject {{')
    end = engine.find('\n}\n', start)
    if start < 0 or end < 0:
        print(f'FAIL: {name} is not where the test expects it in HTTPConnectionEngine.swift')
        sys.exit(1)
    return engine[start:end + 3]


HARNESS = r'''
import Foundation

PROTOCOLS

/// A response as the portal's: its header fields are a dictionary it answers
/// by -httpHeaders.
final class PortalResponse: HTTPDataResponse {
    @objc var httpHeaders: NSMutableDictionary! = NSMutableDictionary(dictionary: ["Content-Type": "application/dicom"])
}

func readThrough(_ response: HTTPServerResponse, _ body: Data, _ name: String) {
    let expected = body.count
    precondition(response.contentLength == UInt64(expected), "\(name) announced \(response.contentLength), the file has \(expected)")
    for size in [1, 7, 100, 4096, 1 << 20] {
        response.offset = 0
        var read = Data()
        while !response.isDone {
            let piece = response.readData(ofLength: size)!
            precondition(!piece.isEmpty, "\(name): an empty read before the end")
            read += piece
        }
        precondition(read == body, "\(name): reading in pieces of \(size) gave \(read.count) bytes")
    }
    response.offset = 1000
    var tail = Data()
    while !response.isDone { tail += response.readData(ofLength: 10)! }
    precondition(tail == body.subdata(in: 1000 ..< body.count) && response.offset == response.contentLength, "\(name): a read from an offset")
    response.offset = UInt64(expected + 10)
    precondition(response.readData(ofLength: 10)!.isEmpty, "\(name): a read past the end")
    precondition(!response.isChunked, "\(name) is chunked")
    precondition((response as? HTTPServerDeferredResponse)?.waitsForData == false, "\(name) waits for data")
}

let path = CommandLine.arguments[1]
let expected = Int(CommandLine.arguments[2])!
let body = FileManager.default.contents(atPath: path)!
precondition(body.count == expected)

let data: PortalResponse = PortalResponse(data: body)
readThrough(data, body, "a data response")
precondition(data.responseHeaderFields.contains { $0 == ("Content-Type", "application/dicom") }, "the header fields of -httpHeaders")
let plain: HTTPDataResponse = HTTPDataResponse(data: body)
precondition(plain.responseHeaderFields.isEmpty, "a data response of no header fields has some")

let file: HTTPFileResponse = HTTPFileResponse(filePath: path)
precondition(file.filePath() == path, "the path of a file response")
readThrough(file, body, "a file response")

// The selectors of the SDK's protocol, as a plugin sends them.
let object = file as AnyObject
typealias Length = @convention(c) (AnyObject, Selector) -> UInt64
typealias SetOffset = @convention(c) (AnyObject, Selector, UInt64) -> Void
typealias Read = @convention(c) (AnyObject, Selector, UInt32) -> Unmanaged<NSData>?
typealias Done = @convention(c) (AnyObject, Selector) -> ObjCBool
func method<T>(_ name: String, of object: AnyObject, as type: T.Type) -> T {
    let selector = NSSelectorFromString(name)
    precondition(object.responds(to: selector), "a file response does not answer \(name)")
    return unsafeBitCast(class_getMethodImplementation(object_getClass(object), selector), to: type)
}
precondition(method("contentLength", of: object, as: Length.self)(object, NSSelectorFromString("contentLength")) == UInt64(expected))
method("setOffset:", of: object, as: SetOffset.self)(object, NSSelectorFromString("setOffset:"), UInt64(expected - 3))
precondition(method("offset", of: object, as: Length.self)(object, NSSelectorFromString("offset")) == UInt64(expected - 3))
let last = method("readDataOfLength:", of: object, as: Read.self)(object, NSSelectorFromString("readDataOfLength:"), 100)?.takeUnretainedValue() as Data?
precondition(last == body.suffix(3) && method("isDone", of: object, as: Done.self)(object, NSSelectorFromString("isDone")).boolValue)

let empty: HTTPDataResponse = HTTPDataResponse(data: nil)
precondition(empty.contentLength == 0 && empty.isDone && empty.readData(ofLength: 10)!.isEmpty)
precondition((HTTPFileResponse(filePath: path + ".missing") as HTTPFileResponse?) == nil, "a file response of a missing file")
precondition((HTTPFileResponse(filePath: nil) as HTTPFileResponse?) == nil, "a file response of no path")
print("ok")
'''.replace('PROTOCOLS', declaration('HTTPServerResponse') + '\n' + declaration('HTTPServerDeferredResponse'))

with tempfile.TemporaryDirectory(prefix='horos-portal-response-length-') as work:
    work = Path(work)
    (work / 'main.swift').write_text(HARNESS)
    binary = work / 'harness'
    compiled = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-sanitize=address,undefined',
                               '-import-objc-header', str(sources / 'HTTPResponse.h'), '-o', str(binary),
                               str(work / 'main.swift'), str(sources / 'HTTPDataResponse.swift'),
                               str(sources / 'HTTPFileResponse.swift')], capture_output=True, text=True, timeout=300)
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
print('PASS: a data response and a file response announce their body\'s length, through links too, and read exactly '
      'that, from any range offset')
