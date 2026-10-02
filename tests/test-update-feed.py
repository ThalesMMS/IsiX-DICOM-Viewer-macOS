#!/usr/bin/env python3
"""Exercise the production Swift client with controlled URLSession responses."""
from pathlib import Path
import hashlib, plistlib, struct, subprocess, tempfile, ssl, threading, zipfile
from http.server import BaseHTTPRequestHandler
root = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(root / 'tools'))
from local_http import ThreadingLocalHTTPServer  # a fixture binds without the DNS (#647)
code = r'''
import Foundation
final class FeedProtocol: URLProtocol {
    static var responses: [String: (Int, Data?, NSError?)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result = Self.responses[request.url!.path]!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            if let error = result.2 { self.client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = result.1 { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
func plist(_ object: Any) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [FeedProtocol.self]
let session = URLSession(configuration: configuration)
let errors = [NSURLErrorServerCertificateUntrusted, NSURLErrorNotConnectedToInternet,
              NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorSecureConnectionFailed]
FeedProtocol.responses = [
 "/valid": (200, plist(["Horos":"12345"]), nil),
 "/http": (503, Data(), nil),
 "/html": (200, Data("<html>unavailable</html>".utf8), nil),
 "/missing": (200, plist(["Other":"12"]), nil),
 "/array": (200, plist(["123"]), nil),
 "/number": (200, plist(["Horos":123]), nil),
 "/junk": (200, plist(["Horos":"123junk"]), nil),
 "/overflow": (200, plist(["Horos":"99999999999999999999999"]), nil),
 "/zero": (200, plist(["Horos":"0"]), nil),
 "/negative": (200, plist(["Horos":"-10"]), nil),
 "/large": (200, Data(repeating: 0, count: 1_048_577), nil)
]
for e in errors { FeedProtocol.responses["/error\(e)"] = (0, nil, NSError(domain: NSURLErrorDomain, code: e)) }
var pending = FeedProtocol.responses.count + 1
var messages: [String:String] = [:]
var heartbeat = false
DispatchQueue.main.async { heartbeat = true }
let start = Date()
for path in FeedProtocol.responses.keys {
    UpdateFeedClient.check(url: URL(string:"https://fixture.invalid\(path)")!, session: session) { version, error in
        precondition(Thread.isMainThread && heartbeat)
        if path == "/valid" { precondition(version == "12345" && error == nil) }
        else { precondition(version == nil && error != nil); messages[path] = UpdateFeedClient.message(for:error!) }
        pending -= 1
    }
}
UpdateFeedClient.check(url: URL(string:"http://fixture.invalid/not-requested")!, session: session) { version, error in
 precondition(Thread.isMainThread && version == nil && error != nil)
 precondition(UpdateFeedClient.message(for:error!).contains("HTTPS"))
 pending -= 1
}
precondition(Date().timeIntervalSince(start) < 0.5, "network start must return without waiting")
let deadline = Date().addingTimeInterval(10)
while pending > 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(pending == 0)
let distinct = ["/http", "/html"] + errors.map { "/error\($0)" }
precondition(Set(distinct.map { messages[$0]! }).count == distinct.count)
precondition(messages["/http"]!.contains("503"))
for path in ["/missing", "/array", "/number", "/junk", "/overflow", "/zero", "/negative", "/large"] {
 precondition(messages[path] == messages["/html"])
}
let summary = UpdateFeedClient.summary(installedVersion: "4.0.0", build: "20201201", availableBuild: "20191217")
precondition(summary.contains("4.0.0 (build 20201201)") && summary.contains("20191217"))
precondition(summary.contains("ThalesMMS/horos stable releases") && summary.contains("Development changes and compatibility are not verified"))
session.invalidateAndCancel()
print("PASS: asynchronous concurrent responses, main-thread delivery, TLS/offline/HTTP/timeout/DNS distinctions, strict plist validation and HTTPS requirement")

// The archive is offered only as an asset of this fork's releases, with a size and a digest.
let asset = "https://github.com/ThalesMMS/horos/releases/download/v1/Horos.zip"
let digest = String(repeating: "ab", count: 32)
let whole: [String: Any] = ["Horos": "2026100200", "Version": "4.0.0", "MinimumSystemVersion": "26.1",
                            "ArchiveURL": asset, "ArchiveSize": 1234, "ArchiveSHA256": digest]
let release = UpdateRelease(feed: whole)!
precondition(release.archive == UpdateRelease.Archive(url: URL(string: asset)!, size: 1234, sha256: digest))
precondition(release.version == "4.0.0" && release.minimumSystemVersion?.majorVersion == 26 && release.minimumSystemVersion?.minorVersion == 1)
precondition(release.isNewer(than: "20220801") && release.isNewer(than: nil) && release.isNewer(than: "junk"))
precondition(!release.isNewer(than: "2026100200") && !release.isNewer(than: "2026100201"))
precondition(UpdateRelease(feed: ["Horos": "2026100200"])!.archive == nil)
let rejected: [[String: Any]] = [
    ["ArchiveURL": "http://github.com/ThalesMMS/horos/releases/download/v1/Horos.zip"],
    ["ArchiveURL": "https://github.com/Other/horos/releases/download/v1/Horos.zip"],
    ["ArchiveURL": "https://github.com.example.org/ThalesMMS/horos/releases/download/v1/Horos.zip"],
    ["ArchiveURL": "https://github.com/ThalesMMS/horos/releases/download/v1/../../../../Other/x.zip"],
    ["ArchiveURL": "https://github.com/ThalesMMS/horos/releases/download/v1/%2e%2e/x.zip"],
    ["ArchiveURL": asset + "?download=1"],
    ["ArchiveURL": "https://github.com/ThalesMMS/horos/releases/download/v1/Horos.dmg"],
    ["ArchiveURL": 7],
    ["ArchiveSize": 0], ["ArchiveSize": -5], ["ArchiveSize": (4 << 30) + 1], ["ArchiveSize": "1234"],
    ["ArchiveSHA256": String(repeating: "AB", count: 32)], ["ArchiveSHA256": String(repeating: "ab", count: 31)],
    ["ArchiveSHA256": String(repeating: "zz", count: 32)],
]
for change in rejected {
    let partial = UpdateRelease(feed: whole.merging(change) { $1 })!
    precondition(partial.build == "2026100200" && partial.archive == nil, "accepted \(change)")
}
precondition(UpdateRelease(feed: whole.merging(["MinimumSystemVersion": "26.x"]) { $1 })!.minimumSystemVersion == nil)
precondition(UpdateFeedClient.stableFeedURL.absoluteString == "https://github.com/ThalesMMS/horos/releases/latest/download/stable.plist")
print("PASS: release archive accepted only as an HTTPS asset of this fork with positive size and lowercase SHA-256; build comparison by integer")

// The feed the release script writes is the feed this client reads.
if CommandLine.arguments.count > 1 {
    let generated = NSDictionary(contentsOfFile: CommandLine.arguments[1]) as! [String: Any]
    let published = UpdateRelease(feed: generated)!
    precondition(published.build == "2026100203" && published.version == "4.0.0")
    precondition(published.minimumSystemVersion?.majorVersion == 26)
    precondition(published.archive?.url.absoluteString == "https://github.com/ThalesMMS/horos/releases/download/v4.0.0-test/Horos-4.0.0-test.zip")
    precondition(published.archive?.size == Int64(CommandLine.arguments[2])! && published.archive?.sha256 == CommandLine.arguments[3])
    precondition(generated["Architectures"] as? [String] == ["arm64"] && generated["ReleaseTag"] as? String == "v4.0.0-test")
    print("PASS: stable.plist written from a release archive carries its build, address, size and SHA-256")
}
'''
with tempfile.TemporaryDirectory(prefix='horos-update-feed-') as directory:
    p = Path(directory)
    (p/'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', str(root/'Horos/Sources/UpdateFeedClient.swift'), str(p/'main.swift'), '-o', str(p/'test')], check=True)
    # A synthetic release archive: one application with an arm64 Mach-O header.
    archive = p/'Horos-4.0.0-test.zip'
    with zipfile.ZipFile(archive, 'w') as bundle:
        bundle.writestr('Isis DICOM Viewer.app/Contents/Info.plist', plistlib.dumps({
            'CFBundleIdentifier': 'thalesmms.isis.workstation', 'CFBundleExecutable': 'Isis DICOM Viewer',
            'CFBundleVersion': '2026100203', 'CFBundleShortVersionString': '4.0.0', 'LSMinimumSystemVersion': '26.0'}))
        bundle.writestr('Isis DICOM Viewer.app/Contents/MacOS/Isis DICOM Viewer', struct.pack('<II', 0xfeedfacf, 0x0100000c) + bytes(24))
        bundle.writestr('Isis DICOM Viewer.app/Contents/PlugIns/Nested.app/Contents/Info.plist', plistlib.dumps({}))
    tool = [sys.executable, str(root/'script/release-metadata.py'), '--update-feed']
    subprocess.run(tool + ['v4.0.0-test', str(root), str(archive)], check=True, stdout=subprocess.DEVNULL)
    assert subprocess.run(tool + ['v4.0.0 test', str(root), str(archive)], capture_output=True).returncode != 0
    (p/'empty.zip').write_bytes(b'')
    assert subprocess.run(tool + ['v4.0.0-test', str(root), str(p/'empty.zip')], capture_output=True).returncode != 0
    subprocess.run([str(p/'test'), str(p/'stable.plist'), str(archive.stat().st_size),
                    hashlib.sha256(archive.read_bytes()).hexdigest()], check=True)

# Exercise the production URLSession (including default certificate validation),
# not the injected protocol, against an untrusted loopback HTTPS endpoint.
with tempfile.TemporaryDirectory(prefix='horos-update-tls-') as directory:
    p = Path(directory)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=localhost', '-keyout', str(p/'key.pem'), '-out', str(p/'cert.pem')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'not reached with an untrusted certificate')
        def log_message(self, *args):
            pass
    server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(p/'cert.pem'), str(p/'key.pem'))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    (p/'main.swift').write_text(r'''import Foundation
var done = false
UpdateFeedClient.check(url: URL(string: CommandLine.arguments[1])!) { version, error in
    precondition(Thread.isMainThread && version == nil)
    let error = error!
    precondition(error.domain == NSURLErrorDomain && error.code == NSURLErrorServerCertificateUntrusted, "Unexpected TLS error: \(error)")
    precondition(UpdateFeedClient.message(for: error).contains("certificate could not be verified"))
    done = true
}
let deadline = Date().addingTimeInterval(15)
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(done)
print("PASS: real loopback HTTPS certificate rejected by the production session")
''')
    try:
        subprocess.run(['xcrun', 'swiftc', str(root/'Horos/Sources/UpdateFeedClient.swift'), str(p/'main.swift'), '-o', str(p/'test')], check=True)
        subprocess.run([str(p/'test'), f'https://127.0.0.1:{server.server_port}/feed'], check=True, timeout=20)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
